/// Backend-agnostic USB interface, designed so it can be implemented on top
/// of either:
///  - libusb (native, e.g. via dart:ffi) — desktop/mobile/CLI
///  - WebUSB (`navigator.usb`, via package:web/dart:js_interop) — browser
///
/// Only the intersection of what both APIs can express is exposed here.
/// Anything libusb-only (e.g. kernel driver detach) or WebUSB-only (e.g.
/// user-gesture device chooser) belongs in backend-specific extensions, not
/// in this shared surface.
library;

import 'usb_types.dart';

/// A connected/enumerable USB device. Roughly the union of libusb's
/// `libusb_device` + `libusb_device_handle` and WebUSB's `USBDevice`.
///
/// Lifecycle: obtain an instance via [UsbBackend.requestDevice] or
/// [UsbBackend.getDevices], call [open] before any transfer/control call,
/// and [close] when done. All transfer methods throw [UsbException] if
/// called while closed.
abstract class UsbDevice {
  /// Static descriptor info; available even before [open].
  UsbDeviceDescriptor get descriptor;

  /// Whether [open] has succeeded and [close] has not yet been called.
  bool get isOpen;

  /// Opens the device for exclusive access.
  ///
  /// libusb: `libusb_open`. WebUSB: `USBDevice.open()`.
  Future<void> open();

  /// Closes the device, releasing any claimed interfaces.
  ///
  /// libusb: `libusb_close`. WebUSB: `USBDevice.close()`.
  Future<void> close();

  /// Selects the active device configuration.
  ///
  /// libusb: `libusb_set_configuration`.
  /// WebUSB: `USBDevice.selectConfiguration()`.
  Future<void> selectConfiguration(int configurationValue);

  /// Claims an interface for exclusive use before transfers on it.
  ///
  /// libusb: `libusb_claim_interface`.
  /// WebUSB: `USBDevice.claimInterface()`.
  Future<void> claimInterface(int interfaceNumber);

  /// Releases a previously claimed interface.
  ///
  /// libusb: `libusb_release_interface`.
  /// WebUSB: `USBDevice.releaseInterface()`.
  Future<void> releaseInterface(int interfaceNumber);

  /// Switches the active alternate setting of a claimed interface.
  ///
  /// libusb: `libusb_set_interface_alt_setting`.
  /// WebUSB: `USBDevice.selectAlternateInterface()`.
  Future<void> selectAlternateInterface(
    int interfaceNumber,
    int alternateSetting,
  );

  /// Performs a control transfer with data direction IN (device -> host).
  ///
  /// libusb: `libusb_control_transfer` with a `LIBUSB_ENDPOINT_IN` request
  /// type. WebUSB: `USBDevice.controlTransferIn()`.
  Future<UsbInTransferResult> controlTransferIn(
    UsbControlSetup setup,
    int length,
  );

  /// Performs a control transfer with data direction OUT (host -> device).
  ///
  /// libusb: `libusb_control_transfer` with a `LIBUSB_ENDPOINT_OUT` request
  /// type. WebUSB: `USBDevice.controlTransferOut()`.
  Future<UsbOutTransferResult> controlTransferOut(
    UsbControlSetup setup,
    List<int> data,
  );

  /// Reads up to [length] bytes from a bulk or interrupt IN endpoint.
  ///
  /// libusb: `libusb_bulk_transfer` / `libusb_interrupt_transfer` (IN).
  /// WebUSB: `USBDevice.transferIn()`.
  Future<UsbInTransferResult> transferIn(int endpointNumber, int length);

  /// Writes [data] to a bulk or interrupt OUT endpoint.
  ///
  /// libusb: `libusb_bulk_transfer` / `libusb_interrupt_transfer` (OUT).
  /// WebUSB: `USBDevice.transferOut()`.
  Future<UsbOutTransferResult> transferOut(int endpointNumber, List<int> data);

  /// Requests the device to perform a bus-level reset.
  ///
  /// libusb: `libusb_reset_device`. WebUSB: `USBDevice.reset()`.
  Future<void> reset();
}

/// Optional filter used to narrow device enumeration/selection, mirroring
/// WebUSB's `USBDeviceFilter` and the vendor/product-id filtering commonly
/// applied to `libusb_get_device_list()` results.
class UsbDeviceFilter {
  final int? vendorId;
  final int? productId;
  final int? classCode;
  final int? subclassCode;
  final int? protocolCode;
  final String? serialNumber;

  const UsbDeviceFilter({
    this.vendorId,
    this.productId,
    this.classCode,
    this.subclassCode,
    this.protocolCode,
    this.serialNumber,
  });
}

/// Entry point of a concrete backend (native-libusb or WebUSB) implementation.
///
/// A native implementation wraps `libusb_init` / `libusb_get_device_list` /
/// `libusb_exit`; a web implementation wraps `navigator.usb`.
abstract class UsbBackend {
  /// Whether [requestDevice] must be called (from a user gesture) before a
  /// device shows up in [getDevices].
  ///
  /// `true` for WebUSB: the browser only reveals a device once the user has
  /// picked it from the `requestDevice()` chooser. `false` for libusb, where
  /// [getDevices] already enumerates everything the process may access and
  /// [requestDevice] just forwards to enumeration + filtering.
  bool get requestDeviceRequired;

  /// Lists devices already accessible without prompting the user.
  ///
  /// libusb: enumerates via `libusb_get_device_list`, filtered client-side.
  /// WebUSB: `navigator.usb.getDevices()`, filtered client-side. Only
  /// returns devices the user has previously granted via [requestDevice].
  Future<List<UsbDevice>> getDevices({List<UsbDeviceFilter> filters});

  /// Requests access to a single device.
  ///
  /// libusb: enumerates and picks/returns a match directly (no user
  /// interaction is possible/needed outside the browser); see
  /// [requestDeviceRequired].
  /// WebUSB: `navigator.usb.requestDevice()`, which prompts the user with a
  /// device chooser — this call therefore must be triggered from a user
  /// gesture in a browser context, and may throw [UsbException] if the user
  /// cancels the prompt.
  Future<UsbDevice> requestDevice({List<UsbDeviceFilter> filters});

  /// Fires when a device matching this backend's watch scope is plugged in.
  /// Optional: backends that cannot support hotplug notifications (e.g. some
  /// native platforms without libusb hotplug support) may leave this empty.
  ///
  /// libusb: backed by `libusb_hotplug_register_callback` where available.
  /// WebUSB: `navigator.usb.addEventListener('connect', ...)`.
  Stream<UsbDevice> get onDeviceConnected;

  /// Fires when a previously visible device is unplugged/revoked.
  ///
  /// libusb: backed by `libusb_hotplug_register_callback` where available.
  /// WebUSB: `navigator.usb.addEventListener('disconnect', ...)`.
  Stream<UsbDevice> get onDeviceDisconnected;
}
