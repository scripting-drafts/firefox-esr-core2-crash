#!/usr/bin/env bash
# verify-core2-live.sh
#
# Run ONLY from a live USB / disposable OS. It refuses to run when / is on
# the internal NVMe, because stressing the suspect core on the installed
# system can panic the machine or silently corrupt data.
#
# Tests physical core 2 (logical CPUs 2 and 8) against control core 0 (CPUs 0,6).
# stress-ng is a screen, not a known-answer test. For confirmation, also run
# mprime/Prime95 Small FFTs in the same live session.
#
# Usage:
#   DURATION=45m LOGDIR=/media/$USER/LOGS/core2 ./verify-core2-live.sh
#
set -euo pipefail

DURATION="${DURATION:-45m}"
LOGDIR="${LOGDIR:-/tmp/core2-verify-$(date +%Y%m%d-%H%M%S)}"
SUSPECT_CPUS="2,8"
CONTROL_CPUS="0,6"
TEMP_LIMIT="${TEMP_LIMIT:-90}"

# --- safety guard: refuse to run on the installed system -------------------
ROOT_SRC="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
if [[ "$ROOT_SRC" == /dev/nvme* ]]; then
  echo "REFUSING: / is on '$ROOT_SRC' (internal disk)." >&2
  echo "Boot a live USB and run this there. Do not stress core 2 on the live host." >&2
  exit 1
fi

if ! mountpoint -q /cdrom 2>/dev/null && ! ls /cdrom/casper/filesystem.squashfs >/dev/null 2>&1; then
  echo "WARNING: /cdrom/casper not found; this may not be an Ubuntu live session." >&2
  read -r -p "Type LIVE to continue anyway: " ans
  [[ "$ans" == LIVE ]] || exit 1
fi

for t in taskset stress-ng sensors; do
  command -v "$t" >/dev/null || {
    echo "Missing: $t" >&2
    echo "Install with: sudo apt install stress-ng lm-sensors util-linux" >&2
    exit 1
  }
done

for c in 2 8 0 6; do
  [[ "$(cat /sys/devices/system/cpu/cpu$c/online 2>/dev/null || echo 0)" == 1 ]] || {
    echo "CPU $c is offline. A live boot should bring it online." >&2
    exit 1
  }
done

mkdir -p "$LOGDIR"
exec > >(tee -a "$LOGDIR/run.log") 2>&1

echo "=== Core 2 verification ==="
date -Is
echo "Root source : $ROOT_SRC"
echo "Log dir     : $LOGDIR"
echo "Duration    : $DURATION per core"
echo "Control     : CPUs $CONTROL_CPUS (physical core 0)"
echo "Suspect     : CPUs $SUSPECT_CPUS (physical core 2)"
echo
lscpu -e=CPU,CORE,SOCKET,ONLINE,MAXMHZ,MINMHZ
echo
echo "Suspect siblings: $(cat /sys/devices/system/cpu/cpu2/topology/thread_siblings_list)"
echo "Control siblings: $(cat /sys/devices/system/cpu/cpu0/topology/thread_siblings_list)"
grep -m1 '^microcode' /proc/cpuinfo || true
echo

# --- temperature watchdog ---------------------------------------------------
(
  while true; do
    tctl="$(sensors 2>/dev/null | awk '$1=="Tctl:" {gsub(/[+°C]/,"",$2); print $2; exit}')"
    if [[ -n "$tctl" ]]; then
      echo "$(date -Is) Tctl=$tctl" >> "$LOGDIR/temps.log"
      if awk -v t="$tctl" -v l="$TEMP_LIMIT" 'BEGIN{exit !(t>l)}'; then
        echo "TEMP ABORT: Tctl=$tctl > $TEMP_LIMIT" | tee -a "$LOGDIR/run.log"
        pkill -TERM -f 'stress-ng --cpu 2' || true
      fi
    fi
    sleep 5
  done
) &
WATCHDOG=$!

# --- MCE logger -------------------------------------------------------------
journalctl -kf --no-pager 2>/dev/null \
  | grep --line-buffered -iE 'mce|machine check|hardware error|corrected|uncorrected' \
  >> "$LOGDIR/mce.log" &
MCE_PID=$!

cleanup() {
  kill "${WATCHDOG:-}" "${MCE_PID:-}" 2>/dev/null || true
}
trap cleanup EXIT

run_test() {
  local name="$1" cpus="$2"
  echo "=== $name: CPUs $cpus, $DURATION ==="
  set +e
  taskset -c "$cpus" stress-ng --cpu 2 --cpu-method all --verify \
    --metrics-brief --timeout "$DURATION" --log-file "$LOGDIR/$name-stress.log"
  local rc=$?
  set -e
  echo "$name exit=$rc"
  return "$rc"
}

# Control first, then suspect. Never concurrent.
run_test control "$CONTROL_CPUS" || true
run_test suspect "$SUSPECT_CPUS" || true

echo
echo "=== Done ==="
echo "Review:"
echo "  $LOGDIR/control-stress.log"
echo "  $LOGDIR/suspect-stress.log"
echo "  $LOGDIR/mce.log"
echo "  $LOGDIR/temps.log"
echo
grep -iE 'error|fail|verify|abort' "$LOGDIR"/*.log 2>/dev/null || true
echo
echo "Any verification failure or MCE only in the suspect run is a positive signal."
echo "No errors is NOT proof the core is good; run longer or use mprime Small FFTs."
