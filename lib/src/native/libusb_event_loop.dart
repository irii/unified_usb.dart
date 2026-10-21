/// Asynchronous libusb transfer engine used by [NativeUsbBackend] when
/// constructed with `UsbTransferMode.asyncEvents`.
///
/// Transfers are allocated, submitted, cancelled and freed directly on the
/// calling isolate (`libusb_submit_transfer` / `libusb_cancel_transfer` are
/// thread-safe). The only thing that needs another thread is the libusb event
/// loop itself: a helper isolate sits blocked in
/// `libusb_handle_events_completed`, and completions reach the calling isolate
/// through a [NativeCallable.listener], which libusb may invoke from any
/// thread. The calling isolate never blocks inside a native call, which is
/// what makes this behave like WebUSB instead of stalling a whole isolate on
/// an idle read.
///
/// Only bulk transfers go through here. Control transfers are rare, short and
/// not a bottleneck, so they stay on the synchronous path even in
/// `asyncEvents` mode.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../usb_types.dart';
import 'libusb_bindings.g.dart';
import 'libusb_transfer_struct.dart';
import 'native_library.dart';

/// How long a shutdown waits for cancelled transfers to be delivered before
/// giving up on them.
const Duration _drainTimeout = Duration(seconds: 1);

/// Result of an async bulk transfer.
class LibusbTransferResult {
  const LibusbTransferResult(this.status, this.actualLength, this.data);

  /// One of the `libusb_transfer_status.*` constants.
  final int status;
  final int actualLength;

  /// Bytes received, for IN transfers. `null` for OUT transfers.
  final Uint8List? data;
}

/// Per-isolate singleton. Reference-counted by the [NativeUsbBackend]s that
/// use it; the event isolate is spawned on first [acquire] and torn down
/// when the last user calls [release].
class LibusbEventLoop {
  LibusbEventLoop._();

  static LibusbEventLoop? _instance;
  static LibusbEventLoop get instance => _instance ??= LibusbEventLoop._();

  LibUsbBindings get _lib => NativeLibusb.instance;

  int _refCount = 0;
  NativeCallable<LibusbTransferCallbackNative>? _callback;
  Future<_EventThread>? _thread;

  /// Completes once the previous event isolate (if any) has exited, so a
  /// re-[acquire] during a shutdown doesn't run two event loops at once.
  Future<void> _stopped = Future.value();

  /// transfer address -> in-flight transfer bookkeeping.
  final Map<int, _InFlight> _inFlight = {};

  /// Throws a [UsbException] if libusb was supplied via
  /// [NativeLibusb.setDynamicLibrary]: the event isolate has to open the
  /// library itself, which needs its path.
  void acquire() {
    if (_refCount == 0 && NativeLibusb.resolvedLibraryPath == null) {
      throw UsbException(
        'UsbTransferMode.asyncEvents needs libusb loaded from a path '
        '(NativeLibusb.libraryPath or the default search), not via '
        'NativeLibusb.setDynamicLibrary().',
      );
    }
    if (_refCount++ > 0) return;
    _callback = NativeCallable<LibusbTransferCallbackNative>.listener(
      _onTransferComplete,
    );
    _thread = _stopped.then((_) => _EventThread.spawn());
  }

  void release() {
    if (_refCount == 0 || --_refCount > 0) return;
    final callback = _callback!;
    final thread = _thread!;
    _callback = null;
    _thread = null;

    final draining = [for (final t in _inFlight.values) t.done.future];
    for (final t in _inFlight.values) {
      _lib.libusb_cancel_transfer(t.transfer.cast());
    }
    _stopped = _shutdown(thread, callback, draining);
  }

  Future<void> _shutdown(
    Future<_EventThread> thread,
    NativeCallable<LibusbTransferCallbackNative> callback,
    List<Future<void>> draining,
  ) async {
    final events = await thread;
    final drained = await Future.wait(draining)
        .then((_) => true)
        .timeout(_drainTimeout, onTimeout: () => false);
    await events.stop();
    // libusb must never call a closed callable. If a transfer is wedged, leak
    // the callable (and the transfer) rather than risk that.
    if (drained) callback.close();
  }

  /// Submits a bulk transfer and completes when libusb reports it done. The
  /// returned [LibusbTransferResult.status] is a raw `libusb_transfer_status`.
  Future<LibusbTransferResult> submitBulk({
    required int deviceHandleAddress,
    required int endpointAddress,
    required bool isIn,
    required int length,
    required int timeoutMs,
    Uint8List? outData,
  }) async {
    final callback = _callback;
    if (callback == null) {
      throw StateError('LibusbEventLoop.submitBulk() called without acquire()');
    }
    final failed = LibusbTransferResult(
      libusb_transfer_status.LIBUSB_TRANSFER_ERROR,
      0,
      isIn ? Uint8List(0) : null,
    );

    final transfer = _lib.libusb_alloc_transfer(0).cast<LibusbTransfer>();
    if (transfer == nullptr) return failed;

    final buffer = calloc<Uint8>(length <= 0 ? 1 : length);
    if (!isIn && outData != null) {
      buffer.asTypedList(outData.length).setAll(0, outData);
    }

    final direction = isIn
        ? libusb_endpoint_direction.LIBUSB_ENDPOINT_IN
        : libusb_endpoint_direction.LIBUSB_ENDPOINT_OUT;
    transfer.fillBulk(
      deviceHandle: Pointer<Void>.fromAddress(deviceHandleAddress),
      endpointAddress: (endpointAddress & 0x0F) | direction,
      buffer: buffer,
      length: length,
      callback: callback.nativeFunction,
      userData: 0,
      timeoutMs: timeoutMs,
    );

    final entry = _InFlight(transfer, deviceHandleAddress);
    _inFlight[transfer.address] = entry;
    try {
      if (_lib.libusb_submit_transfer(transfer.cast()) !=
          libusb_error.LIBUSB_SUCCESS) {
        _inFlight.remove(transfer.address);
        return failed;
      }
      await entry.done.future;

      // libusb doesn't touch the transfer after its callback returns, so its
      // fields and buffer are ours to read until we free them.
      final t = transfer.ref;
      final actual = t.actualLength < 0 ? 0 : t.actualLength;
      return LibusbTransferResult(
        t.status,
        t.actualLength,
        isIn ? Uint8List.fromList(buffer.asTypedList(actual)) : null,
      );
    } finally {
      _lib.libusb_free_transfer(transfer.cast());
      calloc.free(buffer);
    }
  }

  /// Requests cancellation of every in-flight transfer targeting the given
  /// libusb device handle. Their futures complete normally with a `CANCELLED`
  /// status once libusb delivers the cancellation. Called before
  /// `libusb_close`, which must not run while transfers are in flight.
  void cancelForHandle(int deviceHandleAddress) {
    for (final t in _inFlight.values) {
      if (t.deviceHandleAddress == deviceHandleAddress) {
        _lib.libusb_cancel_transfer(t.transfer.cast());
      }
    }
  }

  void _onTransferComplete(Pointer<LibusbTransfer> transfer) {
    _inFlight.remove(transfer.address)?.done.complete();
  }
}

class _InFlight {
  _InFlight(this.transfer, this.deviceHandleAddress);
  final Pointer<LibusbTransfer> transfer;
  final int deviceHandleAddress;
  final Completer<void> done = Completer<void>();
}

/// The helper isolate that runs the libusb event loop.
class _EventThread {
  _EventThread._(this._stopFlag, this._exit);

  /// Doubles as the `completed` argument of `libusb_handle_events_completed`:
  /// setting it to 1 (plus an interrupt) makes the event isolate return.
  final Pointer<Int> _stopFlag;
  final ReceivePort _exit;

  static Future<_EventThread> spawn() async {
    final stopFlag = calloc<Int>();
    final exit = ReceivePort();
    await Isolate.spawn(
      _eventIsolateMain,
      (
        NativeLibusb.contextAddress,
        stopFlag.address,
        NativeLibusb.resolvedLibraryPath!,
      ),
      onExit: exit.sendPort,
      debugName: 'libusb-events',
    );
    return _EventThread._(stopFlag, exit);
  }

  Future<void> stop() async {
    _stopFlag.value = 1;
    NativeLibusb.instance.libusb_interrupt_event_handler(NativeLibusb.context);
    await _exit.first;
    calloc.free(_stopFlag);
  }
}

/// Event isolate entry point. Opens its own binding to the already loaded
/// library (the same shared object, so the same process-wide libusb state)
/// but deliberately not via [NativeLibusb], which would `libusb_init` a
/// second, unused context in this isolate.
void _eventIsolateMain((int, int, String) args) {
  final (contextAddress, stopFlagAddress, libraryPath) = args;
  final ctx = Pointer<libusb_context>.fromAddress(contextAddress);
  final stopFlag = Pointer<Int>.fromAddress(stopFlagAddress);
  final lib = LibUsbBindings(DynamicLibrary.open(libraryPath));

  while (stopFlag.value == 0) {
    lib.libusb_handle_events_completed(ctx, stopFlag);
  }
}
