/// Native (libusb-1.0 via `dart:ffi`) implementation of the backend-agnostic
/// [UsbBackend] / [UsbDevice] interface. Only usable on the Dart VM
/// (desktop/CLI) — not on the web; for the web use `web_usb.dart` instead.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'libusb_bindings.g.dart';

import '../usb_interface.dart';
import '../usb_types.dart';
import 'libusb_event_loop.dart';
import 'native_library.dart';
import 'usb_native_descriptors.dart';

/// How [NativeUsbBackend] issues bulk/control transfers.
enum UsbTransferMode {
  /// Blocking libusb calls (`libusb_bulk_transfer` / `libusb_control_transfer`)
  /// run synchronously on the calling isolate's thread. Simple, but a transfer
  /// that idles until its timeout blocks that isolate for the whole duration.
  sync,

  /// Asynchronous libusb (`libusb_submit_transfer` + a dedicated event thread).
  /// The calling isolate only submits and then `await`s a completion, never
  /// blocking in native code - mirrors WebUSB semantics.
  asyncEvents,
}

/// Bundle of per-device settings the backend injects into every
/// [NativeUsbDevice] it creates, so the device constructor doesn't have to
/// grow a parameter per knob.
class _NativeDeviceConfig {
  const _NativeDeviceConfig({
    required this.readTimeoutMs,
    required this.writeTimeoutMs,
    required this.controlTimeoutMs,
    required this.transferMode,
    required this.events,
  });

  /// Timeout for bulk IN transfers ([NativeUsbDevice.transferIn]).
  final int readTimeoutMs;

  /// Timeout for bulk OUT transfers ([NativeUsbDevice.transferOut]).
  final int writeTimeoutMs;

  /// Timeout for control transfers (both directions).
  final int controlTimeoutMs;

  final UsbTransferMode transferMode;

  /// The async transfer engine, when [transferMode] is
  /// [UsbTransferMode.asyncEvents]; otherwise `null`.
  final LibusbEventLoop? events;
}

/// [UsbBackend] implementation backed by libusb-1.0.
///
/// Requires the libusb-1.0 shared library to be installed on the host
/// system; see [NativeLibusb.libraryPath] if it isn't found automatically.
class NativeUsbBackend implements UsbBackend {
  /// Default value for [readTimeout], [writeTimeout] and [controlTimeout].
  static const Duration defaultTransferTimeout = Duration(seconds: 5);

  /// [readTimeout] is the timeout for bulk IN transfers, [writeTimeout] for
  /// bulk OUT transfers, [controlTimeout] for control transfers. Kept separate
  /// so a caller can use a short idle-read timeout without also making writes
  /// fail quickly on a busy device. A zero duration means "no timeout" (libusb
  /// blocks indefinitely).
  factory NativeUsbBackend({
    Duration readTimeout = defaultTransferTimeout,
    Duration writeTimeout = defaultTransferTimeout,
    Duration controlTimeout = defaultTransferTimeout,
    UsbTransferMode transferMode = UsbTransferMode.sync,
  }) {
    LibusbEventLoop? events;
    if (transferMode == UsbTransferMode.asyncEvents) {
      events = LibusbEventLoop.instance;
      // Bumps the refcount synchronously; the helper isolate spins up in the
      // background and the first transfer awaits it.
      unawaited(events.acquire());
    }
    return NativeUsbBackend._(_NativeDeviceConfig(
      readTimeoutMs: _clampMs(readTimeout),
      writeTimeoutMs: _clampMs(writeTimeout),
      controlTimeoutMs: _clampMs(controlTimeout),
      transferMode: transferMode,
      events: events,
    ));
  }

  NativeUsbBackend._(this._deviceConfig);

  static int _clampMs(Duration d) {
    final ms = d.inMilliseconds;
    return ms < 0 ? 0 : ms;
  }

  final _NativeDeviceConfig _deviceConfig;

  bool _disposed = false;

  /// Releases resources held by this backend. In [UsbTransferMode.asyncEvents]
  /// this drops the backend's reference to the shared libusb event isolate,
  /// shutting it down once no async backend is left. Safe to call more than
  /// once; the backend must not be used afterwards.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _watcher.dispose();
    _deviceConfig.events?.release();
  }

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
          devices.add(
            NativeUsbDevice._(devicePtr, descriptor, lib, _deviceConfig),
          );
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

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _connected.close();
    _disconnected.close();
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
  NativeUsbDevice._(this._device, this._descriptor, this._lib, this._config) {
    _finalizer.attach(this, _device.cast(), detach: this);
  }

  final Pointer<libusb_device> _device;
  final UsbDeviceDescriptor _descriptor;
  final LibUsbBindings _lib;
  final _NativeDeviceConfig _config;
  Pointer<libusb_device_handle>? _handle;

  /// In-flight async transfers, tracked so [close] can wait for them to drain
  /// before `libusb_close` (which must not run with transfers in flight).
  final Set<Future<void>> _outstanding = {};

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
    if (handle == null) return;

    final events = _config.events;
    if (events != null && _outstanding.isNotEmpty) {
      events.cancelForHandle(handle.address);
      // Wait for the cancellations to be delivered so their native buffers
      // are freed; bounded so a wedged transfer can't hang teardown.
      await Future.wait(_outstanding.map((f) => f.catchError((_) {})))
          .timeout(const Duration(seconds: 1), onTimeout: () => const []);
    }

    _lib.libusb_close(handle);
    _handle = null;
  }

  /// Runs [op] while registered in [_outstanding] so [close] can await it.
  Future<T> _tracked<T>(Future<T> Function() op) {
    final future = op();
    final tracked = future.then((_) {}, onError: (_) {});
    _outstanding.add(tracked);
    tracked.whenComplete(() => _outstanding.remove(tracked));
    return future;
  }

  static UsbTransferStatus _statusFromTransfer(int transferStatus) {
    switch (transferStatus) {
      case libusb_transfer_status.LIBUSB_TRANSFER_COMPLETED:
        return UsbTransferStatus.ok;
      case libusb_transfer_status.LIBUSB_TRANSFER_TIMED_OUT:
        return UsbTransferStatus.timeout;
      case libusb_transfer_status.LIBUSB_TRANSFER_CANCELLED:
        return UsbTransferStatus.cancelled;
      case libusb_transfer_status.LIBUSB_TRANSFER_STALL:
        return UsbTransferStatus.stall;
      case libusb_transfer_status.LIBUSB_TRANSFER_OVERFLOW:
        return UsbTransferStatus.babble;
      default:
        return UsbTransferStatus.error;
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
        _config.controlTimeoutMs,
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
        _config.controlTimeoutMs,
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
  ) {
    final events = _config.events;
    if (events == null) return _transferInSync(endpointNumber, length);
    final handle = _requireOpen();
    return _tracked(() async {
      final result = await events.submitBulk(
        deviceHandleAddress: handle.address,
        endpointAddress: endpointNumber,
        isIn: true,
        length: length,
        timeoutMs: _config.readTimeoutMs,
      );
      return UsbInTransferResult(
        status: _statusFromTransfer(result.status),
        data: result.data ?? const <int>[],
      );
    });
  }

  Future<UsbInTransferResult> _transferInSync(
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
        _config.readTimeoutMs,
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
  ) {
    final events = _config.events;
    if (events == null) return _transferOutSync(endpointNumber, data);
    final handle = _requireOpen();
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    return _tracked(() async {
      final result = await events.submitBulk(
        deviceHandleAddress: handle.address,
        endpointAddress: endpointNumber,
        isIn: false,
        length: bytes.length,
        timeoutMs: _config.writeTimeoutMs,
        outData: bytes,
      );
      return UsbOutTransferResult(
        status: _statusFromTransfer(result.status),
        bytesWritten: result.actualLength < 0 ? 0 : result.actualLength,
      );
    });
  }

  Future<UsbOutTransferResult> _transferOutSync(
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
        _config.writeTimeoutMs,
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
