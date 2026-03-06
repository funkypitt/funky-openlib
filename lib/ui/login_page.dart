// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// Project imports:
import 'package:openlib/services/database.dart';
import 'package:openlib/services/download_manager.dart';
import 'package:openlib/services/instance_manager.dart';
import 'package:openlib/services/logger.dart';
import 'package:openlib/services/mirror_fetcher.dart';
import 'package:openlib/state/state.dart' show cookieProvider;

/// Login page that opens Anna's Archive /account in a WebView.
/// After the user logs in, cookies are extracted and persisted.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final AppLogger _logger = AppLogger();
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  String _currentUrl = '';

  Future<String> _getLoginUrl() async {
    final instance = await InstanceManager().getCurrentInstance();
    return '${instance.baseUrl}/account';
  }

  Future<void> _extractAndSaveCookies() async {
    try {
      final instance = await InstanceManager().getCurrentInstance();
      final url = WebUri(instance.baseUrl);

      final cookies =
          await CookieManager.instance().getCookies(url: url);

      if (cookies.isEmpty) {
        _logger.warning('No cookies found after login', tag: 'Login');
        return;
      }

      // Build a cookie string from all cookies
      final cookieString =
          cookies.map((c) => '${c.name}=${c.value}').join('; ');

      _logger.info('Extracted ${cookies.length} cookies', tag: 'Login');

      // Persist to database
      await MyLibraryDb.instance.setBrowserOptions('cookie', cookieString);

      // Update provider and singleton services
      ref.read(cookieProvider.notifier).state = cookieString;
      DownloadManager().setCookie(cookieString);
      MirrorFetcherService().setCookie(cookieString);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Successfully logged in'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      _logger.error('Failed to extract cookies', tag: 'Login', error: e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving session: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Desktop platforms: show a message since InAppWebView may not work
    if (Platform.isLinux || Platform.isWindows) {
      return Scaffold(
        appBar: AppBar(title: const Text('Login')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Text(
              'Account login is currently only supported on mobile devices.\n\n'
              'Please log in on your phone or tablet.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Anna\'s Archive Account'),
        actions: [
          TextButton.icon(
            onPressed: _extractAndSaveCookies,
            icon: const Icon(Icons.check),
            label: const Text('Done'),
          ),
        ],
      ),
      body: Stack(
        children: [
          FutureBuilder<String>(
            future: _getLoginUrl(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              return InAppWebView(
                initialUrlRequest:
                    URLRequest(url: WebUri(snapshot.data!)),
                onWebViewCreated: (controller) {
                  _webViewController = controller;
                },
                onLoadStart: (controller, url) {
                  setState(() {
                    _isLoading = true;
                    _currentUrl = url?.toString() ?? '';
                  });
                },
                onLoadStop: (controller, url) async {
                  setState(() {
                    _isLoading = false;
                    _currentUrl = url?.toString() ?? '';
                  });

                  // Auto-detect successful login:
                  // If user navigated away from /account/login to /account
                  // (the account page itself, not the login form), extract cookies
                  final urlStr = url?.toString() ?? '';
                  if (urlStr.contains('/account') &&
                      !urlStr.contains('/account/login') &&
                      !urlStr.contains('/account/register')) {
                    // User seems logged in, auto-extract
                    await _extractAndSaveCookies();
                  }
                },
              );
            },
          ),
          if (_isLoading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
