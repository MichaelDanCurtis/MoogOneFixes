# Findings

Ordered by severity. Firmware ~v1.2/v1.3; `scsynth` running as

```
scsynth -u 57110 -a 129 -i 9 -b 1026 -z 128 -Z 128 -m 100000 -w 128 -S 48000 -R 0 -C 0 -l 1
```

---

## 1. `/n_free` on any LADSPA effect synth terminates `scsynth` — CONFIRMED

**Impact.** The audio engine dies. The instrument keeps running and its screen and
controls respond, but it produces no digital effects at all until the service is
restarted. Reachable from any OSC client that can talk to port 57110.

**Reproduction.** Nothing else running, on a freshly booted unit:

```
/s_new  "et_plate_1" 96500 0 0 "inBus" 100 "outBus" 102
/sync
/status                     -> answers, ugen count risen by 28
/n_free 96500
/status                     -> no reply, ever again
```

Two out of two in isolation. It also happened twice by accident before it was
isolated, and each time the cause was misattributed to something else first.

`repro/ladspa_free_crash.py` is this, self-contained.

**Why this is never hit in normal use.** `efx_server.scd` creates the five effect
slots once during `waitForBoot` and stops them with `enable = 0` — whose envelope
is `EnvGen.kr(Env.asr(0.1, 1, 2), enable, doneAction: 1)`, and doneAction 1 is
*pause*. Nothing in the shipped firmware ever frees one, so the free path is the
part of these units' lifecycle that the product never exercises.

**Where it is.** `LadspaUGen.so` is built from `sc3-plugins`
(`source/LadspaUGen/LadspaUGen.cpp`), whose destructor is:

```c
void LADSPA_Dtor(LADSPA *unit)
{
    if(!unit->desc) return;
    if(unit->desc->deactivate)
        unit->desc->deactivate(unit->handle);
    unit->desc->cleanup(unit->handle);
}
```

That code contains a **separate, provable defect**: `LADSPA_Ctor` assigns
`unit->desc` *before* calling `instantiate()`, never checks the result, and the
LADSPA specification explicitly permits `instantiate()` to return NULL. A unit
that failed to instantiate therefore has a valid `desc` and a NULL `handle`, and
the guard above lets it through to `deactivate(NULL)` and `cleanup(NULL)`. The
same NULL handle is also passed to `connect_port()` and `activate()` in the
constructor. **`patches/0001-ladspa-null-handle.patch` fixes that.**

**It is probably not what crashed here, and that matters.** In this reproduction
the effect had been instantiated successfully and was audibly processing audio, so
the handle was valid. The fault is therefore most likely inside the Eventide
plugin's own `deactivate()`/`cleanup()` — `las-fx/ladspa/eventide_*.so`, which are
proprietary and, per the paragraph above, have never had those entry points called
in shipping firmware.

**What would settle it:** one reproduction with core dumps enabled
(`scripts/enable-core-dumps.sh`) gives a backtrace naming the faulting library and
function. That has not been run; it costs one deliberate crash.

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

The last kernel message before a reported UI lock-up, roughly two minutes before
the unit was inspected. `INT_STAT_10` is an IPU error-interrupt register.

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
