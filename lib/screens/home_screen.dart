import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../models/app_session.dart';
import '../services/runtime_helpers.dart';
import '../services/storage_service.dart';
import 'login_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.session});

  final AppSession session;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _defaultBase = 'crm.cartzlink.com';

  final _storage = StorageService();
  late final WebViewController _webView;

  String _baseUrl = _defaultBase;
  String _baseOrigin = _defaultBase;
  String _initialUrl = _defaultBase;
  bool _loading = true;
  int _progress = 0;
  List<String> _recentDomains = <String>[];

  @override
  void initState() {
    super.initState();

    _webView = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress < 0 ? 0 : (progress > 100 ? 100 : progress);
              _loading = progress < 100;
            });
          },
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _loading = true;
              _progress = 0;
            });
          },
          onPageFinished: (url) async {
            if (mounted) {
              setState(() {
                _loading = false;
                _progress = 100;
              });
            }
            await _captureSameOriginUrl(url, saveAsLastDomain: true);
          },
          onNavigationRequest: (request) async {
            await _captureSameOriginUrl(request.url);
            return NavigationDecision.navigate;
          },
          onWebResourceError: (_) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _progress = 0;
            });
          },
        ),
      );

    _initialize();
  }

  Future<void> _initialize() async {
    await _enableWebAuthentication();
    await _loadRecentDomains();
    await _bootstrap();
  }

  Future<void> _loadRecentDomains() async {
    final domains = await _storage.getRecentDomains();
    if (!mounted) return;
    setState(() {
      _recentDomains = domains;
    });
  }

  Future<void> _enableWebAuthentication() async {
    final platform = _webView.platform;
    if (platform is! AndroidWebViewController) return;

    try {
      final supported = await platform.isWebViewFeatureSupported(
        WebViewFeatureType.webAuthentication,
      );

      if (!supported) return;

      // Use app-scoped WebAuthn only. Browser mode can terminate the Android
      // process unless the app is approved as a privileged browser.
      await platform.setWebAuthenticationSupport(
        WebAuthenticationSupport.forApp,
      );
    } catch (_) {
      // Do not block the ERP if WebAuthn is unavailable on this device/WebView.
      // The page can still load normally.
    }
  }

  Future<void> _bootstrap() async {
    final storedBase = await _storage.getString(StorageKeys.crmBaseUrl);
    final storedLast = await _storage.getString(StorageKeys.crmLastUrl);

    final candidate = widget.session.loginUrl.isNotEmpty
        ? widget.session.loginUrl
        : (storedBase?.isNotEmpty == true
            ? storedBase!
            : (storedLast?.isNotEmpty == true ? storedLast! : _defaultBase));

    _baseUrl = originOrDefault(candidate, fallback: _defaultBase);
    _baseOrigin = originOrDefault(_baseUrl, fallback: _defaultBase);
    await _storage.setString(StorageKeys.crmBaseUrl, _baseUrl);

    // Open the ERP host itself. Do not force /admin and do not restore a
    // previously redirected path as the first page.
    _initialUrl = _baseUrl;

    final lastLogin = await _storage.getString(StorageKeys.authLastLoginAt);
    if (lastLogin == null || lastLogin.isEmpty) {
      await _storage.setString(
        StorageKeys.authLastLoginAt,
        DateTime.now().toIso8601String(),
      );
    }

    if (!mounted) return;
    await _setFrame(_initialUrl);
  }

  Future<void> _setFrame(String requested) async {
    String target;
    try {
      target = Uri.parse(_baseUrl).resolve(requested).toString();
    } catch (_) {
      target = _baseUrl;
    }

    if (!sameOrigin(target, _baseOrigin)) target = _baseUrl;

    await _storage.setString(StorageKeys.crmBaseUrl, _baseUrl);
    await _storage.setString(StorageKeys.crmLastUrl, target);

    if (mounted) {
      setState(() {
        _loading = true;
        _progress = 0;
      });
    }

    await _webView.loadRequest(Uri.parse(target));
  }

  Future<void> _captureSameOriginUrl(
    String url, {
    bool saveAsLastDomain = false,
  }) async {
    if (!sameOrigin(url, _baseOrigin)) return;

    await _storage.setString(StorageKeys.crmLastUrl, url);

    // Save the last successfully reached ERP domain separately so it can be
    // offered on the login screen after logout/app restart.
    if (saveAsLastDomain) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.host.isNotEmpty) {
        await _storage.addRecentDomain(uri.host);
        await _loadRecentDomains();
      }
    }
  }


  String get _currentDomain {
    final uri = Uri.tryParse(ensureHttps(_baseUrl));
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return normalizeErpHost(_baseUrl);
  }

  Future<void> _switchDomain(String domain) async {
    final host = normalizeErpHost(domain);
    if (host.isEmpty || host == _currentDomain) return;

    final nextBase = originOrDefault(host, fallback: _baseUrl);

    setState(() {
      _baseUrl = nextBase;
      _baseOrigin = nextBase;
      _initialUrl = nextBase;
      _loading = true;
      _progress = 0;
    });

    await _storage.setString(StorageKeys.erpLastUrl, host);
    await _storage.setString(StorageKeys.crmBaseUrl, nextBase);
    await _storage.setString(StorageKeys.crmLastUrl, nextBase);

    await _webView.loadRequest(Uri.parse(nextBase));
  }

  List<PopupMenuEntry<String>> _domainMenuItems() {
    if (_recentDomains.isEmpty) {
      return const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          enabled: false,
          child: Text('No recent domains'),
        ),
      ];
    }

    return _recentDomains.map((domain) {
      final isCurrent = domain.toLowerCase() == _currentDomain.toLowerCase();
      return PopupMenuItem<String>(
        value: domain,
        child: Row(
          children: [
            Icon(
              isCurrent ? Icons.check_circle : Icons.language,
              size: 19,
              color: const Color(0xFF769B12),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                domain,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      );
    }).toList();
  }

  Future<void> _reload() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _progress = 0;
      });
    }
    await _webView.reload();
  }

  Future<void> _logout() async {
    await _storage.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (_) => false,
    );
  }

  Future<void> _nativeBack() async {
    if (await _webView.canGoBack()) {
      await _webView.goBack();
    } else {
      await SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) await _nativeBack();
      },
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: const Color(0xFF93C216),
          foregroundColor: Colors.white,
          title: PopupMenuButton<String>(
            tooltip: 'Switch domain',
            onSelected: _switchDomain,
            itemBuilder: (_) => _domainMenuItems(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'CARTZ Link - ERP',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.language, size: 13, color: Colors.white70),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _currentDomain,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Colors.white,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                    const Icon(
                      Icons.arrow_drop_down,
                      size: 17,
                      color: Colors.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            IconButton(
              onPressed: _reload,
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: IconButton(
                onPressed: _logout,
                tooltip: 'Logout',
                style: IconButton.styleFrom(
                  backgroundColor: const Color(0xFFDC3545),
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.logout),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading)
              LinearProgressIndicator(
                value: _progress > 0 ? _progress / 100 : null,
                minHeight: 3,
                backgroundColor: const Color(0xFFE8E8E8),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFF93C216),
                ),
              ),
            Expanded(
              child: WebViewWidget(controller: _webView),
            ),
          ],
        ),
      ),
    );
  }
}
