// Dart imports:
import 'dart:async';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/archive_page_fetcher.dart';
import 'package:openlibe_eink_remix/services/logger.dart';

/// Full-screen page showing a mirror's anti-bot check so the user can pass it
/// by hand (the "I'm not a robot" box DDoS-Guard falls back to when it cannot
/// verify the browser silently).
///
/// Pops with the real page's HTML as soon as the check redirects to it; the
/// clearance cookies stay in the shared WebView cookie store, so every later
/// plain request passes. Pops with null if the user backs out.
class ChallengePage extends StatefulWidget {
  final String url;
  final String userAgent;

  const ChallengePage({super.key, required this.url, required this.userAgent});

  @override
  State<ChallengePage> createState() => _ChallengePageState();
}

class _ChallengePageState extends State<ChallengePage> {
  final AppLogger _logger = AppLogger();
  InAppWebViewController? _controller;
  Timer? _poll;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(const Duration(milliseconds: 700), (_) => _probe());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _probe() async {
    final c = _controller;
    if (c == null || _done) return;
    try {
      // Only read a fully loaded document: a snapshot taken while the real
      // page is still streaming in would miss the result list.
      final dynamic ready =
          await c.evaluateJavascript(source: 'document.readyState');
      if (ready != 'complete') return;
      final dynamic html = await c.evaluateJavascript(
          source: 'document.documentElement.outerHTML');
      if (html is String &&
          html.length > 200 &&
          !ArchivePageFetcher.isChallengePage(html)) {
        _done = true;
        _poll?.cancel();
        _logger.info('Interactive challenge passed', tag: 'ChallengePage',
            metadata: {'url': widget.url});
        if (mounted) Navigator.of(context).pop(html);
      }
    } catch (_) {
      // page is navigating; try again on the next tick
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(widget.url)?.host ?? widget.url;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browser check'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Text(
              '$host wants to make sure you are not a robot. '
              'Tick the box below; the app continues by itself once the page loads.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                userAgent: widget.userAgent,
                javaScriptEnabled: true,
                thirdPartyCookiesEnabled: true,
              ),
              onWebViewCreated: (c) => _controller = c,
              onLoadStop: (c, url) async {
                _controller = c;
                await _probe();
              },
            ),
          ),
        ],
      ),
    );
  }
}
