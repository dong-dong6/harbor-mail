// Web has no camera plugin import and never fetches a third-party scan library.
export 'device_scanner_stub.dart'
    if (dart.library.io) 'device_scanner_native.dart';
