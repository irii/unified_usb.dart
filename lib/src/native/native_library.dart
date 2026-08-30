/// Loads the native `libusb-1.0` shared library and exposes a lazily
/// initialized [LibUsbBindings] binding instance plus the process-wide
/// `libusb_context` used by the native [UsbBackend] implementation.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'libusb_bindings.g.dart';

import '../usb_types.dart';

/// Candidate file names/paths for the libusb-1.0 shared library, tried in
/// order for the current platform. Override via [NativeLibusb.libraryPath]
/// if libusb is installed somewhere not covered here.
List<String> _candidatePaths() {
  if (Platform.isMacOS) {
    return [
      'libusb-1.0.0.dylib',
      'libusb-1.0.dylib',
      '/opt/homebrew/lib/libusb-1.0.0.dylib',
      '/opt/homebrew/lib/libusb-1.0.dylib',
      '/usr/local/lib/libusb-1.0.0.dylib',
      '/usr/local/lib/libusb-1.0.dylib',
      '/opt/local/lib/libusb-1.0.0.dylib',
    ];
  }
  if (Platform.isLinux) {
    return [
      'libusb-1.0.so.0',
      'libusb-1.0.so',
      '/usr/lib/x86_64-linux-gnu/libusb-1.0.so.0',
      '/usr/lib/aarch64-linux-gnu/libusb-1.0.so.0',
      '/usr/lib/libusb-1.0.so.0',
      '/usr/local/lib/libusb-1.0.so.0',
    ];
  }
  if (Platform.isWindows) {
    return ['libusb-1.0.dll'];
  }
  return const [];
}

/// Access point for the process-wide libusb binding + context used by the
/// native `UsbBackend` implementation. Not exported by
/// `package:unified_usb/unified_usb.dart` — import
/// `package:unified_usb/native_usb.dart` instead.
class NativeLibusb {
  NativeLibusb._();

  /// Explicit path/name to the libusb-1.0 shared library. Set this before
  /// the first call touching the native backend if libusb isn't installed
  /// in one of the default locations searched for the current platform. When
  /// set, this is used instead of [additionalSearchPaths] and the built-in
  /// defaults.
  static String? libraryPath;

  static final List<String> _additionalSearchPaths = [];

  /// Extra candidate paths/names to try (in [paths] order) before the
  /// built-in per-platform defaults, e.g. a location bundled alongside the
  /// app or a non-standard install directory. Call this before the first
  /// call touching the native backend. Ignored if [libraryPath] is set.
  static void addSearchPaths(Iterable<String> paths) {
    _additionalSearchPaths.addAll(paths);
  }

  static LibUsbBindings? _libusb;
  static DynamicLibrary? _dylib;
  static DynamicLibrary? _providedDylib;
  static Pointer<libusb_context>? _context;

  /// Provide an already-loaded libusb-1.0 [DynamicLibrary] to use instead of
  /// letting [NativeLibusb] open one from [libraryPath] / [addSearchPaths] /
  /// the built-in defaults. Call this before the first call touching the
  /// native backend.
  ///
  /// Only allowed while nothing has been initialized yet: throws a
  /// [StateError] if the native backend has already been initialized.
  static void setDynamicLibrary(DynamicLibrary dylib) {
    if (_libusb != null) {
      throw StateError(
        'NativeLibusb is already initialized; setDynamicLibrary() must be '
        'called before the first use of the native backend.',
      );
    }
    _providedDylib = dylib;
  }

  /// The bound libusb FFI functions, loading and `libusb_init`-ing the
  /// library on first access.
  static LibUsbBindings get instance {
    _ensureInitialized();
    return _libusb!;
  }

  /// The process-wide libusb context passed to every libusb call.
  static Pointer<libusb_context> get context {
    _ensureInitialized();
    return _context!;
  }

  /// Raw symbol for `libusb_unref_device`, used to attach a [NativeFinalizer]
  /// to each enumerated device so its native reference is released when the
  /// Dart-side wrapper is garbage collected.
  static Pointer<NativeFunction<Void Function(Pointer<Void>)>>
      get unrefDeviceSymbol {
    _ensureInitialized();
    return _dylib!.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'libusb_unref_device',
    );
  }

  static void _ensureInitialized() {
    if (_libusb != null) return;

    final dylib = _open();
    final libusb = LibUsbBindings(dylib);

    final ctxOut = calloc<Pointer<libusb_context>>();
    try {
      final result = libusb.libusb_init(ctxOut);
      if (result != libusb_error.LIBUSB_SUCCESS) {
        throw UsbException(
          'libusb_init() failed: ${libusbErrorName(result)}',
        );
      }
      _dylib = dylib;
      _libusb = libusb;
      _context = ctxOut.value;
    } finally {
      calloc.free(ctxOut);
    }
  }

  static DynamicLibrary _open() {
    final provided = _providedDylib;
    if (provided != null) {
      return provided;
    }

    final explicit = libraryPath;
    if (explicit != null) {
      return DynamicLibrary.open(explicit);
    }

    final candidates = [..._additionalSearchPaths, ..._candidatePaths()];
    if (candidates.isEmpty) {
      throw UsbException(
        'The native unified_usb backend is not supported on '
        '${Platform.operatingSystem} and no NativeLibusb.libraryPath or '
        'NativeLibusb.addSearchPaths() candidate was provided.',
      );
    }

    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (e) {
        lastError = e;
      }
    }
    throw UsbException(
      'Could not load the libusb-1.0 shared library. Install libusb '
      '(e.g. `brew install libusb`, `apt install libusb-1.0-0`, or the '
      'Windows binary release from libusb repo) or set '
      'NativeLibusb.libraryPath. Last error: $lastError',
    );
  }
}

/// Human-readable name for a `libusb_error` code.
String libusbErrorName(int code) {
  switch (code) {
    case libusb_error.LIBUSB_SUCCESS:
      return 'LIBUSB_SUCCESS';
    case libusb_error.LIBUSB_ERROR_IO:
      return 'LIBUSB_ERROR_IO';
    case libusb_error.LIBUSB_ERROR_INVALID_PARAM:
      return 'LIBUSB_ERROR_INVALID_PARAM';
    case libusb_error.LIBUSB_ERROR_ACCESS:
      return 'LIBUSB_ERROR_ACCESS';
    case libusb_error.LIBUSB_ERROR_NO_DEVICE:
      return 'LIBUSB_ERROR_NO_DEVICE';
    case libusb_error.LIBUSB_ERROR_NOT_FOUND:
      return 'LIBUSB_ERROR_NOT_FOUND';
    case libusb_error.LIBUSB_ERROR_BUSY:
      return 'LIBUSB_ERROR_BUSY';
    case libusb_error.LIBUSB_ERROR_TIMEOUT:
      return 'LIBUSB_ERROR_TIMEOUT';
    case libusb_error.LIBUSB_ERROR_OVERFLOW:
      return 'LIBUSB_ERROR_OVERFLOW';
    case libusb_error.LIBUSB_ERROR_PIPE:
      return 'LIBUSB_ERROR_PIPE';
    case libusb_error.LIBUSB_ERROR_INTERRUPTED:
      return 'LIBUSB_ERROR_INTERRUPTED';
    case libusb_error.LIBUSB_ERROR_NO_MEM:
      return 'LIBUSB_ERROR_NO_MEM';
    case libusb_error.LIBUSB_ERROR_NOT_SUPPORTED:
      return 'LIBUSB_ERROR_NOT_SUPPORTED';
    case libusb_error.LIBUSB_ERROR_OTHER:
      return 'LIBUSB_ERROR_OTHER';
    default:
      return 'libusb error $code';
  }
}
