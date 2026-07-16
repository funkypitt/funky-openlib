// Dart imports:
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

// Project imports:
import 'package:openlibe_eink_remix/services/book_metadata.dart';
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

      // Step 3.5: Names of external files known to duplicate library books —
      // kept both locally and in the manifest so no device downloads them
      // again. Merged from both sources.
      final ignoredExternal = await _loadLocalIgnoredExternalFiles();
      ignoredExternal.addAll(
          ((remoteManifest['ignoredExternalFiles'] as List<dynamic>?) ?? [])
              .cast<String>());

      final bookStorageDir =
          await _database.getPreference('bookStorageDirectory') as String;

      // Step 3.7: One-time repair for libraries hit by the v1.3.1 adoption
      // bug: drop entries that are byte-identical copies of existing books
      // and backfill covers/metadata from the book files themselves.
      await _cleanupLibraryOnce(bookStorageDir, ignoredExternal);

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

      String manifestFileNameOf(Map<String, dynamic> b) =>
          b['fileName'] as String? ?? '${b['id']}.${b['format']}';

      final localFileNamesLower =
          localBooks.map((b) => b.getFileName().toLowerCase()).toSet();

      final booksToUpload =
          localBooks.where((b) => !remoteBookIds.contains(b.id)).toList();
      // A manifest entry is only downloaded if neither its id nor its file
      // name is known locally — the same file must never be imported twice
      // just because two devices assigned it different ids.
      final booksToDownload = remoteBooks.where((b) {
        if (localBookIds.contains(b['id'])) return false;
        return !localFileNamesLower
            .contains(manifestFileNameOf(b).toLowerCase());
      }).toList();

      // Step 4.5: Adopt external books present in the remote books/ folder
      // but absent from the manifest (e.g. dropped there by another app or
      // a browser extension). They are downloaded to a temp file first and
      // only join the library if their content is not already in it.
      final manifestFileNamesLower =
          remoteBooks.map((b) => manifestFileNameOf(b).toLowerCase()).toSet();
      final ignoredExternalLower =
          ignoredExternal.map((n) => n.toLowerCase()).toSet();
      try {
        final remoteFiles =
            await client.listDirectory('${client.remotePath}/books');
        const bookExtensions = ['.epub', '.pdf', '.cbr', '.cbz'];
        for (final f in remoteFiles) {
          if (f.isDirectory) continue;
          final name = f.href;
          final lower = name.toLowerCase();
          if (!bookExtensions.any(lower.endsWith)) continue;
          if (manifestFileNamesLower.contains(lower) ||
              localFileNamesLower.contains(lower) ||
              ignoredExternalLower.contains(lower)) {
            continue;
          }
          final dot = name.lastIndexOf('.');
          booksToDownload.add({
            // Provisional id — replaced by the file's content MD5 once
            // downloaded, so identical files converge across devices.
            'id': name.substring(0, dot),
            'title': titleFromFileName(name),
            'format': lower.substring(dot + 1),
            'fileName': name,
            'link': '',
            'adopted': true,
          });
          _logger.info('Adopting external book from server: $name',
              tag: 'WebDavSync');
        }
      } catch (e) {
        _logger.error('Failed to scan remote books folder',
            tag: 'WebDavSync', error: e);
      }

      final totalTransfers = booksToUpload.length + booksToDownload.length;
      var completedTransfers = 0;

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
            await client.uploadFile(
                'books/${Uri.encodeComponent(fileName)}', localFile);
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
      var skippedDuplicates = 0;
      final adoptedHashes = <String>{};
      for (final remoteBook in booksToDownload) {
        final title = remoteBook['title'] as String? ?? 'Unknown';
        _emitProgress(SyncProgress(
          status: SyncStatus.downloading,
          message: 'Downloading: $title',
          totalItems: totalTransfers,
          completedItems: completedTransfers,
        ));

        try {
          final fileName = manifestFileNameOf(remoteBook);
          final localPath = '$bookStorageDir/$fileName';
          final adopted = remoteBook['adopted'] == true;

          if (adopted) {
            // Download to a temp file first: if the content turns out to be
            // a book we already have under another file name, leave the
            // library untouched and remember the name so it is never
            // downloaded again (on any device).
            final tmpPath = '$bookStorageDir/.openlib_sync_download.tmp';
            await client.downloadFile(
                'books/${Uri.encodeComponent(fileName)}', tmpPath);
            final hash = await computeFileMd5(tmpPath);
            if (localBookIds.contains(hash) ||
                adoptedHashes.contains(hash) ||
                await _matchesExistingFile(
                    hash, tmpPath, localBooks, bookStorageDir)) {
              try {
                await File(tmpPath).delete();
              } catch (_) {}
              ignoredExternal.add(fileName);
              skippedDuplicates++;
              _logger.info(
                  'External file is a copy of an existing book, skipping: $fileName',
                  tag: 'WebDavSync');
            } else {
              await File(tmpPath).rename(localPath);
              adoptedHashes.add(hash);
              // Real metadata and cover come from the book file itself;
              // the file name is only the fallback.
              final meta = await extractEpubMetadata(localPath,
                  coverKey: _coverKey(hash));
              await _database.insert(MyBook(
                id: hash,
                title: meta?.title ?? title,
                author: meta?.author,
                thumbnail: meta?.coverPath,
                link: '',
                publisher: meta?.publisher,
                info: null,
                format: remoteBook['format'] as String?,
                description: meta?.description,
                fileName: fileName,
              ));
              _logger.info('Adopted: ${meta?.title ?? title}',
                  tag: 'WebDavSync');
            }
          } else {
            // Encode the segment: file names may contain characters that
            // are invalid in a raw URL path ('#', '?', spaces, ...)
            await client.downloadFile(
                'books/${Uri.encodeComponent(fileName)}', localPath);

            var bookTitle = title;
            var author = remoteBook['author'] as String?;
            var thumbnail = remoteBook['thumbnail'] as String?;
            var publisher = remoteBook['publisher'] as String?;
            var description = remoteBook['description'] as String?;
            if (thumbnail == null || thumbnail.isEmpty) {
              // No cover URL (book was adopted from an external file on
              // another device) — extract the cover and any missing fields
              // from the downloaded file.
              final meta = await extractEpubMetadata(localPath,
                  coverKey: _coverKey(remoteBook['id'] as String));
              if (meta != null) {
                thumbnail = meta.coverPath;
                if (author == null || author.isEmpty) author = meta.author;
                if (publisher == null || publisher.isEmpty) {
                  publisher = meta.publisher;
                }
                if (description == null || description.isEmpty) {
                  description = meta.description;
                }
                if (bookTitle == 'Unknown') bookTitle = meta.title ?? bookTitle;
              }
            }

            await _database.insert(MyBook(
              id: remoteBook['id'] as String,
              title: bookTitle,
              author: author,
              thumbnail: thumbnail,
              link: remoteBook['link'] as String? ?? '',
              publisher: publisher,
              info: remoteBook['info'] as String?,
              format: remoteBook['format'] as String?,
              description: description,
              fileName: fileName,
            ));

            _logger.info('Downloaded: $title', tag: 'WebDavSync');
          }
        } catch (e) {
          failedDownloads.add(title);
          _logger.error('Failed to download: $title',
              tag: 'WebDavSync', error: e);
        }
        completedTransfers++;
      }

      // Persist the ignore list so skipped duplicates stay skipped.
      await _saveLocalIgnoredExternalFiles(ignoredExternal);

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
        final fileName = lp['fileName'] as String;
        final localPos = lp['position'] as String;
        final localProgress = lp['progress'];
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
                  fileName, rp['position'] as String,
                  progress: (rp['progress'] as num?)?.toDouble());
              mergedPositions.add(rp);
            } else {
              // Local wins
              mergedPositions.add({
                'fileName': fileName,
                'position': localPos,
                if (localProgress is num) 'progress': localProgress,
                'lastModified': localTimestamp,
              });
            }
          } else if (remoteTimestamp != null && localTimestamp == null) {
            // Remote has timestamp, local doesn't — remote wins
            await _database.saveBookState(fileName, rp['position'] as String,
                progress: (rp['progress'] as num?)?.toDouble());
            mergedPositions.add(rp);
          } else {
            // Local wins (has timestamp or both missing)
            mergedPositions.add({
              'fileName': fileName,
              'position': localPos,
              if (localProgress is num) 'progress': localProgress,
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
            if (localProgress is num) 'progress': localProgress,
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
          await _database.saveBookState(fileName, rp['position'] as String,
              progress: (rp['progress'] as num?)?.toDouble());
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
                  // Covers extracted from book files are local paths that
                  // mean nothing to other devices — they re-extract locally.
                  'thumbnail': _isLocalPath(b.thumbnail) ? null : b.thumbnail,
                  'link': b.link,
                  'publisher': b.publisher,
                  'info': b.info,
                  'format': b.format,
                  'description': b.description,
                  'fileName': b.getFileName(),
                })
            .toList(),
        'positions': mergedPositions,
        'ignoredExternalFiles': (ignoredExternal.toList()..sort()),
      };

      await client.uploadString(
        'openlib_sync.json',
        const JsonEncoder.withIndent('  ').convert(mergedManifest),
      );

      // Step 9.5: Merge per-book annotations (highlights & notes)
      _emitProgress(SyncProgress(
        status: SyncStatus.merging,
        message: 'Merging highlights & notes...',
        totalItems: totalTransfers,
        completedItems: totalTransfers,
      ));
      try {
        await _syncAnnotations(client, allLocalBooks);
      } catch (e) {
        _logger.error('Annotation sync failed', tag: 'WebDavSync', error: e);
      }

      // Step 10: Save last sync time
      final now = DateTime.now().toIso8601String();
      await _database.savePreference('webdavLastSync', now);

      final failures = [...failedUploads, ...failedDownloads];
      if (failures.isEmpty) {
        final downloadedCount = booksToDownload.length - skippedDuplicates;
        final dupNote = skippedDuplicates > 0
            ? ', $skippedDuplicates duplicate(s) skipped'
            : '';
        _emitProgress(SyncProgress(
          status: SyncStatus.completed,
          message:
              'Sync complete: ${booksToUpload.length} uploaded, $downloadedCount downloaded$dupNote',
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

  /// External file names known to duplicate existing library books.
  Future<Set<String>> _loadLocalIgnoredExternalFiles() async {
    try {
      final json =
          await _database.getPreference('syncIgnoredExternalFiles') as String;
      return (jsonDecode(json) as List<dynamic>).cast<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _saveLocalIgnoredExternalFiles(Set<String> names) async {
    await _database.savePreference(
        'syncIgnoredExternalFiles', jsonEncode(names.toList()..sort()));
  }

  static bool _isLocalPath(String? thumbnail) =>
      thumbnail != null &&
      (thumbnail.startsWith('/') || thumbnail.startsWith('file://'));

  /// File-system-safe name for a cover image derived from a book id.
  static String _coverKey(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

  /// True if the downloaded temp file is byte-identical to any book file
  /// already in the library (size compared first, MD5 only on size match).
  Future<bool> _matchesExistingFile(String hash, String tmpPath,
      List<MyBook> localBooks, String bookStorageDir) async {
    final size = await File(tmpPath).length();
    for (final book in localBooks) {
      try {
        final file = File('$bookStorageDir/${book.getFileName()}');
        if (await file.exists() && await file.length() == size) {
          if (await computeFileMd5(file.path) == hash) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// One-time library repair after the v1.3.1 adoption bug: entries without
  /// a source link whose file content is identical to another library book
  /// are duplicates created by the old filename-only adoption — remove them
  /// (row + file copy) and ignore their remote file from now on. Remaining
  /// entries missing covers/metadata are backfilled from the epub itself.
  Future<void> _cleanupLibraryOnce(
      String bookStorageDir, Set<String> ignoredExternal) async {
    try {
      final done = await _database.getPreference('libraryDedupePassV1');
      if (done.toString() == '1') return;
    } catch (_) {
      // Preference missing — pass has not run yet.
    }
    try {
      final books = await _database.getAll();
      final booksById = {for (final b in books) b.id: b};
      for (final book in books) {
        final fileName = book.getFileName();
        final file = File('$bookStorageDir/$fileName');
        if (!await file.exists()) continue;

        if (book.link.isEmpty) {
          String? hash;
          try {
            hash = await computeFileMd5(file.path);
          } catch (_) {}
          final original = hash != null ? booksById[hash] : null;
          if (original != null && original.id != book.id) {
            await _database.delete(book.id);
            await _database.deleteBookState(fileName);
            try {
              await file.delete();
            } catch (_) {}
            ignoredExternal.add(fileName);
            _logger.info('Removed duplicate library entry: ${book.title}',
                tag: 'WebDavSync');
            continue;
          }
        }

        final missingCover =
            book.thumbnail == null || book.thumbnail!.isEmpty;
        final missingAuthor = book.author == null ||
            book.author!.isEmpty ||
            book.author == 'Unknown';
        if (missingCover || missingAuthor) {
          final meta = await extractEpubMetadata(file.path,
              coverKey: _coverKey(book.id));
          if (meta == null) continue;
          // Entries without a source link got their title from the file
          // name — the epub's own title is more trustworthy there.
          final preferFileTitle = book.link.isEmpty;
          await _database.insert(MyBook(
            id: book.id,
            title: preferFileTitle ? (meta.title ?? book.title) : book.title,
            author: missingAuthor ? (meta.author ?? book.author) : book.author,
            thumbnail:
                missingCover ? (meta.coverPath ?? book.thumbnail) : book.thumbnail,
            link: book.link,
            publisher: (book.publisher == null || book.publisher!.isEmpty)
                ? (meta.publisher ?? book.publisher)
                : book.publisher,
            info: book.info,
            format: book.format,
            description: (book.description == null || book.description!.isEmpty)
                ? (meta.description ?? book.description)
                : book.description,
            fileName: book.fileName,
          ));
          _logger.info('Backfilled metadata for: ${book.title}',
              tag: 'WebDavSync');
        }
      }
      await _database.savePreference('libraryDedupePassV1', '1');
    } catch (e) {
      _logger.error('Library cleanup failed', tag: 'WebDavSync', error: e);
    }
  }

  /// Sync per-book annotation files under `<remotePath>/annotations/<fileName>.json`.
  /// Each file holds the full annotation list (including tombstones); merge is
  /// done id-by-id with last-updated-wins so deletions propagate across devices.
  Future<void> _syncAnnotations(
      WebDavClient client, List<MyBook> localBooks) async {
    await client.ensureDirectoryExists('${client.remotePath}/annotations');

    final fileNames = <String>{};
    for (final b in localBooks) {
      fileNames.add(b.getFileName());
    }
    fileNames.addAll(await _database.getBookFileNamesWithAnnotations());
    try {
      final remoteFiles =
          await client.listDirectory('${client.remotePath}/annotations');
      for (final f in remoteFiles) {
        if (!f.isDirectory && f.href.endsWith('.json')) {
          fileNames.add(f.href.substring(0, f.href.length - 5));
        }
      }
    } catch (_) {}

    for (final fileName in fileNames) {
      try {
        await _syncAnnotationsForBook(client, fileName);
      } catch (e) {
        _logger.error('Annotation sync failed for $fileName',
            tag: 'WebDavSync', error: e);
      }
    }
  }

  Future<void> _syncAnnotationsForBook(
      WebDavClient client, String fileName) async {
    final remotePath = 'annotations/${Uri.encodeComponent('$fileName.json')}';

    // Remote annotations keyed by id
    final remoteMap = <String, Annotation>{};
    try {
      final json = await client.downloadString(remotePath);
      if (json != null && json.isNotEmpty) {
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        final arr = (decoded['annotations'] as List<dynamic>? ?? []);
        for (final e in arr) {
          final a = Annotation.fromMap((e as Map).cast<String, dynamic>());
          remoteMap[a.id] = a;
        }
      }
    } catch (_) {
      // Missing/unreadable remote file -> treat as empty
    }

    final localRaw = await _database.getAllAnnotationsRaw(fileName);
    final localMap = {for (final a in localRaw) a.id: a};

    if (localMap.isEmpty && remoteMap.isEmpty) return;

    final mergedMap = <String, Annotation>{};
    final allIds = <String>{...localMap.keys, ...remoteMap.keys};
    for (final id in allIds) {
      final local = localMap[id];
      final remote = remoteMap[id];

      if (local == null) {
        // Remote-only -> import into local DB
        mergedMap[id] = remote!;
        await _database.saveAnnotation(remote);
      } else if (remote == null) {
        mergedMap[id] = local;
      } else {
        final ld = DateTime.tryParse(local.updatedAt);
        final rd = DateTime.tryParse(remote.updatedAt);
        if (ld != null && rd != null && rd.isAfter(ld)) {
          mergedMap[id] = remote;
          await _database.saveAnnotation(remote);
        } else {
          mergedMap[id] = local;
        }
      }
    }

    final out = {
      'version': 1,
      'fileName': fileName,
      'lastModified': DateTime.now().toUtc().toIso8601String(),
      'annotations': mergedMap.values.map((a) => a.toMap()).toList(),
    };
    await client.uploadString(
      remotePath,
      const JsonEncoder.withIndent('  ').convert(out),
    );
  }

  void dispose() {
    _progressController.close();
  }
}
