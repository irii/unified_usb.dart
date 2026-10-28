/// WebUSB implementation of the backend-agnostic [UsbBackend] / [UsbDevice]
/// interface, built on top of `navigator.usb`. Only usable when compiled
/// for the web (`dart compile js`/`wasm`, webdev, flutter web, ...).
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../usb_interface.dart';
import '../usb_types.dart';
import 'usb_web_js.dart' as js;

/// [UsbBackend] implementation backed by the browser's `navigator.usb`.
class WebUsbBackend implements UsbBackend {
  WebUsbBackend() {
    if (!js.isWebUsbSupported) {
      throw const UsbException('WebUSB is not supported in this environment.');
    }
  }

  js.USB get _usb => js.navigatorUsb;

  @override
  bool get requestDeviceRequired => true;

  @override
  bool get kernelDriverDetachSupported => false;

  @override
  Future<List<UsbDevice>> getDevices({
    List<UsbDeviceFilter> filters = const [],
  }) async {
    try {
      final devices = await _usb.getDevices().toDart;
      return devices.toDart
          .map((d) => WebUsbDevice(d))
          .where((d) => filters.isEmpty || filters.any((f) => _matches(f, d)))
          .toList();
    } catch (e) {
      throw UsbException('getDevices() failed: $e');
    }
  }

  static bool _matches(UsbDeviceFilter filter, UsbDevice device) {
    final d = device.descriptor;
    if (filter.vendorId != null && filter.vendorId != d.vendorId) {
      return false;
    }
    if (filter.productId != null && filter.productId != d.productId) {
      return false;
    }
    if (filter.classCode != null && filter.classCode != d.deviceClass) {
      return false;
    }
    if (filter.subclassCode != null &&
        filter.subclassCode != d.deviceSubclass) {
      return false;
    }
    if (filter.protocolCode != null &&
        filter.protocolCode != d.deviceProtocol) {
      return false;
    }
    if (filter.serialNumber != null && filter.serialNumber != d.serialNumber) {
      return false;
    }
    return true;
  }

  @override
  Future<UsbDevice> requestDevice({
    List<UsbDeviceFilter> filters = const [],
  }) async {
    try {
      final options = js.USBDeviceRequestOptions(
        filters: filters.map(_toJsFilter).toList().toJS,
      );
      final device = await _usb.requestDevice(options).toDart;
      return WebUsbDevice(device);
    } catch (e) {
      throw UsbException('requestDevice() failed or was cancelled: $e');
    }
  }

  @override
  Stream<UsbDevice> get onDeviceConnected => _connectionEvents('connect');

  @override
  Stream<UsbDevice> get onDeviceDisconnected => _connectionEvents('disconnect');

  Stream<UsbDevice> _connectionEvents(String type) {
    late final StreamController<UsbDevice> controller;
    late final JSFunction listener;

    void handleEvent(JSAny event) {
      final connectionEvent = event as js.USBConnectionEvent;
      controller.add(WebUsbDevice(connectionEvent.device));
    }

    listener = handleEvent.toJS;

    controller = StreamController<UsbDevice>.broadcast(
      onListen: () => _usb.addEventListener(type, listener),
      onCancel: () => _usb.removeEventListener(type, listener),
    );

    return controller.stream;
  }

  js.USBDeviceFilter _toJsFilter(UsbDeviceFilter filter) {
    // Build the filter as a plain JS object, setting only the members that are
    // actually present. Passing `null` for optional members (which Dart's object
    // literal interop does) makes Chrome reject `requestDevice` with a TypeError
    // because e.g. `vendorId: null` is not a valid `unsigned short`.
    final obj = JSObject();
    if (filter.vendorId != null) {
      obj.setProperty('vendorId'.toJS, filter.vendorId!.toJS);
    }
    if (filter.productId != null) {
      obj.setProperty('productId'.toJS, filter.productId!.toJS);
    }
    if (filter.classCode != null) {
      obj.setProperty('classCode'.toJS, filter.classCode!.toJS);
    }
    if (filter.subclassCode != null) {
      obj.setProperty('subclassCode'.toJS, filter.subclassCode!.toJS);
    }
    if (filter.protocolCode != null) {
      obj.setProperty('protocolCode'.toJS, filter.protocolCode!.toJS);
    }
    if (filter.serialNumber != null) {
      obj.setProperty('serialNumber'.toJS, filter.serialNumber!.toJS);
    }
    return obj as js.USBDeviceFilter;
  }
}

/// [UsbDevice] implementation wrapping a WebUSB `USBDevice` object.
class WebUsbDevice implements UsbDevice {
  WebUsbDevice(this._device);

  final js.USBDevice _device;

  @override
  UsbDeviceDescriptor get descriptor => UsbDeviceDescriptor(
        vendorId: _device.vendorId,
        productId: _device.productId,
        deviceClass: _device.deviceClass,
        deviceSubclass: _device.deviceSubclass,
        deviceProtocol: _device.deviceProtocol,
        manufacturerName: _device.manufacturerName,
        productName: _device.productName,
        serialNumber: _device.serialNumber,
        usbVersionMajor: _device.usbVersionMajor,
        usbVersionMinor: _device.usbVersionMinor,
        configurations:
            _device.configurations.toDart.map(_configurationFromJs).toList(),
      );

  @override
  bool get isOpen => _device.opened;

  @override
  Future<void> open() => _run('open', () => _device.open());

  @override
  Future<void> close() => _run('close', () => _device.close());

  @override
  Future<void> selectConfiguration(int configurationValue) => _run(
        'selectConfiguration',
        () => _device.selectConfiguration(configurationValue),
      );

  @override
  Future<void> claimInterface(int interfaceNumber) =>
      _run('claimInterface', () => _device.claimInterface(interfaceNumber));

  @override
  Future<void> releaseInterface(int interfaceNumber) => _run(
        'releaseInterface',
        () => _device.releaseInterface(interfaceNumber),
      );

  @override
  Future<void> selectAlternateInterface(
    int interfaceNumber,
    int alternateSetting,
  ) =>
      _run(
        'selectAlternateInterface',
        () => _device.selectAlternateInterface(
          interfaceNumber,
          alternateSetting,
        ),
      );

  @override
  Future<UsbInTransferResult> controlTransferIn(
    UsbControlSetup setup,
    int length,
  ) async {
    try {
      final result =
          await _device.controlTransferIn(_toJsSetup(setup), length).toDart;
      return _inResultFromJs(result);
    } catch (e) {
      throw UsbException('controlTransferIn() failed: $e');
    }
  }

  @override
  Future<UsbOutTransferResult> controlTransferOut(
    UsbControlSetup setup,
    List<int> data,
  ) async {
    try {
      final view = js.bytesToJSDataView(data);
      final result =
          await _device.controlTransferOut(_toJsSetup(setup), view).toDart;
      return _outResultFromJs(result);
    } catch (e) {
      throw UsbException('controlTransferOut() failed: $e');
    }
  }

  @override
  Future<UsbInTransferResult> transferIn(
    int endpointNumber,
    int length,
  ) async {
    try {
      final result = await _device.transferIn(endpointNumber, length).toDart;
      return _inResultFromJs(result);
    } catch (e) {
      throw UsbException('transferIn() failed: $e');
    }
  }

  @override
  Future<UsbOutTransferResult> transferOut(
    int endpointNumber,
    List<int> data,
  ) async {
    try {
      final view = js.bytesToJSDataView(data);
      final result = await _device.transferOut(endpointNumber, view).toDart;
      return _outResultFromJs(result);
    } catch (e) {
      throw UsbException('transferOut() failed: $e');
    }
  }

  @override
  Future<void> reset() => _run('reset', () => _device.reset());

  // The browser owns kernel driver binding; WebUSB exposes no way to change it.
  static Never _kernelDriverUnsupported() => throw const UsbException(
        'Kernel driver detach is not supported by WebUSB.',
      );

  @override
  Future<bool> isKernelDriverActive(int interfaceNumber) async =>
      _kernelDriverUnsupported();

  @override
  Future<void> detachKernelDriver(int interfaceNumber) async =>
      _kernelDriverUnsupported();

  @override
  Future<void> attachKernelDriver(int interfaceNumber) async =>
      _kernelDriverUnsupported();

  @override
  Future<void> setAutoDetachKernelDriver(bool enable) async =>
      _kernelDriverUnsupported();

  Future<void> _run(String name, JSPromise<JSAny?> Function() call) async {
    try {
      await call().toDart;
    } catch (e) {
      throw UsbException('$name() failed: $e');
    }
  }

  js.USBControlTransferParameters _toJsSetup(UsbControlSetup setup) {
    return js.USBControlTransferParameters(
      requestType: _requestTypeToJs(setup.requestType),
      recipient: _recipientToJs(setup.recipient),
      request: setup.request,
      value: setup.value,
      index: setup.index,
    );
  }

  static UsbInTransferResult _inResultFromJs(js.USBInTransferResult result) {
    final view = result.data;
    return UsbInTransferResult(
      status: _statusFromJs(result.status),
      data: view == null ? const [] : js.jsDataViewToUint8List(view),
    );
  }

  static UsbOutTransferResult _outResultFromJs(
    js.USBOutTransferResult result,
  ) {
    return UsbOutTransferResult(
      status: _statusFromJs(result.status),
      bytesWritten: result.bytesWritten,
    );
  }

  static UsbConfigurationDescriptor _configurationFromJs(
    js.USBConfiguration config,
  ) {
    return UsbConfigurationDescriptor(
      configurationValue: config.configurationValue,
      configurationName: config.configurationName,
      interfaces: config.interfaces.toDart.map(_interfaceFromJs).toList(),
    );
  }

  static UsbInterfaceDescriptor _interfaceFromJs(js.USBInterface iface) {
    return UsbInterfaceDescriptor(
      interfaceNumber: iface.interfaceNumber,
      alternates: iface.alternates.toDart.map(_alternateFromJs).toList(),
    );
  }

  static UsbAlternateInterface _alternateFromJs(
    js.USBAlternateInterface alt,
  ) {
    return UsbAlternateInterface(
      alternateSetting: alt.alternateSetting,
      interfaceClass: alt.interfaceClass,
      interfaceSubclass: alt.interfaceSubclass,
      interfaceProtocol: alt.interfaceProtocol,
      endpoints: alt.endpoints.toDart.map(_endpointFromJs).toList(),
    );
  }

  static UsbEndpointDescriptor _endpointFromJs(js.USBEndpoint endpoint) {
    return UsbEndpointDescriptor(
      endpointNumber: endpoint.endpointNumber,
      direction: endpoint.direction == 'in'
          ? UsbDirection.inDirection
          : UsbDirection.outDirection,
      type: _endpointTypeFromJs(endpoint.type),
      maxPacketSize: endpoint.packetSize,
    );
  }

  static UsbEndpointType _endpointTypeFromJs(String type) {
    switch (type) {
      case 'bulk':
        return UsbEndpointType.bulk;
      case 'interrupt':
        return UsbEndpointType.interrupt;
      case 'isochronous':
        return UsbEndpointType.isochronous;
      default:
        throw UsbException('Unknown WebUSB endpoint type: $type');
    }
  }

  static UsbTransferStatus _statusFromJs(String status) {
    switch (status) {
      case 'ok':
        return UsbTransferStatus.ok;
      case 'stall':
        return UsbTransferStatus.stall;
      case 'babble':
        return UsbTransferStatus.babble;
      default:
        return UsbTransferStatus.error;
    }
  }

  static String _requestTypeToJs(UsbControlTransferType type) {
    switch (type) {
      case UsbControlTransferType.standard:
        return 'standard';
      case UsbControlTransferType.usbClass:
        return 'class';
      case UsbControlTransferType.vendor:
        return 'vendor';
    }
  }

  static String _recipientToJs(UsbRecipient recipient) {
    switch (recipient) {
      case UsbRecipient.device:
        return 'device';
      case UsbRecipient.usbInterface:
        return 'interface';
      case UsbRecipient.endpoint:
        return 'endpoint';
      case UsbRecipient.other:
        return 'other';
    }
  }
}
