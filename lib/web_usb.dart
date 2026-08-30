/// WebUSB implementation of the `unified_usb` interface. Import this only from
/// code compiled for the web (it uses `dart:js_interop` and will not
/// compile for native/VM targets) — for native platforms use a libusb
/// backend instead.
///
/// ```dart
/// import 'package:unified_usb/unified_usb.dart';
/// import 'package:unified_usb/web_usb.dart';
///
/// final UsbBackend backend = WebUsbBackend();
/// final device = await backend.requestDevice(); // must run from a user gesture
/// ```
library;

export 'src/web/usb_web_backend.dart';
