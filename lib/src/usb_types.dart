/// Common USB value types shared by the libusb and WebUSB worlds.
library;

/// Direction of a control transfer / endpoint.
enum UsbDirection { inDirection, outDirection }

/// `bmRequestType` transfer type, as defined by the USB spec and mirrored
/// by both libusb (`LIBUSB_REQUEST_TYPE_*`) and WebUSB (`USBRequestType`).
enum UsbControlTransferType { standard, usbClass, vendor }

/// `bmRequestType` recipient, mirrored by libusb (`LIBUSB_RECIPIENT_*`) and
/// WebUSB (`USBRecipient`).
enum UsbRecipient { device, usbInterface, endpoint, other }

/// Endpoint transfer type (bulk/interrupt/isochronous/control).
enum UsbEndpointType { bulk, interrupt, isochronous, control }

/// Result status of a transfer, collapsing libusb's `libusb_transfer_status`
/// and WebUSB's `USBTransferStatus` into one shared vocabulary.
enum UsbTransferStatus { ok, stall, babble, timeout, cancelled, error }

/// Describes a single endpoint of an interface's alternate setting.
class UsbEndpointDescriptor {
  final int endpointNumber;
  final UsbDirection direction;
  final UsbEndpointType type;
  final int maxPacketSize;

  const UsbEndpointDescriptor({
    required this.endpointNumber,
    required this.direction,
    required this.type,
    required this.maxPacketSize,
  });
}

/// One alternate setting of an interface.
class UsbAlternateInterface {
  final int alternateSetting;
  final int interfaceClass;
  final int interfaceSubclass;
  final int interfaceProtocol;
  final List<UsbEndpointDescriptor> endpoints;

  const UsbAlternateInterface({
    required this.alternateSetting,
    required this.interfaceClass,
    required this.interfaceSubclass,
    required this.interfaceProtocol,
    required this.endpoints,
  });
}

/// A USB interface (collection of alternate settings) within a configuration.
class UsbInterfaceDescriptor {
  final int interfaceNumber;
  final List<UsbAlternateInterface> alternates;

  const UsbInterfaceDescriptor({
    required this.interfaceNumber,
    required this.alternates,
  });
}

/// A USB configuration descriptor.
class UsbConfigurationDescriptor {
  final int configurationValue;
  final String? configurationName;
  final List<UsbInterfaceDescriptor> interfaces;

  const UsbConfigurationDescriptor({
    required this.configurationValue,
    this.configurationName,
    required this.interfaces,
  });
}

/// Static identity/descriptor information about a device, available before
/// (and without needing) an open handle. Mirrors `USBDevice`'s descriptor
/// fields in WebUSB and `libusb_device_descriptor` in libusb.
class UsbDeviceDescriptor {
  final int vendorId;
  final int productId;
  final int deviceClass;
  final int deviceSubclass;
  final int deviceProtocol;
  final String? manufacturerName;
  final String? productName;
  final String? serialNumber;
  final int usbVersionMajor;
  final int usbVersionMinor;
  final List<UsbConfigurationDescriptor> configurations;

  const UsbDeviceDescriptor({
    required this.vendorId,
    required this.productId,
    required this.deviceClass,
    required this.deviceSubclass,
    required this.deviceProtocol,
    this.manufacturerName,
    this.productName,
    this.serialNumber,
    required this.usbVersionMajor,
    required this.usbVersionMinor,
    required this.configurations,
  });
}

/// Parameters of a control transfer request (`bmRequestType` split into
/// direction/type/recipient plus `bRequest`, `wValue`, `wIndex`).
class UsbControlSetup {
  final UsbControlTransferType requestType;
  final UsbRecipient recipient;
  final int request;
  final int value;
  final int index;

  const UsbControlSetup({
    required this.requestType,
    required this.recipient,
    required this.request,
    required this.value,
    required this.index,
  });
}

/// Result of an IN transfer (device -> host).
class UsbInTransferResult {
  final UsbTransferStatus status;
  final List<int> data;

  const UsbInTransferResult({required this.status, required this.data});
}

/// Result of an OUT transfer (host -> device).
class UsbOutTransferResult {
  final UsbTransferStatus status;
  final int bytesWritten;

  const UsbOutTransferResult(
      {required this.status, required this.bytesWritten});
}

/// Base class for errors raised by a [UsbDevice] / [UsbBackend]
/// implementation, letting callers catch backend-agnostic USB failures.
class UsbException implements Exception {
  final String message;
  const UsbException(this.message);

  @override
  String toString() => 'UsbException: $message';
}
