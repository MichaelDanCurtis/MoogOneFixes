# Reproducing the `2662:800d` gadget wedge

**This is documented rather than scripted on purpose.** It ends with an
instrument that does not respond to anything and needs its power removed. A
script would make it too easy to run by accident.

## What to send

UDP to any port on the instrument's LAN address, from a machine on the same
network. Payload contents are irrelevant; size and spacing are not.

- **Safe, for comparison:** 1308-byte datagrams paced at 25→550/second, stepping
  up. That peaks at 719 kB/s, 1.47× the rate of realtime 48 kHz stereo audio, and
  runs indefinitely with zero drops, zero interface errors and flat memory.
- **Wedges it:** the same 1308-byte datagrams, 2000 of them with no pacing at
  all. That is ~18 ms of sending at roughly 145 MB/s. The gadget stops before the
  burst finishes.

Identical size, identical port, identical destination. Only the spacing differs,
which is why this is a burst-rate limit and not a throughput limit.

## What to look for

On the instrument, before the network goes (log to `/var`, not to the network):

```
NETDEV WATCHDOG: usbint (cdc_ether): transmit queue 0 timed out
```

**`usbint`, not `ethext`** — the LAN flood stalls the *voice controller's*
transmit queue, because the two are functions of one gadget.

Then, after unbinding and rebinding the USB device to force re-enumeration:

```
usb 2-1: can't set config #1, error -71
```

`-71` is `EPROTO`: the gadget will not accept `SET_CONFIGURATION`. Bouncing
`ethext` and taking a fresh DHCP lease does nothing either. Only removing power
clears it.

## What it is not

At the moment of the wedge, `MemFree` was normal for the machine and both
`rx_dropped` and `rx_errors` were zero. It is not memory exhaustion, and the
driver never saw a packet it had to discard.

## A warning about diagnosing it

A recovery ladder written for this reported `RECOVERED BY STEP 2`, and that
verdict was wrong. After the unbind, `ethext` no longer existed, so reading its
`rx_packets` returned an empty string and `"" != "8369"` compared true. **A probe
that reads a counter through a path the experiment is expected to destroy has to
distinguish *changed* from *unreadable***, or it reports success at the exact
moment it loses the ability to tell.
