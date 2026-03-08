import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Copies bundled epub.js assets (HTML, JS) from the Flutter asset bundle
/// to the app's support directory so InAppWebView can load via file:// URL.
class EpubAssetsService {
  static const _assetFiles = [
    'assets/epubjs/reader.html',
    'assets/epubjs/epub.min.js',
    'assets/epubjs/jszip.min.js',
  ];

  static String? _cachedDir;

  /// Returns the directory path where epub.js assets are stored.
  /// Always overwrites reader.html to pick up changes between app updates.
  static Future<String> ensureAssets() async {
    if (_cachedDir != null) {
      final dir = Directory(_cachedDir!);
      if (await dir.exists()) return _cachedDir!;
    }

    final appDir = await getApplicationSupportDirectory();
    final epubjsDir = Directory(p.join(appDir.path, 'epubjs'));

    if (!await epubjsDir.exists()) {
      await epubjsDir.create(recursive: true);
    }

    for (final assetPath in _assetFiles) {
      final fileName = p.basename(assetPath);
      final targetFile = File(p.join(epubjsDir.path, fileName));

      // Always overwrite reader.html (it changes between versions).
      // Only copy JS libs if missing (they're large and stable).
      final alwaysOverwrite = fileName == 'reader.html';

      if (alwaysOverwrite || !await targetFile.exists()) {
        final data = await rootBundle.load(assetPath);
        await targetFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
    }

    _cachedDir = epubjsDir.path;
    return _cachedDir!;
  }

  /// Returns the file:// URL to the reader.html file.
  static Future<String> getReaderUrl() async {
    final dir = await ensureAssets();
    return 'file://${p.join(dir, 'reader.html')}';
  }
}
