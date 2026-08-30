/// Native (libusb-1.0 via `dart:ffi`) implementation of the backend-agnostic
/// [UsbBackend] / [UsbDevice] interface. Only usable on the Dart VM
/// (desktop/CLI) — not on the web; for the web use `web_usb.dart` instead.
library;

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'libusb_bindings.g.dart';

import '../usb_interface.dart';
import '../usb_types.dart';
import 'native_library.dart';
import 'usb_native_descriptors.dart';

const int _defaultTimeoutMs = 5000;

/// [UsbBackend] implementation backed by libusb-1.0.
///
/// Requires the libusb-1.0 shared library to be installed on the host
/// system; see [NativeLibusb.libraryPath] if it isn't found automatically.
class NativeUsbBackend implements UsbBackend {
  LibUsbBindings get _lib => NativeLibusb.instance;
  Pointer<libusb_context> get _ctx => NativeLibusb.context;

  @override
  bool get requestDeviceRequired => false;

  @override
  Future<List<UsbDevice>> getDevices({
    List<UsbDeviceFilter> filters = const [],
  }) async {
    final lib = _lib;
    final listOut = calloc<Pointer<Pointer<libusb_device>>>();
    try {
      final count = lib.libusb_get_device_list(_ctx, listOut);
      if (count < 0) {
        throw UsbException(
          'libusb_get_device_list() failed: ${libusbErrorName(count)}',
        );
      }

      final list = listOut.value;
      final devices = <UsbDevice>[];
      try {
        for (var i = 0; i < count; i++) {
          final devicePtr = list[i];
          final descriptor = readDeviceDescriptor(lib, devicePtr);
          if (filters.isNotEmpty &&
              !filters.any((f) => _matches(f, descriptor))) {
            continue;
          }
          lib.libusb_ref_device(devicePtr);
          devices.add(NativeUsbDevice._(devicePtr, descriptor, lib));
        }
      } finally {
        lib.libusb_free_device_list(list, 1);
      }
      return devices;
    } finally {
      calloc.free(listOut);
    }
  }

  static bool _matches(UsbDeviceFilter filter, UsbDeviceDescriptor d) {
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
    final devices = await getDevices(filters: filters);
    if (devices.isEmpty) {
      throw const UsbException(
        'No device matching the given filters was found.',
      );
    }
    return devices.first;
  }

  @override
  Stream<UsbDevice> get onDeviceConnected => _watcher.onConnected;

  @override
  Stream<UsbDevice> get onDeviceDisconnected => _watcher.onDisconnected;

  late final _DeviceWatcher _watcher = _DeviceWatcher(this);
}

/// Polls [NativeUsbBackend.getDevices] on an interval and diffs the result
/// to synthesize connect/disconnect events.
///
/// libusb does have native hotplug callbacks (`libusb_hotplug_register_
/// callback`), but they require running `libusb_handle_events` on a
/// dedicated thread and marshalling the native callback back into Dart,
/// which needs an `Isolate`/`NativeCallable.listener` per platform. Polling
/// is far simpler and portable, at the cost of up to one interval of
/// latency.
class _DeviceWatcher {
  _DeviceWatcher(this._backend);

  final NativeUsbBackend _backend;
  Timer? _timer;
  Map<String, UsbDevice> _known = {};

  late final StreamController<UsbDevice> _connected =
      StreamController<UsbDevice>.broadcast(
    onListen: _start,
    onCancel: _maybeStop,
  );
  late final StreamController<UsbDevice> _disconnected =
      StreamController<UsbDevice>.broadcast(
    onListen: _start,
    onCancel: _maybeStop,
  );

  Stream<UsbDevice> get onConnected => _connected.stream;
  Stream<UsbDevice> get onDisconnected => _disconnected.stream;

  void _start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _maybeStop() {
    if (!_connected.hasListener && !_disconnected.hasListener) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _poll() async {
    List<UsbDevice> devices;
    try {
      devices = await _backend.getDevices();
    } catch (_) {
      // Transient enumeration failure; try again on the next tick.
      return;
    }

    final current = {for (final d in devices) _key(d.descriptor): d};

    for (final entry in current.entries) {
      if (!_known.containsKey(entry.key)) _connected.add(entry.value);
    }
    for (final entry in _known.entries) {
      if (!current.containsKey(entry.key)) _disconnected.add(entry.value);
    }
    _known = current;
  }

  String _key(UsbDeviceDescriptor d) =>
      '${d.vendorId.toRadixString(16)}:${d.productId.toRadixString(16)}:'
      '${d.serialNumber ?? ''}';
}

/// [UsbDevice] implementation wrapping a native libusb device pointer.
///
/// Implements [Finalizable] so a [NativeFinalizer] can release the native
/// `libusb_ref_device()` reference once this wrapper is garbage collected.
class NativeUsbDevice implements UsbDevice, Finalizable {
  NativeUsbDevice._(this._device, this._descriptor, this._lib) {
    _finalizer.attach(this, _device.cast(), detach: this);
  }

  final Pointer<libusb_device> _device;
  final UsbDeviceDescriptor _descriptor;
  final LibUsbBindings _lib;
  Pointer<libusb_device_handle>? _handle;

  static final NativeFinalizer _finalizer =
      NativeFinalizer(NativeLibusb.unrefDeviceSymbol);

  @override
  UsbDeviceDescriptor get descriptor => _descriptor;

  @override
  bool get isOpen => _handle != null;

  Pointer<libusb_device_handle> _requireOpen() {
    final handle = _handle;
    if (handle == null) {
      throw const UsbException('Device is not open; call open() first.');
    }
    return handle;
  }

  @override
  Future<void> open() async {
    final handleOut = calloc<Pointer<libusb_device_handle>>();
    try {
      final result = _lib.libusb_open(_device, handleOut);
      if (result != libusb_error.LIBUSB_SUCCESS) {
        throw UsbException('open() failed: ${libusbErrorName(result)}');
      }
      _handle = handleOut.value;
    } finally {
      calloc.free(handleOut);
    }
  }

  @override
  Future<void> close() async {
    final handle = _handle;
    if (handle != null) {
      _lib.libusb_close(handle);
      _handle = null;
    }
  }

  @override
  Future<void> selectConfiguration(int configurationValue) async {
    final result =
        _lib.libusb_set_configuration(_requireOpen(), configurationValue);
    if (result != libusb_error.LIBUSB_SUCCESS) {
      throw UsbException(
        'selectConfiguration() failed: ${libusbErrorName(result)}',
      );
    }
  }

  @override
  Future<void> claimInterface(int interfaceNumber) async {
    final result = _lib.libusb_claim_interface(_requireOpen(), interfaceNumber);
    if (result != libusb_error.LIBUSB_SUCCESS) {
      throw UsbException(
        'claimInterface() failed: ${libusbErrorName(result)}',
      );
    }
  }

  @override
  Future<void> releaseInterface(int interfaceNumber) async {
    final result =
        _lib.libusb_release_interface(_requireOpen(), interfaceNumber);
    if (result != libusb_error.LIBUSB_SUCCESS) {
      throw UsbException(
        'releaseInterface() failed: ${libusbErrorName(result)}',
      );
    }
  }

  @override
  Future<void> selectAlternateInterface(
    int interfaceNumber,
    int alternateSetting,
  ) async {
    final result = _lib.libusb_set_interface_alt_setting(
      _requireOpen(),
      interfaceNumber,
      alternateSetting,
    );
    if (result != libusb_error.LIBUSB_SUCCESS) {
      throw UsbException(
        'selectAlternateInterface() failed: ${libusbErrorName(result)}',
      );
    }
  }

  @override
  Future<UsbInTransferResult> controlTransferIn(
    UsbControlSetup setup,
    int length,
  ) async {
    final handle = _requireOpen();
    final bmRequestType = libusb_endpoint_direction.LIBUSB_ENDPOINT_IN |
        _requestTypeBits(setup.requestType) |
        _recipientBits(setup.recipient);
    final buffer = calloc<Uint8>(length == 0 ? 1 : length);
    try {
      final result = _lib.libusb_control_transfer(
        handle,
        bmRequestType,
        setup.request,
        setup.value,
        setup.index,
        buffer.cast(),
        length,
        _defaultTimeoutMs,
      );
      if (result < 0) {
        return UsbInTransferResult(
          status: _statusFromError(result),
          data: const [],
        );
      }
      return UsbInTransferResult(
        status: UsbTransferStatus.ok,
        data: buffer.asTypedList(result).toList(),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Future<UsbOutTransferResult> controlTransferOut(
    UsbControlSetup setup,
    List<int> data,
  ) async {
    final handle = _requireOpen();
    final bmRequestType = libusb_endpoint_direction.LIBUSB_ENDPOINT_OUT |
        _requestTypeBits(setup.requestType) |
        _recipientBits(setup.recipient);
    final buffer = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final result = _lib.libusb_control_transfer(
        handle,
        bmRequestType,
        setup.request,
        setup.value,
        setup.index,
        buffer.cast(),
        data.length,
        _defaultTimeoutMs,
      );
      if (result < 0) {
        return UsbOutTransferResult(
          status: _statusFromError(result),
          bytesWritten: 0,
        );
      }
      return UsbOutTransferResult(
        status: UsbTransferStatus.ok,
        bytesWritten: result,
      );
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Future<UsbInTransferResult> transferIn(
    int endpointNumber,
    int length,
  ) async {
    final handle = _requireOpen();
    final address =
        (endpointNumber & 0x0F) | libusb_endpoint_direction.LIBUSB_ENDPOINT_IN;
    final buffer = calloc<Uint8>(length == 0 ? 1 : length);
    final transferredOut = calloc<Int>();
    try {
      final result = _lib.libusb_bulk_transfer(
        handle,
        address,
        buffer.cast(),
        length,
        transferredOut,
        _defaultTimeoutMs,
      );
      final transferred = transferredOut.value;
      final status = result == libusb_error.LIBUSB_SUCCESS
          ? UsbTransferStatus.ok
          : _statusFromError(result);
      final data = (result == libusb_error.LIBUSB_SUCCESS ||
              result == libusb_error.LIBUSB_ERROR_TIMEOUT)
          ? buffer.asTypedList(transferred).toList()
          : const <int>[];
      return UsbInTransferResult(status: status, data: data);
    } finally {
      calloc.free(buffer);
      calloc.free(transferredOut);
    }
  }

  @override
  Future<UsbOutTransferResult> transferOut(
    int endpointNumber,
    List<int> data,
  ) async {
    final handle = _requireOpen();
    final address =
        (endpointNumber & 0x0F) | libusb_endpoint_direction.LIBUSB_ENDPOINT_OUT;
    final buffer = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final transferredOut = calloc<Int>();
    try {
      buffer.asTypedList(data.length).setAll(0, data);
      final result = _lib.libusb_bulk_transfer(
        handle,
        address,
        buffer.cast(),
        data.length,
        transferredOut,
        _defaultTimeoutMs,
      );
      final status = result == libusb_error.LIBUSB_SUCCESS
          ? UsbTransferStatus.ok
          : _statusFromError(result);
      return UsbOutTransferResult(
        status: status,
        bytesWritten: transferredOut.value,
      );
    } finally {
      calloc.free(buffer);
      calloc.free(transferredOut);
    }
  }

  @override
  Future<void> reset() async {
    final result = _lib.libusb_reset_device(_requireOpen());
    // A successful reset commonly makes the device re-enumerate, which
    // surfaces as LIBUSB_ERROR_NOT_FOUND on this now-stale handle.
    if (result != libusb_error.LIBUSB_SUCCESS &&
        result != libusb_error.LIBUSB_ERROR_NOT_FOUND) {
      throw UsbException('reset() failed: ${libusbErrorName(result)}');
    }
  }

  static UsbTransferStatus _statusFromError(int result) {
    switch (result) {
      case libusb_error.LIBUSB_ERROR_TIMEOUT:
        return UsbTransferStatus.timeout;
      case libusb_error.LIBUSB_ERROR_PIPE:
        return UsbTransferStatus.stall;
      case libusb_error.LIBUSB_ERROR_OVERFLOW:
        return UsbTransferStatus.babble;
      case libusb_error.LIBUSB_ERROR_INTERRUPTED:
        return UsbTransferStatus.cancelled;
      default:
        return UsbTransferStatus.error;
    }
  }

  static int _requestTypeBits(UsbControlTransferType type) {
    switch (type) {
      case UsbControlTransferType.standard:
        return libusb_request_type.LIBUSB_REQUEST_TYPE_STANDARD;
      case UsbControlTransferType.usbClass:
        return libusb_request_type.LIBUSB_REQUEST_TYPE_CLASS;
      case UsbControlTransferType.vendor:
        return libusb_request_type.LIBUSB_REQUEST_TYPE_VENDOR;
    }
  }

  static int _recipientBits(UsbRecipient recipient) {
    switch (recipient) {
      case UsbRecipient.device:
        return libusb_request_recipient.LIBUSB_RECIPIENT_DEVICE;
      case UsbRecipient.usbInterface:
        return libusb_request_recipient.LIBUSB_RECIPIENT_INTERFACE;
      case UsbRecipient.endpoint:
        return libusb_request_recipient.LIBUSB_RECIPIENT_ENDPOINT;
      case UsbRecipient.other:
        return libusb_request_recipient.LIBUSB_RECIPIENT_OTHER;
    }
  }
}
