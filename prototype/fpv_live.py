#!/usr/bin/env python3
"""Live analog FPV (PAL, FM) receiver for HackRF One, with a browser GUI.

    python3 fpv_live.py                 # live from HackRF, opens http://127.0.0.1:8765
    python3 fpv_live.py --file fpv.iq   # replay a 20 Msps int8 IQ capture instead
    python3 fpv_live.py --bench fpv.iq  # time the decoder on a capture, no GUI

Needs: numpy, scipy, pillow, and hackrf_transfer / hackrf_sweep on PATH.
"""
import argparse, io, json, os, re, signal, subprocess, sys, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import numpy as np
import scipy.ndimage as nd
import scipy.signal as ss
from PIL import Image

FS = 20_000_000
TUNE_OFFSET = 3_500_000      # tune above the channel so the HackRF DC spur sits off-carrier
BLOCK = 1_300_000            # complex samples decoded per frame (~65 ms, > 1 frame + 1 field)
RING = 16 * 1024 * 1024      # bytes of IQ kept (~420 ms)

BANDS = {
    "A": [5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725],
    "B": [5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866],
    "E": [5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945],
    "F": [5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880],
    "R": [5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917],
}
CHANNELS = [(f"{b}{i+1}", f) for b in "ABEFR" for i, f in enumerate(BANDS[b])]  # 1..40


# --------------------------------------------------------------------------- sources
class Ring:
    def __init__(self):
        self.buf = np.zeros(RING, np.int8)
        self.total = 0
        self.lock = threading.Lock()

    def reset(self):
        with self.lock:
            self.total = 0

    def write(self, b):
        a = np.frombuffer(b, np.int8)
        with self.lock:
            i = self.total % RING
            n = min(len(a), RING - i)
            self.buf[i:i + n] = a[:n]
            if n < len(a):
                self.buf[:len(a) - n] = a[n:]
            self.total += len(a)

    def latest(self, nbytes):
        with self.lock:
            end = self.total & ~1
            if end < nbytes:
                return None, end
            s = (end - nbytes) % RING
            if s + nbytes <= RING:
                out = self.buf[s:s + nbytes].copy()
            else:
                k = RING - s
                out = np.concatenate((self.buf[s:], self.buf[:nbytes - k]))
            return out, end


class HackRFSource:
    STAT = re.compile(r"([\d.]+) MB/second, average power ([-\d.]+) dBfs")

    def __init__(self, ring):
        self.ring = ring
        self.proc = None
        self.mbps = 0.0
        self.dbfs = None
        self.errors = []
        self.lock = threading.Lock()

    def start(self, freq_hz, amp, lna, vga):
        with self.lock:
            self._stop()
            self.ring.reset()
            self.dbfs = None
            cmd = ["hackrf_transfer", "-r", "-", "-f", str(int(freq_hz)), "-s", str(FS),
                   "-a", str(int(amp)), "-l", str(int(lna)), "-g", str(int(vga))]
            self.proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()
            threading.Thread(target=self._stderr, args=(self.proc,), daemon=True).start()

    def stop(self):
        with self.lock:
            self._stop()

    def _stop(self):
        p, self.proc = self.proc, None
        if p and p.poll() is None:
            p.send_signal(signal.SIGINT)
            try:
                p.wait(timeout=3)
            except subprocess.TimeoutExpired:
                p.kill(); p.wait()

    def _read(self, p):
        fd = p.stdout.fileno()
        while True:
            b = os.read(fd, 1 << 20)
            if not b:
                break
            self.ring.write(b)

    def _stderr(self, p):
        for line in iter(p.stderr.readline, b""):
            s = line.decode(errors="replace")
            m = self.STAT.search(s)
            if m:
                self.mbps, self.dbfs = float(m.group(1)), float(m.group(2))
            elif re.search(r"error|fail|HACKRF_ERROR|not found", s, re.I):
                self.errors = (self.errors + [s.strip()])[-5:]

    def running(self):
        return self.proc is not None and self.proc.poll() is None


class FileSource:
    """Replays a capture into the ring at the real 40 MB/s rate, looping."""
    def __init__(self, ring, path):
        self.ring, self.path = ring, path
        self.mbps, self.dbfs, self.errors = 0.0, None, []
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        mm = np.memmap(self.path, np.int8, mode="r")
        chunk, pos, t0, sent = 1 << 20, 0, time.time(), 0
        while True:
            if pos + chunk > len(mm):
                pos = 0
            self.ring.write(mm[pos:pos + chunk].tobytes())
            pos += chunk; sent += chunk
            ahead = sent / (2 * FS) - (time.time() - t0)
            if ahead > 0:
                time.sleep(ahead)
            self.mbps = sent / 1e6 / max(time.time() - t0, 1e-3)

    def start(self, *a): pass
    def stop(self): pass
    def running(self): return True


# --------------------------------------------------------------------------- decoder
class Reject(Exception):
    """A block whose sync or levels look wrong; the caller keeps showing the last good frame."""


class Decoder:
    B = 80                              # sync boxcar length
    SEG = np.arange(-20, 1300)          # samples kept per line, relative to sync position
    BURST = slice(20 + 108, 20 + 145)
    ACT0, ACTN = 210, 1040
    W, H2, SKIP, MARGIN = 768, 288, 22, 6
    WHITE = 1.05                        # peak white on the sync-referenced scale (black = 0)
    CLICK_T = 2.2                       # |inst. freq| (rad/sample) beyond any real video level: an FM click
    BAND_MIN = 150                      # clicked samples in a line's active video before it can be a band

    def __init__(self):
        self.lsos = ss.butter(4, 3.0e6, fs=FS, output="sos")
        self.csos = ss.butter(4, 1.1e6, fs=FS, output="sos")
        self.w = None                   # carrier offset, rad/sample (AFC)
        self.P = 1280.0                 # line period, samples
        # sync depth and burst amplitude references: slow averages over good fields.
        # Levels are fixed relative to sync, so there is no frame-to-frame AGC to pump.
        self.S_ref = None
        self.burst_ref = None
        self.rejects = 0
        self.prev = {}                  # last good planes per field slot, for temporal band repair
        xs = np.linspace(0, self.ACTN - 1, self.W)
        self.i0 = np.minimum(xs.astype(int), self.ACTN - 2)
        self.fr = (xs - self.i0).astype(np.float32)
        # chroma is ~1 MHz wide: process it at quarter width, then interpolate up
        cw = self.W // 4
        xc = np.linspace(0, self.ACTN - 1, cw)
        self.ci0 = np.minimum(xc.astype(int), self.ACTN - 2)
        self.cfr = (xc - self.ci0).astype(np.float32)
        xu = np.linspace(0, cw - 1, self.W)
        self.ui0 = np.minimum(xu.astype(int), cw - 2)
        self.ufr = (xu - self.ui0).astype(np.float32)
        self.stats = {}

    def _resample(self, a):
        return a[:, self.i0] * (1 - self.fr) + a[:, self.i0 + 1] * self.fr

    def _chroma_plane(self, a):
        small = a[:, self.ci0] * (1 - self.cfr) + a[:, self.ci0 + 1] * self.cfr
        small = nd.median_filter(small, size=(3, 3))
        return small[:, self.ui0] * (1 - self.ufr) + small[:, self.ui0 + 1] * self.ufr

    def decode(self, raw, color=True, sat=1.0, weave=False):
        x = raw.astype(np.float32).view(np.complex64)
        x = x - x.mean()
        p = x[1:] * np.conj(x[:-1])
        wn = float(np.angle(p.sum()))
        self.w = wn if self.w is None else float(np.angle(0.8 * np.exp(1j * self.w) + 0.2 * np.exp(1j * wn)))
        d = np.angle(p * np.complex64(np.exp(-1j * self.w))).astype(np.float32)

        # FM click suppression: a click is a 2*pi phase slip, a spike in d well outside the video
        # range. Mask it (plus 2 samples either side) and bridge the gap by interpolation.
        m = np.convolve(np.abs(d) > self.CLICK_T, np.ones(5), "same") > 0
        if m.any():
            bi, gi = np.flatnonzero(m), np.flatnonzero(~m)
            d[bi] = np.interp(bi, gi, d[gi])
        self.ccum = np.concatenate(([0], np.cumsum(m, dtype=np.int32)))

        B = self.B
        cs = np.concatenate(([0.0], np.cumsum(d, dtype=np.float64)))
        box = ((cs[B:] - cs[:-B]) / B).astype(np.float32)
        sub = box[::13]
        tip, med = np.percentile(sub, 1.0), np.median(sub)
        thr = tip + 0.5 * (med - tip)
        st = {"carrier_off_hz": self.w * FS / (2 * np.pi), "click_pct": float(m.mean() * 100)}

        # horizontal sync: PLL over predicted line starts
        k0 = int(np.argmin(box[:1400]))
        if box[k0] >= thr:
            st["lock"] = 0.0
            self.stats = st
            return None
        pos, ok = [], []
        pred, P = float(k0), self.P
        while pred + P + 1400 < len(box):
            a = max(int(pred) - 40, 0)
            win = box[a:a + 81]
            k = int(np.argmin(win))
            good = win[k] < thr
            if good:
                pred += 0.35 * ((a + k) - pred)
            pos.append(pred); ok.append(good)
            pred += P
        pos, ok = np.array(pos), np.array(ok)
        st["lock"] = float(ok.mean())
        if st["lock"] < 0.9:
            self.stats = st
            raise Reject("sync lock %.2f" % st["lock"])
        if ok.sum() > 100:
            li = np.arange(len(pos))
            Pm = np.polyfit(li[ok], pos[ok], 1)[0]
            if 1270 < Pm < 1290:
                self.P = 0.9 * self.P + 0.1 * Pm
        st["line_us"] = self.P / FS * 1e6

        # vertical sync: lines mostly at sync level are the broad pulses
        grid = pos.astype(int)[:, None] + np.arange(100, 1180, 6)[None, :]
        lf = (box[np.minimum(grid, len(box) - 1)] < thr).mean(1)
        vs = lf > 0.35
        starts = np.where(vs & ~np.concatenate(([False], vs[:-1])))[0]
        starts = [s for s in starts if s > 0]
        # drop starts inside the same vertical interval
        st_f = []
        for s in starts:
            if not st_f or s - st_f[-1] > 50:
                st_f.append(s)
        need = self.SKIP + self.H2 + 1
        usable = [s for s in st_f if s - self.MARGIN >= 0 and s + need < len(pos)]
        if len(st_f) >= 2:
            st["field_lines"] = int(st_f[1] - st_f[0])
        if not usable:
            self.stats = st
            return None

        fsc = 283.7516 / self.P
        f0 = usable[0]
        self.patched = 0
        fa = self._field(d, pos, f0, fsc, color, 0)
        if weave and len(usable) >= 2:
            f1 = usable[1]
            fb = self._field(d, pos, f1, fsc, color, 1)
            top_first = (f1 - f0) >= 313
            planes = []
            for pa, pb in zip(fa, fb):
                fr = np.empty((2 * self.H2, self.W), np.float32)
                fr[0::2], fr[1::2] = (pa, pb) if top_first else (pb, pa)
                planes.append(fr)
        else:
            planes = [np.repeat(pl, 2, axis=0) for pl in fa]

        g = 1.0 / self.WHITE
        Y = planes[0] * g
        if color:
            U, V = planes[1] * g * sat, planes[2] * g * sat
            R = Y + V / 0.877
            Bc = Y + U / 0.492
            G = (Y - 0.299 * R - 0.114 * Bc) / 0.587
            rgb = np.stack([R, G, Bc], -1)
        else:
            rgb = np.repeat(Y[:, :, None], 3, axis=2)
        st["patched"] = self.patched
        self.stats = st
        return np.clip(rgb * 255, 0, 255).astype(np.uint8)

    def _field(self, d, pos, f, fsc, color, slot):
        return self._patch(self._field_planes(d, pos, f, fsc, color), self._band_flags(pos, f), slot)

    def _band_flags(self, pos, f):
        """Lines hit by an interference burst: click count far above the lines around them."""
        p = pos[np.arange(f + self.SKIP, f + self.SKIP + self.H2)].astype(int) + self.ACT0
        n = self.ccum[p + self.ACTN] - self.ccum[p]
        local = nd.median_filter(n, size=15, mode="nearest")
        flag = n > np.maximum(self.BAND_MIN, 3 * local)
        return flag | np.roll(flag, 1) | np.roll(flag, -1)   # PAL delay line smears into neighbours

    def _patch(self, planes, flag, slot):
        prev = self.prev.get(slot)
        if prev is not None and len(prev) != len(planes):
            prev = None
        n = len(flag)
        if flag.any():
            bad = np.flatnonzero(flag)
            self.patched += len(bad)
            for run in np.split(bad, np.flatnonzero(np.diff(bad) > 1) + 1):
                a, b = run[0] - 1, run[-1] + 1
                if len(run) <= 3 and a >= 0 and b < n or prev is None:
                    if a >= 0 and b < n:
                        t = ((run - a) / (b - a)).astype(np.float32)[:, None]
                        for pl in planes:
                            pl[run] = pl[a] * (1 - t) + pl[b] * t
                    else:
                        src = a if a >= 0 else b
                        if 0 <= src < n:
                            for pl in planes:
                                pl[run] = pl[src]
                else:
                    for pl, pp in zip(planes, prev):
                        pl[run] = pp[run]
        self.prev[slot] = planes
        return planes

    def _field_planes(self, d, pos, f, fsc, color):
        L = np.arange(f + self.SKIP - self.MARGIN, f + self.SKIP + self.H2)
        idx = pos[L].astype(int)[:, None] + self.SEG[None, :]
        seg = d[idx]
        luma = ss.sosfiltfilt(self.lsos, seg, axis=1)
        tip = np.median(luma[:, 30:80])
        blank = np.median(luma[:, 170:210])
        S = blank - tip
        if self.S_ref is None:
            if S <= 0.05:
                raise Reject("no sync depth")
            self.S_ref = S
        elif not 0.8 < S / self.S_ref < 1.25:
            raise Reject("sync depth %.3f vs %.3f" % (S, self.S_ref))
        self.S_ref += 0.05 * (S - self.S_ref)
        S = self.S_ref
        act = slice(20 + self.ACT0, 20 + self.ACT0 + self.ACTN)
        Y = self._resample(((luma - blank) / S * (0.3 / 0.7))[self.MARGIN:, act])
        if not color:
            return (Y,)
        lo = np.exp(-2j * np.pi * ((idx.astype(np.float64) * fsc) % 1.0)).astype(np.complex64)
        C = ss.sosfiltfilt(self.csos, seg * lo, axis=1)
        b = C[:, self.BURST].mean(1)
        ref = np.convolve(b, np.ones(8), "same")
        ref /= np.abs(ref) + 1e-12
        rel = np.angle(b * np.conj(ref))
        alt = (-1.0) ** np.arange(len(L))
        s0 = -np.sign(np.sum(np.sign(rel) * alt)) or 1.0
        vsw = (s0 * alt)[:, None]
        Cd = -C * np.conj(ref)[:, None]
        amp = float(np.median(np.abs(b)))
        vconf = float(abs(np.mean(np.sign(rel) * alt)))
        self.fdbg = {"S": float(S), "blank": float(blank), "burst": amp, "vconf": vconf}
        if self.burst_ref is None:
            self.burst_ref = amp
        good_burst = vconf > 0.5 and 0.6 < amp / self.burst_ref < 1.6
        if good_burst:
            self.burst_ref += 0.05 * (amp - self.burst_ref)
        else:  # colour killer: burst unreliable this field, show it monochrome
            return (Y, np.zeros_like(Y), np.zeros_like(Y))
        amp = self.burst_ref
        U = Cd.real / amp * (0.15 / 0.7)
        V = Cd.imag / amp * (0.15 / 0.7) * vsw
        U[1:] = 0.5 * (U[1:] + U[:-1]); V[1:] = 0.5 * (V[1:] + V[:-1])
        U = self._chroma_plane(U[self.MARGIN:, act])
        V = self._chroma_plane(V[self.MARGIN:, act])
        return (Y, U, V)


# --------------------------------------------------------------------------- app
class App:
    def __init__(self, file=None):
        self.ring = Ring()
        self.file = file
        self.src = FileSource(self.ring, file) if file else HackRFSource(self.ring)
        self.dec = Decoder()
        self.cfg = {"ch": 5, "amp": 1, "lna": 32, "vga": 30, "color": 1, "sat": 1.0, "weave": 0}
        self.msg = "replaying " + os.path.basename(file) if file else ""
        self.jpeg, self.fid = None, 0
        self.cond = threading.Condition()
        self.fps, self.dec_ms = 0.0, 0.0
        self.busy = threading.Lock()   # held while scanning (radio stopped)
        self.scan_result = []
        threading.Thread(target=self._loop, daemon=True).start()

    def freq(self):
        return CHANNELS[self.cfg["ch"] - 1][1] * 1_000_000

    def tune(self):
        c = self.cfg
        self.dec.w = None
        self.src.start(self.freq() + TUNE_OFFSET, c["amp"], c["lna"], c["vga"])

    def _loop(self):
        last_end, t_last = -1, time.time()
        while True:
            if self.busy.locked():
                time.sleep(0.05); continue
            raw, end = self.ring.latest(2 * BLOCK)
            if raw is None or end == last_end or end < 2 * FS * 0.15:   # skip first 150 ms after tune
                time.sleep(0.005); continue
            last_end = end
            t0 = time.time()
            try:
                img = self.dec.decode(raw, bool(self.cfg["color"]), float(self.cfg["sat"]), bool(self.cfg["weave"]))
            except Reject:          # bad block: hold the previous frame
                self.dec.rejects += 1
                img = None
            except Exception as e:  # keep the stream alive on a bad block
                self.msg = f"decode error: {e}"
                img = None
            self.dec_ms = 0.9 * self.dec_ms + 0.1 * (time.time() - t0) * 1000
            # front-end protection: drop the RF amp if the level gets hot
            if self.src.dbfs is not None and self.cfg["amp"] and self.src.dbfs > -6:
                self.cfg["amp"] = 0
                self.msg = f"level {self.src.dbfs:.1f} dBFS with amp on: amp switched off to protect front end"
                self.tune()
                continue
            if img is None:
                continue
            buf = io.BytesIO()
            Image.fromarray(img).save(buf, "JPEG", quality=82)
            now = time.time()
            self.fps = 0.9 * self.fps + 0.1 / max(now - t_last, 1e-3)
            t_last = now
            with self.cond:
                self.jpeg, self.fid = buf.getvalue(), self.fid + 1
                self.cond.notify_all()

    def status(self):
        c, st = self.cfg, self.dec.stats
        name, mhz = CHANNELS[c["ch"] - 1]
        off = st.get("carrier_off_hz")
        return {
            **c, "name": name, "mhz": mhz, "file": bool(self.file),
            "carrier_mhz": (self.freq() + TUNE_OFFSET + off) / 1e6 if off is not None else None,
            "lock": st.get("lock"), "line_us": st.get("line_us"), "field_lines": st.get("field_lines"),
            "mbps": self.src.mbps, "dbfs": self.src.dbfs, "fps": self.fps, "dec_ms": self.dec_ms, "rejects": self.dec.rejects,
            "running": self.src.running(), "errors": self.src.errors, "msg": self.msg,
            "scan": self.scan_result,
        }

    def scan(self):
        if self.file:
            self.msg = "scan needs the live HackRF"
            return
        with self.busy:
            self.src.stop()
            c = self.cfg
            cmd = ["hackrf_sweep", "-f", "5620:5980", "-w", "500000", "-a", str(c["amp"]),
                   "-l", str(c["lna"]), "-g", str(c["vga"]), "-N", "12"]
            out = subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout
            fr, pw = [], []
            for line in out.splitlines():
                r = line.split(",")
                if len(r) < 7:
                    continue
                lo, w = float(r[2]), float(r[4])
                for i, v in enumerate(r[6:]):
                    fr.append(lo + w * (i + 0.5)); pw.append(10 ** (float(v) / 10))
            order = np.argsort(fr)
            fr, pw = np.array(fr)[order], np.array(pw)[order]
            if not len(pw):
                self.msg = "scan: hackrf_sweep returned no data"
                self.tune()
                return
            floor = np.median(pw)
            # locate the ~16 MHz-wide FM video hump, then snap to the nearest channel
            sm = np.convolve(pw, np.ones(32) / 32, "same")
            k = int(np.argmax(sm[32:-32])) + 32
            peak_db, peak_f = 10 * np.log10(sm[k] / floor), fr[k]
            n = min(range(40), key=lambda i: abs(CHANNELS[i][1] * 1e6 - peak_f)) + 1
            name, mhz = CHANNELS[n - 1]
            # other channels on the same frequency (bands overlap, e.g. F8 = R7)
            same = [c[0] for c in CHANNELS if c[1] == mhz and c[0] != name]
            self.scan_result = [{"ch": n, "name": name, "mhz": mhz, "db": round(peak_db, 1),
                                 "peak_mhz": round(peak_f / 1e6, 1)}]
            if peak_db > 3.0:   # report only; the user picks the channel
                self.msg = (f"scan: VTX centred near {peak_f/1e6:.1f} MHz, +{peak_db:.1f} dB, nearest channel "
                            f"{n} ({name}, {mhz} MHz)"
                            + (f", same frequency as {', '.join(same)}" if same else ""))
            else:
                self.msg = "scan: no VTX found above the noise floor"
            self.tune()


PAGE = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>FPV Receiver</title>
<style>
:root{--bg:#111316;--panel:#1b1e23;--line:#2c3139;--fg:#e6e8eb;--dim:#8b93a0;--acc:#3b82f6;--ok:#22c55e;--warn:#f59e0b;--bad:#ef4444}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.4 -apple-system,system-ui,sans-serif}
.wrap{display:flex;gap:16px;padding:16px;flex-wrap:wrap}
.video{flex:1 1 640px;min-width:0}.video img{width:100%;aspect-ratio:4/3;background:#000;border-radius:8px;display:block;object-fit:contain}
.side{flex:0 1 380px;display:flex;flex-direction:column;gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px}
h2{font-size:12px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:0 0 8px}
.grid{display:grid;grid-template-columns:24px repeat(8,1fr);gap:4px;align-items:center}
.grid .b{color:var(--dim);font-weight:600;text-align:center}
.grid button{background:#242830;color:var(--fg);border:1px solid var(--line);border-radius:5px;padding:4px 0;font-size:11px;cursor:pointer;line-height:1.1}
.grid button small{display:block;color:var(--dim);font-size:9px}
.grid button.on{background:var(--acc);border-color:var(--acc)}.grid button.on small{color:#dbe7ff}
.row{display:flex;align-items:center;gap:8px;margin:6px 0}.row label{width:70px;color:var(--dim)}.row input[type=range]{flex:1}
.row output{width:40px;text-align:right;font-variant-numeric:tabular-nums}
.stats{display:grid;grid-template-columns:auto 1fr;gap:3px 12px;font-variant-numeric:tabular-nums}.stats span:nth-child(odd){color:var(--dim)}
.btn{background:var(--acc);color:#fff;border:0;border-radius:6px;padding:7px 12px;cursor:pointer;font-weight:600}
.msg{color:var(--warn);min-height:1.2em;font-size:12px}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.hdr{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px}.hdr .big{font-size:20px;font-weight:700}
</style></head><body><div class="wrap">
<div class="video"><img id="v" src="/stream" alt="live video"><div class="msg" id="msg"></div></div>
<div class="side">
 <div class="card"><div class="hdr"><span class="big" id="cur">-</span><span id="carrier" class="dim"></span></div>
  <div class="grid" id="grid"></div>
  <div class="row" style="margin-top:10px"><button class="btn" onclick="scan()" title="Sweeps 5.62-5.98 GHz and reports where the VTX is. Does not change channel.">Find VTX</button><span id="scanres" style="color:var(--dim);font-size:12px"></span></div>
  <div style="color:var(--dim);font-size:12px">Arrow keys step channels.</div></div>
 <div class="card"><h2>Receiver</h2>
  <div class="row"><label>RF amp</label><input type="checkbox" id="amp" onchange="set('amp',+this.checked)"><span style="color:var(--dim);font-size:12px">+11 dB, keep off when drone is close</span></div>
  <div class="row"><label>LNA</label><input type="range" id="lna" min="0" max="40" step="8" oninput="lnaO.value=this.value" onchange="set('lna',this.value)"><output id="lnaO"></output></div>
  <div class="row"><label>VGA</label><input type="range" id="vga" min="0" max="62" step="2" oninput="vgaO.value=this.value" onchange="set('vga',this.value)"><output id="vgaO"></output></div></div>
 <div class="card"><h2>Picture</h2>
  <div class="row"><label>Colour</label><input type="checkbox" id="color" onchange="set('color',+this.checked)"></div>
  <div class="row"><label>Saturation</label><input type="range" id="sat" min="0" max="2.5" step="0.1" oninput="satO.value=this.value" onchange="set('sat',this.value)"><output id="satO"></output></div>
  <div class="row"><label>Interlace</label><select id="weave" onchange="set('weave',this.value)"><option value="0">Bob (smooth motion)</option><option value="1">Weave (full detail)</option></select></div></div>
 <div class="card"><h2>Signal</h2><div class="stats" id="stats"></div></div>
</div></div>
<script>
const CH=%CHANNELS%;let st={};
const grid=document.getElementById('grid');
"ABEFR".split('').forEach(b=>{const l=document.createElement('div');l.className='b';l.textContent=b;grid.appendChild(l);
 CH.forEach((c,i)=>{if(c[0][0]!==b)return;const e=document.createElement('button');e.id='c'+(i+1);
  e.innerHTML=(i+1)+'<small>'+c[1]+'</small>';e.title=c[0]+' '+c[1]+' MHz';e.onclick=()=>tune(i+1);grid.appendChild(e);});});
function tune(n){fetch('/tune?ch='+n).then(poll)}
function set(k,v){fetch('/set?'+k+'='+v).then(poll)}
function scan(){document.getElementById('scanres').textContent='scanning...';fetch('/scan').then(poll)}
document.addEventListener('keydown',e=>{if(e.target.tagName==='INPUT'||e.target.tagName==='SELECT')return;
 if(e.key==='ArrowRight'||e.key==='ArrowDown')tune(st.ch%40+1);if(e.key==='ArrowLeft'||e.key==='ArrowUp')tune((st.ch+38)%40+1)});
const f=(v,d,u)=>v==null?'-':v.toFixed(d)+(u||'');
function poll(){fetch('/status').then(r=>r.json()).then(s=>{st=s;
 document.querySelectorAll('.grid button').forEach(b=>b.classList.toggle('on',b.id==='c'+s.ch));
 document.getElementById('cur').textContent='Ch '+s.ch+' / '+s.name+' / '+s.mhz+' MHz';
 document.getElementById('carrier').textContent=s.carrier_mhz?'measured '+s.carrier_mhz.toFixed(2)+' MHz':'';
 for(const k of ['amp','color'])document.getElementById(k).checked=!!s[k];
 for(const k of ['lna','vga','sat']){const e=document.getElementById(k);if(document.activeElement!==e){e.value=s[k];document.getElementById(k+'O').value=s[k]}}
 document.getElementById('weave').value=s.weave;
 const lock=s.lock==null?'-':Math.round(s.lock*100)+'%';const lc=s.lock>0.9?'ok':s.lock>0.5?'warn':'bad';
 const dc=s.dbfs==null?'':s.dbfs>-6?'bad':s.dbfs>-12?'warn':'ok';
 const tc=s.mbps>39?'ok':'warn';
 document.getElementById('stats').innerHTML=
  '<span>Sync lock</span><span class="'+lc+'">'+lock+'</span>'+
  '<span>Line period</span><span>'+f(s.line_us,3,' us')+'</span>'+
  '<span>Field lines</span><span>'+(s.field_lines||'-')+'</span>'+
  '<span>Level</span><span class="'+dc+'">'+f(s.dbfs,1,' dBFS')+'</span>'+
  '<span>USB rate</span><span class="'+tc+'">'+f(s.mbps,1,' MB/s')+'</span>'+
  '<span>Display</span><span>'+f(s.fps,1,' fps')+' ('+f(s.dec_ms,0,' ms')+'/frame)</span>'+
  '<span>Bad fields held</span><span>'+(s.rejects||0)+'</span>'+
  '<span>Source</span><span>'+(s.file?'file replay':(s.running?'HackRF live':'<span class=bad>stopped</span>'))+'</span>';
 document.getElementById('msg').textContent=[s.msg].concat(s.errors||[]).filter(Boolean).join('  |  ');
 if(s.scan&&s.scan.length)document.getElementById('scanres').textContent='found '+s.scan.map(x=>x.name+' @ '+x.peak_mhz+' MHz, +'+x.db+' dB').join(', ');
})}
poll();setInterval(poll,700);
</script></body></html>"""


def make_handler(app):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a): pass

        def _send(self, body, ctype="application/json"):
            b = body if isinstance(body, bytes) else body.encode()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(b)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(b)

        def do_GET(self):
            u = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(u.query).items()}
            if u.path == "/":
                self._send(PAGE.replace("%CHANNELS%", json.dumps(CHANNELS)), "text/html; charset=utf-8")
            elif u.path == "/status":
                self._send(json.dumps(app.status()))
            elif u.path == "/tune":
                ch = int(q.get("ch", app.cfg["ch"]))
                if 1 <= ch <= 40:
                    app.cfg["ch"] = ch; app.msg = ""
                    threading.Thread(target=app.tune, daemon=True).start()
                self._send("{}")
            elif u.path == "/set":
                retune = False
                for k, v in q.items():
                    if k in ("amp", "lna", "vga"):
                        app.cfg[k] = int(float(v)); retune = True
                    elif k in ("color", "weave"):
                        app.cfg[k] = int(float(v))
                    elif k == "sat":
                        app.cfg[k] = float(v)
                if retune:
                    app.msg = ""
                    threading.Thread(target=app.tune, daemon=True).start()
                self._send("{}")
            elif u.path == "/scan":
                threading.Thread(target=app.scan, daemon=True).start()
                self._send("{}")
            elif u.path == "/stream":
                self.send_response(200)
                self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                last = -1
                try:
                    while True:
                        with app.cond:
                            app.cond.wait_for(lambda: app.fid != last, timeout=2)
                            jpg, last = app.jpeg, app.fid
                        if jpg is None:
                            continue
                        self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\nContent-Length: "
                                         + str(len(jpg)).encode() + b"\r\n\r\n" + jpg + b"\r\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
            else:
                self.send_error(404)
    return H


def bench(path):
    dec = Decoder()
    mm = np.memmap(path, np.int8, mode="r")
    for color, weave in [(False, False), (True, False), (True, True)]:
        ts = []
        for k in range(12):
            raw = np.array(mm[k * 20_000_000: k * 20_000_000 + 2 * BLOCK])
            t = time.time()
            try:
                img = dec.decode(raw, color, 1.0, weave)
            except Reject:
                img = None
            ts.append(time.time() - t)
        print(f"color={color} weave={weave}: {np.median(ts)*1000:.0f} ms/frame, lock {dec.stats.get('lock', 0):.2f}, "
              f"line {dec.stats.get('line_us', 0):.4f} us, field {dec.stats.get('field_lines')}")
        if img is not None:
            Image.fromarray(img).save(f"bench_c{int(color)}_w{int(weave)}.jpg")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--file", help="replay a 20 Msps int8 IQ capture instead of the HackRF")
    ap.add_argument("--bench", help="time the decoder on a capture and exit")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--ch", type=int, default=5, help="start channel 1..40 (default 5 = A5)")
    ap.add_argument("--no-amp", action="store_true", help="start with the RF amp off")
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    if a.bench:
        return bench(a.bench)
    # a background launch ignores SIGINT, so make SIGTERM shut down cleanly too
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    app = App(a.file)
    app.cfg["ch"] = a.ch
    if a.no_amp:
        app.cfg["amp"] = 0
    app.tune()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(app))
    url = f"http://127.0.0.1:{a.port}/"
    print(f"FPV receiver running at {url}  (Ctrl-C to stop)")
    if not a.no_browser:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        app.src.stop()


if __name__ == "__main__":
    main()
