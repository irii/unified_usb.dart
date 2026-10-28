/// Reads libusb device/configuration/interface/endpoint descriptors into the
/// backend-agnostic descriptor types from `usb_types.dart`.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'libusb_bindings.g.dart';

import '../usb_types.dart';
import 'native_library.dart';

const int _maxStringDescriptorLength = 256;

/// Reads the full [UsbDeviceDescriptor] (including configurations) for
/// [device]. Manufacturer/product/serial strings require a handle, so this
/// transiently opens the device to read them, ignoring failures (e.g.
/// missing permissions) and leaving those fields `null` in that case.
UsbDeviceDescriptor readDeviceDescriptor(
  LibUsbBindings lib,
  Pointer<libusb_device> device, {
  Pointer<libusb_device_handle>? openHandle,
}) {
  final descPtr = calloc<libusb_device_descriptor>();
  try {
    final result = lib.libusb_get_device_descriptor(device, descPtr);
    if (result != libusb_error.LIBUSB_SUCCESS) {
      throw UsbException(
        'libusb_get_device_descriptor() failed: ${libusbErrorName(result)}',
      );
    }
    final desc = descPtr.ref;

    String? manufacturerName;
    String? productName;
    String? serialNumber;

    void readStrings(Pointer<libusb_device_handle> handle) {
      manufacturerName = _readStringDescriptor(
        lib,
        handle,
        desc.iManufacturer,
      );
      productName = _readStringDescriptor(lib, handle, desc.iProduct);
      serialNumber = _readStringDescriptor(lib, handle, desc.iSerialNumber);
    }

    if (openHandle != null) {
      // Already open (e.g. a wrapped system device that libusb cannot
      // open by itself).
      readStrings(openHandle);
    } else {
      final handleOut = calloc<Pointer<libusb_device_handle>>();
      try {
        if (lib.libusb_open(device, handleOut) ==
            libusb_error.LIBUSB_SUCCESS) {
          final handle = handleOut.value;
          try {
            readStrings(handle);
          } finally {
            lib.libusb_close(handle);
          }
        }
      } finally {
        calloc.free(handleOut);
      }
    }

    return UsbDeviceDescriptor(
      vendorId: desc.idVendor,
      productId: desc.idProduct,
      deviceClass: desc.bDeviceClass,
      deviceSubclass: desc.bDeviceSubClass,
      deviceProtocol: desc.bDeviceProtocol,
      manufacturerName: manufacturerName,
      productName: productName,
      serialNumber: serialNumber,
      usbVersionMajor: (desc.bcdUSB >> 8) & 0xFF,
      usbVersionMinor: (desc.bcdUSB >> 4) & 0xF,
      configurations: _readConfigurations(lib, device, desc.bNumConfigurations),
    );
  } finally {
    calloc.free(descPtr);
  }
}

String? _readStringDescriptor(
  LibUsbBindings lib,
  Pointer<libusb_device_handle> handle,
  int index,
) {
  if (index == 0) return null;
  final buffer = calloc<Uint8>(_maxStringDescriptorLength);
  try {
    final result = lib.libusb_get_string_descriptor_ascii(
      handle,
      index,
      buffer.cast(),
      _maxStringDescriptorLength,
    );
    if (result <= 0) return null;
    return String.fromCharCodes(buffer.asTypedList(result));
  } finally {
    calloc.free(buffer);
  }
}

List<UsbConfigurationDescriptor> _readConfigurations(
  LibUsbBindings lib,
  Pointer<libusb_device> device,
  int numConfigurations,
) {
  final configs = <UsbConfigurationDescriptor>[];
  for (var i = 0; i < numConfigurations; i++) {
    final configOut = calloc<Pointer<libusb_config_descriptor>>();
    try {
      final result = lib.libusb_get_config_descriptor(device, i, configOut);
      if (result != libusb_error.LIBUSB_SUCCESS) continue;
      final config = configOut.value;
      try {
        configs.add(_configurationFromNative(config.ref));
      } finally {
        lib.libusb_free_config_descriptor(config);
      }
    } finally {
      calloc.free(configOut);
    }
  }
  return configs;
}

UsbConfigurationDescriptor _configurationFromNative(
  libusb_config_descriptor config,
) {
  final interfaces = <UsbInterfaceDescriptor>[];
  for (var i = 0; i < config.bNumInterfaces; i++) {
    final iface = config.interface[i];
    final alternates = <UsbAlternateInterface>[];
    for (var a = 0; a < iface.num_altsetting; a++) {
      final alt = iface.altsetting[a];
      final endpoints = <UsbEndpointDescriptor>[];
      for (var e = 0; e < alt.bNumEndpoints; e++) {
        final ep = alt.endpoint[e];
        endpoints.add(UsbEndpointDescriptor(
          endpointNumber: ep.bEndpointAddress & 0x0F,
          direction: (ep.bEndpointAddress & 0x80) != 0
              ? UsbDirection.inDirection
              : UsbDirection.outDirection,
          type: _endpointTypeFromAttributes(ep.bmAttributes),
          maxPacketSize: ep.wMaxPacketSize,
        ));
      }
      alternates.add(UsbAlternateInterface(
        alternateSetting: alt.bAlternateSetting,
        interfaceClass: alt.bInterfaceClass,
        interfaceSubclass: alt.bInterfaceSubClass,
        interfaceProtocol: alt.bInterfaceProtocol,
        endpoints: endpoints,
      ));
    }
    interfaces.add(UsbInterfaceDescriptor(
      interfaceNumber: iface.altsetting[0].bInterfaceNumber,
      alternates: alternates,
    ));
  }
  return UsbConfigurationDescriptor(
    configurationValue: config.bConfigurationValue,
    // String lookup needs an open handle; not read during enumeration.
    configurationName: null,
    interfaces: interfaces,
  );
}

UsbEndpointType _endpointTypeFromAttributes(int bmAttributes) {
  switch (bmAttributes & 0x3) {
    case libusb_endpoint_transfer_type
          .LIBUSB_ENDPOINT_TRANSFER_TYPE_ISOCHRONOUS:
      return UsbEndpointType.isochronous;
    case libusb_endpoint_transfer_type.LIBUSB_ENDPOINT_TRANSFER_TYPE_BULK:
      return UsbEndpointType.bulk;
    case libusb_endpoint_transfer_type.LIBUSB_ENDPOINT_TRANSFER_TYPE_INTERRUPT:
      return UsbEndpointType.interrupt;
    default:
      return UsbEndpointType.control;
  }
}
