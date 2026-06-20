// Dart imports:
import 'dart:async';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/logger.dart';
import 'package:openlibe_eink_remix/services/platform_utils.dart';

/// Service to fetch mirror links in the background without showing UI
class MirrorFetcherService {
  static final MirrorFetcherService _instance = MirrorFetcherService._internal();
  factory MirrorFetcherService() => _instance;
  MirrorFetcherService._internal();

  final AppLogger _logger = AppLogger();
  String _cookie = "";

  /// Set the authentication cookie for mirror fetching WebViews
  void setCookie(String cookie) {
    _cookie = cookie;
  }

  /// Pre-load cookies into the InAppWebView CookieManager for a given URL
  Future<void> _preloadCookies(String url) async {
    if (_cookie.isEmpty) return;
    try {
      final uri = Uri.parse(url);
      final domain = uri.host;
      final cookiePairs = _cookie.split('; ');
      for (final pair in cookiePairs) {
        final idx = pair.indexOf('=');
        if (idx > 0) {
          await CookieManager.instance().setCookie(
            url: WebUri('https://$domain'),
            name: pair.substring(0, idx),
            value: pair.substring(idx + 1),
            domain: domain,
          );
        }
      }
    } catch (e) {
      _logger.error('Failed to pre-load cookies for mirror fetch',
          tag: 'MirrorFetcher', error: e);
    }
  }

  /// Fetch mirror links from the given URL in the background.
  ///
  /// Returns a list of mirror download links. The slow_download flow is
  /// resilient to Anna's Archive's "Please wait" interstitial / countdown:
  /// instead of reading the page only once on load, it polls for the download
  /// link to appear and retries a second time if the first attempt comes back
  /// empty.
  Future<List<String>> fetchMirrors(String url) async {
    _logger.info('Starting background mirror fetch', tag: 'MirrorFetcher', metadata: {'url': url});

    // On Linux, WebView is not supported - return empty to trigger manual download flow
    if (PlatformUtils.isLinux) {
      _logger.warning('WebView not supported on Linux, returning empty mirrors', tag: 'MirrorFetcher');
      return [];
    }

    final bool isSlowDownload = url.contains('slow_download');

    // slow_download pages gate the link behind a countdown, so give them more
    // time and a second attempt; mirror/IPFS pages render immediately.
    final int maxAttempts = isSlowDownload ? 2 : 1;
    final Duration perAttemptTimeout =
        isSlowDownload ? const Duration(seconds: 35) : const Duration(seconds: 20);

    // Pre-load cookies once before spinning up the webview(s)
    await _preloadCookies(url);

    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      final links =
          await _attemptFetch(url, isSlowDownload, perAttemptTimeout, attempt);
      if (links.isNotEmpty) {
        _logger.info('Mirror fetch succeeded', tag: 'MirrorFetcher',
            metadata: {'attempt': attempt, 'count': links.length});
        return links;
      }
      _logger.warning('Mirror fetch attempt returned no links',
          tag: 'MirrorFetcher', metadata: {'attempt': attempt, 'maxAttempts': maxAttempts});
    }

    return [];
  }

  /// Run a single headless-webview attempt to extract download links.
  Future<List<String>> _attemptFetch(
    String url,
    bool isSlowDownload,
    Duration timeout,
    int attempt,
  ) async {
    final Completer<List<String>> completer = Completer<List<String>>();
    Timer? pollTimer;
    HeadlessInAppWebView? headlessWebView;

    void finish(List<String> links) {
      pollTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(links);
      }
    }

    try {
      headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        onLoadStop: (controller, loadedUrl) async {
          if (loadedUrl == null) {
            _logger.warning('URL is null in onLoadStop', tag: 'MirrorFetcher');
            return;
          }

          _logger.debug('Page loaded', tag: 'MirrorFetcher',
              metadata: {'url': loadedUrl.toString(), 'attempt': attempt});

          // Try immediately in case the link is already present.
          final links = await _extractLinks(controller, isSlowDownload);
          if (links.isNotEmpty) {
            finish(links);
            return;
          }

          // Otherwise poll: the slow_download countdown reveals the link a few
          // seconds after load, without necessarily triggering a navigation.
          pollTimer ??= Timer.periodic(const Duration(seconds: 2), (timer) async {
            if (completer.isCompleted) {
              timer.cancel();
              return;
            }
            final polled = await _extractLinks(controller, isSlowDownload);
            if (polled.isNotEmpty) {
              _logger.info('Extracted link via polling', tag: 'MirrorFetcher',
                  metadata: {'count': polled.length, 'attempt': attempt});
              finish(polled);
            }
          });
        },
        onReceivedError: (controller, request, error) {
          // Only fail fast on main-frame errors. Sub-resource errors (ads,
          // trackers, blocked third parties) are common on these pages and
          // must not abort the fetch - let polling / timeout govern instead.
          final bool isMainFrame = request.isForMainFrame ?? true;
          if (isMainFrame) {
            _logger.error('WebView main-frame error', tag: 'MirrorFetcher',
                error: error.description);
            finish([]);
          } else {
            _logger.debug('WebView sub-resource error (ignored)',
                tag: 'MirrorFetcher', metadata: {'desc': error.description});
          }
        },
      );

      await headlessWebView.run();
      _logger.debug('Headless webview started', tag: 'MirrorFetcher', metadata: {'attempt': attempt});

      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          _logger.warning('Mirror fetch timed out', tag: 'MirrorFetcher',
              metadata: {'seconds': timeout.inSeconds, 'attempt': attempt});
          return <String>[];
        },
      );

      return result;
    } catch (e, stackTrace) {
      _logger.error('Mirror fetch attempt failed', tag: 'MirrorFetcher',
          error: e, stackTrace: stackTrace);
      return [];
    } finally {
      pollTimer?.cancel();
      try {
        await headlessWebView?.dispose();
      } catch (_) {
        // ignore dispose errors
      }
      _logger.debug('Headless webview disposed', tag: 'MirrorFetcher', metadata: {'attempt': attempt});
    }
  }

  /// Extract download links from the currently loaded page.
  ///
  /// Returns an empty list (never throws) so callers can safely poll/retry.
  Future<List<String>> _extractLinks(
    InAppWebViewController controller,
    bool isSlowDownload,
  ) async {
    try {
      if (isSlowDownload) {
        // Robust against markup tweaks: match the bold paragraph link by class
        // tokens (order-independent), then fall back to any "Download now"
        // anchor. Wrapped in try/catch in-page so it returns '' instead of
        // throwing when the link is not present yet (countdown still running).
        const String query = r'''
(function () {
  try {
    var link = document.querySelector('p.mb-4.text-xl.font-bold a')
      || document.querySelector('p[class*="font-bold"] a');
    if (link && link.href) return link.href;
    var anchors = Array.prototype.slice.call(document.querySelectorAll('a'));
    var dl = anchors.find(function (a) {
      return /download now/i.test((a.textContent || ''));
    });
    if (dl && dl.href) return dl.href;
    return '';
  } catch (e) {
    return '';
  }
})();''';
        final result = await controller.evaluateJavascript(source: query);
        if (result is String && result.isNotEmpty) {
          return [result];
        }
        return [];
      } else {
        // For mirror pages, extract all IPFS/mirror links.
        const String query = r'''
(function () {
  try {
    var tags = document.querySelectorAll('ul>li>a');
    var links = [];
    tags.forEach(function (e) { if (e.href) links.push(e.href); });
    return links;
  } catch (e) {
    return [];
  }
})();''';
        final result = await controller.evaluateJavascript(source: query);
        if (result is List) {
          return result.whereType<String>().toList();
        }
        return [];
      }
    } catch (e) {
      _logger.debug('Link extraction failed (will retry/poll)',
          tag: 'MirrorFetcher', metadata: {'error': e.toString()});
      return [];
    }
  }
}
