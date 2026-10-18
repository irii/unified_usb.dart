/// Exercises `UsbTransferMode.asyncEvents`: opens the first device, claims its
/// first interface, and shows that a long-idling bulk IN read does NOT block a
/// concurrently issued read on another endpoint - the whole point of the async
/// path.
///
/// ```sh
/// dart run example/async_transfer_example.dart
/// ```
///
/// Needs libusb installed and (usually) elevated privileges. Adjust the
/// endpoint numbers for your device.
library;

import 'package:unified_usb/native_usb.dart';
import 'package:unified_usb/unified_usb.dart';

Future<void> main() async {
  final backend = NativeUsbBackend(
    transferMode: UsbTransferMode.asyncEvents,
    readTimeout: const Duration(seconds: 2),
  );

  try {
    final devices = await backend.getDevices();
    if (devices.isEmpty) {
      print('No USB devices found.');
      return;
    }
    final device = devices.first;
    await device.open();
    try {
      final config = device.descriptor.configurations.first;
      await device.selectConfiguration(config.configurationValue);
      final iface = config.interfaces.first;
      await device.claimInterface(iface.interfaceNumber);

      final inEndpoint = iface.alternates.first.endpoints
          .firstWhere((e) => e.direction == UsbDirection.inDirection);

      final sw = Stopwatch()..start();

      // Fire one read that will very likely idle out to its 2s timeout...
      final idle = device.transferIn(inEndpoint.endpointNumber, 512).then((r) {
        print('idle read done @ ${sw.elapsedMilliseconds}ms  status=${r.status}');
      });

      // ...and immediately a second one. On the sync path this would queue
      // behind the first for ~2s; on the async path both run concurrently.
      final concurrent =
          device.transferIn(inEndpoint.endpointNumber, 512).then((r) {
        print(
          'concurrent read done @ ${sw.elapsedMilliseconds}ms  '
          'status=${r.status} bytes=${r.data.length}',
        );
      });

      await Future.wait([idle, concurrent]);
    } finally {
      await device.close();
    }
  } finally {
    backend.dispose();
  }
}
