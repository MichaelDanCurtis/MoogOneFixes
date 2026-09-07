#!/usr/bin/env python3
"""Reproduce: /n_free on a LADSPA effect synth terminates scsynth.

Self-contained -- plain sockets and forty lines of OSC, no dependencies, so it
runs anywhere Python 3 does.

WHAT IT DOES TO THE UNIT. It kills the audio engine. The instrument keeps
running, its screen and controls respond, and it produces no digital effects
until the service is restarted. Nothing is written to storage and no
configuration changes; a restart or a power cycle puts it back.

    python3 ladspa_free_crash.py 192.168.1.138
    python3 ladspa_free_crash.py 192.168.1.138 --effect et_hall_1
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
    """
    return b + b"\0" * (4 - len(b) % 4)


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
    # /status.reply: an unused int, then ugens, synths, groups, synthdefs...
    values = struct.unpack_from(">iiiii", reply, len(pad(b"/status.reply\0")) + 8)
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
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    before = status(sock, args.host)
    if before is None:
        print("scsynth is not answering /status; nothing to test against")
        return 2
    print(f"  before:            {before['ugens']} ugens, {before['synths']} synths")

    sock.sendto(
        msg("/s_new", args.effect, args.node, 0, 0,
            "inBus", float(args.in_bus), "outBus", float(args.out_bus)),
        (args.host, SC_PORT),
    )
    ask(sock, args.host, msg("/sync", 1), "/synced")
    created = status(sock, args.host)
    if created is None:
        print("  server stopped answering when the effect was CREATED -- unexpected")
        return 1
    print(f"  effect created:    {created['ugens']} ugens, {created['synths']} synths")

    print(f"  freeing node {args.node} ...")
    sock.sendto(msg("/n_free", args.node), (args.host, SC_PORT))
    time.sleep(2.0)

    after = status(sock, args.host)
    if after is None:
        print("\n  scsynth is gone. /n_free on a LADSPA effect terminated the server.")
        print("  Recover with: /etc/init.d/S42sc restart")
        return 0
    print(f"\n  still answering:   {after['ugens']} ugens -- did NOT reproduce here")
    return 1


if __name__ == "__main__":
    sys.exit(main())
