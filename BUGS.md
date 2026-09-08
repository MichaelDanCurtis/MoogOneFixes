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

**It is reachable in normal use, and it is audible.** Engaging one more effect on
an ordinary patch at 72% of a core took it past the throttle and the output cut out
for about a tenth of a second at a time -- reported by ear before any measurement
found it. The five Eventide LADSPA reverbs cost **23-33% of a core each**;
everything else in the rack costs 1-10%, the 21-band vocoder being the one native
effect worth watching at 10%.

*A note on the arithmetic.* An earlier version of this report put the total at
"101% of a core". That was 72 + 29 rather than a reading: a thread cannot exceed one
core, and this one is descheduled near 95% by the very throttle being described. The
demand exceeds the core; the measurement cannot. The effect costs themselves have
since been re-measured on an idle engine with a per-thread probe and stand up --
`et_plate_1` at +26%, against +27% by the original method.

**The block size is the lever, and it is one line.** `init_sc_1.scd` runs the
engine at `blockSize = 128`. At 256:

| graph | `-z 128` | `-z 256` |
|---|---|---|
| bare default, 496 ugens | 22% | **17%** |
| a real patch, 682 ugens, five effects routed | 72% | **51%** |

That is 21 points of a core handed back for 2.7 ms of extra block latency, and it
is per-block overhead rather than any one synth: `et_plate_1` costs +29% at 128
and +27% at 256. With it, the same sixth effect that dropped out
plays clean -- zero dropouts over 20 ms across a recorded phrase.

**RETRACTED, in part — the block size is not the problem, and 128 is correct.**

The dropouts that motivated this were produced by a *sixth* effect added alongside
the instrument's own five-slot rack. The instrument budgets for five. Adding one
more and concluding the block size is wrong inverts cause and effect.

And 128 is right for this design. Insert effects read straight from the ADC
(`input = SoundIn.ar(inBus, 2)`), so a timbre routed through one takes the whole
ADC→DAC round trip while a timbre without one goes out in analog with none. Doubling
the block doubles that skew — roughly 8-11 ms to 16-21 ms between two timbres played
together, which is the difference between a slight thickening and an audible flam,
and between "tight" and "behind the keys" for the player.

Moog chose 128 to keep the insert path aligned with the analog path. That is the
correct trade for an analog instrument with a digital insert loop, and the earlier
recommendation here to ship a larger default was wrong.

What survives is the underlying observation: the RT throttle is reachable, and the
headroom above a normal patch is thin. The right response is not a bigger block. It
is that
`scripts/apply.sh rt-throttle` raises the realtime budget -- but the tradeoff is
real and it is not ours to make: an unbounded budget means a spinning RT thread
can lock the machine out. When demand genuinely exceeds one core it only moves the cliff anyway.

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

## 10. An `export` in `systemCmd` makes a shipped effect unreachable — CONFIRMED

**Impact.** One of the six Eventide reverbs you ship cannot be selected on the
instrument, and never has been.

`init_sc_1.scd` line 23:

```supercollider
("export LADSPA_PATH=/usr/share/las-fx/ladspa").systemCmd;
```

`systemCmd` runs its argument in a subshell, so the `export` dies with that
subshell. It never reaches `sclang`'s environment and certainly not the `scsynth`
it boots, so `LadspaUGen` falls back to its built-in default of `/usr/lib/ladspa`.

The consequence is visible on disk:

```
/usr/share/las-fx/ladspa/   blackhole  hall  plate  room  shimmer  SPRING
/usr/lib/ladspa/            blackhole  hall  plate  room  shimmer
```

Five plugins appear to have been copied into the fallback directory by hand. The
sixth was missed, and nothing pointed it out because the line that was supposed to
make the copy unnecessary silently does nothing.

**A second, independent fault keeps it unreachable even once the plugin loads.**
`et_spring` has SynthDef source in `synthdefs.scd` beside the other five, calling
`LADSPA.ar(2, 29153, ...)`, but there is no `et_spring.scsyndef` in
`/usr/share/las-fx/synthdefs/`. `init_sc_1.scd` loads that directory with
`loadDirectory`, so an uncompiled definition does not exist to the server.

**Evidence it has never been used:** `strings` over the 100 MB factory bank
`MOOG ONE.db` finds every other effect family tens of thousands of times and
`et_spring` **zero** times.

**A third fault, and the reason the first two were never noticed.** The
`et_spring` SynthDef would not have worked even if it had been compiled and the
plugin had loaded. It passes the **plate's** argument list into the spring:

```supercollider
distance, diffusion, modLvl, tone, highDamp, lowDamp, preDelay, size, decay, mix
```

`ladspalist` reports 29153's actual ports as:

```
TREM-INTENSITY  TREM-RATE  MOD-LEVEL  RESONANCE  HIGH-DAMP
LOW-DAMP        NUM SPRINGS  TENSION  DECAY      MIX
```

Ten control ports either way, so it maps positionally and compiles cleanly. Every
knob is simply the wrong knob — and `preDelay`'s default of **0.1 lands on NUM
SPRINGS**. Instantiated as written it produces **silence**, measured on hardware:
identical rms to the dry signal attenuated by the wet/dry, and no tail.

The SynthDef's own `metadata` block describes Trem Intensity, Trem Rate,
Resonance, Num Springs and Tension correctly. The argument list beneath it does
not match its own documentation.

**Verified fixed.** With the plugin copied into `/usr/lib/ladspa` and a
definition using the real port order, scsynth reports
`LADSPA: Found plugin 29153 (Eventide Spring)` at boot and the effect works. A
0.35 s pluck that leaves **0.00 s** of tail dry leaves **0.18 s** through it.

**Fix, three parts.**

1. Set the environment before `sclang` starts — in `launch-sc-1`, where the
   server's other environment variables already are — rather than from inside it:

   ```sh
   LADSPA_PATH=/usr/share/las-fx/ladspa DISPLAY=:0 SCSYNTH_IP=$scip ... sclang ...
   ```

2. Correct `et_spring`'s argument list to the plugin's ports. The working
   definition is in `patches/0003-et-spring-correct-ports.scd`.

3. Compile it with the rest, so `loadDirectory` finds it.

---

## 11. The two-server configuration cannot run — CONFIRMED, and the cause is the build

`init_sc_2.scd` describes exactly the architecture this hardware needs, in its own
comment: `// frontendGroup lives on shared CPU core, dspGroup lives on DSP core`.

**Why this matters.** Measured over three seconds on an otherwise quiet instrument:

```
cpu     busy  12.1%
cpu0    busy  12.6%      <- all the audio
cpu1    busy  11.6%      <- and under load this one stays near idle
```

Under a loaded patch cpu0 saturates while cpu1 remains roughly 87% idle. A single
Eventide reverb costs 23-33% of one core (finding 4). The second core of a two-core
machine is not used for audio at all, and that is the difference between a reverb
that fits and one that does not.

Four faults keep the configuration unreachable, and all four are repairable:

* **Nothing selects it.** `launch-sc-2` is a **symlink to `launch-sc-1`** — same
  md5, same banner `LAUNCHING SINGLE EFFECTS SERVER CONFIGURATION` — and so loads
  `init_sc_1.scd`. `init_sc_2.scd` is present and is the larger file (7205 bytes
  against 4136). The launcher named for this configuration points at its sibling.
* **`~dspGroup` is used at lines 68-69 and defined at line 77**, so the input and
  output routers are created against `nil`.
* **`~serverANumOuts = 4`**, but the main outputs are buses 0 and 7. Bus 7 does not
  exist on `server_a`.
* **`launch-sn`** would start `supernova`, the multicore server that is the right
  answer here. Its `supernova` line is commented out, it `cd`s into
  `/usr/share/efx` which does not exist, and it starts `jackd -dalsa -dhw:4` when
  the only card present is card 0. **No `supernova` binary is installed.**

**None of those is the reason it cannot work.** Underneath all four:

> **The shipped `scsynth` is an ALSA-only build.** `SC_AlsaDriver` is present;
> `SC_JackDriver` appears **zero** times.

`jackd` *is* installed at `/usr/bin/jackd` — an earlier version of this report said
it was absent, which was wrong — but `scsynth` cannot be a JACK client, so it cannot
help. And two ALSA clients cannot share this card:

```
card 0 [xmosaudio]   the only card
pcm0p                subdevices_count: 1    subdevices_avail: 0
hw_params            access: RW_INTERLEAVED (not MMAP)
                     8ch S24_LE 48000, period 256, buffer 512
/usr/lib/alsa-lib/   smixer only            (no dmix plugin)
/etc/asound.conf     empty
```

One subdevice, already held. `dmix` is the way to share an ALSA device and it
requires mmap on the slave, which this driver does not offer — and the plugin is not
installed regardless. No `snd-aloop` module either.

**JACK works on this hardware. Tested.** Stopping the audio stack and starting the
`jackd` that already ships, on the card that actually exists:

```
jackd -d alsa -d hw:0 -r 48000 -p 256 -n 2

JACK server starting in realtime mode with priority 10
configuring for 48000Hz, period = 256 frames (5.3 ms), buffer = 2 periods
ALSA: final selected sample format for capture:  24bit little-endian
ALSA: final selected sample format for playback: 24bit little-endian
```

`jackdmp 1.9.12`. It took the card, matched its 24-bit format in both directions,
published all 8 capture and 8 playback ports, and ran with **zero xruns** in
realtime mode at a 5.3 ms period. `S42sc restart` restored the instrument normally
afterwards.

Two further faults in `launch-sn` follow from that, now demonstrated rather than
suspected: it asks for **`-dhw:4`** when the only card is `hw:0`, and it passes
**`-S`**, JACK's *16-bit shorts* flag, to a card whose format is `S24_LE`.

**What would fix it is one binary, not three.** Ship a `scsynth` built with the JACK
driver — or the `supernova` that `launch-sn` already expects — and correct
`launch-sn`'s card and format flags. The sharing layer is already on the device,
already works, and is not used by anything.

For a customer this is out of reach: there is no compiler on the instrument, and the
sysroot is armv7l against glibc 2.21 (Buildroot, 2015) on a 4.1.15-rt kernel. For
whoever builds the image it is a build-flag change.

**Verification**

```sh
strings /usr/bin/scsynth | grep -c SC_JackDriver     # 0
strings /usr/bin/scsynth | grep -c SC_AlsaDriver     # non-zero
cat /proc/asound/card0/pcm0p/info | grep subdevices  # count 1, avail 0
cat /proc/asound/card0/pcm0p/sub0/hw_params          # access: RW_INTERLEAVED
ls /usr/lib/alsa-lib/                                # smixer only
ls -l /usr/share/las-fx/launch-sc-2                  # -> launch-sc-1
```

---

## 12. `scsynth` reports its CPU usage as exactly zero — CONFIRMED

`/status.reply` carries `avg_cpu` and `peak_cpu`. On this firmware both are
**exactly `0.000`**, always, including while the server's own DSP thread is using
82% of a core.

```
status 0: avg=0.000 peak=0.000 ugens=710 synths=19 groups=12 defs=110 sr=48000.0
status 1: avg=0.000 peak=0.000 ugens=710 synths=19 groups=12 defs=110 sr=48000.0
status 2: avg=0.000 peak=0.000 ugens=710 synths=19 groups=12 defs=110 sr=48000.0
status 3: avg=0.000 peak=0.000 ugens=710 synths=19 groups=12 defs=110 sr=48000.0
```

Measured against the kernel over the same period, the busiest `scsynth` thread was
at 82% of one core. Every other field in the same reply is correct — ugens, synths,
groups, synthdefs, sample rate — so this is not a broken reply, it is two dead
fields inside a working one.

**Why this matters.** This instrument runs `scsynth` `SCHED_FIFO` against a 95% RT
throttle (finding 4), so CPU headroom is the thing most worth watching, and it is
the one number the server will not report. Any monitoring built on the documented
SuperCollider interface — including Moog's own, if it uses it — sees an idle
machine right up to the moment the audio drops out.

**Workaround**, if anything needs the real figure: read it from the kernel. The
DSP is one thread, and the throttle acts per thread, so the busiest thread is the
number:

```sh
pid=$(ps | grep '[s]csynth -u' | awk '{print $1}' | head -1)
{ cat /proc/stat; cat /proc/$pid/task/*/stat; } > /tmp/a
sleep 2
{ cat /proc/stat; cat /proc/$pid/task/*/stat; } > /tmp/b
# busiest thread's jiffies / (total jiffies / ncores) = share of one core
```

Two traps for anyone reproducing this. **busybox `top` on this device reports
`%CPU` as a fraction of both cores** — it shows 42% for the thread measured above
at 82% of one. And **an effect's cost cannot be measured on a busy engine**: at an
82% baseline every Eventide reverb measured 12-15%, consistently enough across all
five to look like a result, because 82% plus a reverb is past the throttle and the
kernel caps the thread. On an idle engine the same five measure 23-33%.

---

## 13. `las-sc` sends `/hw/` addresses the controller does not serve — OBSERVED

`las-sc` contains three `/hw/` leaves. Queried on the voice controller:

```
/hw/mute      ack                          <- served
/hw/hpf       404 Not found
/hw/autor     404 Not found
```

`/info/product` returns `lasvc` and a deliberately invalid address returns 404, so
the harness is sound in both directions. Minor, and listed only because it is
evidence about how much of `las-sc`'s address table is live — relevant to anyone
reading that binary to learn the namespace.

Also observed while testing: **`/hw/mute` acknowledges a zero-argument message**
rather than returning `400 Malformed message`, which the same firmware does return
for genuinely malformed input. The instrument went on playing normally afterwards,
so the message matched a setter and did not write.

---

## 14. A warm `reboot` wedges the USB gadget and needs power removal — CONFIRMED

**Impact.** After `/sbin/reboot`, the instrument comes back with its LEDs lit, its
OLEDs showing a single line, no main display, and no network. It is not recoverable
by software: only removing power restores it.

Observed directly. Before the reboot: uptime 65269 s, network up, audio stack
running, three OLED pages, main display live. After: LEDs on, OLEDs reduced to one
line, no main display, and no reply on either IP address or over mDNS for more than
five minutes.

**The single-device explanation.** `2662:800d "LAS internal"` is one USB gadget
carrying *both* links — `ethext`, the LAN interface, and `usbint`, the path to the
voice controller at 203.0.113.2. Both symptoms are one failure:

* no `ethext` -> invisible on the network
* no `usbint` -> the controller cannot reach the voice cards, which is exactly what
  an OLED reduced to a single line means

This is finding 2's wedge (`SET_CONFIGURATION` refused) reached by a different
route. Finding 2 reached it with a traffic microburst; a warm reboot reaches it with
no traffic at all.

**Why it matters more than finding 2.** A burst is avoidable — the toolkit here is
interlocked against it. `reboot` is a command any engineer types without thinking,
it is what every remote-administration habit reaches for, and there is nothing on
the device to warn that it is one-way. An instrument in a rack, rebooted remotely,
does not come back.

**The safe path exists and is already used.** `/etc/init.d/S42sc restart` cycles the
whole audio stack — `las-sc`, `sclang`, `scsynth`, the XMOS firmware upload — and
recovers cleanly every time. It has been run five times in one session here without
incident. Whatever `reboot` does to the gadget on the way down, `S42sc restart` does
not do.

**Suggestion.** Either make the shutdown path leave the gadget re-enumerable, or
have the controller reset it at boot. Failing both, the watchdog is well placed to
notice that `usbint` never came up and reset the XMOS rather than sit in a state no
software can leave.

**Reproduction.** Note that this leaves the unit needing physical access.

```sh
ssh root@<ip> 'sync; /sbin/reboot'
# LEDs return, OLEDs show one line, no main display, no network.
# Only a power cycle recovers it.
```

---

## 15. `S02sys` writes the RT budget into a file called `/sched_rt_runtime_us` — CONFIRMED

**Impact.** Moog intended to raise the realtime budget from the 95% default to
99.995%. The line has no directory in it, so it creates a file in `/` and the
throttle stays at 95% — which is the throttle that produces audible dropouts
(finding 4).

`/etc/init.d/S02sys`, line 8:

```sh
echo 999950 > sched_rt_runtime_us
```

There is no `cd` to `/proc/sys/kernel/` anywhere above it. The evidence is on the
instrument, with the current boot's timestamp:

```
$ cat /proc/sys/kernel/sched_rt_runtime_us
950000                                   <- still the kernel default

$ ls -la /sched_rt_runtime_us
-rw-r--r-- 1 root root 7 Sep  8 19:11    <- written at boot, into the root directory
```

Seven bytes: `999950\n`. The value Moog wanted, in the wrong file, every boot since
the unit was built.

**Why it matters.** `scsynth`'s audio thread runs `SCHED_FIFO` at priority 99 on an
isolated core. At `sched_rt_runtime_us = 950000` the kernel deschedules it once it
exceeds 95% of each period, which is heard as the sound cutting out for about a
tenth of a second. `dmesg` on this unit carries `sched: RT throttling activated`.
The intended 999950 would have left it essentially unthrottled.

**Suggested fix.** One word:

```sh
echo 999950 > /proc/sys/kernel/sched_rt_runtime_us
```

**A caution worth stating.** 999950/1000000 leaves 50 µs per second for everything
that is not realtime. That is close to no safety valve at all: a realtime thread
that spins takes the machine with it, and the 95% default exists precisely to stop
that. The fix restores Moog's intent, and their intent was aggressive. A middle
value — 980000, say — buys most of the headroom and keeps a usable margin.

---

## 16. `S14fs` lists a crontab instead of starting `crond` — CONFIRMED

`/etc/init.d/S14fs`, line 61:

```sh
crontab -c /etc/crontab -l
```

`-l` **lists** a crontab. It does not start a daemon. There is no `crond` in the
process table, so the daily log rotation the entry exists for has never run on any
unit. `S99final` compensates by hand — deleting `/var/log/*.0.*` and rotating the
watchdog log at every boot — which is why nobody noticed.

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
