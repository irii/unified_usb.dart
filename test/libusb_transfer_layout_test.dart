@TestOn('vm')
library;

import 'dart:ffi';

import 'package:test/test.dart';
import 'package:unified_usb/src/native/libusb_transfer_struct.dart';

void main() {
  test('LibusbTransfer mirrors the C struct libusb_transfer layout', () {
    // On a 64-bit target `sizeof(struct libusb_transfer)` (as allocated by
    // libusb_alloc_transfer(0), i.e. without the trailing iso_packet_desc
    // flexible array) is 64 bytes. If this fails, the hand-written struct in
    // libusb_transfer_struct.dart has drifted from libusb's ABI and the async
    // transfer path must not be used until it is fixed.
    expect(sizeOf<LibusbTransfer>(), 64);
  });
}
