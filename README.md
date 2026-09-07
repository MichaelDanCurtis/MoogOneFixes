# Moog One — defect reports and fixes

Findings from working on a Moog One (firmware ~v1.2/v1.3) over its own network
interface, with reproductions and, where the code is reachable, patches.

Sent to Moog rather than published. Where a fix lands in open-source code that
Moog ship (`sc3-plugins`, SuperCollider) it is a patch against the upstream
source. Where it lands in proprietary parts it is a **script that applies the
change on the device**, because the source is not ours to modify or to hold.

Nothing here contains Moog's source. Diff context is kept to the few lines needed
to locate a change.

## How to read the status labels

Every finding carries one, and they are not decoration.

| label | means |
|---|---|
| **CONFIRMED** | reproduced deliberately, in isolation, with everything else stopped |
| **OBSERVED** | seen and logged, not yet reproduced on demand |
| **HYPOTHESIS** | mechanism proposed and the test that would settle it named, but not run |
| **RETRACTED** | investigated, and it is not a defect — kept because the reasoning is worth having |

There is a retracted entry in `BUGS.md`. It is there on purpose: it was a
plausible reading of Moog's own source that a five-minute measurement disproved,
and leaving it out would misrepresent how much of the rest was checked.

## Layout

```
BUGS.md      the findings
patches/     unified diffs against upstream open-source projects
scripts/     changes applied on the device, for proprietary parts
repro/       standalone reproductions
evidence/    kernel logs and captures taken from a running unit
```

## Running anything here

`scripts/apply.sh` is **dry-run by default**. It prints what it would change and
exits. `--apply` performs the change and backs up whatever it replaces first.

One reproduction, `repro/usb-burst-wedge.md`, ends with an instrument that needs
its power removed. It is documented rather than scripted for that reason.
