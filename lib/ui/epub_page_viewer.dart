import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:openlibe_eink_remix/services/epub_assets.dart';
import 'package:openlibe_eink_remix/state/state.dart'
    show
        saveEpubState,
        getBookPosition,
        epubViewModeProvider,
        epubReaderFontSizeProvider;

/// Returns an optimal font size for epub.js based on screen width.
int getOptimalFontSize(double screenWidth) {
  if (screenWidth <= 360) return 16;
  if (screenWidth <= 480) return 17;
  if (screenWidth <= 600) return 18;
  if (screenWidth <= 800) return 20;
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
  List<_TocEntry> _toc = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _loadSavedPosition();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  Future<void> _loadSavedPosition() async {
    try {
      final pos =
          await ref.read(getBookPosition(widget.fileName).future);
      if (pos != null && pos.isNotEmpty) {
        _savedCfi = pos;
      }
    } catch (_) {}
  }

  @override
  void deactivate() {
    _savePosition();
    super.deactivate();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _savePosition() async {
    if (_webViewController == null || !_bookReady) return;
    try {
      final result = await _webViewController!
          .evaluateJavascript(source: 'getCurrentCfi()');
      if (result != null && result.toString().isNotEmpty) {
        saveEpubState(widget.fileName, result.toString(), ref);
      }
    } catch (_) {}
  }

  Future<void> _injectBook() async {
    if (_webViewController == null) return;

    final bytes = await File(widget.filePath).readAsBytes();
    final base64Data = base64Encode(bytes);

    // Set theme
    final isDark = Theme.of(context).brightness == Brightness.dark;
    await _webViewController!
        .evaluateJavascript(source: 'setTheme($isDark)');

    // Set font size
    final fontSize = _getEffectiveFontSize();
    await _webViewController!
        .evaluateJavascript(source: 'setFontSize($fontSize)');

    // Load book
    await _webViewController!
        .evaluateJavascript(source: 'loadBook("$base64Data")');
  }

  int _getEffectiveFontSize() {
    final configuredSize = ref.read(epubReaderFontSizeProvider);
    if (configuredSize > 0) return configuredSize;
    final screenWidth = MediaQuery.of(context).size.width;
    return getOptimalFontSize(screenWidth);
  }

  void _goNext() {
    _webViewController?.evaluateJavascript(source: 'goNext()');
  }

  void _goPrev() {
    _webViewController?.evaluateJavascript(source: 'goPrev()');
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
          // Toggle to scroll view
          IconButton(
            icon: Icon(Icons.view_stream,
                color: Theme.of(context).colorScheme.tertiary),
            tooltip: 'Switch to scroll view',
            onPressed: () {
              ref.read(epubViewModeProvider.notifier).state = 'scroll';
            },
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
                    ),
                    onWebViewCreated: (controller) {
                      _webViewController = controller;

                      controller.addJavaScriptHandler(
                        handlerName: 'onRelocated',
                        callback: (args) {
                          // args[0] = cfi, args[1] = progress
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

                              // Restore position after book is ready
                              if (_savedCfi != null) {
                                Future.delayed(
                                    const Duration(milliseconds: 300), () {
                                  _webViewController?.evaluateJavascript(
                                      source:
                                          'goToCfi("${_savedCfi!.replaceAll('"', '\\"')}")');
                                });
                              }
                            } catch (_) {
                              setState(() {
                                _bookReady = true;
                                _isLoading = false;
                              });
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
                color: isDarkMode
                    ? const Color(0xFF121212)
                    : Colors.white,
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
