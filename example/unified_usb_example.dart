/// Lists the USB devices visible to the native (libusb) backend and, for the
/// first one, opens it and reads its string descriptors via a standard
/// GET_DESCRIPTOR control transfer.
///
/// Run with:
///
/// ```sh
/// dart run example/unified_usb_example.dart
/// ```
///
/// Requires the libusb-1.0 shared library to be installed on the host
/// (`brew install libusb`, `apt install libusb-1.0-0`, or the Windows binary
/// release from https://libusb.info). Reading from a device may require
/// elevated privileges (e.g. `sudo`, or a udev rule on Linux).
library;

import 'package:unified_usb/unified_usb.dart';
import 'package:unified_usb/native_usb.dart';

Future<void> main() async {
  // If libusb isn't installed in one of the default locations, point the
  // native backend at it explicitly before the first backend call. Either
  // pin an exact path:
  //
  //   NativeLibusb.libraryPath = '/opt/custom/lib/libusb-1.0.dylib';
  //
  // or add extra candidates that are tried (in order) before the built-in
  // per-platform defaults:
  //
  //   NativeLibusb.addSearchPaths([
  //     'libusb-1.0.dylib',
  //     '${Platform.resolvedExecutable}/../lib/libusb-1.0.dylib',
  //   ]);

  final UsbBackend backend = NativeUsbBackend();

  // On the native backend `getDevices()` already enumerates everything the
  // process may access. On the WebUSB backend `backend.requestDeviceRequired`
  // is `true`: a device stays invisible to `getDevices()` until the user has
  // picked it once from the chooser prompt, which must be triggered from a
  // user gesture:
  //
  //   final device = await backend.requestDevice(
  //     filters: [const UsbDeviceFilter(vendorId: 0x2188)],
  //   );

  final devices = await backend.getDevices();
  if (devices.isEmpty) {
    print('No USB devices found.');
    return;
  }

  print('Found ${devices.length} device(s):');
  for (final device in devices) {
    final d = device.descriptor;
    final vid = d.vendorId.toRadixString(16).padLeft(4, '0');
    final pid = d.productId.toRadixString(16).padLeft(4, '0');
    final name = d.productName ?? '<unknown product>';
    final vendor = d.manufacturerName ?? '<unknown vendor>';
    print('  $vid:$pid  $vendor — $name');
  }

  final device = devices.first;
  print('\nOpening ${_label(device.descriptor)} ...');

  try {
    await device.open();
  } on UsbException catch (e) {
    print('Could not open device: $e');
    print('(You may need elevated privileges to access it.)');
    return;
  }

  try {
    // Standard request: GET_DESCRIPTOR, type STRING (0x03), index 0 returns
    // the list of supported language IDs.
    const getDescriptor = 0x06;
    const stringDescriptorType = 0x03;

    final result = await device.controlTransferIn(
      const UsbControlSetup(
        requestType: UsbControlTransferType.standard,
        recipient: UsbRecipient.device,
        request: getDescriptor,
        value: (stringDescriptorType << 8) | 0,
        index: 0,
      ),
      255,
    );

    if (result.status == UsbTransferStatus.ok) {
      print('Supported language IDs (raw descriptor bytes): ${result.data}');
    } else {
      print('GET_DESCRIPTOR failed with status ${result.status.name}.');
    }
  } finally {
    await device.close();
    print('Closed.');
  }
}

String _label(UsbDeviceDescriptor d) {
  final vid = d.vendorId.toRadixString(16).padLeft(4, '0');
  final pid = d.productId.toRadixString(16).padLeft(4, '0');
  return d.productName ?? '$vid:$pid';
}
