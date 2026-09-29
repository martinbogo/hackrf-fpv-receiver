#!/usr/bin/env python3
"""Synthesise an analog FPV video transmission as HackRF-style 8-bit IQ at 20 Msps.

Builds standards-accurate PAL-B/G (ITU-R BT.470) or NTSC-M (SMPTE 170M) composite video, with
sync, equalising and broad pulses at the standard line positions, colour burst and interlace, and
a known test pattern. It FM-modulates that with the deviation measured from a real 5.8 GHz VTX,
adds noise, and writes interleaved int8 IQ like `hackrf_transfer -r`.

    python3 synth_fpv.py ntsc out_ntsc.iq --seconds 0.4
    python3 synth_fpv.py pal  out_pal.iq  --seconds 0.4

Test pattern (frame rows, both fields interleaved):
  - top two thirds: 75% colour bars (white, yellow, cyan, green, magenta, red, blue, black)
  - bottom third, left: a horizontal grey ramp, with a white box that moves every frame
  - bottom third, right: a weave probe on grey, a white line on a top-field row directly above a
    black line on the next (bottom-field) row. A decoder that weaves the fields in the right order
    shows white above black.
"""
import argparse
import numpy as np

FS = 20e6
STANDARDS = {
    # Levels in volts on a 1 V p-p scale. Vertical interval: `eq` equalising half-lines, then as
    # many broad pulses, then as many equalising, starting at half-line slot `vA` / `vB` of the
    # frame (slot = 2 * line index + half). `top`/`bottom`: (first line index, last line index)
    # of each field's active picture, with half-lines at the top of the top field and the
    # bottom of the bottom field.
    "pal": dict(lines=625, fh=15625.0, fsc=4.43361875e6, sync=-0.3, black=0.0, white=0.7,
                burst_amp=0.15, burst_start=5.6e-6, burst_cycles=10, active_start=10.5e-6,
                active_len=52e-6, eq=5, vA=-5, vB=620, top=(22, 309), bottom=(335, 622), pal=True),
    "ntsc": dict(lines=525, fh=15734.264, fsc=3.579545e6, sync=-0.2857, black=0.0536, white=0.7143,
                 burst_amp=0.1429, burst_start=5.3e-6, burst_cycles=9, active_start=9.4e-6,
                 active_len=52.6e-6, eq=6, vA=0, vB=525, top=(282, 524), bottom=(20, 262), pal=False),
}
BARS = [(0.75, 0.75, 0.75), (0.75, 0.75, 0), (0, 0.75, 0.75), (0, 0.75, 0),
        (0.75, 0, 0.75), (0.75, 0, 0), (0, 0, 0.75), (0, 0, 0)]


def pattern(rows, frame):
    """RGB test image (rows x 1000) in 0..1; `rows` counts both fields."""
    img = np.zeros((rows, 1000, 3))
    top = (rows * 2 // 3) & ~1
    for i, c in enumerate(BARS):
        img[:top, i * 125:(i + 1) * 125] = c
    img[top:, :600] = np.linspace(0, 1, 600)[None, :, None]
    x0 = 20 + (frame * 37) % 440
    img[top + 10:top + 60, x0:x0 + 120] = 1.0
    img[top:, 600:] = 0.5
    probe = top + 40                                   # even row: top field
    img[probe, 620:980] = 1.0
    img[probe + 1, 620:980] = 0.0                     # odd row: bottom field
    return img, probe


def synth(std, seconds, cnr_db, seed=1):
    s = STANDARDS[std]
    N, T = s["lines"], 1 / s["fh"]
    half_T = T / 2
    n = int(seconds * FS)
    t = np.arange(n) / FS
    v = np.zeros(n)
    w = 2 * np.pi * s["fsc"]

    hs = np.floor(t / half_T).astype(np.int64)        # global half-line slot
    slot = hs % (2 * N)
    frame = hs // (2 * N)
    tin = t - hs * half_T                             # time within the half-line
    line = slot // 2                                  # line index within the frame, 0-based
    tl = t - (hs - hs % 2) * half_T                   # time within the full line
    e = s["eq"]

    in_eq = np.zeros(n, bool)
    in_broad = np.zeros(n, bool)
    for start in (s["vA"], s["vB"]):
        sub = (slot - start) % (2 * N)
        vi = sub < 3 * e
        in_eq |= vi & ((sub < e) | (sub >= 2 * e))
        in_broad |= vi & (sub >= e) & (sub < 2 * e)
    normal = ~(in_eq | in_broad)

    v[in_eq & (tin < 2.35e-6)] = s["sync"]
    v[in_broad & (tin < half_T - 4.7e-6)] = s["sync"]
    v[normal & (tl < 4.7e-6)] = s["sync"]

    gline = hs // 2                                   # global line count, for the PAL V-switch
    vsw = np.where(gline % 2 == 0, 1.0, -1.0) if s["pal"] else np.ones(n)
    bmask = normal & (tl >= s["burst_start"]) & (tl < s["burst_start"] + s["burst_cycles"] / s["fsc"])
    if s["pal"]:
        burst = s["burst_amp"] * (-np.sin(w * t) + vsw * np.cos(w * t)) / np.sqrt(2)  # 135 / 225 deg
    else:
        burst = -s["burst_amp"] * np.sin(w * t)                                        # 180 deg (-U)
    v[bmask] = burst[bmask]

    # map each line to a frame row: top field on even rows, bottom field on odd rows
    row_of = np.full(N, -1)
    halfmask = np.zeros(N, int)                       # 1 = first half active, 2 = second, 3 = both
    (t0, t1), (b0, b1) = s["top"], s["bottom"]
    for l in range(t0, t1 + 1):
        row_of[l] = 2 * (l - t0); halfmask[l] = 2 if l == t0 else 3
    for l in range(b0, b1 + 1):
        row_of[l] = 2 * (l - b0) + 1; halfmask[l] = 1 if l == b1 else 3
    rows = 2 * max(t1 - t0 + 1, b1 - b0 + 1)

    r = row_of[line]
    hm = halfmask[line]
    first_half = tl < half_T
    amask = normal & (r >= 0) & (tl >= s["active_start"]) & (tl < s["active_start"] + s["active_len"]) & \
        np.where(first_half, (hm & 1) > 0, (hm & 2) > 0)
    idx = np.flatnonzero(amask)
    scale = s["white"] - s["black"]
    for fr in np.unique(frame[idx]):
        sel = idx[frame[idx] == fr]
        img, probe = pattern(rows, int(fr))
        x = ((tl[sel] - s["active_start"]) / s["active_len"] * 999).astype(int)
        rgb = img[r[sel], x]
        Y = 0.299 * rgb[:, 0] + 0.587 * rgb[:, 1] + 0.114 * rgb[:, 2]
        U = 0.492 * (rgb[:, 2] - Y)
        V = 0.877 * (rgb[:, 0] - Y)
        c = U * np.sin(w * t[sel]) + vsw[sel] * V * np.cos(w * t[sel])
        v[sel] = s["black"] + scale * (Y + c)

    # FM: deviation measured from the real VTX (about 5.16 MHz per volt, white = higher frequency),
    # carrier ~3.5 MHz below the tuned frequency as the receiver tunes it
    f_inst = -3.5e6 + (v - 0.2) * 5.16e6
    x = 40 * np.exp(1j * 2 * np.pi * np.cumsum(f_inst) / FS)
    rng = np.random.default_rng(seed)
    x += (rng.normal(size=n) + 1j * rng.normal(size=n)) * (40 / np.sqrt(2) * 10 ** (-cnr_db / 20))
    iq = np.empty(2 * n, np.int8)
    iq[0::2] = np.clip(np.round(x.real), -128, 127)
    iq[1::2] = np.clip(np.round(x.imag), -128, 127)
    return iq, rows, probe


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("standard", choices=STANDARDS)
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=0.4)
    ap.add_argument("--cnr", type=float, default=20.0, help="carrier-to-noise ratio in dB")
    a = ap.parse_args()
    iq, rows, probe = synth(a.standard, a.seconds, a.cnr)
    iq.tofile(a.out)
    print(f"wrote {a.out}: {a.standard.upper()}, {a.seconds} s, CNR {a.cnr} dB, "
          f"{rows} picture rows, weave probe at rows {probe}/{probe + 1}")
