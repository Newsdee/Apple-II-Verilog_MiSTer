#!/usr/bin/env python3
"""Measure the circular horizontal shift between a 1-bit source image
(mapped to 560 samples) and a dumped B&W PPM output of the VGA tester.

The B&W DUT output is R=G=B with white=1/black=0, so its luminance bit
should equal the video bit fed to the DUT (up to a horizontal rotation
and the 559-vs-560 sample drop).

Usage:
    .venv/Scripts/python.exe tools/shift_check.py <source.png> <output_bw.ppm> [-t 128]

Requires Pillow (the repo .venv at E:\\MiSTer\\Apple-II_FPGAdev has it).
"""
import sys

from PIL import Image

W, H = 560, 192


def map_source(img, threshold):
    """Apply the same 280/284/560/568 -> 560 profiles as image_source.cpp.
    Returns a list of 192 Python ints, 560 bits each (bit 559 = x=0)."""
    sw, sh = img.size
    if sh != H:
        raise ValueError(f"unsupported source height {sh} (need 192)")
    g = img.convert("L")
    if sw == 560:
        pass
    elif sw == 568:
        g = g.crop((4, 0, 564, H))
    elif sw == 284:
        g = g.crop((2, 0, 282, H))
    elif sw == 280:
        pass
    else:
        raise ValueError(f"unsupported source width {sw} (need 280/284/560/568)")
    if g.width != W:
        g = g.resize((W, H), Image.NEAREST)  # 2x horizontal duplication
    px = g.load()
    rows = []
    for y in range(H):
        v = 0
        for x in range(W):
            if px[x, y] >= threshold:
                v |= 1 << (W - 1 - x)
        rows.append(v)
    return rows


def ppm_bits(path, threshold=64):
    """Load a PPM (or anything PIL reads), return (w, h, list of row ints)."""
    img = Image.open(path).convert("L")
    w, h = img.size
    px = img.load()
    rows = []
    for y in range(h):
        v = 0
        for x in range(w):
            if px[x, y] >= threshold:
                v |= 1 << (w - 1 - x)
        rows.append(v)
    return w, h, rows


def circ_right(row, s, width):
    """Rotate a `width`-bit row right by s (out[x] = src[(x+s) mod width])."""
    if s == 0:
        return row
    mask = (1 << s) - 1
    return (row >> s) | ((row & mask) << (width - s))


def main():
    args = sys.argv[1:]
    threshold = 128
    if "-t" in args:
        i = args.index("-t")
        threshold = int(args[i + 1])
        del args[i : i + 2]
    if len(args) < 2:
        print(f"usage: {sys.argv[0]} <source.png> <output_bw.ppm> [-t 128]")
        return 2
    src_path, out_path = args[0], args[1]

    src_img = Image.open(src_path)
    src = map_source(src_img, threshold)
    print(f"source: {src_img.size[0]}x{src_img.size[1]} -> 560x192 bits")

    ow, oh, out = ppm_bits(out_path)
    print(f"output ppm: {ow}x{oh}")
    OH, OW = min(oh, H), min(ow, W)
    keep = (1 << OW) - 1

    total = OW * OH
    best_s, best_err = -1, None
    second_s, second_err = -1, None
    errs = {}
    for s in range(W):
        err = 0
        for y in range(OH):
            shifted = circ_right(src[y], s, W) & keep
            err += (shifted ^ out[y]).bit_count()
        errs[s] = err
        if best_err is None or err < best_err:
            second_s, second_err = best_s, best_err
            best_s, best_err = s, err
        elif second_err is None or err < second_err:
            second_s, second_err = s, err

    print(f"best shift s={best_s}  mismatch={best_err}/{total} "
          f"({100.0 * best_err / total:.2f}%)")
    print(f"second best s={second_s} mismatch={second_err} "
          f"({100.0 * second_err / total:.2f}%)")
    for s in (0, 1, W - 1, W // 2):
        e = errs[s]
        print(f"  shift {s}: mismatch={e} ({100.0 * e / total:.2f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
