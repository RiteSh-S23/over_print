import 'dart:typed_data';

/// Only used on web. See download_web.dart.
void downloadBytes(Uint8List bytes, String filename) {
  throw UnsupportedError('Browser download is only available on web.');
}
