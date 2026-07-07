// Dart imports:
import 'dart:convert';
import 'dart:io';

// Package imports:
import 'package:crypto/crypto.dart' show md5;
import 'package:dio/dio.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/database.dart'
    show MyLibraryDb;

/// Keeps the Android home-screen "currently reading" widget in sync with the
/// book the user last opened/read. No-op on all other platforms.
class ReadingWidgetService {
  ReadingWidgetService._();

  static const String _androidProviderName = 'ReadingWidgetProvider';
  static const String _qualifiedProviderName =
      'dev.wath.openlibeextendedeinkremix.ReadingWidgetProvider';

  // Skip redundant widget refreshes while turning pages within the same book.
  static String? _lastFileName;
  static int? _lastPercent;

  /// Update the widget with the book currently being read.
  /// [progress] is 0.0–1.0 when the caller knows it; otherwise the last
  /// value stored in the database is used.
  static Future<void> updateFromReading(String fileName,
      {double? progress}) async {
    if (!Platform.isAndroid) return;
    try {
      final prog =
          progress ?? await MyLibraryDb.instance.getBookProgress(fileName);
      final percent =
          prog != null ? (prog * 100).round().clamp(0, 100) : -1;
      if (fileName == _lastFileName && percent == _lastPercent) return;

      final book = await MyLibraryDb.instance.getBookByFileName(fileName);
      final title = (book?.title.trim().isNotEmpty ?? false)
          ? book!.title.trim()
          : _titleFromFileName(fileName);
      final author = book?.author?.trim() ?? '';

      String coverPath = '';
      final thumbnail = book?.thumbnail;
      if (thumbnail != null && thumbnail.isNotEmpty) {
        coverPath = await _ensureCoverFile(thumbnail) ?? '';
      }

      await HomeWidget.saveWidgetData<String>('reading_file', fileName);
      await HomeWidget.saveWidgetData<String>('reading_title', title);
      await HomeWidget.saveWidgetData<String>('reading_author', author);
      await HomeWidget.saveWidgetData<int>('reading_percent', percent);
      await HomeWidget.saveWidgetData<String>('reading_cover', coverPath);
      await HomeWidget.updateWidget(
        name: _androidProviderName,
        qualifiedAndroidName: _qualifiedProviderName,
      );

      _lastFileName = fileName;
      _lastPercent = percent;
    } catch (_) {
      // The widget is best-effort; never let it break reading.
    }
  }

  static String _titleFromFileName(String fileName) {
    var name = fileName;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  }

  /// Download the cover once and cache it, so the widget (a RemoteViews on
  /// the launcher side) can load it from a local file path.
  static Future<String?> _ensureCoverFile(String url) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final coversDir = Directory(p.join(dir.path, 'widget_covers'));
      final file = File(
          p.join(coversDir.path, '${md5.convert(utf8.encode(url))}.img'));
      if (await file.exists()) return file.path;
      await coversDir.create(recursive: true);
      final response = await Dio().get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return null;
    }
  }
}
