# FPV Receiver

A native macOS app that turns a **HackRF One** into a live receiver for **analog 5.8 GHz FPV video**.
It demodulates the FM video signal from a drone's video transmitter (VTX), decodes **PAL or NTSC**
composite video in color, and shows it in a window you can watch, snapshot and record.

Version 0.2. Built and tested with a HackRF One + PortaPack (Mayhem firmware, in HackRF mode) receiving
a JJPRO P175 drone's 600 mW, 48-channel VTX with an 800TVL PAL camera.

## Features

- Live color decoding at 20 Msps, around 30 fps on Apple Silicon
- **PAL and NTSC**, detected automatically from the line period, or forced in the inspector
- All 48 channels, named the way the VTX's LED display shows them (for example `H:1`)
- **Find VTX**: searches every channel for PAL sync and reports the measured carrier frequency
- **Recording** to H.264 MP4 and **snapshots** to PNG
- Automatic gain (VGA first, then LNA), with the RF amplifier never switched on automatically
- Front-end protection: the RF amplifier switches itself off if the level passes -6 dBFS
- Interference band repair: lines hit by another transmitter are rebuilt from neighboring lines or the previous field
- FM click suppression, bad-field rejection (the last good frame is held), and a color killer for unreliable bursts
- Replay of raw IQ captures (`hackrf_transfer -r` files) without any hardware
- Live signal readout: sync lock, level, line period, field lines, click noise, USB rate, frame rate

## Requirements

- A Mac with **Apple Silicon**, running **macOS 14 Sonoma or later**
- A **HackRF One** on a USB port that can sustain 40 MB/s. A PortaPack must be switched to HackRF mode.
- An analog 5.8 GHz FPV transmitter sending **PAL or NTSC** video. The camera sets the standard;
  many FPV cameras can be switched between the two in their on-screen menu.
- Ideally a 5.8 GHz antenna on the HackRF (SMA male, matching the VTX antenna's polarization, usually RHCP)

No Homebrew, Python or drivers are needed to run the app: libhackrf and libusb are linked into it.

## Install

1. Download `FPV-Receiver-0.1-macOS-arm64.zip` from the [Releases](../../releases) page and unzip it.
2. Move **FPV Receiver.app** to Applications, or anywhere you like.
3. The app is not notarized, so the first time, **right-click it and choose Open**, then confirm.
   Or clear the quarantine flag: `xattr -dr com.apple.quarantine "/Applications/FPV Receiver.app"`

## Use

1. Connect the HackRF. The app picks it up automatically and reconnects if it is unplugged.
2. Pick the channel shown on the drone's VTX display from the toolbar menu, the Channel menu, or the
   band and slot pickers in the inspector. If you do not know it, click **Find VTX**.
3. Adjust the receiver in the inspector: RF amplifier, LNA and VGA, or turn on **Automatic gain**.

| Shortcut | Action |
|---|---|
| ⌘] / ⌘[ or → / ← | Next / previous channel |
| ⌘R | Start / stop recording (saved to `~/Movies/FPV Receiver`) |
| ⇧⌘S | Save snapshot (saved to `~/Pictures/FPV Receiver`) |
| ⌥⌘F | Find VTX |
| ⌘O | Replay an IQ recording |
| ⌥⌘I | Show / hide the inspector |

**Deinterlace**: *Bob* shows each field line-doubled for smooth motion. *Weave* interleaves both fields
for full detail, but shows combing on fast motion. NTSC's 480 active lines are scaled onto the same
768 × 576 canvas as PAL.

**Video standard**: *Automatic* tells PAL (1280 samples per line) from NTSC (1271) by the measured line
period. Force PAL or NTSC in the inspector if a weak signal makes detection hesitate.

### Channel table (MHz)

| Display | Band | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 |
|---|---|---|---|---|---|---|---|---|---|
| A | Boscam A | 5865 | 5845 | 5825 | 5805 | 5785 | 5765 | 5745 | 5725 |
| B | Boscam B | 5733 | 5752 | 5771 | 5790 | 5809 | 5828 | 5847 | 5866 |
| C | Boscam E | 5705 | 5685 | 5665 | 5645 | 5885 | 5905 | 5925 | 5945 |
| D | FatShark | 5740 | 5760 | 5780 | 5800 | 5820 | 5840 | 5860 | 5880 |
| H | RaceBand | 5658 | 5695 | 5732 | 5769 | 5806 | 5843 | 5880 | 5917 |
| L | Low Band | 5362 | 5399 | 5436 | 5473 | 5510 | 5547 | 5584 | 5621 |

## Safety

- **Protect the HackRF front end.** A 600 mW VTX is about +28 dBm. At bench distance that can reach
  the damage threshold of the HackRF's input. Keep the drone at least 1 m away, start with the RF
  amplifier off, and watch the Level readout, keeping it well below 0 dBFS.
- **Protect the VTX.** On the bench a VTX gets no cooling from prop wash and can overheat. Use its
  low-power setting indoors, and never power it without its antenna attached.
- **Propellers off** whenever the drone is powered on the bench.
- **Mind Wi-Fi.** Channels around 5745 to 5825 MHz share spectrum with 5 GHz Wi-Fi (channels 149 to 165),
  which shows up as noise bands. Channels outside that range are usually much cleaner.
- Transmitting on 5.8 GHz is regulated differently in each country. This app only receives.

## Build from source

Requires Xcode (Swift 6 toolchain) and `brew install hackrf`, which provides the static
`libhackrf.a` and `libusb-1.0.a` that get linked into the app.

```bash
cd macos
./build.sh
```

The app and a release zip are written to `macos/build/`. There is no Xcode project: `build.sh` calls
`swiftc` directly, assembles the bundle, generates the icon and ad-hoc signs it.

### Testing

`tools/synth_fpv.py` synthesises a standards-accurate PAL or NTSC transmission (sync, equalizing and
broad pulses at the standard line positions, color burst, interlace, color bars and a weave probe),
FM-modulates it like a real VTX and writes HackRF-style IQ. `macos/Tests/dectest` decodes any IQ capture
and prints the standard, sync lock, line period and field length for each block:

```bash
python3 tools/synth_fpv.py ntsc /tmp/ntsc.iq
cd macos
swiftc -O -import-objc-header Sources/Bridging.h -I "$(brew --prefix)/include" \
    Sources/Decoder.swift Tests/dectest/main.swift -o /tmp/dectest
/tmp/dectest /tmp/ntsc.iq
```

The synthetic files can also be replayed in the app with **File > Open IQ Recording**.

## How it works

| Stage | What happens |
|---|---|
| Capture | libhackrf streams 8-bit IQ at 20 Msps (40 MB/s), tuned 3.5 MHz above the channel to keep the HackRF's DC spur off the carrier |
| FM demodulation | Phase difference of consecutive samples, with automatic frequency correction from the mean phase step |
| Click suppression | Phase slips beyond any real video level are masked and bridged by interpolation |
| Standard | The autocorrelation peak of the sync signal gives the line period: 1280 samples (64 µs) is PAL, 1271.1 (63.556 µs) is NTSC |
| Line sync | A boxcar-filtered sync detector drives a PLL at the standard's line period, refined by a least-squares fit |
| Field sync | Lines dominated by broad vertical-sync pulses mark each field; fields alternate 312/313 lines (PAL) or 262/263 (NTSC), and the short/long pattern identifies the top field for weaving |
| Levels | Luma is scaled against the sync tip and blanking level, so brightness is fixed, with no frame-to-frame AGC |
| Color | The subcarrier (4.43361875 MHz PAL, 3.579545 MHz NTSC) is mixed to baseband and referenced to the color burst; PAL adds V-switch detection and a delay-line average |
| Repair | Lines with abnormal amplitude fluctuation or click density are replaced |
| Output | 768 × 576 BGRA frames to the window, and to AVFoundation for H.264 recording |

`prototype/fpv_live.py` is the earlier Python version: the PAL decoder with a browser-based UI.
It needs numpy, scipy, pillow and the `hackrf_transfer` command-line tool.

## Limitations

- NTSC support is verified against standards-accurate synthetic signals (see Testing), not yet against a
  real NTSC camera. PAL is verified on real hardware.
- The HackRF's 8-bit ADC and 20 Msps ceiling clip the FM sidebands, so the picture is noisier than an
  analog goggle receiver. A weak signal shows up as speckle, and a proper antenna helps most.
- Latency is roughly 100 to 150 ms. Fine for watching, not goggle-grade for flying.
- Apple Silicon only. An Intel build would need universal builds of libhackrf and libusb.

## License

Copyright (c) 2026 Martin Bogomolni

FPV Receiver is licensed under the
[Creative Commons Attribution-NonCommercial 4.0 International License](https://creativecommons.org/licenses/by-nc/4.0/)
(CC BY-NC 4.0). You may share and adapt it for non-commercial purposes, with attribution.
See [LICENSE](LICENSE).

Third-party components keep their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
