// Dart imports:
import 'dart:io';

// Package imports:
import 'package:crypto/crypto.dart' show md5;
import 'package:epubx/epubx.dart' as epubx;
// The lazy content-file refs are not exported from the package root.
// ignore: implementation_imports
import 'package:epubx/src/ref_entities/epub_byte_content_file_ref.dart';
// ignore: implementation_imports
import 'package:epubx/src/ref_entities/epub_content_file_ref.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/logger.dart';

/// Metadata read from a book file itself (currently epub only).
class BookFileMetadata {
  final String? title;
  final String? author;
  final String? publisher;
  final String? description;
  final String? coverPath;

  BookFileMetadata({
    this.title,
    this.author,
    this.publisher,
    this.description,
    this.coverPath,
  });
}

/// MD5 of a file's content, streamed so large books don't load into memory.
/// Matches Anna's Archive book ids, which are the MD5 of the file.
Future<String> computeFileMd5(String filePath) async {
  final digest = await md5.bind(File(filePath).openRead()).first;
  return digest.toString();
}

/// Directory where covers extracted from book files are stored.
Future<Directory> getCoversDirectory() async {
  final appDir = await getApplicationSupportDirectory();
  final dir = Directory(p.join(appDir.path, 'covers'));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// Human-readable title derived from a file name: strips the extension and
/// turns separator characters back into spaces.
String titleFromFileName(String fileName) {
  var name = fileName;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return name.isEmpty ? fileName : name;
}

/// Reads title/author/publisher/description and the cover image from an epub
/// file. The cover is written to the covers directory as `<coverKey>.<ext>`
/// and its absolute path returned. Returns null for non-epub files or when
/// the file cannot be parsed.
///
/// Uses the lazy [epubx.EpubReader.openBook] so only the OPF schema and the
/// cover image are read — a book with one broken content entry (bad internal
/// href, missing chapter file) still delivers its metadata and cover.
Future<BookFileMetadata?> extractEpubMetadata(String filePath,
    {required String coverKey}) async {
  if (!filePath.toLowerCase().endsWith('.epub')) return null;
  try {
    final bytes = await File(filePath).readAsBytes();
    final book = await epubx.EpubReader.openBook(bytes);

    final metadata = book.Schema?.Package?.Metadata;
    String? metadataTitle;
    for (final t in metadata?.Titles ?? <String>[]) {
      if (t.trim().isNotEmpty) {
        metadataTitle = t;
        break;
      }
    }
    final title = _nonEmpty(book.Title) ?? _nonEmpty(metadataTitle);
    final author = _nonEmpty(book.Author) ??
        _nonEmpty(book.AuthorList?.whereType<String>().join(', '));
    final publisher = _nonEmpty(metadata?.Publishers?.isNotEmpty == true
        ? metadata!.Publishers!.first
        : null);
    final description = _nonEmpty(metadata?.Description);

    String? coverPath;
    final cover = await _readCoverImage(book);
    if (cover != null) {
      final coversDir = await getCoversDirectory();
      final file = File(p.join(coversDir.path, '$coverKey${cover.extension}'));
      await file.writeAsBytes(cover.bytes, flush: true);
      coverPath = file.path;
    }

    return BookFileMetadata(
      title: title,
      author: author,
      publisher: publisher,
      description: description,
      coverPath: coverPath,
    );
  } catch (e) {
    AppLogger().warning('Failed to extract epub metadata from $filePath: $e',
        tag: 'BookMetadata');
    return null;
  }
}

String? _nonEmpty(String? s) {
  final t = s?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

class _CoverImage {
  final List<int> bytes;
  final String extension;
  _CoverImage(this.bytes, this.extension);
}

/// Reads the cover image, trying candidates in priority order: the epub2
/// meta[name=cover] convention, the epub3 cover-image manifest property, a
/// "cover"-named image, then the largest embedded image. Candidates whose
/// content cannot be read are skipped instead of failing the whole book.
Future<_CoverImage?> _readCoverImage(epubx.EpubBookRef book) async {
  final images = book.Content?.Images;
  if (images == null || images.isEmpty) return null;

  Iterable<EpubByteContentFileRef> byHref(String? href) sync* {
    if (href == null || href.isEmpty) return;
    if (images.containsKey(href)) yield images[href]!;
    for (final entry in images.entries) {
      if (entry.key != href &&
          (entry.key.endsWith(href) || href.endsWith(entry.key))) {
        yield entry.value;
      }
    }
  }

  final candidates = <EpubByteContentFileRef>[];
  final manifestItems = book.Schema?.Package?.Manifest?.Items ?? [];

  // epub2: <meta name="cover" content="<manifest item id>"/>
  final metaItems = book.Schema?.Package?.Metadata?.MetaItems ?? [];
  for (final meta in metaItems) {
    if (meta.Name?.toLowerCase() == 'cover' && meta.Content != null) {
      final id = meta.Content!;
      for (final item in manifestItems) {
        if (item.Id == id) candidates.addAll(byHref(item.Href));
      }
      // Some books put the href directly in the content attribute
      candidates.addAll(byHref(id));
    }
  }

  // epub3: manifest item with properties="cover-image"
  for (final item in manifestItems) {
    if (item.Properties?.toLowerCase().contains('cover-image') ?? false) {
      candidates.addAll(byHref(item.Href));
    }
  }

  // An image whose path mentions "cover"
  for (final entry in images.entries) {
    if (entry.key.toLowerCase().contains('cover')) candidates.add(entry.value);
  }

  for (final candidate in candidates) {
    try {
      final bytes = await candidate.readContent();
      if (bytes.isNotEmpty) {
        return _CoverImage(bytes, _imageExtension(candidate));
      }
    } catch (_) {
      // Broken entry — try the next candidate
    }
  }

  // Fall back to the largest readable image — usually the cover in practice
  _CoverImage? largest;
  for (final img in images.values) {
    try {
      final bytes = await img.readContent();
      if (bytes.length > (largest?.bytes.length ?? 0)) {
        largest = _CoverImage(bytes, _imageExtension(img));
      }
    } catch (_) {}
  }
  return largest;
}

String _imageExtension(EpubContentFileRef img) {
  final mime = img.ContentMimeType?.toLowerCase() ?? '';
  if (mime.contains('png')) return '.png';
  if (mime.contains('gif')) return '.gif';
  if (mime.contains('svg')) return '.svg';
  final name = img.FileName?.toLowerCase() ?? '';
  final dot = name.lastIndexOf('.');
  if (dot > 0) return name.substring(dot);
  return '.jpg';
}
