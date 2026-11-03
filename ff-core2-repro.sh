#!/usr/bin/env bash
# ff-core2-repro.sh — reproduce the Moxfield/WebRender crash on physical core 2.
#
# Default: all Firefox processes are pinned to CPUs 2 and 8 (SMT siblings of
# physical core 2), using a fresh profile and a dedicated crash directory.
#
# Control run:
#   CPUS=0,6 PROFILE=$HOME/ff-control-profile CRASHDIR=$HOME/ff-control-crashes \
#     ./ff-core2-repro.sh
#
# This does NOT make the test safe. It can crash Firefox or corrupt data on a
# machine that is not disposable. Use a fresh profile; never log into important
# accounts; keep backups.
#
set -euo pipefail

CPUS="${CPUS:-2,8}"
PROFILE="${PROFILE:-$HOME/ff-core2-profile}"
CRASHDIR="${CRASHDIR:-$HOME/ff-core2-crashes}"
URL="${URL:-https://moxfield.com/decks}"

command -v firefox-esr >/dev/null || {
  echo "firefox-esr not found" >&2
  exit 1
}

IFS=',' read -ra cpu_list <<< "$CPUS"
for c in "${cpu_list[@]}"; do
  if [[ "$(cat "/sys/devices/system/cpu/cpu${c}/online" 2>/dev/null || echo 0)" != 1 ]]; then
    echo "CPU $c is offline; bring it online before testing." >&2
    exit 1
  fi
done

mkdir -p "$PROFILE" "$CRASHDIR"
cd "$CRASHDIR"
ulimit -c unlimited || true

cat <<EOF
Firefox ESR core-2 reproducer
  affinity : $CPUS
  profile  : $PROFILE
  crashes  : $CRASHDIR
  URL      : $URL
  core     : pattern=$(cat /proc/sys/kernel/core_pattern), limit=$(ulimit -c)

Verify all Firefox processes stay on the intended CPUs:
  pgrep -af 'firefox-esr.*ff-'
  for p in \$(pgrep -f '/usr/lib/firefox-esr/firefox-esr'); do taskset -pc \$p; done

After a crash:
  coredumpctl list | grep -i firefox | tail
  ls -lh "$CRASHDIR"
  ls -lh "$PROFILE/minidumps" 2>/dev/null || true
  # Firefox: about:crashes
EOF

exec taskset -c "$CPUS" firefox-esr --no-remote --new-instance --profile "$PROFILE" "$URL"
