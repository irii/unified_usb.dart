/// Native (libusb-1.0) implementation of the `unified_usb` interface. Import
/// this only from code compiled for the Dart VM (desktop/CLI) — it uses
/// `dart:ffi` and requires the libusb-1.0 shared library to be installed
/// (e.g. `brew install libusb`, `apt install libusb-1.0-0`, or the Windows
/// binary release from https://libusb.info) — for the web use a WebUSB
/// backend instead.
///
/// ```dart
/// import 'package:unified_usb/unified_usb.dart';
/// import 'package:unified_usb/native_usb.dart';
///
/// final UsbBackend backend = NativeUsbBackend();
/// final devices = await backend.getDevices();
/// ```
library;

export 'src/native/native_library.dart' show NativeLibusb;
export 'src/native/usb_native_backend.dart';
