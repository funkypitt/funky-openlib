// Dart imports:
import 'dart:convert';
import 'dart:io';

// Package imports:
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/files.dart';

class MyBook {
  final String id;
  final String title;
  final String? author;
  final String? thumbnail;
  final String link;
  final String? publisher;
  final String? info;
  final String? description;
  final String? format;
  final String? fileName;

  MyBook(
      {required this.id,
      required this.title,
      required this.author,
      required this.thumbnail,
      required this.link,
      required this.publisher,
      required this.info,
      required this.format,
      required this.description,
      this.fileName});

  // Getter for compatibility with BookInfoWidget which expects 'md5'
  String get md5 => id;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'author': author,
      'thumbnail': thumbnail,
      'link': link,
      'publisher': publisher,
      'info': info,
      'format': format,
      'description': description,
      'fileName': fileName
    };
  }

  @override
  String toString() {
    return 'MyBook{id: $id,title: $title,author: $author,thumbnail: $thumbnail,link: $link,publisher: $publisher,info: $info,format: $format,description:$description,fileName:$fileName}';
  }

  // Get actual filename - uses fileName if available, otherwise falls back to id.format
  String getFileName() {
    if (fileName != null && fileName!.isNotEmpty) {
      return fileName!;
    }
    return "$id.$format";
  }
}

/// A reader annotation: either a highlight over a passage or a short note
/// anchored at a word/passage. Anchored via an epubcfi range string.
class Annotation {
  final String id;
  final String fileName;
  final String cfiRange;
  final String type; // 'highlight' | 'note'
  final String color;
  final String? selectedText;
  final String? note;
  final String createdAt;
  final String updatedAt;
  final bool deleted;

  Annotation({
    required this.id,
    required this.fileName,
    required this.cfiRange,
    required this.type,
    required this.color,
    this.selectedText,
    this.note,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'fileName': fileName,
        'cfiRange': cfiRange,
        'type': type,
        'color': color,
        'selectedText': selectedText,
        'note': note,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'deleted': deleted ? 1 : 0,
      };

  factory Annotation.fromMap(Map<String, dynamic> m) => Annotation(
        id: m['id'] as String,
        fileName: m['fileName'] as String,
        cfiRange: m['cfiRange'] as String,
        type: (m['type'] as String?) ?? 'highlight',
        color: (m['color'] as String?) ?? 'yellow',
        selectedText: m['selectedText'] as String?,
        note: m['note'] as String?,
        createdAt: (m['createdAt'] as String?) ?? '',
        updatedAt: (m['updatedAt'] as String?) ?? '',
        deleted: (m['deleted'] is bool)
            ? m['deleted'] as bool
            : ((m['deleted'] as int?) ?? 0) == 1,
      );

  Annotation copyWith({
    String? cfiRange,
    String? type,
    String? color,
    String? selectedText,
    String? note,
    String? updatedAt,
    bool? deleted,
  }) =>
      Annotation(
        id: id,
        fileName: fileName,
        cfiRange: cfiRange ?? this.cfiRange,
        type: type ?? this.type,
        color: color ?? this.color,
        selectedText: selectedText ?? this.selectedText,
        note: note ?? this.note,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        deleted: deleted ?? this.deleted,
      );
}

class MyLibraryDb {
  static final MyLibraryDb instance = MyLibraryDb._internal();
  static Database? _database;
  MyLibraryDb._internal();

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String databasePath;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final directory = await getApplicationSupportDirectory();
      databasePath = directory.path;
      try {
        await Directory(databasePath).create(recursive: true);
      } catch (_) {}
    } else {
      databasePath = await getDatabasesPath();
    }
    final path = join(databasePath, 'mylibrary.db');

    return await openDatabase(
      path,
      version: 7,
      onCreate: (Database db, int version) async {
        await db.execute(
            'CREATE TABLE mybooks (id TEXT PRIMARY KEY, title TEXT,author TEXT,thumbnail TEXT,link TEXT,publisher TEXT,info TEXT,format TEXT,description TEXT,fileName TEXT)');
        await db.execute(
            'CREATE TABLE preferences (name TEXT PRIMARY KEY,value TEXT)');
        // Create these tables for all platforms (both mobile and desktop)
        await db.execute(
            'CREATE TABLE bookposition (fileName TEXT PRIMARY KEY,position TEXT,progress REAL)');
        await db.execute(
            'CREATE TABLE browserOptions (name TEXT PRIMARY KEY,value TEXT)');
        await db.execute(_createAnnotationsTableSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        List<dynamic> isTableExist = await db.query('sqlite_master',
            where: 'name = ?', whereArgs: ['bookposition']);
        List<dynamic> isPreferenceTableExist = await db.query('sqlite_master',
            where: 'name = ?', whereArgs: ['preferences']);
        List<dynamic> isbrowserOptionsExist = await db.query('sqlite_master',
            where: 'name = ?', whereArgs: ['browserOptions']);
        if (isPreferenceTableExist.isEmpty) {
          await db.execute(
              'CREATE TABLE preferences (name TEXT PRIMARY KEY,value TEXT)');
        }
        // Create bookposition table on all platforms if not exists
        if (isTableExist.isEmpty) {
          await db.execute(
              'CREATE TABLE bookposition (fileName TEXT PRIMARY KEY,position TEXT)');
        }
        // Create browserOptions table on all platforms if not exists
        if (isbrowserOptionsExist.isEmpty) {
          await db.execute(
              'CREATE TABLE browserOptions (name TEXT PRIMARY KEY,value TEXT)');
        }
        // Add fileName column if upgrading from version < 6
        if (oldVersion < 6) {
          try {
            await db.execute('ALTER TABLE mybooks ADD COLUMN fileName TEXT');
          } catch (_) {
            // Column might already exist
          }
        }
        // v7: reading progress percentage + annotations (notes/highlights)
        if (oldVersion < 7) {
          try {
            await db.execute(
                'ALTER TABLE bookposition ADD COLUMN progress REAL');
          } catch (_) {
            // Column might already exist
          }
          final annotationsExist = await db.query('sqlite_master',
              where: 'name = ?', whereArgs: ['annotations']);
          if (annotationsExist.isEmpty) {
            await db.execute(_createAnnotationsTableSql);
          }
        }
      },
      onOpen: (db) async {
        final bookStorageDefaultDirectory =
            await getBookStorageDefaultDirectory;
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('darkMode', 0)");
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('themeMode', 'system')");
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('openPdfwithExternalApp', 0)");
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('openEpubwithExternalApp', 0)");
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('bookStorageDirectory', '$bookStorageDefaultDirectory')");
        await db.execute(
            "INSERT OR IGNORE INTO preferences (name, value) VALUES ('showManualDownloadButton', 0)");
      },
    );
  }

  // Database dbInstance;
  String tableName = 'mybooks';

  static const String _createAnnotationsTableSql =
      'CREATE TABLE annotations (id TEXT PRIMARY KEY, fileName TEXT, cfiRange TEXT, '
      'type TEXT, color TEXT, selectedText TEXT, note TEXT, createdAt TEXT, '
      'updatedAt TEXT, deleted INTEGER DEFAULT 0)';

  Future<void> insert(MyBook book) async {
    final dbInstance = await instance.database;
    await dbInstance.insert(
      tableName,
      book.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> delete(String id) async {
    final dbInstance = await instance.database;
    await dbInstance.delete(
      tableName,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<MyBook?> getId(String id) async {
    final dbInstance = await instance.database;
    List<Map<String, dynamic>> data =
        await dbInstance.query(tableName, where: 'id = ?', whereArgs: [id]);
    List<MyBook> book = listMapToMyBook(data);
    if (book.isNotEmpty) {
      return book.first;
    }
    return null;
  }

  Future<bool> checkIdExists(String id) async {
    final dbInstance = await instance.database;
    List<Map<String, dynamic>> data =
        await dbInstance.query(tableName, where: 'id = ?', whereArgs: [id]);
    List<MyBook> book = listMapToMyBook(data);
    if (book.isNotEmpty) {
      return true;
    }
    return false;
  }

  Future<List<MyBook>> getAll() async {
    final dbInstance = await instance.database;
    final List<Map<String, dynamic>> maps = await dbInstance.query(tableName);
    return listMapToMyBook(maps);
  }

  List<MyBook> listMapToMyBook(List<Map<String, dynamic>> maps) {
    List<MyBook> myBookList = List.generate(maps.length, (i) {
      return MyBook(
          id: maps[i]['id'],
          title: maps[i]['title'],
          author: maps[i]['author'],
          thumbnail: maps[i]['thumbnail'],
          link: maps[i]['link'],
          publisher: maps[i]['publisher'],
          info: maps[i]['info'],
          format: maps[i]['format'],
          description: maps[i]['description'],
          fileName: maps[i]['fileName']);
    });
    return myBookList.reversed.toList();
  }

  Future<void> saveBookState(String fileName, String position,
      {double? progress}) async {
    final dbInstance = await instance.database;
    final row = <String, dynamic>{'fileName': fileName, 'position': position};
    if (progress != null) {
      row['progress'] = progress;
    }
    await dbInstance.insert(
      'bookposition',
      row,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _updatePositionTimestamp(fileName);
  }

  /// Reading progress (0.0–1.0) for a book, or null if unknown.
  Future<double?> getBookProgress(String fileName) async {
    final dbInstance = await instance.database;
    final data = await dbInstance.query('bookposition',
        columns: ['progress'],
        where: 'fileName = ?',
        whereArgs: [fileName]);
    if (data.isNotEmpty) {
      final v = data.first['progress'];
      if (v is num) return v.toDouble();
    }
    return null;
  }

  Future<Map<String, double>> getAllBookProgress() async {
    final dbInstance = await instance.database;
    final data = await dbInstance.query('bookposition');
    final result = <String, double>{};
    for (final row in data) {
      final v = row['progress'];
      if (v is num) {
        result[row['fileName'] as String] = v.toDouble();
      }
    }
    return result;
  }

  Future<void> _updatePositionTimestamp(String fileName) async {
    try {
      Map<String, String> timestamps = {};
      try {
        final json = await getPreference('syncPositionTimestamps') as String;
        final map = jsonDecode(json) as Map<String, dynamic>;
        timestamps = map.map((k, v) => MapEntry(k, v as String));
      } catch (_) {}
      timestamps[fileName] = DateTime.now().toUtc().toIso8601String();
      await savePreference('syncPositionTimestamps', jsonEncode(timestamps));
    } catch (_) {}
  }

  Future<void> deleteBookState(String fileName) async {
    final dbInstance = await instance.database;
    await dbInstance.delete(
      'bookposition',
      where: 'fileName = ?',
      whereArgs: [fileName],
    );
  }

  Future<String?> getBookState(String fileName) async {
    final dbInstance = await instance.database;
    List<Map<String, dynamic>> data = await dbInstance
        .query('bookposition', where: 'fileName = ?', whereArgs: [fileName]);
    List<dynamic> dataList = List.generate(data.length, (i) {
      return {'fileName': data[i]['fileName'], 'position': data[i]['position']};
    });
    if (dataList.isNotEmpty) {
      return dataList[0]['position'];
    } else {
      return null;
    }
  }

  Future<void> savePreference(String name, dynamic value) async {
    switch (value) {
      case bool _:
        value = value ? 1 : 0;
        break;
      case int _ || String _:
        break;
      default:
        throw 'Invalid type';
    }
    Database dbInstance = await instance.database;
    await dbInstance.insert(
      'preferences',
      {'name': name, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<dynamic> getPreference(String name) async {
    Database dbInstance = await instance.database;
    List<Map<String, dynamic>> data = await dbInstance
        .query('preferences', where: 'name = ?', whereArgs: [name]);
    List<dynamic> dataList = List.generate(data.length, (i) {
      return {'name': data[i]['name'], 'value': data[i]['value']};
    });
    if (dataList.isNotEmpty) {
      // Convert to int if possible
      int? preference = int.tryParse(dataList[0]['value']);
      if (preference != null) {
        return preference;
      }
      // Return string value if not int
      return dataList[0]['value'];
    }
    throw "Preference $name not found";
  }

  Future<void> setBrowserOptions(String name, String value) async {
    final dbInstance = await instance.database;
    await dbInstance.insert(
      'browserOptions',
      {'name': name, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> getBrowserOptions(String name) async {
    final dbInstance = await instance.database;
    List<Map<String, dynamic>> data = await dbInstance
        .query('browserOptions', where: 'name = ?', whereArgs: [name]);
    List<dynamic> dataList = List.generate(data.length, (i) {
      return {'name': data[i]['name'], 'value': data[i]['value']};
    });
    if (dataList.isNotEmpty) {
      return dataList[0]['value'];
    } else {
      return "";
    }
  }

  Future<List<Map<String, dynamic>>> getAllBookPositions() async {
    final dbInstance = await instance.database;
    final data = await dbInstance.query('bookposition');
    return data
        .map((row) => {
              'fileName': row['fileName'] as String,
              'position': row['position'] as String,
              if (row['progress'] is num)
                'progress': (row['progress'] as num).toDouble(),
            })
        .toList();
  }

  Future<void> importBookPositions(
      List<Map<String, dynamic>> positions) async {
    final dbInstance = await instance.database;
    for (final pos in positions) {
      final row = <String, dynamic>{
        'fileName': pos['fileName'] as String,
        'position': pos['position'] as String,
      };
      if (pos['progress'] is num) {
        row['progress'] = (pos['progress'] as num).toDouble();
      }
      await dbInstance.insert(
        'bookposition',
        row,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  // ==================================================================
  // ANNOTATIONS (notes & highlights)
  // ==================================================================

  /// Insert or update an annotation (upsert by id).
  Future<void> saveAnnotation(Annotation annotation) async {
    final dbInstance = await instance.database;
    await dbInstance.insert(
      'annotations',
      annotation.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Soft-delete an annotation (tombstone) so the deletion propagates on sync.
  Future<void> softDeleteAnnotation(String id) async {
    final dbInstance = await instance.database;
    await dbInstance.update(
      'annotations',
      {
        'deleted': 1,
        'note': null,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Active (non-deleted) annotations for a book, oldest first.
  Future<List<Annotation>> getAnnotations(String fileName) async {
    final dbInstance = await instance.database;
    final data = await dbInstance.query(
      'annotations',
      where: 'fileName = ? AND deleted = 0',
      whereArgs: [fileName],
      orderBy: 'createdAt ASC',
    );
    return data.map((m) => Annotation.fromMap(m)).toList();
  }

  /// Single annotation by id (may be a tombstone).
  Future<Annotation?> getAnnotation(String id) async {
    final dbInstance = await instance.database;
    final data = await dbInstance
        .query('annotations', where: 'id = ?', whereArgs: [id]);
    if (data.isNotEmpty) return Annotation.fromMap(data.first);
    return null;
  }

  /// All annotations for a book including tombstones — used by sync merge.
  Future<List<Annotation>> getAllAnnotationsRaw(String fileName) async {
    final dbInstance = await instance.database;
    final data = await dbInstance
        .query('annotations', where: 'fileName = ?', whereArgs: [fileName]);
    return data.map((m) => Annotation.fromMap(m)).toList();
  }

  /// Distinct book fileNames that have at least one annotation row.
  Future<List<String>> getBookFileNamesWithAnnotations() async {
    final dbInstance = await instance.database;
    final data = await dbInstance.rawQuery(
        'SELECT DISTINCT fileName FROM annotations');
    return data.map((r) => r['fileName'] as String).toList();
  }
}
