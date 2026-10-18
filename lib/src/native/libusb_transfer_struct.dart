/// Hand-written Dart FFI mirror of `struct libusb_transfer` from `libusb.h`.
///
/// The ffigen-generated bindings in `libusb_bindings.g.dart` emit
/// `libusb_transfer` as an opaque type, because its final member is a
/// flexible array member (`struct libusb_iso_packet_descriptor
/// iso_packet_desc[]`) which ffigen cannot express. The async transfer path
/// (`libusb_submit_transfer`) needs to read and write the struct's fields, so
/// we reproduce its public layout here.
///
/// This layout has been ABI-stable since libusb 1.0.0 (2012). We only ever
/// obtain transfers from `libusb_alloc_transfer(0)`, so `num_iso_packets` is
/// always 0 and the trailing flexible array never materialises - it is
/// omitted here. Isochronous transfers are not supported by this package.
///
/// If the libusb bindings are ever regenerated, `libusb_transfer` stays
/// opaque and this file remains the authoritative definition. The layout is
/// guarded by `test/libusb_transfer_layout_test.dart`.
library;

import 'dart:ffi';

import 'libusb_bindings.g.dart';

/// Signature of the C transfer-completion callback
/// (`void (*)(struct libusb_transfer *)`).
typedef LibusbTransferCallbackNative = Void Function(
    Pointer<LibusbTransfer> transfer);

/// Mirror of `struct libusb_transfer`.
///
/// C layout on a 64-bit target (offsets in bytes):
/// ```
///  0  libusb_device_handle *dev_handle
///  8  uint8_t               flags
///  9  unsigned char         endpoint
/// 10  unsigned char         type
/// 11  (1 byte padding)
/// 12  unsigned int          timeout
/// 16  enum ...              status
/// 20  int                   length
/// 24  int                   actual_length
/// 28  (4 bytes padding)
/// 32  libusb_transfer_cb_fn callback
/// 40  void                 *user_data
/// 48  unsigned char        *buffer
/// 56  int                   num_iso_packets
/// 60  (4 bytes tail padding) -> sizeof == 64
/// ```
/// Dart FFI applies the same C alignment rules, so the field declarations
/// below reproduce this layout; `sizeOf<LibusbTransfer>()` must be 64.
final class LibusbTransfer extends Struct {
  external Pointer<Void> devHandle;

  @Uint8()
  external int flags;

  @Uint8()
  external int endpoint;

  @Uint8()
  external int type;

  @Uint32()
  external int timeout;

  /// One of the `libusb_transfer_status.*` constants.
  @Int32()
  external int status;

  @Int32()
  external int length;

  @Int32()
  external int actualLength;

  external Pointer<NativeFunction<LibusbTransferCallbackNative>> callback;

  external Pointer<Void> userData;

  external Pointer<Uint8> buffer;

  @Int32()
  external int numIsoPackets;
}

/// `LIBUSB_CONTROL_SETUP_SIZE` - the 8-byte control setup packet that must
/// prefix the buffer of a control transfer. (Not currently used - control
/// transfers stay on the synchronous path - but kept for completeness.)
const int libusbControlSetupSize = 8;

extension LibusbTransferFill on Pointer<LibusbTransfer> {
  /// Dart equivalent of the `libusb_fill_bulk_transfer` static inline helper.
  void fillBulk({
    required Pointer<Void> deviceHandle,
    required int endpointAddress,
    required Pointer<Uint8> buffer,
    required int length,
    required Pointer<NativeFunction<LibusbTransferCallbackNative>> callback,
    required int userData,
    required int timeoutMs,
  }) {
    final t = ref;
    t.devHandle = deviceHandle;
    t.endpoint = endpointAddress & 0xFF;
    t.type = libusb_transfer_type.LIBUSB_TRANSFER_TYPE_BULK;
    t.timeout = timeoutMs;
    t.buffer = buffer;
    t.length = length;
    t.callback = callback;
    t.userData = Pointer<Void>.fromAddress(userData);
    t.flags = 0;
    t.numIsoPackets = 0;
    t.status = 0;
    t.actualLength = 0;
  }
}
