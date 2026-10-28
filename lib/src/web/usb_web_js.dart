/// Raw `dart:js_interop` bindings for the WebUSB API
/// (https://wicg.github.io/webusb/). Kept separate from the public,
/// backend-agnostic types in `usb_types.dart` / `usb_interface.dart` so this
/// file is the only place that touches JS interop.
///
/// Not exported by `package:unified_usb/unified_usb.dart` — import
/// `package:unified_usb/web_usb.dart` instead, which only works when compiled
/// for the web.
library;

import 'dart:js_interop';
import 'dart:typed_data';

@JS('navigator.usb')
external USB? get _navigatorUsb;

/// Whether the WebUSB API is available in the current JS environment.
bool get isWebUsbSupported => _navigatorUsb != null;

/// The `navigator.usb` singleton. Throws a [StateError] if WebUSB is not
/// supported by the current browser/context.
USB get navigatorUsb {
  final usb = _navigatorUsb;
  if (usb == null) {
    throw StateError('WebUSB is not supported in this environment.');
  }
  return usb;
}

extension type USB._(JSObject _) implements JSObject {
  external JSPromise<JSArray<USBDevice>> getDevices();
  external JSPromise<USBDevice> requestDevice(USBDeviceRequestOptions options);
  external void addEventListener(String type, JSFunction listener);
  external void removeEventListener(String type, JSFunction listener);
}

extension type USBDeviceRequestOptions._(JSObject _) implements JSObject {
  external factory USBDeviceRequestOptions({JSArray<USBDeviceFilter> filters});
}

extension type USBDeviceFilter._(JSObject _) implements JSObject {
  external factory USBDeviceFilter({
    int? vendorId,
    int? productId,
    int? classCode,
    int? subclassCode,
    int? protocolCode,
    String? serialNumber,
  });
}

extension type USBConnectionEvent._(JSObject _) implements JSObject {
  external USBDevice get device;
}

extension type USBDevice._(JSObject _) implements JSObject {
  external int get vendorId;
  external int get productId;
  external int get deviceClass;
  external int get deviceSubclass;
  external int get deviceProtocol;
  external String? get manufacturerName;
  external String? get productName;
  external String? get serialNumber;
  external int get usbVersionMajor;
  external int get usbVersionMinor;
  external bool get opened;
  external JSArray<USBConfiguration> get configurations;

  external JSPromise<JSAny?> open();
  external JSPromise<JSAny?> close();
  external JSPromise<JSAny?> selectConfiguration(int configurationValue);
  external JSPromise<JSAny?> claimInterface(int interfaceNumber);
  external JSPromise<JSAny?> releaseInterface(int interfaceNumber);
  external JSPromise<JSAny?> selectAlternateInterface(
    int interfaceNumber,
    int alternateSetting,
  );
  external JSPromise<USBInTransferResult> controlTransferIn(
    USBControlTransferParameters setup,
    int length,
  );
  external JSPromise<USBOutTransferResult> controlTransferOut(
    USBControlTransferParameters setup,
    JSDataView data,
  );
  external JSPromise<USBInTransferResult> transferIn(
    int endpointNumber,
    int length,
  );
  external JSPromise<USBOutTransferResult> transferOut(
    int endpointNumber,
    JSDataView data,
  );
  external JSPromise<JSAny?> reset();
}

extension type USBConfiguration._(JSObject _) implements JSObject {
  external int get configurationValue;
  external String? get configurationName;
  external JSArray<USBInterface> get interfaces;
}

extension type USBInterface._(JSObject _) implements JSObject {
  external int get interfaceNumber;
  external JSArray<USBAlternateInterface> get alternates;
}

extension type USBAlternateInterface._(JSObject _) implements JSObject {
  external int get alternateSetting;
  external int get interfaceClass;
  external int get interfaceSubclass;
  external int get interfaceProtocol;
  external String? get interfaceName;
  external JSArray<USBEndpoint> get endpoints;
}

extension type USBEndpoint._(JSObject _) implements JSObject {
  external int get endpointNumber;
  external String get direction; // "in" | "out"
  external String get type; // "bulk" | "interrupt" | "isochronous"
  external int get packetSize;
}

extension type USBControlTransferParameters._(JSObject _) implements JSObject {
  external factory USBControlTransferParameters({
    required String requestType, // "standard" | "class" | "vendor"
    required String recipient, // "device" | "interface" | "endpoint" | "other"
    required int request,
    required int value,
    required int index,
  });
}

extension type USBInTransferResult._(JSObject _) implements JSObject {
  external JSDataView? get data;
  external String get status; // "ok" | "stall" | "babble"
}

extension type USBOutTransferResult._(JSObject _) implements JSObject {
  external int get bytesWritten;
  external String get status; // "ok" | "stall"
}

/// Wraps raw bytes in a JS `DataView` (via an intermediate `ArrayBuffer`)
/// for use as WebUSB OUT-transfer payloads.
JSDataView bytesToJSDataView(List<int> bytes) {
  final buffer = Uint8List.fromList(bytes).buffer;
  return buffer.asByteData().toJS;
}

/// Reads a WebUSB `DataView` result back into a plain byte list.
Uint8List jsDataViewToUint8List(JSDataView view) {
  final byteData = view.toDart;
  return byteData.buffer.asUint8List(
    byteData.offsetInBytes,
    byteData.lengthInBytes,
  );
}
