# Findings

Ordered by severity. Firmware ~v1.2/v1.3; `scsynth` running as

```
scsynth -u 57110 -a 129 -i 9 -b 1026 -z 128 -Z 128 -m 100000 -w 128 -S 48000 -R 0 -C 0 -l 1
```

---

## 1. `/n_free` on a LADSPA effect synth faults inside `eventide_plate.so` — CONFIRMED

**Impact.** The audio engine dies. The instrument keeps running and its screen and
controls respond, but it produces no digital effects until the service is
restarted. Reachable from any OSC client that can talk to port 57110.

**Intermittent, and that matters for reproducing it.** It is not one-shot. In the
run that produced the fault below, the first `/n_free` completed cleanly and the
second crashed the server. An earlier session hit it twice out of two in
isolation, and twice more by accident. `repro/ladspa_free_crash.py` therefore
retries rather than giving up after one attempt.

**Reproduction.** On a freshly booted unit, with nothing else running:

```
/s_new  "et_plate_1" <node> 0 0 "inBus" 100.0 "outBus" 102.0
/sync
/n_free <node>            # repeat until the server stops answering
```

Buses above 63 are unused by the instrument's own graph, so the effect processes
nothing of the user's and no patch is modified.

**The fault.** Captured with `kernel.print-fatal-signals = 1`, and the process's
`/proc/<pid>/maps` saved beforehand, because the mapping dies with the process:

```
potentially unexpected fatal signal 11.
CPU: 1 PID: 1337 Comm: scsynth Tainted: G        W       4.1.15-rt18 #1
PC is at 0x757d6bd6
LR is at 0x757dcb75
Flags: nzcv  IRQs on  FIQs on  Mode USER_32  ISA Thumb  Segment user
```

Against the saved map, `eventide_plate.so` is mapped `757b2000-75815000 r-xp`:

| register | address | library | file offset |
|---|---|---|---|
| PC | `0x757d6bd6` | `/usr/lib/ladspa/eventide_plate.so` | **+0x24bd6** |
| LR | `0x757dcb75` | `/usr/lib/ladspa/eventide_plate.so` | **+0x2ab75** |

**Both the faulting instruction and its return address are inside
`eventide_plate.so`.** The crash is in the Eventide plugin's own code, reached
through `LadspaUGen`'s destructor, which calls `deactivate()` and then `cleanup()`
on the plugin handle. It is not in `LadspaUGen.so` and not in `scsynth`.

Those two offsets should resolve to functions immediately against an unstripped
build. Full log in `evidence/segv-eventide-plate.txt`.

**Why it is never hit in normal use.** `efx_server.scd` creates the five effect
slots once during `waitForBoot` and stops them with `enable = 0` — whose envelope
is `EnvGen.kr(Env.asr(0.1, 1, 2), enable, doneAction: 1)`, and doneAction 1 is
*pause*. Nothing in the shipped firmware ever frees one, so `deactivate()` and
`cleanup()` are entry points the product never calls.

**`patches/0001-ladspa-null-handle.patch` does NOT fix this, and is offered
anyway.** It fixes a real and separate defect in the same destructor path:
`LADSPA_Ctor` assigns `unit->desc` *before* calling `instantiate()`, never checks
the result — which the LADSPA specification explicitly permits to be NULL — and
the destructor guards `desc` rather than `handle`. A unit whose instantiate failed
therefore reaches `deactivate(NULL)` and `cleanup(NULL)`, and the same NULL handle
is passed to `connect_port()` and `activate()` in the constructor. That is not
what happened here: the effect had instantiated successfully and was audibly
processing audio, so its handle was valid.

---

## 2. Burst network traffic wedges the `2662:800d` USB gadget — CONFIRMED

**Impact.** The instrument leaves the network *and* loses its internal link to the
voice controller. Only removing power clears it. Reproducible on demand.

**Mechanism.** `2662:800d`, product string "LAS internal", presents four
interfaces: `usbint` (the voice controller) on `2-1:1.0`/`1.1`, and `ethext` (the
LAN) on `2-1:1.2`/`1.3`. **They are two CDC-Ether functions of one gadget**, so
traffic aimed at the LAN can take out the instrument's own internal bus.

Measured by stepping a paced load up and then sending the same datagrams unpaced:

| shape | rate | result |
|---|---|---|
| paced, 25→550 datagrams/s of 1308 B | 719 kB/s, 1.47× realtime 48 kHz stereo | untroubled: zero drops, zero errors, memory flat |
| unpaced, 2000 datagrams back to back | 18 ms, ~145 MB/s, 296× realtime | wedged before the burst finished |

Identical size, port and destination. Only the spacing differed.

**What the kernel says.** Logged to `/var`, because the log has to outlive the
network:

```
[467.013682] NETDEV WATCHDOG: usbint (cdc_ether): transmit queue 0 timed out
[491.910429] usb 2-1: can't set config #1, error -71
```

The first names **`usbint`** — flooding the LAN stalls the *voice controller's*
transmit queue. The second is after unbinding and rebinding the device to force
re-enumeration: `-71` is `EPROTO`, the gadget refusing `SET_CONFIGURATION`. It is
wedged below the level the host can reach. At the moment of the wedge `MemFree`
was normal and `rx_dropped`/`rx_errors` were both zero — it is not memory
exhaustion and the driver never discarded a packet. It simply stopped answering.

**No fix offered.** Neither XMOS firmware image on the device contains a USB
descriptor table or string descriptors, so the gadget stack is not in either of
them and is not reachable from here. `repro/usb-burst-wedge.md` documents the
reproduction; it is deliberately not a script.

---

## 3. `scsynth` neither handles nor ignores `SIGPIPE` — CONFIRMED

**Impact.** Any write to a pipe or socket whose reader has gone away terminates
the audio engine, with the same consequence as finding 1.

**Evidence**, read from `/proc/<scsynth>/status`:

```
SigIgn: 0000000000000004      (SIGQUIT alone)
SigCgt: 0000000180000000      (pthread internals)
```

Bit 12 is in neither mask, so the default action applies and the default action
for `SIGPIPE` is terminate.

**How it was hit.** `/b_write` to a FIFO, `DiskOut` streaming into it, and the
process on the other end exited. The engine died instantly. Any host application
that streams from the instrument and then quits reproduces it.

**Fix.** `patches/0002-scsynth-ignore-sigpipe.patch`. A daemon that writes to
sockets and pipes should not die of `SIGPIPE`; the write should fail with `EPIPE`
and be handled locally. This is upstream SuperCollider, not Moog code, but Moog
build and ship the binary.

---

## 4. `sched: RT throttling activated` — OBSERVED

**Impact.** The kernel forcibly deschedules `scsynth`'s realtime thread, which is
an audio dropout.

`scsynth` runs `SCHED_FIFO`. Linux caps realtime tasks at
`sched_rt_runtime_us`/`sched_rt_period_us`, 950000/1000000 by default — 95% of
each period. Exceed it and the throttle fires. Logged once, 17 minutes after boot,
on a unit doing nothing unusual.

**Fix.** `scripts/apply.sh rt-throttle` raises the budget, with the tradeoff
stated in the script: an unbounded realtime budget means a spinning RT thread can
lock the machine out, so this is a decision for whoever owns the product rather
than a default anyone should apply blindly.

---

## 5. `imx-ipuv3` display-controller fault — OBSERVED

```
[12844.843490] imx-ipuv3 2400000.ipu: IPU Warning - IPU_INT_STAT_10 = 0x00080000
```

**It recurs.** `dmesg` holds only the current boot, and `/var/log/messages` shows
it has happened on more than one:

```
Sep  7 12:26:54  IPU Warning - IPU_INT_STAT_10 = 0x00080000
Sep  7 12:26:54  IPU Warning - IPU_INT_STAT_5  = 0x00800000
Sep  7 18:04:49  IPU Warning - IPU_INT_STAT_10 = 0x00080000
```

Two separate events on two different boots, and the first raised a second error
register alongside it. `INT_STAT_10` and `INT_STAT_5` are IPU error-interrupt
registers. The 18:04 one is the last kernel message before a reported UI lock-up.

**A scheduling detail that may or may not be related, offered because it is
cheap to check.** `S99final` puts the IPU threads on `SCHED_FIFO` at priority 93
via `chrt -f -p`, directly below `scsynth` at 94:

```
  prio 94  scsynth
  prio 93  ipu1_task  (x2)
  prio 89  irq/26-esai
  prio 80  irq/297-2400000, irq/298-2400000
```

Realtime tasks share one budget, and this unit logged `sched: RT throttling
activated` (finding 4). Display and audio are adjacent priorities drawing on the
same throttled budget.

At the time: network responsive, `scsynth` answering normally with a full effects
graph, no process in uninterruptible sleep, no OOM kill, `las-frontend` consuming
about 36% of a core. So whatever stopped was **not** the audio engine and not the
network.

Reported as an observation, not a diagnosis. One sighting, not reproduced, and the
correlation with the lock-up is timing alone. Full log in
`evidence/dmesg-ipu-fault.txt`.

---

## 6. `/etc/init.d/S42sc` stop/start asymmetry — NEEDS ONE CONTROLLED TEST

`stop()` kills `sclang`, `jackd`, `scsynth` and `las-sc`. `start()` runs only
`las-sc`. On its face `restart` should leave a control layer with no audio engine.

Against that: `S42sc restart` was used three times on a running unit and the
engine came back each time — though one of those returned a `scsynth` reporting
**0 synths with 105 synthdefs loaded**, i.e. running with no effects graph built.

**Not claimed as a defect until that test is run**, because a fix for a bug that
is not there is worse than no report.

---

## 7. Service mode gives unauthenticated root over the network — CONFIRMED

**Not a shipped default, and the distinction matters.** A stock unit runs no SSH
at all. `S50dropbear` starts the daemon *only* when a key file is present:

```sh
if [ -e /media/thumbdrive/k ]; then
    keyval=`hexdump /media/thumbdrive/k | awk '{print $3 $2}'`
    if [ $keyval = 23051934 ]; then
        ... start-stop-daemon -S -q ... --exec /usr/sbin/dropbear ...
```

**But `/etc/shadow` ships with the root password empty** — the file is dated
2022-05-16, i.e. build time, and the entry is `root::10933:0:99999:7:::`. So once
that key enables `dropbear`, root is reachable from anywhere on the LAN with no
credential at all. Verified from another machine:

```
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@<unit>
  -> logged in as root, no key and no password
```

There is no `authorized_keys` on the unit; `/root/.ssh` is empty.

**The gate is one fixed constant.** `23051934` is a compile-time value, the same
on every unit, checked identically by `S50dropbear` and `S99final`. It needs
physical access to place a file on removable media, which is a real limit on
severity — but it is a product-wide shared secret, so it is secret exactly once.

**Suggested fix.** Give root a password, or require a key for SSH, even in
service mode; and derive the service token per unit rather than sharing one
constant across the product line. The convenience of the current arrangement is
preserved by shipping a per-unit token with the unit.

---

## 8. `mount -f -o remount,ro /` may never remount anything — HYPOTHESIS

`S99final` ends, on units *without* a service key, with:

```sh
#no key or hot key press was found so kill xterms, dwm, and mount root RO
killall xterm;
killall las-dwm;
mount -f -o remount,ro /
```

The intent is explicit in the comment. But `-f` is BusyBox mount's *fake* flag —
everything except the actual mount syscall — so the remount would be a no-op and
root would stay writable. On an instrument that is switched off at the back, a
writable root filesystem is an unclean-shutdown corruption risk, and it is
presumably why the line is there.

**Not confirmed, because it could not be tested here:** this unit has a service
key, so `S99final` exits before reaching that line, and its root is writable for
that reason instead.

**The test:** on a unit with no key on the thumbdrive, after a normal boot, run
`grep " / " /proc/mounts`. If it says `rw`, the remount did not take.

---

## 9. RT priority is assigned by an unanchored `ps | grep` — OBSERVED

`S99final` again:

```sh
iputasks=`ps | grep ipu | awk  '{print $1} NR==2{exit}'`
ipuirq=`ps | grep 2400000 | awk  '{print $1} NR==2{exit}'`
assign_ipu_pri $iputasks 93
assign_ipu_pri $ipuirq 80
```

`assign_ipu_pri` takes three positional arguments and is called with two, which
works only because each variable is unquoted and happens to expand to exactly two
PIDs. That in turn depends on `ps | grep ipu` matching exactly the two `ipu1_task`
threads and nothing else, with no anchoring and no filter on the process name
column.

On this unit it landed correctly. It is listed because the failure mode is quiet
and bad: a different match count silently gives `chrt -f -p` the wrong arguments,
or puts `SCHED_FIFO` priority 93 on an unrelated process. Matching on the command
column explicitly, and checking the count before using it, costs two lines.

---

## RETRACTED — `inputRouter` writes 56-59, `outputRouter` reads 60-63

Reading `synthdefs.scd`, `inputRouter` ends with `Out.ar(56..59, ...)` while
`outputRouter` reads `master1 = In.ar([60, 61])` and `master2 = In.ar([62, 63])`,
and `master1_out_busses = [60, 61]` is declared inside `inputRouter` but used only
for the `par_amount` feedback tap. That reads like a disconnected send return.

A bus sweep appeared to confirm it: a tone on 56 or 57 reached the output at the
noise floor while every neighbouring bus was audible.

**It is not a defect.** Buses 56-59 are the *inputs* to the two bus-effect slots
and 60-63 are their *outputs*; the chain meets through the effect in between.

```
 1038  none_2        inBus=56  outBus=60      send 1's slot
 1024  et_shimmer_2  inBus=58  outBus=62      send 2's slot
```

56 and 57 measured silent because send 1 held `none_2`, which passes nothing, and
58/59 carried signal because send 2 held a live shimmer. **A bus that reaches
nothing is not evidence of a broken graph when a no-op effect is sitting in it.**

---

## RETRACTED — "the supervisor is not running", "root is writable", "X is still up"

All three are true on this unit and none is a defect. They are the documented
consequence of the service key in finding 7: `S99final` finds the key, logs
`You have a key! Aren't you special!`, runs `killall las-watchdog` and **exits
early** — skipping `killall xterm`, `killall las-dwm` and the root remount.

So on a stock unit `las-watchdog -t=10000` *is* running, checking `las-frontend`,
`las-sc`, `sclang` and `scsynth` on a ten-second timer with the ability to restart
X and `las-dwm`. Reporting its absence as a robustness defect would have been
wrong, and reporting an empty root password as a shipped network exposure would
have been wrong in the other direction — the SSH daemon that exposes it is itself
gated by the same key.

Worth knowing separately: because service mode disables it, the supervisor that
might have caught the UI lock-up was not running when the lock-up happened.
