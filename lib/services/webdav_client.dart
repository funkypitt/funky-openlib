// Dart imports:
import 'dart:convert';
import 'dart:io';

// Package imports:
import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/logger.dart';

class WebDavException implements Exception {
  final String message;
  final int? statusCode;
  WebDavException(this.message, {this.statusCode});
  @override
  String toString() => message;
}

class WebDavAuthException extends WebDavException {
  WebDavAuthException() : super('Authentication failed', statusCode: 401);
}

class WebDavNotFoundException extends WebDavException {
  WebDavNotFoundException(String path)
      : super('Not found: $path', statusCode: 404);
}

class WebDavRemoteFile {
  final String href;
  final String? lastModified;
  final int? contentLength;
  final bool isDirectory;

  WebDavRemoteFile({
    required this.href,
    this.lastModified,
    this.contentLength,
    this.isDirectory = false,
  });
}

class WebDavClient {
  final String serverUrl;
  final String username;
  final String password;
  final String remotePath;
  final AppLogger _logger = AppLogger();
  late final Dio _dio;

  WebDavClient({
    required this.serverUrl,
    required this.username,
    required this.password,
    this.remotePath = '/OpenLib',
  }) {
    final baseUrl = serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {
        'Authorization':
            'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      },
    ));
  }

  String get _basePath =>
      remotePath.endsWith('/') ? remotePath : '$remotePath/';

  String _fullPath(String subPath) {
    if (subPath.startsWith('/')) subPath = subPath.substring(1);
    return '$_basePath$subPath';
  }

  Future<bool> testConnection() async {
    try {
      final response = await _dio.request(
        _basePath,
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
      );
      return response.statusCode == 207 || response.statusCode == 200;
    } on DioException catch (e) {
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw WebDavAuthException();
      }
      _logger.error('WebDAV connection test failed', tag: 'WebDAV', error: e);
      return false;
    }
  }

  Future<void> createDirectory(String path) async {
    final fullPath = path.startsWith('/') ? path : _fullPath(path);
    try {
      await _dio.request(fullPath, options: Options(method: 'MKCOL'));
    } on DioException catch (e) {
      // 405 = already exists, which is fine
      if (e.response?.statusCode == 405 || e.response?.statusCode == 301) {
        return;
      }
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw WebDavAuthException();
      }
      rethrow;
    }
  }

  Future<void> ensureDirectoryExists(String path) async {
    final fullPath = path.startsWith('/') ? path : _fullPath(path);
    final parts = fullPath.split('/')..removeWhere((p) => p.isEmpty);
    var current = '';
    for (final part in parts) {
      current += '/$part';
      try {
        await createDirectory('$current/');
      } catch (_) {
        // Continue — parent may already exist
      }
    }
  }

  Future<List<WebDavRemoteFile>> listDirectory(String path) async {
    final fullPath = path.startsWith('/') ? path : _fullPath(path);
    try {
      final response = await _dio.request(
        fullPath,
        options: Options(
          method: 'PROPFIND',
          headers: {'Depth': '1'},
          responseType: ResponseType.plain,
        ),
      );
      return _parsePropfindResponse(response.data as String, fullPath);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return [];
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw WebDavAuthException();
      }
      rethrow;
    }
  }

  List<WebDavRemoteFile> _parsePropfindResponse(
      String xml, String requestPath) {
    final document = XmlDocument.parse(xml);
    // Match by local name regardless of the server's namespace prefix
    // (Nextcloud uses d:, Apache mod_dav uses D:, others use none).
    final responses =
        document.findAllElements('response', namespace: '*').toList();

    final files = <WebDavRemoteFile>[];
    final normalizedRequestPath = Uri.decodeFull(requestPath)
        .replaceAll(RegExp(r'/+$'), '');

    for (final response in responses) {
      final hrefElements = response.findAllElements('href', namespace: '*');
      if (hrefElements.isEmpty) continue;

      final href = Uri.decodeFull(hrefElements.first.innerText.trim());
      final normalizedHref = href.replaceAll(RegExp(r'/+$'), '');

      // Skip the directory itself
      if (normalizedHref == normalizedRequestPath ||
          normalizedHref.endsWith(normalizedRequestPath)) {
        continue;
      }

      final propstat =
          response.findAllElements('propstat', namespace: '*');
      String? lastModified;
      int? contentLength;
      bool isDirectory = href.endsWith('/');

      for (final ps in propstat) {
        final props = ps.findAllElements('prop', namespace: '*');
        for (final prop in props) {
          final lm =
              prop.findAllElements('getlastmodified', namespace: '*');
          if (lm.isNotEmpty) lastModified = lm.first.innerText.trim();

          final cl =
              prop.findAllElements('getcontentlength', namespace: '*');
          if (cl.isNotEmpty) {
            contentLength = int.tryParse(cl.first.innerText.trim());
          }

          final rt = prop.findAllElements('resourcetype', namespace: '*');
          for (final r in rt) {
            if (r.findAllElements('collection', namespace: '*').isNotEmpty) {
              isDirectory = true;
            }
          }
        }
      }

      final fileName = href.split('/').where((s) => s.isNotEmpty).last;
      files.add(WebDavRemoteFile(
        href: fileName,
        lastModified: lastModified,
        contentLength: contentLength,
        isDirectory: isDirectory,
      ));
    }
    return files;
  }

  Future<void> uploadFile(String remotePath, File localFile) async {
    final fullPath = _fullPath(remotePath);
    final fileStream = localFile.openRead();
    final length = await localFile.length();

    await _dio.put(
      fullPath,
      data: fileStream,
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': length,
        },
        // Don't transform stream data
        requestEncoder: null,
      ),
    );
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    final fullPath = _fullPath(remotePath);
    await _dio.download(fullPath, localPath);
  }

  Future<void> uploadString(String remotePath, String content) async {
    final fullPath = _fullPath(remotePath);
    await _dio.put(
      fullPath,
      data: content,
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
  }

  Future<String?> downloadString(String remotePath) async {
    final fullPath = _fullPath(remotePath);
    try {
      final response = await _dio.get(
        fullPath,
        options: Options(responseType: ResponseType.plain),
      );
      return response.data as String;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      if (e.response?.statusCode == 401 || e.response?.statusCode == 403) {
        throw WebDavAuthException();
      }
      rethrow;
    }
  }

  Future<bool> exists(String remotePath) async {
    final fullPath = _fullPath(remotePath);
    try {
      await _dio.request(
        fullPath,
        options: Options(method: 'PROPFIND', headers: {'Depth': '0'}),
      );
      return true;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return false;
      rethrow;
    }
  }

  void dispose() {
    _dio.close();
  }
}
