# unified_usb

A unified USB API for Dart — works both natively (desktop/CLI, via libusb) and in the browser (via WebUSB).

> **⚠️ Work in progress.** This project is under active development. The API is
> not yet stable and may change without notice.

## Features

- List, open, and claim interfaces on USB devices
- Control, bulk, and interrupt transfers
- One codebase, two backends: native (libusb) and web (WebUSB)

## TODO's before pub release
- Async libusb implementation

## Regenerating native bindings

Only needed if you're changing the native backend itself. Point the generator
at a directory containing `libusb.h` (from `brew install libusb`,
`apt install libusb-1.0-0-dev`, a manual download, etc. — any source works):

```sh
dart run tool/generate_bindings.dart --libusb-include=/path/to/include
```

or via an environment variable:

```sh
LIBUSB_INCLUDE=/path/to/include dart run tool/generate_bindings.dart
```

## Disclaimer

This is experimental, unfinished software, provided free of charge and "as
is". It may not work, may break, may change or disappear at any time. There
is **no warranty and no support**. You use it entirely at your own risk — if
you depend on it, you are responsible for verifying that it does what you
need. See [LICENSE](LICENSE) for the full terms.

## License

MIT — see [LICENSE](LICENSE). Third-party licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Additional information

Feedback and contributions are welcome.
