# Third-party notices

The FPV Receiver app binary statically links the following libraries. They are **not** covered by
this project's CC BY-NC 4.0 license. Each remains under its own license, reproduced in `licenses/`,
and the same files are included inside the app bundle at `Contents/Resources/Licenses`.

## libhackrf

- Source: https://github.com/greatscottgadgets/hackrf (host/libhackrf)
- Copyright (c) 2012-2022 Great Scott Gadgets, (c) 2012 Jared Boone, (c) 2013 Benjamin Vernoux
- License: BSD 3-Clause. See [licenses/libhackrf-LICENSE.txt](licenses/libhackrf-LICENSE.txt)

## libusb

- Source: https://github.com/libusb/libusb (version 1.0.30)
- License: GNU Lesser General Public License, version 2.1 or later.
  See [licenses/libusb-COPYING.txt](licenses/libusb-COPYING.txt)

libusb is linked statically. As the LGPL requires, you may modify libusb and relink the app against
your modified version: the complete source of FPV Receiver and its build script (`macos/build.sh`)
are in this repository, and `build.sh` links whichever `libusb-1.0.a` it finds under the Homebrew
prefix. You may also reverse-engineer the app for the purpose of debugging such modifications.
