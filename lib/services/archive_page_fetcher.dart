// Dart imports:
import 'dart:async';

// Package imports:
import 'package:dio/dio.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

// Project imports:
import 'package:openlibe_eink_remix/services/logger.dart';
import 'package:openlibe_eink_remix/services/network_error.dart';
import 'package:openlibe_eink_remix/services/platform_utils.dart';

/// A page (HTML or JSON text) fetched from an Anna's Archive instance.
class FetchedPage {
  final String body;
  final String finalUrl;

  /// True when the body came out of the headless WebView (the plain HTTP
  /// request was challenged), false when plain HTTP returned it.
  final bool viaWebView;

  const FetchedPage(this.body, this.finalUrl, {required this.viaWebView});
}

/// Fetches Anna's Archive pages through the anti-bot layer in front of it.
///
/// Since 2026 the archive sits behind DDoS-Guard: the first request to a host
/// gets redirected to `?check=1` and answered with a 403 JavaScript challenge
/// ("Checking your browser before accessing…"). Only a real browser engine
/// can solve it, after which the clearance lives in a handful of `__ddg*`
/// cookies tied to the User-Agent.
///
/// Strategy:
///  1. Plain HTTP (Dio) with the WebView's own User-Agent and whatever
///     cookies the WebView cookie store already holds for that host. Fast
///     path once the clearance exists.
///  2. If the answer is a challenge page, load the URL in a headless
///     [HeadlessInAppWebView], wait for the challenge to redirect to the real
///     page, and return that page's HTML. The clearance cookies are now in the
///     shared cookie store, so the next plain request passes.
///
/// One WebView solve runs at a time; concurrent callers queue behind it.
class ArchivePageFetcher {
  static final ArchivePageFetcher _instance = ArchivePageFetcher._internal();
  factory ArchivePageFetcher() => _instance;
  ArchivePageFetcher._internal();

  static const String fallbackUserAgent =
      "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36";

  /// How long a headless solve may take. The DDoS-Guard check itself takes
  /// 3–8 s; slow networks and the redirect add a little.
  static const Duration solveTimeout = Duration(seconds: 40);
  static const Duration pollInterval = Duration(milliseconds: 700);

  final AppLogger _logger = AppLogger();
  final Dio dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 15),
  ));
  String? _userAgent;
  String _loginCookie = '';
  Future<void> _solveQueue = Future.value();
  String? _lastHeadlessHtml;

  /// Hosts whose browser check has been passed in this session. Callers use
  /// it to keep talking to a cleared mirror instead of rotating to one that
  /// would ask the user again.
  final Set<String> clearedHosts = {};

  /// After the user closes the browser-check page, stay quiet for a while
  /// instead of popping it up again for every queued request.
  DateTime? _userDeclinedUntil;
  static const Duration declineBackoff = Duration(seconds: 60);

  bool get userRecentlyDeclined =>
      _userDeclinedUntil != null && DateTime.now().isBefore(_userDeclinedUntil!);

  /// Set by the app: shows the challenge page to the user (visible WebView)
  /// and completes with the real page's HTML, or null if dismissed. Used when
  /// the silent headless attempt ends on a manual "I'm not a robot" check.
  Future<String?> Function(String url, String userAgent)? interactiveSolver;

  /// Cookie string captured at login (account session). Merged into every
  /// request; fresh values from the WebView cookie store take precedence.
  void setLoginCookie(String cookie) {
    _loginCookie = cookie;
  }

  /// The User-Agent used for plain HTTP. It must match the WebView's UA,
  /// because the DDoS-Guard clearance is bound to it.
  Future<String> userAgent() async {
    if (_userAgent != null) return _userAgent!;
    if (PlatformUtils.isWebViewSupported) {
      try {
        final ua = await InAppWebViewController.getDefaultUserAgent();
        if (ua.isNotEmpty) _userAgent = ua;
      } catch (e) {
        _logger.debug('Default WebView UA unavailable, using fallback',
            tag: 'PageFetcher', metadata: {'error': e.toString()});
      }
    }
    _userAgent ??= fallbackUserAgent;
    return _userAgent!;
  }

  /// Cookies minted by the anti-bot layer. They are short-lived and bound to
  /// the network address, so they must never be persisted with the account
  /// session or re-injected later: a stale one only triggers a new challenge.
  static bool isAntiBotCookie(String name) {
    return name.startsWith('__ddg') ||
        name == 'aa_ddg_check' ||
        name == 'ddg_last_challenge' ||
        name.startsWith('cf_clearance') ||
        name.startsWith('__cf');
  }

  /// DDoS-Guard's own "429 Too Many Requests" page. Solving a challenge does
  /// not help here; only waiting (or another network) does.
  static bool isRateLimitPage(String? body, {int? statusCode}) {
    if (statusCode == 429) return true;
    if (body == null) return false;
    final lower = body.toLowerCase();
    return lower.contains('429 too many requests') &&
        lower.contains('ddos-guard');
  }

  /// Whether the interstitial gave up on silent verification and now asks for
  /// a manual "I'm not a robot" tick. No point waiting any longer headless.
  static bool needsManualCheck(String? body) {
    if (body == null) return false;
    final lower = body.toLowerCase();
    return lower.contains('could not verify your browser') ||
        lower.contains('manual check') ||
        lower.contains('not a robot') ||
        lower.contains('ddg-captcha') ||
        lower.contains('captcha');
  }

  /// Whether [body] is an anti-bot interstitial rather than a real page.
  static bool isChallengePage(String? body, {int? statusCode}) {
    if (body == null) return statusCode == 403;
    final lower = body.toLowerCase();
    if (lower.contains('/.well-known/ddos-guard/')) return true;
    if (lower.contains('<title>ddos-guard</title>')) return true;
    if (lower.contains('checking your browser before accessing')) return true;
    if (lower.contains('cf-browser-verification')) return true;
    if (lower.contains('<title>just a moment...</title>')) return true;
    if (statusCode == 403 && lower.contains('ddos-guard')) return true;
    return false;
  }

  /// Merge the login cookie with the WebView cookie store for [url].
  Future<String> cookieHeaderFor(String url) async {
    final Map<String, String> jar = {};
    for (final pair in _loginCookie.split(';')) {
      final idx = pair.indexOf('=');
      if (idx > 0) {
        jar[pair.substring(0, idx).trim()] = pair.substring(idx + 1).trim();
      }
    }
    if (PlatformUtils.isWebViewSupported) {
      try {
        final cookies =
            await CookieManager.instance().getCookies(url: WebUri(url));
        for (final c in cookies) {
          jar[c.name] = c.value.toString();
        }
      } catch (e) {
        _logger.debug('Cookie store read failed',
            tag: 'PageFetcher', metadata: {'error': e.toString()});
      }
    }
    return jar.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<Map<String, String>> headersFor(String url) async {
    final headers = <String, String>{
      'user-agent': await userAgent(),
      'accept':
          'text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8',
    };
    final cookie = await cookieHeaderFor(url);
    if (cookie.isNotEmpty) headers['cookie'] = cookie;
    return headers;
  }

  /// Fetch [url]. Returns the page body, solving the anti-bot challenge in a
  /// headless WebView when plain HTTP is refused.
  ///
  /// Throws [DioException] for transport errors and non-challenge HTTP
  /// errors (so callers can move on to the next mirror), and
  /// [NetworkError] of type `cloudflareBlock` when the challenge could not be
  /// solved.
  Future<FetchedPage> fetch(String url) async {
    final headers = await headersFor(url);
    final response = await dio.get<String>(
      url,
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        followRedirects: true,
        maxRedirects: 8,
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    final String body = response.data ?? '';
    final int status = response.statusCode ?? 0;
    final String finalUrl =
        response.realUri.toString().isNotEmpty ? response.realUri.toString() : url;

    if (status >= 200 && status < 300 && !isChallengePage(body)) {
      clearedHosts.add(Uri.parse(url).host);
      return FetchedPage(body, finalUrl, viaWebView: false);
    }

    if (isRateLimitPage(body, statusCode: status)) {
      throw NetworkError(
        type: NetworkErrorType.rateLimited,
        userMessage: 'This mirror is rate-limiting your connection',
        solution:
            "The mirror's protection saw too many requests from your network address.\n\n🔧 Solutions to try:\n• Wait a few minutes before retrying\n• Switch network (Wi-Fi ↔ mobile data)\n• Try a different mirror in Settings → Instances",
        technicalDetails: 'HTTP $status from $url',
      );
    }

    if (!isChallengePage(body, statusCode: status)) {
      // A genuine HTTP error (404 …): let the caller try another mirror.
      throw DioException.badResponse(
          statusCode: status, requestOptions: response.requestOptions, response: response);
    }

    _logger.info('Anti-bot challenge on plain request, solving in WebView',
        tag: 'PageFetcher', metadata: {'url': url, 'status': status});

    if (!PlatformUtils.isWebViewSupported) {
      throw _blockedError(url, 'No WebView on this platform to solve the challenge');
    }
    clearedHosts.remove(Uri.parse(url).host);
    if (userRecentlyDeclined) {
      throw _blockedError(url, 'Browser check dismissed by the user moments ago');
    }

    String? html = await _solveInWebView(url);
    if ((html == null || isChallengePage(html)) &&
        interactiveSolver != null &&
        !userRecentlyDeclined) {
      _logger.info('Headless solve failed, asking the user',
          tag: 'PageFetcher', metadata: {'url': url});
      html = await _solveInteractively(url);
      if (html == null) {
        _userDeclinedUntil = DateTime.now().add(declineBackoff);
      }
    }
    if (html == null || isChallengePage(html)) {
      throw _blockedError(url, 'Could not get past the browser check');
    }
    clearedHosts.add(Uri.parse(url).host);
    return FetchedPage(html, url, viaWebView: true);
  }

  /// Run the visible solver, serialized behind any headless solve so that two
  /// challenge screens never stack up.
  Future<String?> _solveInteractively(String url) {
    final completer = Completer<String?>();
    _solveQueue = _solveQueue.then((_) async {
      try {
        completer.complete(await interactiveSolver!(url, await userAgent()));
      } catch (e, st) {
        _logger.error('Interactive solve crashed',
            tag: 'PageFetcher', error: e, stackTrace: st);
        completer.complete(null);
      }
    });
    return completer.future;
  }

  /// Like [fetch] but always returns a body obtained over plain HTTP, which is
  /// what JSON endpoints need (the WebView would wrap JSON in `<pre>`).
  Future<String> fetchText(String url) async {
    final page = await fetch(url);
    if (!page.viaWebView) return page.body;

    // The solve populated the cookie store; the plain request should pass now.
    final headers = await headersFor(url);
    final retry = await dio.get<String>(url,
        options: Options(
          headers: headers,
          responseType: ResponseType.plain,
          followRedirects: true,
          maxRedirects: 8,
          validateStatus: (status) => status != null && status < 500,
        ));
    final body = retry.data ?? '';
    if (!isChallengePage(body, statusCode: retry.statusCode)) return body;

    // Last resort: unwrap what the WebView rendered.
    final pre = RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false)
        .firstMatch(page.body);
    if (pre != null) {
      return pre
          .group(1)!
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&amp;', '&');
    }
    throw _blockedError(url, 'Plain request still challenged after WebView solve');
  }

  NetworkError _blockedError(String url, String details) {
    return NetworkError(
      type: NetworkErrorType.cloudflareBlock,
      userMessage: "The mirror's anti-bot check could not be passed",
      solution:
          "Anna's Archive protects its mirrors with a browser check.\n\n🔧 Solutions to try:\n• Retry in a few seconds\n• Open the mirror once in Settings → Account (the built-in browser passes the check)\n• Try a different mirror in Settings → Instances\n• Use a VPN or a different network",
      technicalDetails: '$details — $url',
    );
  }

  /// Load [url] in a headless WebView and return the real page's HTML once
  /// the challenge redirected to it. Serialized: one solve at a time.
  Future<String?> _solveInWebView(String url) {
    final completer = Completer<String?>();
    _solveQueue = _solveQueue.then((_) async {
      try {
        completer.complete(await _runHeadless(url));
      } catch (e, st) {
        _logger.error('Headless solve crashed',
            tag: 'PageFetcher', error: e, stackTrace: st);
        completer.complete(null);
      }
    });
    return completer.future;
  }

  Future<String?> _runHeadless(String url) async {
    final Completer<String?> done = Completer<String?>();
    HeadlessInAppWebView? webView;
    Timer? poll;
    InAppWebViewController? controller;
    final ua = await userAgent();

    void finish(String? html) {
      poll?.cancel();
      if (!done.isCompleted) done.complete(html);
    }

    Future<void> probe() async {
      final c = controller;
      if (c == null || done.isCompleted) return;
      try {
        final dynamic ready =
            await c.evaluateJavascript(source: 'document.readyState');
        if (ready != 'complete') return;
        final dynamic html = await c.evaluateJavascript(
            source: 'document.documentElement.outerHTML');
        if (html is String) _lastHeadlessHtml = html;
        if (html is String && html.length > 200 && !isChallengePage(html)) {
          finish(html);
        } else if (html is String && isRateLimitPage(html)) {
          _logger.warning('Rate-limit page in headless WebView',
              tag: 'PageFetcher');
          finish(null);
        } else if (html is String && needsManualCheck(html)) {
          _logger.info('Challenge wants a manual check; stopping headless',
              tag: 'PageFetcher');
          finish(null);
        }
      } catch (_) {
        // Navigating between challenge and target page: try again later.
      }
    }

    try {
      webView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          userAgent: ua,
          javaScriptEnabled: true,
          thirdPartyCookiesEnabled: true,
        ),
        onWebViewCreated: (c) {
          controller = c;
        },
        onLoadStop: (c, loadedUrl) async {
          controller = c;
          _logger.debug('Headless page loaded',
              tag: 'PageFetcher', metadata: {'url': loadedUrl?.toString()});
          await probe();
        },
        onReceivedError: (c, request, error) {
          if (request.isForMainFrame ?? true) {
            _logger.warning('Headless main-frame error',
                tag: 'PageFetcher', metadata: {'desc': error.description});
            finish(null);
          }
        },
      );

      await webView.run();
      poll = Timer.periodic(pollInterval, (_) => probe());

      final html = await done.future.timeout(solveTimeout, onTimeout: () {
        final last = _lastHeadlessHtml ?? '';
        _logger.warning('Headless solve timed out',
            tag: 'PageFetcher', metadata: {
              'url': url,
              'lastHtml': last.substring(0, last.length > 300 ? 300 : last.length),
            });
        return null;
      });

      if (html != null) {
        _logger.info('Challenge solved', tag: 'PageFetcher',
            metadata: {'url': url, 'bytes': html.length});
      }
      return html;
    } finally {
      poll?.cancel();
      try {
        await webView?.dispose();
      } catch (_) {
        // ignore dispose errors
      }
    }
  }
}
