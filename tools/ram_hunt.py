#!/usr/bin/env python3
"""
ram_hunt.py - find a game variable in PS1 RAM via the psxrecomp TCP debug server.

The debug server (runtime/src/debug_server.c) speaks JSON-per-line on port 4370
and is only compiled in when PSX_DEBUG_TOOLS is ON - i.e. a RelWithDebInfo
build, not Release. Two commands matter here:

    {"id":1,"cmd":"mem_words","addr":"0x80010000","count":256}
    {"id":2,"cmd":"write_ram","addr":"0x80010000","val":"0x03"}

read_ram serves up to the whole 2 MiB in a single hex-encoded response, so
snapshots use it in 256 KiB chunks with a short pause between them. The server
runs on the emulator's main thread with a 15 s per-response budget and drops
clients that overrun it - hammering it with thousands of small mem_words
requests gets the connection aborted mid-sweep.

Typical workflow for a stage index
----------------------------------
    # with the game sitting on stage 1
    python tools/ram_hunt.py snapshot stage1

    # play to stage 2, then
    python tools/ram_hunt.py snapshot stage2

    # addresses that were 0 on stage1 and 1 on stage2 (0-based index),
    # and separately 1/2 in case the game counts from 1
    python tools/ram_hunt.py candidates stage1=0 stage2=1
    python tools/ram_hunt.py candidates stage1=1 stage2=2

    # or, if you do not want to assume the encoding, just list what changed
    python tools/ram_hunt.py changed stage1 stage2

    # confirm by writing and watching the game react
    python tools/ram_hunt.py poke 0x800A1234 0x04
    python tools/ram_hunt.py watch 0x800A1234

Snapshots are written to hunt/<name>.bin (raw bytes, gitignored).
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

HOST = "127.0.0.1"
PORT = 4370
RAM_BASE = 0x80000000
RAM_SIZE = 2 * 1024 * 1024          # PS1 has 2 MiB of main RAM
WORDS_PER_REQ = 256                 # mem_words clamps to 256
CHUNK_BYTES = 256 * 1024            # per read_ram request
CHUNK_DELAY = 0.05                  # let the emulator run between chunks


class Debug:
    """One connection to the debug server, JSON object per line."""

    def __init__(self, host=HOST, port=PORT, timeout=30.0):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.f = self.sock.makefile("rwb")
        self.next_id = 1

    def call(self, cmd, **params):
        req = {"id": self.next_id, "cmd": cmd}
        req.update(params)
        self.next_id += 1
        self.f.write((json.dumps(req) + "\n").encode())
        self.f.flush()
        line = self.f.readline()
        if not line:
            raise ConnectionError("debug server closed the connection")
        rsp = json.loads(line.decode())
        if not rsp.get("ok"):
            raise RuntimeError(f"{cmd} failed: {rsp.get('error')}")
        return rsp

    def read_words(self, addr, count):
        rsp = self.call("mem_words", addr=f"0x{addr:08X}", count=count)
        return [int(w, 16) for w in rsp["words"]]

    def read_bytes(self, addr, length):
        """One read_ram request; returns raw bytes."""
        rsp = self.call("read_ram", addr=f"0x{addr:08X}", len=length)
        return bytes.fromhex(rsp["hex"])

    def read_range(self, start, size, chunk=CHUNK_BYTES, delay=CHUNK_DELAY,
                   progress=True):
        """Return `size` bytes from `start`.

        Uses read_ram, which serves up to the whole 2 MiB in one request. The
        server is pumped on the emulator's main thread with a 15 s per-response
        budget and drops clients that overrun it, so this deliberately does NOT
        ask for everything at once, and sleeps briefly between chunks to let
        frames run. (The original mem_words loop issued ~2048 requests for a
        2 MiB sweep and got dropped with WinError 10053 partway through.)
        """
        out = bytearray()
        t0 = time.time()
        while len(out) < size:
            n = min(chunk, size - len(out))
            out += self.read_bytes(start + len(out), n)
            if progress:
                pct = len(out) * 100.0 / size
                sys.stderr.write(f"\r  reading... {pct:5.1f}%")
                sys.stderr.flush()
            if delay and len(out) < size:
                time.sleep(delay)
        if progress:
            sys.stderr.write(f"\r  read {size/1024:.0f} KiB in {time.time()-t0:.1f}s\n")
        return bytes(out)

    def close(self):
        try:
            self.f.close()
            self.sock.close()
        except OSError:
            pass


def snap_path(name):
    return os.path.join("hunt", f"{name}.bin")


def load_snap(name):
    p = snap_path(name)
    if not os.path.exists(p):
        sys.exit(f"no snapshot '{name}' at {p}")
    with open(p, "rb") as fh:
        return fh.read()


def value_at(buf, off, width):
    if off + width > len(buf):
        return None
    if width == 1:
        return buf[off]
    if width == 2:
        return struct.unpack_from("<H", buf, off)[0]
    return struct.unpack_from("<I", buf, off)[0]


def cmd_snapshot(args):
    os.makedirs("hunt", exist_ok=True)
    d = Debug(port=args.port)
    try:
        print(f"snapshot '{args.name}': 0x{args.start:08X} +0x{args.size:X}")
        data = d.read_range(args.start, args.size,
                            chunk=args.chunk, delay=args.delay)
    finally:
        d.close()
    with open(snap_path(args.name), "wb") as fh:
        fh.write(data)
    meta = {"start": args.start, "size": args.size}
    with open(snap_path(args.name) + ".json", "w") as fh:
        json.dump(meta, fh)
    print(f"wrote {snap_path(args.name)} ({len(data)} bytes)")


def snap_start(name, default):
    p = snap_path(name) + ".json"
    if os.path.exists(p):
        with open(p) as fh:
            return json.load(fh)["start"]
    return default


def cmd_candidates(args):
    pairs = []
    for spec in args.pairs:
        if "=" not in spec:
            sys.exit(f"expected NAME=VALUE, got '{spec}'")
        name, val = spec.split("=", 1)
        pairs.append((name, int(val, 0), load_snap(name)))

    start = snap_start(pairs[0][0], args.start)
    size = min(len(b) for _, _, b in pairs)
    w = args.width
    hits = []
    for off in range(0, size - w + 1, args.align):
        for _, want, buf in pairs:
            if value_at(buf, off, w) != want:
                break
        else:
            hits.append(start + off)

    print(f"{len(hits)} candidate(s) at width {w}:")
    for a in hits[: args.limit]:
        print(f"  0x{a:08X}")
    if len(hits) > args.limit:
        print(f"  ... {len(hits) - args.limit} more")


def cmd_changed(args):
    a, b = load_snap(args.a), load_snap(args.b)
    start = snap_start(args.a, args.start)
    size = min(len(a), len(b))
    w = args.width
    hits = []
    for off in range(0, size - w + 1, args.align):
        va, vb = value_at(a, off, w), value_at(b, off, w)
        if va != vb:
            hits.append((start + off, va, vb))

    if args.same:
        hits = [(addr, va, vb) for addr, va, vb in
                ((start + off, value_at(a, off, w), value_at(b, off, w))
                 for off in range(0, size - w + 1, args.align))
                if va == vb]
        print(f"{len(hits)} address(es) unchanged at width {w}")
    else:
        print(f"{len(hits)} address(es) changed at width {w}:")
    for addr, va, vb in hits[: args.limit]:
        print(f"  0x{addr:08X}  {va:#0{w*2+2}x} -> {vb:#0{w*2+2}x}")
    if len(hits) > args.limit:
        print(f"  ... {len(hits) - args.limit} more")


def cmd_peek(args):
    d = Debug(port=args.port)
    try:
        words = d.read_words(args.addr, args.count)
    finally:
        d.close()
    for i in range(0, len(words), 4):
        row = words[i:i + 4]
        addr = args.addr + i * 4
        hexs = " ".join(f"{w:08X}" for w in row)
        raw = b"".join(struct.pack("<I", w) for w in row)
        txt = "".join(chr(c) if 32 <= c < 127 else "." for c in raw)
        print(f"  0x{addr:08X}  {hexs:<35}  {txt}")


def cmd_poke(args):
    d = Debug(port=args.port)
    try:
        for i, b in enumerate(args.values):
            d.call("write_ram", addr=f"0x{args.addr + i:08X}", val=f"0x{b:02X}")
        print(f"wrote {len(args.values)} byte(s) at 0x{args.addr:08X}")
    finally:
        d.close()


def cmd_watch(args):
    d = Debug(port=args.port)
    last = None
    try:
        print(f"watching 0x{args.addr:08X} (ctrl-c to stop)")
        while True:
            words = d.read_words(args.addr, max(1, (args.count + 3) // 4))
            raw = b"".join(struct.pack("<I", w) for w in words)[: args.count]
            if raw != last:
                stamp = time.strftime("%H:%M:%S")
                print(f"  {stamp}  {' '.join(f'{b:02X}' for b in raw)}")
                last = raw
            time.sleep(args.interval)
    except KeyboardInterrupt:
        print()
    finally:
        d.close()


def auto_int(s):
    return int(s, 0)


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=PORT)
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("snapshot", help="dump a RAM range to hunt/<name>.bin")
    s.add_argument("name")
    s.add_argument("--start", type=auto_int, default=RAM_BASE)
    s.add_argument("--size", type=auto_int, default=RAM_SIZE)
    s.add_argument("--chunk", type=auto_int, default=CHUNK_BYTES,
                   help="bytes per read_ram request (default 256 KiB)")
    s.add_argument("--delay", type=float, default=CHUNK_DELAY,
                   help="seconds to pause between chunks so frames keep running")
    s.set_defaults(func=cmd_snapshot)

    c = sub.add_parser("candidates", help="addresses matching NAME=VALUE in every snapshot")
    c.add_argument("pairs", nargs="+", metavar="NAME=VALUE")
    c.add_argument("--width", type=int, choices=[1, 2, 4], default=1)
    c.add_argument("--align", type=int, default=1)
    c.add_argument("--start", type=auto_int, default=RAM_BASE)
    c.add_argument("--limit", type=int, default=40)
    c.set_defaults(func=cmd_candidates)

    g = sub.add_parser("changed", help="addresses that differ (or match) between two snapshots")
    g.add_argument("a")
    g.add_argument("b")
    g.add_argument("--width", type=int, choices=[1, 2, 4], default=1)
    g.add_argument("--align", type=int, default=1)
    g.add_argument("--start", type=auto_int, default=RAM_BASE)
    g.add_argument("--limit", type=int, default=40)
    g.add_argument("--same", action="store_true", help="list unchanged instead")
    g.set_defaults(func=cmd_changed)

    p = sub.add_parser("peek", help="hex dump live memory")
    p.add_argument("addr", type=auto_int)
    p.add_argument("--count", type=int, default=16, help="words")
    p.set_defaults(func=cmd_peek)

    k = sub.add_parser("poke", help="write bytes to live memory")
    k.add_argument("addr", type=auto_int)
    k.add_argument("values", nargs="+", type=auto_int)
    k.set_defaults(func=cmd_poke)

    w = sub.add_parser("watch", help="poll an address and print changes")
    w.add_argument("addr", type=auto_int)
    w.add_argument("--count", type=int, default=4, help="bytes")
    w.add_argument("--interval", type=float, default=0.25)
    w.set_defaults(func=cmd_watch)

    args = ap.parse_args()
    try:
        args.func(args)
    except ConnectionRefusedError:
        sys.exit(f"nothing listening on {HOST}:{args.port} - is the RelWithDebInfo "
                 f"build running? (Release strips the debug server)")


if __name__ == "__main__":
    main()
