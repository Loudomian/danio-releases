#!/usr/bin/env python3
"""Checks a build of danio's FFmpeg the way danio uses it, before release.

    check.py <ffmpeg> <version>

It says the version it was built as, encodes three fragments from PNG
frames with danio's parameters (H.264 with B-frames, and ProRes 4444), and
joins the H.264 ones the way danio does: the concat demuxer, each fragment's
exact length given (its frames' durations, from the MP4), copying the
stream. The film must have every frame, each exactly 1/24 s: a join that
puts a fragment a little early or late shows up as one frame's duration
off. Only the standard library: it runs on each platform's own runner.
"""
import os
import struct
import subprocess
import sys
import tempfile
import zlib
from fractions import Fraction

H264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-profile:v", "high",
        "-bf", "2", "-g", "48", "-sc_threshold", "0",
        "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p", "-movflags", "+faststart", "-f", "mp4"]
PRORES = ["-c:v", "prores_ks", "-profile:v", "4444", "-pix_fmt", "yuva444p10le", "-vendor", "apl0", "-f", "mov"]


def png(path, w, h, i):
    """A frame with a pattern that moves, so the encoder uses B-frames."""
    rows = b"".join(b"\0" + bytes(c for x in range(w) for c in (
        (x + i * 3) * 8 & 255, (y + i * 2) * 8 & 255, (x + y + i) * 4 & 255)) for y in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def boxes(data, at, end):
    while at + 8 <= end:
        size, typ = struct.unpack_from(">I4s", data, at)
        head = 8
        if size == 1:
            size, head = struct.unpack_from(">Q", data, at + 8)[0], 16
        elif size == 0:
            size = end - at
        yield typ.decode("latin-1"), at + head, at + size
        at += size


def child(data, at, end, typ):
    for t, a, e in boxes(data, at, end):
        if t == typ:
            return a, e
    raise SystemExit(f"no {typ} box")


def video(path):
    """The video track's time scale and its runs of frames: [(count, duration)]."""
    data = open(path, "rb").read()
    moov = child(data, 0, len(data), "moov")
    for t, a, e in boxes(data, *moov):
        if t != "trak":
            continue
        mdia = child(data, a, e, "mdia")
        hdlr = child(data, *mdia, "hdlr")
        if data[hdlr[0] + 8:hdlr[0] + 12] != b"vide":
            continue
        mdhd = child(data, *mdia, "mdhd")
        scale = struct.unpack_from(">I", data, mdhd[0] + (20 if data[mdhd[0]] == 1 else 12))[0]
        stbl = child(data, *child(data, *mdia, "minf"), "stbl")
        stts = child(data, *stbl, "stts")
        n = struct.unpack_from(">I", data, stts[0] + 4)[0]
        return scale, [struct.unpack_from(">II", data, stts[0] + 8 + i * 8) for i in range(n)]
    raise SystemExit(f"{path}: no video track")


def run(exe, args):
    r = subprocess.run([exe, "-hide_banner", "-loglevel", "error", "-y"] + args, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f"ffmpeg {' '.join(args)}\n{r.stderr}")


def main():
    exe, version = os.path.abspath(sys.argv[1]), sys.argv[2]
    said = subprocess.run([exe, "-version"], capture_output=True, text=True).stdout.split("\n")[0]
    if not said.startswith(f"ffmpeg version {version} "):
        raise SystemExit(f"says {said!r}, want version {version}")
    d = tempfile.mkdtemp()
    parts, n = [], 0
    for k, count in enumerate([8, 7, 9]):
        frames = os.path.join(d, f"s{k}")
        os.mkdir(frames)
        for i in range(count):
            png(os.path.join(frames, f"{i:08d}.png"), 65, 33, n + i)  # odd size: padded to even
        n += count
        out = os.path.join(d, f"p{k}.mp4")
        run(exe, ["-framerate", "24", "-i", os.path.join(frames, "%08d.png")] + H264 + [out])
        parts.append(out)
    run(exe, ["-framerate", "24", "-i", os.path.join(d, "s0", "%08d.png")] + PRORES + [os.path.join(d, "p.mov")])
    scale, runs = video(os.path.join(d, "p.mov"))
    if sum(c for c, _ in runs) != 8:
        raise SystemExit(f"ProRes: frames {runs}")

    # the join, as danio writes the list: each fragment's end in whole
    # microseconds, rounded, and its duration up to there
    lst, at, prev = os.path.join(d, "list.txt"), Fraction(0), 0
    with open(lst, "w") as f:
        for p in parts:
            scale, runs = video(p)
            at += Fraction(sum(c * t for c, t in runs), scale)
            end = round(at * 1_000_000)
            f.write(f"file '{p.replace(os.sep, '/')}'\nduration {(end - prev) // 1_000_000}.{(end - prev) % 1_000_000:06d}\n")
            prev = end
    film = os.path.join(d, "film.mp4")
    run(exe, ["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", "-movflags", "+faststart", "-f", "mp4", film])
    scale, runs = video(film)
    if len(runs) != 1 or runs[0][0] != 24 or Fraction(runs[0][1], scale) != Fraction(1, 24):
        raise SystemExit(f"film frames {runs} at 1/{scale} s: want 24 of 1/24 s")
    print(f"{said}: fragments, ProRes and the join check out")


main()
