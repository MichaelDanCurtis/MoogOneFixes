#!/usr/bin/env python3
"""Reproduce: /n_free on a LADSPA effect synth faults inside eventide_plate.so.

IT IS INTERMITTENT. One free is not enough -- in the run that produced the
captured fault, the first completed cleanly and the second crashed the server.
This retries, and reports how many attempts it took.

Self-contained -- plain sockets and forty lines of OSC, no dependencies, so it
runs anywhere Python 3 does.

WHAT IT DOES TO THE UNIT. It kills the audio engine. The instrument keeps
running, its screen and controls respond, and it produces no digital effects
until the service is restarted. Nothing is written to storage and no
configuration changes; a restart or a power cycle puts it back.

To capture the fault rather than just observing it, first:

    echo 1 > /proc/sys/kernel/print-fatal-signals
    cp /proc/$(pidof scsynth)/maps /var/maps-before.txt   # dies with the process

then read `dmesg` afterwards and map PC and LR against the saved file.

    python3 ladspa_free_crash.py 192.168.1.138
    python3 ladspa_free_crash.py 192.168.1.138 --effect et_hall_1 --attempts 20
"""

import argparse
import socket
import struct
import sys
import time

SC_PORT = 57110


def pad(b: bytes) -> bytes:
    """OSC pads every block to four bytes, and a string ALWAYS gets a NUL first.

    A four-character address therefore occupies eight bytes, not four. It is the
    classic off-by-one in hand-rolled OSC and it produces a message the server
    ignores in silence.

    The outer `% 4` is the half that is easy to lose, and this script shipped
    without it. When a block is ALREADY aligned, `4 - len % 4` is 4, and adding
    four more NULs pushes everything after it four bytes late. `/s_new` survived
    that -- seven bytes with its terminator, so it needed real padding -- while
    `/n_free`, at exactly eight, had its type tags misplaced and was read as
    carrying no arguments at all. It freed nothing, silently, and the effect
    synths piled up 28 ugens at a time while the test reported success.
    """
    return b + b"\0" * ((4 - len(b) % 4) % 4)


def msg(address: str, *args) -> bytes:
    tags, body = ",", b""
    for a in args:
        if isinstance(a, int):
            tags += "i"
            body += struct.pack(">i", a)
        elif isinstance(a, float):
            tags += "f"
            body += struct.pack(">f", a)
        else:
            tags += "s"
            body += pad(a.encode() + b"\0")
    return pad(address.encode() + b"\0") + pad(tags.encode() + b"\0") + body


def ask(sock, host, payload, want, timeout=4.0):
    sock.sendto(payload, (host, SC_PORT))
    sock.settimeout(timeout)
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(65536)
        except socket.timeout:
            return None
        if data.split(b"\0", 1)[0].decode(errors="replace") == want:
            return data
    return None


def status(sock, host):
    reply = ask(sock, host, msg("/status"), "/status.reply")
    if reply is None:
        return None
    # The args begin after the address block AND the typetag block, and both are
    # padded independently. Hardcoding a length for the tags read four bytes early
    # and reported the reply's unused first int as the ugen count.
    address, rest = reply.split(b"\0", 1)
    at = len(pad(address + b"\0"))
    tags = reply[at:].split(b"\0", 1)[0]
    at += len(pad(tags + b"\0"))
    # /status.reply: an unused int, then ugens, synths, groups, synthdefs...
    values = struct.unpack_from(">iiiii", reply, at)
    return {"ugens": values[1], "synths": values[2], "defs": values[4]}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("host")
    ap.add_argument("--effect", default="et_plate_1")
    ap.add_argument("--node", type=int, default=96500)
    # Buses above 63 are unused by the instrument's own graph, so the effect
    # processes nothing of the user's and modifies no patch.
    ap.add_argument("--in-bus", type=int, default=100)
    ap.add_argument("--out-bus", type=int, default=102)
    ap.add_argument("--attempts", type=int, default=10)
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    before = status(sock, args.host)
    if before is None:
        print("scsynth is not answering /status; nothing to test against")
        return 2
    print(f"  before:            {before['ugens']} ugens, {before['synths']} synths")

    for attempt in range(1, args.attempts + 1):
        node = args.node + attempt
        sock.sendto(
            msg("/s_new", args.effect, node, 0, 0,
                "inBus", float(args.in_bus), "outBus", float(args.out_bus)),
            (args.host, SC_PORT),
        )
        ask(sock, args.host, msg("/sync", 1), "/synced")
        created = status(sock, args.host)
        if created is None:
            print(f"  attempt {attempt}: server died CREATING the effect -- unexpected")
            return 0

        sock.sendto(msg("/n_free", node), (args.host, SC_PORT))
        time.sleep(1.5)
        after = status(sock, args.host)
        if after is None:
            print(f"  attempt {attempt}: node {node} freed -> SCSYNTH GONE")
            print(f"\n  Reproduced after {attempt} attempt(s).")
            print("  Recover with: /etc/init.d/S42sc restart")
            print("  Then: dmesg | grep -A 12 'fatal signal'")
            return 0
        # The ugen count must FALL by the effect's size. If it does not, the free
        # did not happen and the run is measuring nothing -- which is exactly what
        # a malformed /n_free looks like from here.
        if after["ugens"] >= created["ugens"]:
            print(f"  attempt {attempt}: /n_free did not free anything "
                  f"({created['ugens']} -> {after['ugens']} ugens). Aborting: the "
                  f"message is not reaching the server as intended.")
            return 2
        print(f"  attempt {attempt}: freed cleanly "
              f"({created['ugens']} -> {after['ugens']} ugens)")

    print(f"\n  Did not reproduce in {args.attempts} attempts. It is intermittent; "
          f"try again or raise --attempts.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
