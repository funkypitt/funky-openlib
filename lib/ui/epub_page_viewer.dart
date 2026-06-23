import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:openlibe_eink_remix/services/epub_assets.dart';
import 'package:openlibe_eink_remix/services/database.dart'
    show MyLibraryDb, Annotation;
import 'package:openlibe_eink_remix/state/state.dart'
    show
        getBookPosition,
        epubViewModeProvider,
        epubReaderFontSizeProvider;

/// Available highlight colors (name -> swatch shown in the picker).
const Map<String, Color> kAnnotationColors = {
  'yellow': Color(0xFFFFEB3B),
  'green': Color(0xFFA5D6A7),
  'blue': Color(0xFF90CAF9),
  'pink': Color(0xFFF48FB1),
  'orange': Color(0xFFFFCC80),
};

String _generateAnnotationId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Returns an optimal font size for epub.js based on screen width
/// and device pixel ratio (accounts for high-DPI screens).
int getOptimalFontSize(BuildContext context) {
  final screenWidth = MediaQuery.of(context).size.width;

  // Base size on logical width, bump up for phone-sized screens.
  if (screenWidth <= 360) return 18;
  if (screenWidth <= 420) return 20;
  if (screenWidth <= 480) return 21;
  if (screenWidth <= 600) return 22;
  if (screenWidth <= 800) return 22;
  // Tablets / desktop
  return 20;
}

class _TocEntry {
  final String label;
  final String href;
  _TocEntry({required this.label, required this.href});
}

class EpubPageViewer extends ConsumerStatefulWidget {
  const EpubPageViewer(
      {super.key, required this.filePath, required this.fileName});

  final String filePath;
  final String fileName;

  @override
  ConsumerState<EpubPageViewer> createState() => _EpubPageViewerState();
}

class _EpubPageViewerState extends ConsumerState<EpubPageViewer> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  bool _bookReady = false;
  String? _savedCfi;
  String? _currentCfi; // Updated by onRelocated, used for sync save in deactivate
  List<_TocEntry> _toc = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FocusNode _focusNode = FocusNode();
  late int _currentFontSize;
  bool? _isDark;

  // Annotations (highlights + notes) for this book, loaded once the book is ready.
  List<Annotation> _annotations = [];
  bool _annotationsLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadSavedPosition();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _currentFontSize = _getEffectiveFontSize();

    final nowDark = Theme.of(context).brightness == Brightness.dark;
    if (_isDark != null && _isDark != nowDark && _bookReady) {
      _isDark = nowDark;
      _webViewController?.evaluateJavascript(source: 'setTheme($nowDark)');
    }
    _isDark = nowDark;
  }

  Future<void> _loadSavedPosition() async {
    try {
      final pos = await ref.read(getBookPosition(widget.fileName).future);
      if (pos != null && pos.isNotEmpty) {
        _savedCfi = pos;
        // If the book was already ready before we finished loading, restore now
        if (_bookReady) {
          _restorePositionWhenReady();
        }
      }
    } catch (_) {}
  }

  void _restorePositionWhenReady() {
    if (_savedCfi == null) return;
    final cfi = _savedCfi!;
    Future.delayed(const Duration(milliseconds: 300), () {
      _webViewController?.evaluateJavascript(
          source: 'goToCfi("${cfi.replaceAll('"', '\\"')}")');
    });
  }

  @override
  void deactivate() {
    // Save _currentCfi directly — no async JS call that could race with WebView destruction
    if (_currentCfi != null && _currentCfi!.isNotEmpty) {
      MyLibraryDb.instance.saveBookState(widget.fileName, _currentCfi!);
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _injectBook() async {
    if (_webViewController == null) return;

    final bytes = await File(widget.filePath).readAsBytes();
    final base64Data = base64Encode(bytes);

    // Set theme and font size BEFORE loading the book,
    // so the content hook picks them up from the first render.
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await _webViewController!
        .evaluateJavascript(source: 'setTheme($isDark)');
    await _webViewController!
        .evaluateJavascript(source: 'setFontSize($_currentFontSize)');

    // Load book — theme/font will be injected into each section via hooks.content
    await _webViewController!
        .evaluateJavascript(source: 'loadBook("$base64Data")');
  }

  int _getEffectiveFontSize() {
    final configuredSize = ref.read(epubReaderFontSizeProvider);
    if (configuredSize > 0) return configuredSize;
    return getOptimalFontSize(context);
  }

  void _increaseFontSize() {
    _webViewController?.evaluateJavascript(source: 'changeFontSize(2)');
    setState(() {
      _currentFontSize = (_currentFontSize + 2).clamp(10, 40);
    });
  }

  void _decreaseFontSize() {
    _webViewController?.evaluateJavascript(source: 'changeFontSize(-2)');
    setState(() {
      _currentFontSize = (_currentFontSize - 2).clamp(10, 40);
    });
  }

  void _goNext() {
    _webViewController?.evaluateJavascript(source: 'goNext()');
  }

  void _goPrev() {
    _webViewController?.evaluateJavascript(source: 'goPrev()');
  }

  // ==================================================================
  // ANNOTATIONS
  // ==================================================================

  /// Load saved annotations from the DB and render them in the reader.
  Future<void> _loadAnnotations() async {
    if (_annotationsLoaded) return;
    _annotationsLoaded = true;
    try {
      final annotations =
          await MyLibraryDb.instance.getAnnotations(widget.fileName);
      if (!mounted) return;
      setState(() => _annotations = annotations);
      for (final a in annotations) {
        _renderAnnotation(a);
      }
    } catch (_) {}
  }

  void _renderAnnotation(Annotation a) {
    _webViewController?.evaluateJavascript(
      source:
          'addAnnotation(${jsonEncode(a.id)}, ${jsonEncode(a.cfiRange)}, ${jsonEncode(a.type)}, ${jsonEncode(a.color)})',
    );
  }

  void _unrenderAnnotation(Annotation a) {
    _webViewController?.evaluateJavascript(
      source:
          'removeAnnotation(${jsonEncode(a.cfiRange)}, ${jsonEncode(a.type)})',
    );
  }

  void _clearSelection() {
    _webViewController?.evaluateJavascript(source: 'clearSelection()');
  }

  /// Called from JS when the user selects text. Shows the action menu.
  void _onTextSelected(String cfiRange, String text) {
    final trimmed = text.trim();
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (trimmed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  '"$trimmed"',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontStyle: FontStyle.italic, fontSize: 14),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Highlight',
                  style: Theme.of(ctx).textTheme.labelLarge),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: kAnnotationColors.entries.map((e) {
                  return Padding(
                    padding: const EdgeInsets.all(4),
                    child: InkWell(
                      onTap: () {
                        Navigator.of(ctx).pop();
                        _createHighlight(cfiRange, trimmed, e.key);
                      },
                      child: CircleAvatar(
                          backgroundColor: e.value, radius: 18),
                    ),
                  );
                }).toList(),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.note_add_outlined),
              title: const Text('Add note'),
              onTap: () {
                Navigator.of(ctx).pop();
                _addNoteFlow(cfiRange, trimmed);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () {
                Navigator.of(ctx).pop();
                _clearSelection();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _createHighlight(
      String cfiRange, String text, String color) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final annotation = Annotation(
      id: _generateAnnotationId(),
      fileName: widget.fileName,
      cfiRange: cfiRange,
      type: 'highlight',
      color: color,
      selectedText: text,
      note: null,
      createdAt: now,
      updatedAt: now,
    );
    await MyLibraryDb.instance.saveAnnotation(annotation);
    _renderAnnotation(annotation);
    _clearSelection();
    if (mounted) setState(() => _annotations = [..._annotations, annotation]);
  }

  Future<void> _addNoteFlow(String cfiRange, String text) async {
    final note = await _promptNote();
    if (note == null || note.trim().isEmpty) {
      _clearSelection();
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final annotation = Annotation(
      id: _generateAnnotationId(),
      fileName: widget.fileName,
      cfiRange: cfiRange,
      type: 'note',
      color: 'blue',
      selectedText: text,
      note: note.trim(),
      createdAt: now,
      updatedAt: now,
    );
    await MyLibraryDb.instance.saveAnnotation(annotation);
    _renderAnnotation(annotation);
    _clearSelection();
    if (mounted) setState(() => _annotations = [..._annotations, annotation]);
  }

  Future<String?> _promptNote({String initial = ''}) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'Write a short note…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  /// Called from JS when an existing annotation is tapped.
  Future<void> _onAnnotationTap(String id) async {
    Annotation? a;
    for (final x in _annotations) {
      if (x.id == id) {
        a = x;
        break;
      }
    }
    a ??= await MyLibraryDb.instance.getAnnotation(id);
    if (a == null || !mounted) return;
    _showAnnotationActions(a);
  }

  void _showAnnotationActions(Annotation a) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((a.selectedText ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  '"${a.selectedText}"',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontStyle: FontStyle.italic, fontSize: 14),
                ),
              ),
            if ((a.note ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Text(a.note!, style: const TextStyle(fontSize: 15)),
              ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text((a.note ?? '').isEmpty ? 'Add note' : 'Edit note'),
              onTap: () async {
                Navigator.of(ctx).pop();
                final note = await _promptNote(initial: a.note ?? '');
                if (note != null) {
                  // Keep the visual type (highlight stays a highlight; it can
                  // still carry a note that shows when tapped).
                  await _updateAnnotation(a, note: note.trim());
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('Change color'),
              onTap: () {
                Navigator.of(ctx).pop();
                _showColorPicker(a);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete',
                  style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(ctx).pop();
                _deleteAnnotation(a);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showColorPicker(Annotation a) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: kAnnotationColors.entries.map((e) {
              return InkWell(
                onTap: () {
                  Navigator.of(ctx).pop();
                  _updateAnnotation(a, color: e.key);
                },
                child: CircleAvatar(backgroundColor: e.value, radius: 20),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Future<void> _updateAnnotation(Annotation a,
      {String? note, String? color, String? type}) async {
    // Re-render with new style: remove the old overlay first.
    _unrenderAnnotation(a);
    final updated = a.copyWith(
      note: note,
      color: color,
      type: type,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
    );
    await MyLibraryDb.instance.saveAnnotation(updated);
    _renderAnnotation(updated);
    if (mounted) {
      setState(() {
        _annotations = [
          for (final x in _annotations) if (x.id == a.id) updated else x,
        ];
      });
    }
  }

  Future<void> _deleteAnnotation(Annotation a) async {
    _unrenderAnnotation(a);
    await MyLibraryDb.instance.softDeleteAnnotation(a.id);
    if (mounted) {
      setState(() {
        _annotations = _annotations.where((x) => x.id != a.id).toList();
      });
    }
  }

  void _showAnnotationsList() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, scrollController) {
          if (_annotations.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No highlights or notes yet.'),
              ),
            );
          }
          return ListView.builder(
            controller: scrollController,
            itemCount: _annotations.length,
            itemBuilder: (ctx, index) {
              final a = _annotations[index];
              final swatch = kAnnotationColors[a.color] ?? Colors.yellow;
              return ListTile(
                leading: Icon(
                  a.type == 'note'
                      ? Icons.sticky_note_2
                      : Icons.format_paint,
                  color: swatch,
                ),
                title: Text(
                  (a.selectedText ?? '').isNotEmpty
                      ? a.selectedText!
                      : (a.note ?? ''),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: (a.note ?? '').isNotEmpty
                    ? Text(a.note!,
                        maxLines: 2, overflow: TextOverflow.ellipsis)
                    : null,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _webViewController?.evaluateJavascript(
                      source: 'goToCfi(${jsonEncode(a.cfiRange)})');
                },
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        backgroundColor: isDarkMode
            ? Theme.of(context).colorScheme.surface
            : Theme.of(context).colorScheme.primary,
        title: const Text("OpenLibeExtended-eInk-Remix"),
        titleTextStyle: Theme.of(context).textTheme.displayLarge,
        leading: IconButton(
          icon: Icon(Icons.arrow_back,
              color: Theme.of(context).colorScheme.tertiary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          // Font size decrease
          IconButton(
            icon: Icon(Icons.text_decrease,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Decrease font size',
            onPressed: _decreaseFontSize,
          ),
          // Font size indicator
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Center(
              child: Text(
                '$_currentFontSize',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.tertiary,
                ),
              ),
            ),
          ),
          // Font size increase
          IconButton(
            icon: Icon(Icons.text_increase,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Increase font size',
            onPressed: _increaseFontSize,
          ),
          // Toggle to scroll view
          IconButton(
            icon: Icon(Icons.view_stream,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Switch to scroll view',
            onPressed: () {
              ref.read(epubViewModeProvider.notifier).state = 'scroll';
            },
          ),
          // Annotations (highlights & notes) list
          IconButton(
            icon: Icon(Icons.sticky_note_2_outlined,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Highlights & notes',
            onPressed: _showAnnotationsList,
          ),
          // TOC button
          IconButton(
            icon: Icon(Icons.menu_book,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Table of Contents',
            onPressed: () {
              _scaffoldKey.currentState?.openEndDrawer();
            },
          ),
        ],
      ),
      endDrawer: Drawer(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'Table of Contents',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Divider(),
              Expanded(
                child: _toc.isEmpty
                    ? const Center(child: Text('No table of contents'))
                    : ListView.builder(
                        itemCount: _toc.length,
                        itemBuilder: (context, index) {
                          final entry = _toc[index];
                          return ListTile(
                            title: Text(
                              entry.label,
                              style: const TextStyle(fontSize: 14),
                            ),
                            onTap: () {
                              Navigator.of(context).pop();
                              _webViewController?.evaluateJavascript(
                                  source:
                                      'goToHref("${entry.href.replaceAll('"', '\\"')}")');
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
      body: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
                event.logicalKey == LogicalKeyboardKey.pageDown) {
              _goNext();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
                event.logicalKey == LogicalKeyboardKey.pageUp) {
              _goPrev();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.equal ||
                event.logicalKey == LogicalKeyboardKey.numpadAdd) {
              _increaseFontSize();
              return KeyEventResult.handled;
            }
            if (event.logicalKey == LogicalKeyboardKey.minus ||
                event.logicalKey == LogicalKeyboardKey.numpadSubtract) {
              _decreaseFontSize();
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            FutureBuilder<String>(
              future: EpubAssetsService.getReaderUrl(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return Center(
                    child: CircularProgressIndicator(
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  );
                }
                return InAppWebView(
                    initialUrlRequest:
                        URLRequest(url: WebUri(snapshot.data!)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      allowFileAccessFromFileURLs: true,
                      allowUniversalAccessFromFileURLs: true,
                      useOnLoadResource: false,
                      supportZoom: false,
                      transparentBackground: isDarkMode,
                      hardwareAcceleration: false,
                      useWideViewPort: true,
                    ),
                    onWebViewCreated: (controller) {
                      _webViewController = controller;

                      controller.addJavaScriptHandler(
                        handlerName: 'onRelocated',
                        callback: (args) {
                          if (args.isNotEmpty) {
                            final cfi = args[0]?.toString();
                            if (cfi != null && cfi.isNotEmpty) {
                              _currentCfi = cfi;
                              // Reading progress (0.0–1.0), if available
                              double? progress;
                              if (args.length > 1 && args[1] is num) {
                                progress = (args[1] as num).toDouble();
                              }
                              // Save position (+ progress) to DB on every relocation
                              MyLibraryDb.instance.saveBookState(
                                  widget.fileName, cfi,
                                  progress: progress);
                            }
                          }
                        },
                      );

                      controller.addJavaScriptHandler(
                        handlerName: 'onTextSelected',
                        callback: (args) {
                          if (args.isNotEmpty) {
                            final cfiRange = args[0]?.toString() ?? '';
                            final text =
                                args.length > 1 ? args[1]?.toString() ?? '' : '';
                            if (cfiRange.isNotEmpty) {
                              _onTextSelected(cfiRange, text);
                            }
                          }
                        },
                      );

                      controller.addJavaScriptHandler(
                        handlerName: 'onAnnotationTap',
                        callback: (args) {
                          if (args.isNotEmpty) {
                            final id = args[0]?.toString();
                            if (id != null && id.isNotEmpty) {
                              _onAnnotationTap(id);
                            }
                          }
                        },
                      );

                      controller.addJavaScriptHandler(
                        handlerName: 'onBookReady',
                        callback: (args) {
                          if (args.isNotEmpty) {
                            try {
                              final tocJson =
                                  jsonDecode(args[0]) as List<dynamic>;
                              setState(() {
                                _toc = tocJson
                                    .map((e) => _TocEntry(
                                          label: e['label'] ?? '',
                                          href: e['href'] ?? '',
                                        ))
                                    .toList();
                                _bookReady = true;
                                _isLoading = false;
                              });

                              _restorePositionWhenReady();
                              _loadAnnotations();
                            } catch (_) {
                              setState(() {
                                _bookReady = true;
                                _isLoading = false;
                              });
                              _loadAnnotations();
                            }
                          }
                        },
                      );

                      controller.addJavaScriptHandler(
                        handlerName: 'onLocationsReady',
                        callback: (args) {},
                      );
                    },
                    onLoadStop: (controller, url) async {
                      await _injectBook();
                    },
                  );
              },
            ),
            if (_isLoading)
              Container(
                color: isDarkMode ? const Color(0xFF121212) : Colors.white,
                child: Center(
                  child: CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.secondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
