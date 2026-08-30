# Third-Party Notices

This project is licensed under the MIT License (see `LICENSE`). It relies on
the following third-party components.

## libusb

- License: LGPL-2.1 — https://libusb.info
- Not bundled; loaded dynamically at runtime via dart:ffi. Install
  separately (e.g. `brew install libusb`, `apt install libusb-1.0-0`).
- Bindings are generated locally from a `libusb.h` you point the generator
  at (see README) — how you obtain that header is up to you (package
  manager, manual download, submodule, ...). No libusb source is
  redistributed.
