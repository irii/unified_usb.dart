/// Asynchronous libusb transfer engine used by [NativeUsbBackend] when
/// constructed with `UsbTransferMode.asyncEvents`.
///
/// A dedicated helper isolate owns all native transfer memory and runs the
/// libusb event loop (`libusb_handle_events_timeout_completed`). Callers
/// submit a transfer and `await` a [LibusbTransferResult]; the calling
/// isolate never blocks inside a native call, which is what makes this behave
/// like WebUSB instead of stalling a whole isolate on an idle read.
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

import 'libusb_bindings.g.dart';
import 'libusb_transfer_struct.dart';
import 'native_library.dart';

/// How often (worst case) the helper isolate notices a newly submitted
/// transfer or a completion while otherwise idle. A blocking libusb event
/// wait of this length is used between poll iterations; completions that
/// arrive sooner return immediately, so active streaming is not slowed by it.
const int _eventWaitMs = 10;

/// Result of an async bulk transfer, reported back to the submitting isolate.
class LibusbTransferResult {
  const LibusbTransferResult(this.status, this.actualLength, this.data);

  /// One of the `libusb_transfer_status.*` constants.
  final int status;
  final int actualLength;

  /// Bytes received, for IN transfers. `null` for OUT transfers.
  final Uint8List? data;
}

// ---------------------------------------------------------------------------
// Cross-isolate messages
// ---------------------------------------------------------------------------

class _InitMsg {
  const _InitMsg(this.toBackend, this.contextAddress, this.libraryPath);
  final SendPort toBackend;
  final int contextAddress;
  final String? libraryPath;
}

class _ReadyMsg {
  const _ReadyMsg(this.toEvent);
  final SendPort toEvent;
}

class _SubmitMsg {
  const _SubmitMsg({
    required this.seq,
    required this.deviceHandleAddress,
    required this.endpointAddress,
    required this.isIn,
    required this.length,
    required this.timeoutMs,
    required this.outData,
  });
  final int seq;
  final int deviceHandleAddress;
  final int endpointAddress;
  final bool isIn;
  final int length;
  final int timeoutMs;
  final Uint8List? outData;
}

class _CancelMsg {
  const _CancelMsg(this.deviceHandleAddress);
  final int deviceHandleAddress;
}

class _ResultMsg {
  const _ResultMsg(this.seq, this.status, this.actualLength, this.data);
  final int seq;
  final int status;
  final int actualLength;
  final Uint8List? data;
}

class _ShutdownMsg {
  const _ShutdownMsg();
}

// ---------------------------------------------------------------------------
// Backend-isolate side
// ---------------------------------------------------------------------------

/// Per-isolate singleton. Reference-counted by the [NativeUsbBackend]s that
/// use it; the helper isolate is spawned on first [acquire] and torn down
/// when the last user calls [release].
class LibusbEventLoop {
  LibusbEventLoop._();

  static LibusbEventLoop? _instance;
  static LibusbEventLoop get instance => _instance ??= LibusbEventLoop._();

  int _refCount = 0;
  Isolate? _isolate;
  SendPort? _toEvent;
  ReceivePort? _fromEvent;
  Future<void>? _starting;

  int _nextSeq = 1;
  final Map<int, Completer<LibusbTransferResult>> _pending = {};

  Future<void> acquire() async {
    _refCount++;
    await _ensureStarted();
  }

  void release() {
    if (_refCount == 0) return;
    _refCount--;
    if (_refCount == 0) {
      _toEvent?.send(const _ShutdownMsg());
      _isolate?.kill(priority: Isolate.beforeNextEvent);
      _isolate = null;
      _toEvent = null;
      _fromEvent?.close();
      _fromEvent = null;
      _starting = null;
      for (final c in _pending.values) {
        if (!c.isCompleted) {
          c.complete(const LibusbTransferResult(
            libusb_transfer_status.LIBUSB_TRANSFER_CANCELLED,
            0,
            null,
          ));
        }
      }
      _pending.clear();
    }
  }

  Future<void> _ensureStarted() {
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final fromEvent = ReceivePort();
    _fromEvent = fromEvent;
    final ready = Completer<SendPort>();

    fromEvent.listen((msg) {
      if (msg is _ReadyMsg) {
        if (!ready.isCompleted) ready.complete(msg.toEvent);
      } else if (msg is _ResultMsg) {
        final c = _pending.remove(msg.seq);
        c?.complete(LibusbTransferResult(
          msg.status,
          msg.actualLength,
          msg.data,
        ));
      }
    });

    _isolate = await Isolate.spawn(
      _eventIsolateMain,
      _InitMsg(
        fromEvent.sendPort,
        NativeLibusb.contextAddress,
        NativeLibusb.resolvedLibraryPath,
      ),
      debugName: 'libusb-events',
    );

    _toEvent = await ready.future;
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
    await _ensureStarted();
    final seq = _nextSeq++;
    final completer = Completer<LibusbTransferResult>();
    _pending[seq] = completer;
    _toEvent!.send(_SubmitMsg(
      seq: seq,
      deviceHandleAddress: deviceHandleAddress,
      endpointAddress: endpointAddress,
      isIn: isIn,
      length: length,
      timeoutMs: timeoutMs,
      outData: outData,
    ));
    return completer.future;
  }

  /// Requests cancellation of every in-flight transfer targeting the given
  /// libusb device handle. Their futures complete normally with a `CANCELLED`
  /// status once libusb delivers the cancellation. Called before
  /// `libusb_close`, which must not run while transfers are in flight.
  void cancelForHandle(int deviceHandleAddress) {
    _toEvent?.send(_CancelMsg(deviceHandleAddress));
  }
}

// ---------------------------------------------------------------------------
// Helper-isolate side
// ---------------------------------------------------------------------------

void _eventIsolateMain(_InitMsg init) {
  _EventIsolate(init).run();
}

class _EventIsolate {
  _EventIsolate(this._init);

  final _InitMsg _init;

  late final LibUsbBindings _lib;
  late final Pointer<libusb_context> _ctx;
  late final NativeCallable<LibusbTransferCallbackNative> _callback;

  final ReceivePort _commands = ReceivePort();
  final Pointer<timeval> _tv = calloc<timeval>();
  final Pointer<Int> _completed = calloc<Int>();

  /// seq -> in-flight transfer bookkeeping. `seq` is also stored as the
  /// transfer's `user_data`, so the C completion callback can recover it.
  final Map<int, _InFlight> _inFlight = {};

  bool _pumpScheduled = false;
  bool _shuttingDown = false;

  void run() {
    _lib = NativeLibusb.instance;
    _ctx = Pointer<libusb_context>.fromAddress(_init.contextAddress);
    _callback = NativeCallable<LibusbTransferCallbackNative>.isolateLocal(
      _onTransferComplete,
    );
    _tv.ref
      ..tv_sec = 0
      ..tv_usec = _eventWaitMs * 1000;

    _commands.listen(_handleCommand);
    _init.toBackend.send(_ReadyMsg(_commands.sendPort));
  }

  void _handleCommand(dynamic msg) {
    if (msg is _SubmitMsg) {
      _submit(msg);
    } else if (msg is _CancelMsg) {
      for (final entry in _inFlight.values) {
        if (entry.deviceHandleAddress == msg.deviceHandleAddress) {
          _lib.libusb_cancel_transfer(entry.transfer.cast());
        }
      }
    } else if (msg is _ShutdownMsg) {
      _shutdown();
    }
  }

  void _submit(_SubmitMsg msg) {
    final transfer = _lib.libusb_alloc_transfer(0).cast<LibusbTransfer>();
    if (transfer == nullptr) {
      _init.toBackend.send(_ResultMsg(
        msg.seq,
        libusb_transfer_status.LIBUSB_TRANSFER_ERROR,
        0,
        msg.isIn ? Uint8List(0) : null,
      ));
      return;
    }

    final bufLen = msg.length <= 0 ? 1 : msg.length;
    final buffer = calloc<Uint8>(bufLen);
    if (!msg.isIn && msg.outData != null) {
      buffer.asTypedList(msg.outData!.length).setAll(0, msg.outData!);
    }

    final address = msg.isIn
        ? (msg.endpointAddress & 0x0F) | libusb_endpoint_direction.LIBUSB_ENDPOINT_IN
        : (msg.endpointAddress & 0x0F) |
            libusb_endpoint_direction.LIBUSB_ENDPOINT_OUT;

    transfer.fillBulk(
      deviceHandle: Pointer<Void>.fromAddress(msg.deviceHandleAddress),
      endpointAddress: address,
      buffer: buffer,
      length: msg.length,
      callback: _callback.nativeFunction,
      userData: msg.seq,
      timeoutMs: msg.timeoutMs,
    );

    _inFlight[msg.seq] =
        _InFlight(transfer, buffer, msg.isIn, msg.deviceHandleAddress);

    final rc = _lib.libusb_submit_transfer(transfer.cast());
    if (rc != libusb_error.LIBUSB_SUCCESS) {
      _inFlight.remove(msg.seq);
      _lib.libusb_free_transfer(transfer.cast());
      calloc.free(buffer);
      _init.toBackend.send(_ResultMsg(
        msg.seq,
        libusb_transfer_status.LIBUSB_TRANSFER_ERROR,
        0,
        msg.isIn ? Uint8List(0) : null,
      ));
      return;
    }

    _schedulePump();
  }

  void _onTransferComplete(Pointer<LibusbTransfer> transfer) {
    final t = transfer.ref;
    final seq = t.userData.address;
    final entry = _inFlight.remove(seq);
    final status = t.status;
    final actual = t.actualLength;

    Uint8List? data;
    if (entry != null && entry.isIn) {
      final n = actual < 0 ? 0 : actual;
      data = Uint8List(n)..setAll(0, entry.buffer.asTypedList(n));
    }

    _lib.libusb_free_transfer(transfer.cast());
    if (entry != null) calloc.free(entry.buffer);

    _init.toBackend.send(_ResultMsg(seq, status, actual, data));
  }

  void _schedulePump() {
    if (_pumpScheduled || _shuttingDown) return;
    _pumpScheduled = true;
    Timer.run(_pump);
  }

  void _pump() {
    _pumpScheduled = false;
    if (_shuttingDown) return;

    // Blocks up to `_eventWaitMs`, but returns as soon as any event (a
    // completion) is handled, so back-to-back transfers are not throttled.
    _lib.libusb_handle_events_timeout_completed(_ctx, _tv, _completed);

    if (_inFlight.isNotEmpty) _schedulePump();
  }

  void _shutdown() {
    _shuttingDown = true;
    for (final entry in _inFlight.values) {
      _lib.libusb_cancel_transfer(entry.transfer.cast());
    }
    // Give libusb a brief chance to fire the cancellation callbacks so the
    // native allocations are freed rather than leaked on the way out.
    _lib.libusb_handle_events_timeout_completed(_ctx, _tv, _completed);
    for (final entry in _inFlight.values) {
      _lib.libusb_free_transfer(entry.transfer.cast());
      calloc.free(entry.buffer);
    }
    _inFlight.clear();
    _callback.close();
    calloc.free(_tv);
    calloc.free(_completed);
    _commands.close();
  }
}

class _InFlight {
  _InFlight(this.transfer, this.buffer, this.isIn, this.deviceHandleAddress);
  final Pointer<LibusbTransfer> transfer;
  final Pointer<Uint8> buffer;
  final bool isIn;
  final int deviceHandleAddress;
}
