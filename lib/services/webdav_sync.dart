// Dart imports:
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Project imports:
import 'package:openlibe_eink_remix/services/database.dart';
import 'package:openlibe_eink_remix/services/logger.dart';
import 'package:openlibe_eink_remix/services/webdav_client.dart';

enum SyncStatus {
  idle,
  connecting,
  uploading,
  downloading,
  merging,
  completed,
  failed,
}

class SyncProgress {
  final SyncStatus status;
  final String message;
  final int totalItems;
  final int completedItems;
  final String? errorMessage;

  SyncProgress({
    required this.status,
    this.message = '',
    this.totalItems = 0,
    this.completedItems = 0,
    this.errorMessage,
  });
}

class WebDavSyncService {
  static final WebDavSyncService _instance = WebDavSyncService._internal();
  factory WebDavSyncService() => _instance;
  WebDavSyncService._internal();

  final MyLibraryDb _database = MyLibraryDb.instance;
  final AppLogger _logger = AppLogger();

  final StreamController<SyncProgress> _progressController =
      StreamController<SyncProgress>.broadcast();

  Stream<SyncProgress> get progressStream => _progressController.stream;

  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  void _emitProgress(SyncProgress progress) {
    if (!_progressController.isClosed) {
      _progressController.add(progress);
    }
  }

  Future<String> _getDeviceId() async {
    try {
      final id = await _database.getPreference('syncDeviceId');
      return id as String;
    } catch (_) {
      final id = _generateRandomId();
      await _database.savePreference('syncDeviceId', id);
      return id;
    }
  }

  String _generateRandomId() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<Map<String, String>> _getPositionTimestamps() async {
    try {
      final json =
          await _database.getPreference('syncPositionTimestamps') as String;
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<WebDavClient?> _createClientAsync() async {
    try {
      final url = await _database.getPreference('webdavUrl') as String;
      final username =
          await _database.getPreference('webdavUsername') as String;
      final encodedPassword =
          await _database.getPreference('webdavPassword') as String;
      final password = utf8.decode(base64Decode(encodedPassword));
      String remotePath;
      try {
        remotePath =
            await _database.getPreference('webdavRemotePath') as String;
      } catch (_) {
        remotePath = '/OpenLib';
      }
      return WebDavClient(
        serverUrl: url,
        username: username,
        password: password,
        remotePath: remotePath,
      );
    } catch (e) {
      _logger.error('Failed to create WebDAV client', tag: 'WebDavSync',
          error: e);
      return null;
    }
  }

  Future<bool> testConnection() async {
    final client = await _createClientAsync();
    if (client == null) return false;
    try {
      return await client.testConnection();
    } on WebDavAuthException {
      rethrow;
    } catch (e) {
      _logger.error('Connection test failed', tag: 'WebDavSync', error: e);
      return false;
    } finally {
      client.dispose();
    }
  }

  Future<bool> testConnectionWith({
    required String url,
    required String username,
    required String password,
    required String remotePath,
  }) async {
    final client = WebDavClient(
      serverUrl: url,
      username: username,
      password: password,
      remotePath: remotePath,
    );
    try {
      return await client.testConnection();
    } on WebDavAuthException {
      rethrow;
    } catch (e) {
      _logger.error('Connection test failed', tag: 'WebDavSync', error: e);
      return false;
    } finally {
      client.dispose();
    }
  }

  Future<void> saveCredentials({
    required String url,
    required String username,
    required String password,
    required String remotePath,
  }) async {
    await _database.savePreference('webdavUrl', url);
    await _database.savePreference('webdavUsername', username);
    await _database.savePreference(
        'webdavPassword', base64Encode(utf8.encode(password)));
    await _database.savePreference('webdavRemotePath', remotePath);
    await _database.savePreference('webdavSyncEnabled', 1);
  }

  Future<void> clearCredentials() async {
    await _database.savePreference('webdavUrl', '');
    await _database.savePreference('webdavUsername', '');
    await _database.savePreference('webdavPassword', '');
    await _database.savePreference('webdavRemotePath', '/OpenLib');
    await _database.savePreference('webdavSyncEnabled', 0);
    await _database.savePreference('webdavAutoSync', 0);
  }

  Future<void> performSync() async {
    if (_isSyncing) return;
    _isSyncing = true;

    final client = await _createClientAsync();
    if (client == null) {
      _emitProgress(SyncProgress(
        status: SyncStatus.failed,
        errorMessage: 'WebDAV not configured',
      ));
      _isSyncing = false;
      return;
    }

    try {
      // Step 1: Connect
      _emitProgress(SyncProgress(
        status: SyncStatus.connecting,
        message: 'Connecting to server...',
      ));

      final connected = await client.testConnection();
      if (!connected) {
        // Try creating the remote directory
        await client.ensureDirectoryExists(client.remotePath);
      }

      // Step 2: Ensure remote directory structure
      _emitProgress(SyncProgress(
        status: SyncStatus.connecting,
        message: 'Setting up remote directories...',
      ));
      await client.ensureDirectoryExists('${client.remotePath}/books');

      // Step 3: Fetch remote manifest
      _emitProgress(SyncProgress(
        status: SyncStatus.connecting,
        message: 'Reading remote library...',
      ));
      final manifestJson = await client.downloadString('openlib_sync.json');
      Map<String, dynamic> remoteManifest;
      if (manifestJson != null) {
        remoteManifest = jsonDecode(manifestJson) as Map<String, dynamic>;
      } else {
        remoteManifest = {
          'version': 1,
          'books': [],
          'positions': [],
        };
      }

      // Step 4: Diff local vs remote
      final localBooks = await _database.getAll();
      final localPositions = await _database.getAllBookPositions();
      final localTimestamps = await _getPositionTimestamps();
      final deviceId = await _getDeviceId();

      final remoteBooks =
          (remoteManifest['books'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();
      final remotePositions =
          (remoteManifest['positions'] as List<dynamic>? ?? [])
              .cast<Map<String, dynamic>>();

      final remoteBookIds = remoteBooks.map((b) => b['id'] as String).toSet();
      final localBookIds = localBooks.map((b) => b.id).toSet();

      final booksToUpload =
          localBooks.where((b) => !remoteBookIds.contains(b.id)).toList();
      final booksToDownload =
          remoteBooks.where((b) => !localBookIds.contains(b['id'])).toList();

      final totalTransfers = booksToUpload.length + booksToDownload.length;
      var completedTransfers = 0;

      // Step 5: Get book storage directory
      final bookStorageDir =
          await _database.getPreference('bookStorageDirectory') as String;

      // Step 6: Upload local-only books
      final List<String> failedUploads = [];
      for (final book in booksToUpload) {
        _emitProgress(SyncProgress(
          status: SyncStatus.uploading,
          message: 'Uploading: ${book.title}',
          totalItems: totalTransfers,
          completedItems: completedTransfers,
        ));

        try {
          final fileName = book.getFileName();
          final localFile = File('$bookStorageDir/$fileName');
          if (await localFile.exists()) {
            await client.uploadFile('books/$fileName', localFile);
            _logger.info('Uploaded: ${book.title}', tag: 'WebDavSync');
          } else {
            _logger.warning('File not found for upload: $fileName',
                tag: 'WebDavSync');
          }
        } catch (e) {
          failedUploads.add(book.title);
          _logger.error('Failed to upload: ${book.title}',
              tag: 'WebDavSync', error: e);
        }
        completedTransfers++;
      }

      // Step 7: Download remote-only books
      final List<String> failedDownloads = [];
      for (final remoteBook in booksToDownload) {
        final title = remoteBook['title'] as String? ?? 'Unknown';
        _emitProgress(SyncProgress(
          status: SyncStatus.downloading,
          message: 'Downloading: $title',
          totalItems: totalTransfers,
          completedItems: completedTransfers,
        ));

        try {
          final fileName = remoteBook['fileName'] as String? ??
              '${remoteBook['id']}.${remoteBook['format']}';
          final localPath = '$bookStorageDir/$fileName';

          await client.downloadFile('books/$fileName', localPath);

          await _database.insert(MyBook(
            id: remoteBook['id'] as String,
            title: title,
            author: remoteBook['author'] as String?,
            thumbnail: remoteBook['thumbnail'] as String?,
            link: remoteBook['link'] as String? ?? '',
            publisher: remoteBook['publisher'] as String?,
            info: remoteBook['info'] as String?,
            format: remoteBook['format'] as String?,
            description: remoteBook['description'] as String?,
            fileName: fileName,
          ));

          _logger.info('Downloaded: $title', tag: 'WebDavSync');
        } catch (e) {
          failedDownloads.add(title);
          _logger.error('Failed to download: $title',
              tag: 'WebDavSync', error: e);
        }
        completedTransfers++;
      }

      // Step 8: Merge reading positions
      _emitProgress(SyncProgress(
        status: SyncStatus.merging,
        message: 'Merging reading positions...',
        totalItems: totalTransfers,
        completedItems: completedTransfers,
      ));

      final remotePositionMap = <String, Map<String, dynamic>>{};
      for (final rp in remotePositions) {
        remotePositionMap[rp['fileName'] as String] = rp;
      }

      final mergedPositions = <Map<String, dynamic>>[];

      // Process all local positions
      for (final lp in localPositions) {
        final fileName = lp['fileName']!;
        final localPos = lp['position']!;
        final localTimestamp = localTimestamps[fileName];

        if (remotePositionMap.containsKey(fileName)) {
          final rp = remotePositionMap[fileName]!;
          final remoteTimestamp = rp['lastModified'] as String?;

          // Last-modified wins
          if (localTimestamp != null && remoteTimestamp != null) {
            final localDt = DateTime.tryParse(localTimestamp);
            final remoteDt = DateTime.tryParse(remoteTimestamp);
            if (localDt != null && remoteDt != null && remoteDt.isAfter(localDt)) {
              // Remote wins — update local
              await _database.saveBookState(
                  fileName, rp['position'] as String);
              mergedPositions.add(rp);
            } else {
              // Local wins
              mergedPositions.add({
                'fileName': fileName,
                'position': localPos,
                'lastModified': localTimestamp,
              });
            }
          } else if (remoteTimestamp != null && localTimestamp == null) {
            // Remote has timestamp, local doesn't — remote wins
            await _database.saveBookState(fileName, rp['position'] as String);
            mergedPositions.add(rp);
          } else {
            // Local wins (has timestamp or both missing)
            mergedPositions.add({
              'fileName': fileName,
              'position': localPos,
              'lastModified':
                  localTimestamp ?? DateTime.now().toUtc().toIso8601String(),
            });
          }
          remotePositionMap.remove(fileName);
        } else {
          // Local-only position
          mergedPositions.add({
            'fileName': fileName,
            'position': localPos,
            'lastModified':
                localTimestamp ?? DateTime.now().toUtc().toIso8601String(),
          });
        }
      }

      // Remaining remote-only positions
      for (final rp in remotePositionMap.values) {
        final fileName = rp['fileName'] as String;
        // Only import if the book exists locally
        final bookExists = await _database.checkIdExists(fileName) ||
            (await _database.getAll())
                .any((b) => b.getFileName() == fileName);
        if (bookExists) {
          await _database.saveBookState(fileName, rp['position'] as String);
        }
        mergedPositions.add(rp);
      }

      // Step 9: Build and upload merged manifest
      final allLocalBooks = await _database.getAll();
      final mergedManifest = {
        'version': 1,
        'lastModified': DateTime.now().toUtc().toIso8601String(),
        'deviceId': deviceId,
        'books': allLocalBooks
            .map((b) => {
                  'id': b.id,
                  'title': b.title,
                  'author': b.author,
                  'thumbnail': b.thumbnail,
                  'link': b.link,
                  'publisher': b.publisher,
                  'info': b.info,
                  'format': b.format,
                  'description': b.description,
                  'fileName': b.getFileName(),
                })
            .toList(),
        'positions': mergedPositions,
      };

      await client.uploadString(
        'openlib_sync.json',
        const JsonEncoder.withIndent('  ').convert(mergedManifest),
      );

      // Step 10: Save last sync time
      final now = DateTime.now().toIso8601String();
      await _database.savePreference('webdavLastSync', now);

      final failures = [...failedUploads, ...failedDownloads];
      if (failures.isEmpty) {
        _emitProgress(SyncProgress(
          status: SyncStatus.completed,
          message:
              'Sync complete: ${booksToUpload.length} uploaded, ${booksToDownload.length} downloaded',
          totalItems: totalTransfers,
          completedItems: totalTransfers,
        ));
      } else {
        _emitProgress(SyncProgress(
          status: SyncStatus.completed,
          message: 'Sync done with ${failures.length} error(s)',
          errorMessage: 'Failed: ${failures.join(", ")}',
          totalItems: totalTransfers,
          completedItems: completedTransfers,
        ));
      }

      _logger.info(
        'Sync completed: ${booksToUpload.length} up, ${booksToDownload.length} down, ${failures.length} failed',
        tag: 'WebDavSync',
      );
    } on WebDavAuthException {
      _emitProgress(SyncProgress(
        status: SyncStatus.failed,
        errorMessage: 'Authentication failed — check your credentials',
      ));
    } catch (e) {
      _logger.error('Sync failed', tag: 'WebDavSync', error: e);
      _emitProgress(SyncProgress(
        status: SyncStatus.failed,
        errorMessage: 'Sync failed: $e',
      ));
    } finally {
      client.dispose();
      _isSyncing = false;
    }
  }

  void dispose() {
    _progressController.close();
  }
}
