# Firefox ESR / Crash on Ryzen Core 2

## Related Issue

[webcompat/web-bugs#238716](https://github.com/webcompat/web-bugs/issues/238716)

## Initial Symptoms

- Firefox becomes unresponsive while interacting with or refreshing Moxfield.
- The affected Firefox process can reach **100% CPU usage**.
- Keyboard shortcuts and other user interactions stop responding.
- The freeze occurs in Firefox's native **Gecko/WebRender rendering code**, rather than directly inside Moxfield's JavaScript.
- The main thread is occupied with hash-table iteration during a painting operation.
- The lack of keyboard responsiveness is consistent with main-thread blockage.
- Disabling hardware acceleration does not eliminate the affected native rendering path.

**Important:** The profiling evidence does not establish whether Moxfield's page content, a browser extension, or an internal Firefox defect originally triggered the condition.

## Technical Analysis

### 1. Initial Profiling

The original Firefox performance profile identified the following rendering call chain:

```text
GeckoMain
 └─ PVsync::Msg_Notify
    └─ RefreshDriver tick
       └─ Update rendering / Paint
          └─ nsLayoutUtils::PaintFrame
             └─ nsDisplayList::PaintRoot
                └─ WebRender display list
                   └─ libxul.so [unsymbolicated]
```

The initial profile pointed to Firefox's rendering pipeline but lacked sufficient symbol information to identify the specific internal operations consuming CPU time.

### 2. Re-Symbolicated Profile

After re-symbolication, the performance profile revealed a more precise call stack:

```text
nsRefreshDriver::PaintIfNeeded()
 └─ nsLayoutUtils::PaintFrame()
    └─ nsDisplayList::PaintRoot()
       └─ WebRenderCommandBuilder::BuildWebRenderCommands()
          └─ RemoveUnusedAndResetWebRenderUserData()
             └─ nsTBaseHashSet::RemoveIf()
                └─ nsTHashtableKeyIterator::operator++()
                   └─ PLDHashTable::Iterator::Next()
                      └─ PLDHashTable::Iterator::MoveToNextLiveEntry()
```

### 3. Suspected Bottleneck

The re-symbolicated profile provides evidence of a performance bottleneck in Firefox's WebRender user-data cleanup path.

The relevant operations are:

1. **Rendering:** `nsRefreshDriver::PaintIfNeeded()` initiates a painting operation.
2. **Display-list construction:** `WebRenderCommandBuilder::BuildWebRenderCommands()` prepares rendering commands.
3. **User-data cleanup:** `RemoveUnusedAndResetWebRenderUserData()` processes WebRender-associated data.
4. **Hash-table filtering:** `nsTBaseHashSet::RemoveIf()` iterates through entries for potential removal.
5. **Hash-table traversal:** `PLDHashTable::Iterator::MoveToNextLiveEntry()` appears in the CPU-intensive execution path.

These observations suggest that excessive processing during hash-table traversal or cleanup may be responsible for the main-thread stall.

However, the profile alone does not prove whether the underlying cause is an unusually large data structure, pathological iteration behavior, excessive repeated cleanup, or another upstream rendering condition.

## Impact

When the main thread is blocked, Firefox may fail to process:

- Keyboard input and shortcuts.
- Mouse interactions.
- Page refresh requests.
- Other main-thread browser operations.

The issue persists with hardware acceleration disabled, indicating that disabling GPU acceleration alone is insufficient to avoid the affected code path.

## Fix and Build Verification

A proposed fix, together with build and verification instructions, is documented here:

**[Fix download and Firefox ESR build verification guide](https://chatgpt.com/share/6adf294e-3a50-83eb-8112-2c182eebb99e)**

The linked instructions should be used to obtain the proposed changes, build Firefox ESR, and evaluate whether the modification resolves the freeze.

The proposed fix should be considered experimental until its behavior is verified against a reproducible baseline.

## Status

**Investigation:** Native rendering bottleneck identified through Firefox performance profiling.

**Root cause:** Not conclusively established.

**Fix:** Proposed; validation required.

**Affected components:** Gecko, WebRender, display-list construction, and hash-table iteration.

## Status Update - 19.56 27 Oct

Navigating Moxfield with the [CPUs that affect the users experience behavior](https://github.com/scripting-drafts/CPU-Stress-Tests/tree/main) display the following results:

| Property | CPU 2 crash | CPU 8 crash |
|---|---|---|
| **Process** | Isolated Web Content | Isolated Web Content |
| **Faulting function** | `SnowWhiteKiller::Visit` | `CustomEvent_Binding::get_detail` |
| **Subsystem** | Cycle collector | DOM / JavaScript |
| **Fault type** | General protection fault | Invalid memory write |
| **Last page** | `/decks` | `/playtest` |
| **Physical core** | 2 | 2 |

Without the mentioned CPUs, it is confirmed that Moxfield can drive heavy parallel rendering activity without causing Firefox to hang.

```text
taskset -c 0,1,3-7,9-11 firefox-esr --no-remote
```

```text
Average CPU: 108.1%
Peak over 1 second: 246.2%
Capture duration: 5.82 s
```

### Steps for testing Moxfield on CPUs that don't trigger Cycle Collector nor DOM / Javascript faults
 - Finding the exact threads using the CPU
 - Refining a Firefox Profiler values
 - Testing wether DOM mutations are excessive
 - Running controlled isolation tests

Affinity mask:

```text
Allowed:  0,1,3,4,5,6,7,9,10,11
Excluded: 2,8
```

Anecdotical test results:

| Measurement | Result |
|---|---|
| SHA-256 canary checks | Approximately 460,000 across 10 CPUs |
| Integrity mismatches | 0 |
| CPU thermal maximum (`Tccd1`) | 72.0°C |
| CPU control temperature maximum (`Tctl`) | 68.1°C |
| Average utilization per permitted CPU | 9.7–12.6% |
| Firefox average aggregate CPU usage | Approximately 45% of one logical CPU |
| Peak sampled Firefox CPU usage | Approximately 499% across multiple threads |

## Status Update - 10.26 28 Oct

Evidence demonstrates a single-bit discrepancy in an array index, not yet definitive proof that physical CPU core 2 flipped the bit.

### Firefox crash observation — alleged bit flip

| Property | Observed value |
|---|---|
| Function | `mozilla::detail::nsDequeBase::PopFront()` |
| Source file | `xpcom/ds/nsDeque.cpp` |
| Reported source line | 208 |
| Subsystem | Gecko cycle collector |
| Faulting instruction | `mov (%rdx,%rcx,8),%rax` |
| Expected index | `0x0019B707` |
| Index in RCX | `0x0119B707` |
| XOR difference | `0x01000000` |
| Divergent bit | 24 |
| Signal | `SIGSEGV` |

### Bitflip
```text
Expected: 0x0019B707
Observed: 0x0119B707
          ----------
XOR:      0x01000000 = 2^24
```

### Index memory read
```text
RDX = 0x7f4a29600000
RCX = 0x0119b707

Instruction:
mov (%rdx,%rcx,8),%rax

Calculated address:
0x7f4a29600000 + (0x0119b707 × 8)
= 0x7f4a322db838
```

TLDR; The processor attempted to read a location outside the allocated deque because the effective index contained an additional set bit


### Involved parts of the code
```text

void* nsDequeBase::PopFront() {
    void* result = nullptr;

    if (mSize > 0) {
        NS_ASSERTION(mOrigin < mCapacity, "Error: Bad origin");

        result = mData[mOrigin];
        mData[mOrigin++] = nullptr;

        mSize--;

        if (mCapacity == mOrigin || !mSize) {
            mOrigin = 0;
        }
    }

    return result;
}
```
[Relevant implementation in the Firefox-ESR branch](https://github.com/mozilla-firefox/firefox/blob/esr140/xpcom/ds/nsDeque.cpp?utm_source=chatgpt.com)

The following invariant check leads to an ambivalent RCA:
```text
NS_ASSERTION(mOrigin < mCapacity, "Error: Bad origin");
```

- Memory corruption: ***If mOrigin is already corrupted in memory***, an explicit release-build bounds check could detect that invalid state.
- CPU register corruption: ***If mOrigin is valid in memory but the CPU produces an incorrect index register after loading it***, a check performed earlier may not prevent the subsequent invalid access.

The second possibility is particularly interesting because the register discrepancy corresponds to exactly one bit.

### A catch up of the observed crash locations fit the bitflip hypothesis
| Crash location | Subsystem | Interpretation |
|---|---|---|
| `nsDequeBase::PopFront` | Cycle collector traversal | Confirmed invalid indexed memory access |
| `SnowWhiteKiller::Visit` | Cycle collector cleanup | Could involve corrupted pointers or object lifetime |
| `CustomEvent_Binding::get_detail` | DOM / JavaScript | Invalid memory write; cause unresolved |

***Observation***: Firefox can deliberately terminate a process for security reasons when it detects an unsafe internal state. In fact, Firefox already uses this strategy in some situations. Mozilla documents controlled crashes through MOZ_CRASH and MOZ_RELEASE_ASSERT, as well as deliberate termination of content processes that send invalid IPC messages.

### Crashes overview
| Crash location | Security rationale for termination | Observed cause |
|---|---|---|
| `nsDequeBase::PopFront` | Yes. Prevent further use of a corrupted deque | No. Observed invalid memory access |
| `SnowWhiteKiller::Visit` | Yes. Avoid continuing with potentially corrupted object references | Not established |
| `CustomEvent_Binding::get_detail` | Yes. Stop further execution after an invalid memory write | Not established |
| `CompositorBridgeChild` abnormal IPC shutdown | Yes. Isolating a failed child process limits damage | Generally a consequence of process failure, not evidence of its original cause |

## A defensive proposal to bear with security faults

### Current code
```text
NS_ASSERTION(mOrigin < mCapacity, "Error: Bad origin");
result = mData[mOrigin];
```

### The following code would make Firefox shutdown gracefully if the invalid index is already detectable at the NS_ASSERTION check
```text
MOZ_RELEASE_ASSERT(
    mOrigin < mCapacity,
    "Corrupted deque index"
);

result = mData[mOrigin];
```

### Conclusion 10.59 28 Oct
The safest strategy is not to make Firefox ignore errors. It is to combine hardware isolation with intentional process termination when corruption is detected.
