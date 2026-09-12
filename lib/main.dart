import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_shared/hermes_shared.dart' hide ServerConfig;
import 'reader/providers/library_provider.dart';
import 'reader/providers/session_provider.dart';
import 'reader/providers/task_provider.dart';
import 'reader/providers/global_config_provider.dart';
import 'reader/providers/server_provider.dart';
import 'reader/services/library_service.dart';
import 'reader/services/reader_config_storage.dart';
import 'reader/services/tts_service.dart';
import 'reader/services/local_tts_source.dart';
import 'reader/services/server_tts_source.dart';
import 'reader/screens/reader_home_screen.dart';
import 'reader/screens/session_monitor_screen.dart';
import 'reader/screens/task_list_screen.dart';
import 'reader/screens/ebook_reader_screen.dart';
import 'reader/models/book.dart';
import 'reader/models/global_config.dart';
import 'reader/services/direct_file_transport.dart';
import 'reader/services/proxy_file_transport.dart';
import 'reader/services/proxy_client.dart' as reader_proxy;
import 'reader/screens/local_library_screen.dart';
import 'reader/models/hive_models.dart';

void main() {
  runApp(const HermesReaderApp());
}

class HermesReaderApp extends StatelessWidget {
  const HermesReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<LibraryService>(
          create: (_) => LibraryService(),
          dispose: (_, __) {},
        ),
        ChangeNotifierProxyProvider<LibraryService, LibraryProvider>(
          create: (context) => LibraryProvider(context.read<LibraryService>()),
          update: (context, service, previous) =>
              previous ?? LibraryProvider(service),
        ),
        ChangeNotifierProvider(
          create: (_) => ReaderProvider(
            configStorage: ReaderConfigStorage(),
          ),
        ),
        ChangeNotifierProvider(create: (_) => SessionProvider()),
        ChangeNotifierProvider(create: (_) => TaskProvider()),
        ChangeNotifierProvider(create: (_) => GlobalConfigProvider()),
        ChangeNotifierProvider(create: (_) => ServerProvider()),
        Provider<TtsService>(
          create: (_) => TtsService(
            serverSource: _UnavailableServerTts(),
            localSource: LocalTtsSource(),
          ),
          dispose: (_, service) => service.dispose(),
        ),
      ],
      child: MaterialApp(
        title: 'hermes-reader',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.light,
          ),
          useMaterial3: true,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF6750A4),
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          cardTheme: CardThemeData(
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        themeMode: ThemeMode.system,
        home: const StartupScreen(),
      ),
    );
  }
}

/// Startup screen with itemized checklist
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  final List<_CheckItem> _checks = [];
  bool _allPassed = true;

  @override
  void initState() {
    super.initState();
    FlutterError.onError = (details) {
      debugPrint('Flutter error: ${details.exception}');
    };
    _checkConfig();
  }

  /// Restores the saved reader settings before the first page is shown.
  Future<void> _restoreReaderConfig() async {
    try {
      final config = await ReaderConfigStorage().load();
      if (!mounted) return;
      context.read<ReaderProvider>().updateConfig(config);
    } catch (e) {
      debugPrint('reader config restore failed: $e');
    }
  }

  Future<void> _checkConfig() async {
    await _restoreReaderConfig();
    _addCheck('读取本地配置');
    try {
      final globalConfig = context.read<GlobalConfigProvider>();
      await globalConfig.load();
      _passCheck();
    } catch (e) {
      _failCheck(e.toString());
      _navigateToLocal();
      return;
    }

    if (!mounted) return;

    final globalConfig = context.read<GlobalConfigProvider>();
    if (globalConfig.config.proxyUrl.isEmpty) {
      _addCheck('检查代理配置', skip: true);
      _navigateToLocal();
      return;
    }

    // Test HTTP connectivity first
    _addCheck('测试 HTTP 连通性');
    try {
      final httpScheme = globalConfig.config.proxyUrl.startsWith('https') ? 'https' : 'http';
      final host = Uri.parse(globalConfig.config.proxyUrl).host;
      final healthUrl = '$httpScheme://$host/health';
      final resp = await http.get(Uri.parse(healthUrl)).timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        _passCheck();
      } else {
        _failCheck('HTTP ${resp.statusCode}');
      }
    } catch (e) {
      _failCheck(e.toString());
      _navigateToLocal();
      return;
    }

    if (!mounted) return;

    // Connect WebSocket
    _addCheck('连接 WebSocket');
    List<dynamic> servers = [];
    try {
      final proxyClient = reader_proxy.ProxyClient(
        proxyUrl: globalConfig.config.proxyWsUrl,
        authToken: globalConfig.config.proxyAuthToken,
      );
      await proxyClient.connect();
      _passCheck();

      if (!mounted) return;

      // Fetch servers
      _addCheck('获取服务器列表');
      try {
        servers = await proxyClient.fetchServersDI();
        _passCheck('${servers.length} 个服务器');
      } catch (e) {
        _failCheck('获取失败: $e');
      }

      if (mounted) {
        final serverProvider = context.read<ServerProvider>();
        serverProvider.setServers(servers);
      }

      if (!mounted) return;
      _navigateToOnline();
    } catch (e) {
      _failCheck(e.toString());
      _navigateToLocal();
    }
  }

  void _addCheck(String label, {bool skip = false}) {
    if (!mounted) return;
    setState(() {
      _checks.add(_CheckItem(label: label, skipped: skip));
    });
  }

  void _passCheck([String? detail]) {
    if (!mounted) return;
    setState(() {
      _checks.last.pass(detail);
    });
  }

  void _failCheck(String error) {
    if (!mounted) return;
    setState(() {
      _allPassed = false;
      _checks.last.fail(error);
    });
  }

  void _navigateToLocal() {
    if (!mounted) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen(mode: AppMode.local)),
        );
      }
    });
  }

  void _navigateToOnline() {
    if (!mounted) return;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const HomeScreen(mode: AppMode.online)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                value: _checks.isEmpty ? null : _checks.where((c) => c.done).length / _checks.length,
              ),
              const SizedBox(height: 24),
              Text(
                _allPassed ? '正在启动...' : '启动完成（有警告）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 16),
              ..._checks.map((c) => _buildCheckItem(c)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCheckItem(_CheckItem item) {
    IconData icon;
    Color color;
    if (item.skipped) {
      icon = Icons.skip_next;
      color = Colors.grey;
    } else if (item.passed) {
      icon = Icons.check_circle;
      color = Colors.green;
    } else {
      icon = Icons.error;
      color = Colors.red;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.label + (item.detail != null ? ': ${item.detail}' : ''),
              style: TextStyle(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckItem {
  final String label;
  final bool skipped;
  bool done = false;
  bool passed = false;
  String? detail;

  _CheckItem({required this.label, this.skipped = false});

  void pass([String? info]) {
    done = true;
    passed = true;
    detail = info;
  }

  void fail(String error) {
    done = true;
    passed = false;
    detail = error;
  }
}

enum AppMode { local, online }

class HomeScreen extends StatefulWidget {
  final AppMode mode;

  const HomeScreen({super.key, required this.mode});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _pageIndex = 0;
  AppMode _currentMode = AppMode.local;
  final GlobalKey<_SessionMonitorTabState> _sessionTabKey = GlobalKey();
  String _sessionLimit = '10';

  @override
  void initState() {
    super.initState();
    _currentMode = widget.mode;
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _sessionLimit = prefs.getString('session_limit') ?? '10';
      });
    }
    // Auto-connect if proxy config exists
    _autoConnect();
  }

  Future<void> _autoConnect() async {
    final globalConfig = context.read<GlobalConfigProvider>();
    await globalConfig.load();
    if (globalConfig.isProxyMode && globalConfig.config.proxyUrl.isNotEmpty) {
      print('[AUTO] Found saved proxy config, auto-connecting...');
      // Load servers from proxy
      try {
        final proxyClient = reader_proxy.ProxyClient(
          proxyUrl: globalConfig.config.proxyWsUrl,
          authToken: globalConfig.config.proxyAuthToken,
        );
        await proxyClient.connect();
        final servers = await proxyClient.fetchServersDI();
        print('[AUTO] Connected, got ${servers.length} servers');
        await _onConnected(
          'wss://${globalConfig.config.proxyWsUrl.split('://').last.split('/').first}',
          globalConfig.config.proxyAuthToken,
          servers,
        );
      } catch (e) {
        print('[AUTO] Auto-connect failed: $e');
      }
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('session_limit', _sessionLimit);
  }

  Future<void> _scanQR() async {
    final raw = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QRScannerPage()),
    );
    if (raw == null || !mounted) return;

    final config = QRConfigParser.parse(raw);
    if (config == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无效的二维码')),
      );
      return;
    }

    _showConnectionDialog(config);
  }

  void _showConnectionDialog(Map<String, String> config) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConnectionDialog(
        config: config,
        onConnected: (proxyUrl, token, servers) async {
          await _onConnected(proxyUrl, token, servers);
          if (ctx.mounted) Navigator.pop(ctx);
        },
        onFailed: (error) {
          Navigator.pop(ctx);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('连接失败: $error')),
          );
        },
        onCancel: () {
          Navigator.pop(ctx);
        },
      ),
    );
  }

  Future<void> _onConnected(String proxyUrl, String token, List<dynamic> servers) async {
      print('[ONCONNECTED] START proxyUrl=$proxyUrl servers=${servers.length}');
      final globalConfig = context.read<GlobalConfigProvider>();
    
      // proxyUrl from dialog is the stripped ws_url (e.g. wss://host or wss://host:port)
      // Convert back to https URL for storage in GlobalConfig
      final wsUri = Uri.parse(proxyUrl);
      final httpsScheme = 'https';
      final host = wsUri.host;
      final port = wsUri.port;
      // Store https URL (without port if default 443)
      String baseUrl;
      if (port > 0 && port != 443) {
        baseUrl = '$httpsScheme://$host:$port';
      } else {
        baseUrl = '$httpsScheme://$host';
      }
    
      // Recompute wsUrl from the corrected proxyUrl
      final config = GlobalConfig(
        mode: ConnectionMode.hermesProxy,
        proxyUrl: baseUrl,
        proxyAuthToken: token,
        proxyWsPort: port > 0 ? port : 8649,
        proxyAdminPort: 8650,
      );
      final wsUrl = config.proxyWsUrl;
    
      globalConfig.updateConfig(config);

      final serverProvider = context.read<ServerProvider>();
      serverProvider.setServers(servers);

      // Create proxy client and wire DI session updates to SessionProvider
      final proxyClient = reader_proxy.ProxyClient(
        proxyUrl: wsUrl,
        authToken: token,
      );
      final sessionProvider = context.read<SessionProvider>();
      print('[ONCONNECTED] Setting proxy client...');
      sessionProvider.setProxyClient(proxyClient);
      print('[ONCONNECTED] Connecting proxy client...');
      await proxyClient.connect();
      print('[ONCONNECTED] Proxy client connected!');

      setState(() {
        _currentMode = AppMode.online;
      });

      ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已连接')),
          );
    }

  void _switchServer(String? serverId) {
    // Tell the session tab its cached view is stale for the new server.
    _sessionTabKey.currentState?.onServerSwitched(serverId);
    if (serverId == null || serverId == '__local__') {
      setState(() {
        _currentMode = AppMode.local;
      });
      return;
    }

    final serverProvider = context.read<ServerProvider>();
    final server = serverProvider.servers.firstWhere(
      (s) => s.id == serverId,
      orElse: () => serverProvider.servers.first,
    );
    serverProvider.setActiveServer(server);
    setState(() {
      _currentMode = AppMode.online;
    });

    // Switching must actually attach the proxy to the new backend. Previously
    // this only mutated local state, so the proxy never dialled the server and
    // every later request for it timed out.
    _attachServer(server);
  }

  /// Attach the proxy to [server], sending full credentials.
  ///
  /// Fire-and-forget: a failure is surfaced as a snackbar rather than blocking
  /// the UI, because reading must never be blocked by session plumbing.
  void _attachServer(ServerConfig server) {
    final proxyClient = context.read<SessionProvider>().proxyClient;
    if (proxyClient == null || !proxyClient.isConnected) {
      return;
    }
    unawaited(
      proxyClient
          .connectServer(
        server.id,
        username: server.username,
        password: server.password,
        profile: server.profile,
      )
          .then((_) {
        debugPrint('[SWITCH] attached ${server.id}');
      }).catchError((Object e) {
        debugPrint('[SWITCH] attach ${server.id} failed: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法连接 ${server.name}: $e')),
        );
      }),
    );
  }

  void _disconnect() {
    final globalConfig = context.read<GlobalConfigProvider>();
    globalConfig.updateConfig(GlobalConfig(
      mode: ConnectionMode.standalone,
      proxyUrl: '',
      proxyAuthToken: '',
    ));

    final serverProvider = context.read<ServerProvider>();
    serverProvider.clearServers();

    setState(() {
      _currentMode = AppMode.local;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已断开')),
    );
  }



  void _showEditConfigDialog(String currentUrl, String currentToken) {
    final urlController = TextEditingController(text: currentUrl);
    final tokenController = TextEditingController(text: currentToken);
    final limitController = TextEditingController(text: _sessionLimit);
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: '代理地址',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenController,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    prefixIcon: Icon(Icons.key),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: limitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每服务器会话数 (N)',
                    prefixIcon: Icon(Icons.format_list_numbered),
                    helperText: '每个服务器最多显示的会话数',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final url = urlController.text.trim();
                if (url.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入代理地址')),
                  );
                  return;
                }
                final token = tokenController.text.trim();
                final provider = context.read<GlobalConfigProvider>();
                provider.updateConfig(GlobalConfig(
                  mode: ConnectionMode.hermesProxy,
                  proxyUrl: url,
                  proxyAuthToken: token,
                ));
                setState(() {
                  _sessionLimit = limitController.text.trim();
                });
                _saveSettings();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配置已保存')),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _openConfig() {
    final globalConfig = context.read<GlobalConfigProvider>();
    if (globalConfig.isProxyMode) {
      _showProxyConfigSheet(globalConfig);
    } else {
      _showStandaloneConfigSheet(globalConfig);
    }
  }

  void _showProxyConfigSheet(GlobalConfigProvider globalConfig) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('当前配置', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Text('代理地址: ${globalConfig.config.proxyUrl}'),
              Text('WS 端口: ${globalConfig.config.proxyWsPort}'),
              Text('Token: ${globalConfig.config.proxyAuthToken.isNotEmpty ? '已配置' : '未配置'}'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _scanQR();
                },
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫码更换'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showEditConfigDialog(globalConfig.config.proxyUrl, globalConfig.config.proxyAuthToken);
                },
                icon: const Icon(Icons.edit),
                label: const Text('手动编辑'),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _disconnect();
                },
                icon: const Icon(Icons.link_off),
                label: const Text('断开连接'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showStandaloneConfigSheet(GlobalConfigProvider globalConfig) {
    final serverProvider = context.read<ServerProvider>();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('独立模式 — 服务器列表', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              ...serverProvider.servers.map((s) => ListTile(
                    title: Text(s.name),
                    subtitle: Text(s.url),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showEditServerDialog(s);
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete, size: 20, color: Colors.red),
                          onPressed: () async {
                            await serverProvider.removeServer(s.id);
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ],
                    ),
                  )),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showAddServerDialog();
                },
                icon: const Icon(Icons.add),
                label: const Text('添加服务器'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAddServerDialog() {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: idCtrl, decoration: const InputDecoration(labelText: 'ID (唯一)')),
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称')),
              TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'URL', hintText: 'http://10.10.164.32:8648')),
              TextField(controller: userCtrl, decoration: const InputDecoration(labelText: '用户名 (可选)')),
              TextField(controller: passCtrl, decoration: const InputDecoration(labelText: '密码 (可选)'), obscureText: true),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final id = idCtrl.text.trim();
              if (id.isEmpty) return;
              final server = ServerConfig(
                id: id,
                name: nameCtrl.text.trim().isEmpty ? id : nameCtrl.text.trim(),
                url: urlCtrl.text.trim(),
                username: userCtrl.text.trim().isEmpty ? null : userCtrl.text.trim(),
                password: passCtrl.text.trim().isEmpty ? null : passCtrl.text.trim(),
              );
              context.read<ServerProvider>().addServer(server);
              Navigator.pop(ctx);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  void _showEditServerDialog(ServerConfig server) {
    final nameCtrl = TextEditingController(text: server.name);
    final urlCtrl = TextEditingController(text: server.url);
    final userCtrl = TextEditingController(text: server.username ?? '');
    final passCtrl = TextEditingController(text: server.password ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('编辑 ${server.name}'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: '名称')),
              TextField(controller: urlCtrl, decoration: const InputDecoration(labelText: 'URL')),
              TextField(controller: userCtrl, decoration: const InputDecoration(labelText: '用户名')),
              TextField(controller: passCtrl, decoration: const InputDecoration(labelText: '密码'), obscureText: true),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final updated = ServerConfig(
                id: server.id,
                name: nameCtrl.text.trim(),
                url: urlCtrl.text.trim(),
                username: userCtrl.text.trim().isEmpty ? null : userCtrl.text.trim(),
                password: passCtrl.text.trim().isEmpty ? null : passCtrl.text.trim(),
              );
              context.read<ServerProvider>().updateServer(updated);
              Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _showManualConfigDialog() {
    final urlController = TextEditingController(text: 'https://hermes-proxy.willam.eu.org');
    final tokenController = TextEditingController();
    final limitController = TextEditingController(text: '10');
    
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('接入配置'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: '代理地址',
                    hintText: 'https://hermes-proxy.willam.eu.org',
                    prefixIcon: Icon(Icons.link),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenController,
                  decoration: const InputDecoration(
                    labelText: 'Token',
                    hintText: '可选',
                    prefixIcon: Icon(Icons.key),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: limitController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '每服务器会话数 (N)',
                    prefixIcon: Icon(Icons.format_list_numbered),
                    helperText: '每个服务器最多显示的会话数',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _scanQR();
              },
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('扫码'),
            ),
            FilledButton(
              onPressed: () {
                final url = urlController.text.trim();
                if (url.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('请输入代理地址')),
                  );
                  return;
                }
                final token = tokenController.text.trim();
                final provider = context.read<GlobalConfigProvider>();
                provider.updateConfig(GlobalConfig(
                  mode: ConnectionMode.hermesProxy,
                  proxyUrl: url,
                  proxyAuthToken: token,
                ));
                setState(() {
                  _sessionLimit = limitController.text.trim();
                });
                _saveSettings();
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('配置已保存')),
                );
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  void _openEbook() {
    final serverProvider = context.read<ServerProvider>();
    final globalConfig = context.read<GlobalConfigProvider>();
    
    if (serverProvider.servers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先添加服务器')),
      );
      return;
    }
    
    final server = serverProvider.activeServer ?? serverProvider.servers.first;
    final transport = globalConfig.isProxyMode
        ? ProxyFileTransport(
            proxyClient: serverProvider.getProxyClient(server) ??
                reader_proxy.ProxyClient(
                  proxyUrl: globalConfig.config.proxyWsUrl,
                  authToken: globalConfig.config.proxyAuthToken,
                ),
            serverId: server.id,
            username: server.username,
            password: server.password,
            profile: server.profile,
          )
        : DirectFileTransport(server: server);
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderHomeScreen(
          serverId: server.id,
          serverName: server.name,
          transport: transport,
        ),
      ),
    );
  }

  Future<void> _openLocalLibrary() async {
    final globalConfig = context.read<GlobalConfigProvider>();
    if (!globalConfig.isProxyMode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地文库需要代理模式')),
      );
      return;
    }
    final proxyClient = reader_proxy.ProxyClient(
      proxyUrl: globalConfig.config.proxyWsUrl,
      authToken: globalConfig.config.proxyAuthToken,
    );
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => LocalLibraryScreen(proxyClient: proxyClient),
      ),
    );
  }

  void _showModeSelector() {
    final globalConfig = context.read<GlobalConfigProvider>();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择模式'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<bool>(
              title: const Text('代理模式'),
              subtitle: const Text('通过 hermes-proxy 连接多个服务器'),
              value: true,
              groupValue: globalConfig.isProxyMode,
              onChanged: (_) {
                Navigator.pop(ctx);
                _switchToProxyMode();
              },
            ),
            RadioListTile<bool>(
              title: const Text('独立模式'),
              subtitle: const Text('直接连接服务器，手动增删改'),
              value: false,
              groupValue: globalConfig.isProxyMode,
              onChanged: (_) {
                Navigator.pop(ctx);
                _switchToStandaloneMode();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _switchToProxyMode() async {
    // Always show proxy configuration dialog so user can review settings
    _showManualConfigDialog();
  }

  Future<void> _switchToStandaloneMode() async {
    final sessionProvider = context.read<SessionProvider>();
    sessionProvider.clearProxyClient();
    if (mounted) setState(() => _currentMode = AppMode.local);
  }

  void _showMenu() {
    final serverProvider = context.read<ServerProvider>();
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('菜单', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text('当前模式: ${context.read<GlobalConfigProvider>().isProxyMode ? '代理' : '独立'}'),
                onTap: () {
                  Navigator.pop(ctx);
                  _showModeSelector();
                },
              ),
              const Divider(),
              ListTile(
                leading: const Icon(Icons.settings),
                title: const Text('接入配置'),
                subtitle: Text(context.read<GlobalConfigProvider>().config.proxyUrl.isEmpty 
                    ? '未配置' 
                    : '已配置'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openConfig();
                },
              ),
              if (serverProvider.servers.isNotEmpty) ...[
                const Divider(),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('服务器列表', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                ),
                ...serverProvider.servers.map((s) => ListTile(
                  leading: Icon(
                    s.isOnline ? Icons.cloud_done : Icons.cloud_off,
                    color: s.isOnline ? Colors.green : Colors.grey,
                  ),
                  title: Text(s.name),
                  subtitle: Text(s.url),
                  selected: serverProvider.activeServer?.id == s.id,
                  onTap: () {
                    Navigator.pop(ctx);
                    _switchServer(s.id);
                  },
                )),
              ],
              const Divider(),
              ListTile(
                leading: const Icon(Icons.monitor_heart),
                title: const Text('会话清单'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _pageIndex = 0);
                },
              ),
              ListTile(
                leading: const Icon(Icons.assignment),
                title: const Text('待办事项'),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _pageIndex = 1);
                },
              ),
              ListTile(
                leading: const Icon(Icons.menu_book),
                title: const Text('电子书库'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openEbook();
                },
              ),
              ListTile(
                leading: const Icon(Icons.folder_special),
                title: const Text('本地文库'),
                subtitle: const Text('统一管理各服务器下载的文件，可上传/转发'),
                onTap: () {
                  Navigator.pop(ctx);
                  _openLocalLibrary();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      _SessionMonitorTab(key: _sessionTabKey, sessionLimit: _sessionLimit),
      const TaskListScreen(),
    ];

    final serverProvider = context.watch<ServerProvider>();
    final hasServers = serverProvider.servers.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: _currentMode == AppMode.online && hasServers
            ? DropdownButton<String>(
                value: serverProvider.activeServer?.id ?? serverProvider.servers.first.id,
                underline: const SizedBox(),
                dropdownColor: Theme.of(context).colorScheme.surface,
                isExpanded: false,
                items: [
                  const DropdownMenuItem<String>(
                    value: '__local__',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.phone_android, size: 16),
                        SizedBox(width: 4),
                        Text('本地'),
                      ],
                    ),
                  ),
                  ...serverProvider.servers.map((s) => DropdownMenuItem<String>(
                    value: s.id,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(s.isOnline ? Icons.cloud_done : Icons.cloud_off, size: 16,
                          color: s.isOnline ? Colors.green : Colors.grey),
                        const SizedBox(width: 4),
                        Text(s.name),
                      ],
                    ),
                  )),
                ],
                onChanged: (value) {
                  _switchServer(value);
                },
              )
            : Text(_currentMode == AppMode.online ? 'hermes-reader (联网)' : 'hermes-reader (本地)'),
      ),
      body: IndexedStack(
        index: _pageIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomAppBar(
        child: Row(
          children: [
            _BarButton(
              icon: Icons.menu,
              label: 'Menu',
              active: false,
              onPressed: _showMenu,
            ),
            _BarButton(
              icon: Icons.menu_book,
              label: 'Books',
              active: false,
              onPressed: _openEbook,
            ),
            _BarButton(
              icon: Icons.monitor_heart,
              label: 'Session',
              active: _pageIndex == 0,
              onPressed: () => setState(() => _pageIndex = 0),
            ),
            _BarButton(
              icon: Icons.assignment,
              label: 'Tasks',
              active: _pageIndex == 1,
              onPressed: () => setState(() => _pageIndex = 1),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom bar icon with a visible text label.
class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onPressed;

  const _BarButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? Theme.of(context).colorScheme.primary : Colors.grey;
    return Expanded(
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: color),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(fontSize: 11, color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Session monitor tab that connects to all servers
class _SessionMonitorTab extends StatefulWidget {
  final String sessionLimit;

  const _SessionMonitorTab({super.key, required this.sessionLimit});

  @override
  State<_SessionMonitorTab> createState() => _SessionMonitorTabState();
}

class _SessionMonitorTabState extends State<_SessionMonitorTab> {
  final Map<String, List<SessionSnapshot>> _serverSessions = {};
  bool _loading = false;
  String? _error;
  Timer? _pollTimer;
  Timer? _autoRefreshTimer;
  String? _shownServerId;
  bool _onlyActive = false;
  final Set<String> _alerted = {};

  @override
  void initState() {
    super.initState();
    // Periodically refresh the active server so newly-stopped sessions
    // surface without the user pulling to refresh.
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (!mounted) return;
      final id = context.read<ServerProvider>().activeServer?.id;
      if (id != null) _fetchServer(id, quiet: true);
    });

    // Poll for proxy client availability every 2 seconds
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final sessionProvider = context.read<SessionProvider>();
      final serverProvider = context.read<ServerProvider>();
      final activeId =
          serverProvider.activeServer?.id ?? serverProvider.servers.firstOrNull?.id;
      if (sessionProvider.proxyClient == null || _loading || _fetchingAll) return;
      // Only kick off the full sweep once, for the very first load.
      if (activeId != null &&
          _serverSessions[activeId] == null &&
          _serverSessions.isEmpty) {
        _fetchAllSessions();
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_SessionMonitorTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionLimit != widget.sessionLimit) {
      _fetchAllSessions();
    }
  }

  /// Called when the user picks a different server in the app bar.
  void onServerSwitched(String? serverId) {
    _shownServerId = serverId;
    if (serverId == null) return;
    // Rebuild immediately so the header/list follow the selection, then
    // (re)fetch just that server in the background.
    if (mounted) setState(() {});
    _fetchServer(serverId);
  }

  /// Fetch sessions for a single server, used when the user switches servers.
  Future<void> _fetchServer(String serverId, {bool quiet = false}) async {
    final sessionProvider = context.read<SessionProvider>();
    final serverProvider = context.read<ServerProvider>();
    final proxyClient = sessionProvider.proxyClient;
    if (proxyClient == null) {
      await _fetchAllSessions();
      return;
    }
    final server =
        serverProvider.servers.where((x) => x.id == serverId).firstOrNull;
    if (server == null) return;

    if (mounted) setState(() => _error = null);
    try {
      if (!proxyClient.isConnected) {
        await proxyClient.connect();
        await proxyClient.whenConnected
            .timeout(const Duration(seconds: 15));
      }
      await proxyClient.connectServer(
        serverId,
        username: server.username,
        password: server.password,
        profile: server.profile,
      );
      final update = await proxyClient.requestSessions(serverId,
          timeout: const Duration(seconds: 8));
      final sessions = (update['sessions'] as List? ?? [])
          .map<SessionSnapshot>(
              (x) => SessionSnapshot.fromJson(x as Map<String, dynamic>))
          .toList();
      print('[FETCH1] Got ${sessions.length} for $serverId');
      if (quiet) _detectChanges(serverId, sessions);
      if (mounted) {
        setState(() {
          _serverSessions[serverId] = sessions;
          _loading = false;
        });
      }
      serverProvider.setServerOnline(serverId, true);
    } catch (e) {
      print('[FETCH1] failed $serverId: $e');
      if (mounted && !quiet) {
        setState(() {
          _serverSessions[serverId] = [];
          _loading = false;
          _error = 'Server $serverId: $e';
        });
      }
      serverProvider.setServerOnline(serverId, false);
    }
  }

  /// Compare a fresh poll against the previous one and alert the user about
  /// sessions that just stopped or started waiting for input.
  void _detectChanges(String serverId, List<SessionSnapshot> fresh) {
    final previous = _serverSessions[serverId];
    if (previous == null || previous.isEmpty) return;

    final prevMap = {for (final s in previous) s.id: s};
    final freshIds = fresh.map((s) => s.id).toSet();

    final stopped = <SessionSnapshot>[];
    final needsInput = <SessionSnapshot>[];

    for (final snap in fresh) {
      final prev = prevMap[snap.id];
      if (prev == null) continue;
      if (prev.state != snap.state) {
        if (snap.state == SessionState.stopped) stopped.add(snap);
        if (snap.state == SessionState.pending) needsInput.add(snap);
      }
    }
    // Sessions that vanished from the listing are treated as stopped.
    for (final snap in previous) {
      if (!freshIds.contains(snap.id)) stopped.add(snap);
    }

    for (final s in stopped) {
      if (!_alerted.add('$serverId:${s.id}:stopped')) continue;
      _notify('Session finished', s.title, serverId);
    }
    for (final s in needsInput) {
      if (!_alerted.add('$serverId:${s.id}:pending')) continue;
      _notify('Session needs input', s.title, serverId);
    }
  }

  void _notify(String title, String body, String serverId) {
    if (!mounted) return;
    final name = context.read<ServerProvider>().servers
        .where((x) => x.id == serverId)
        .firstOrNull
        ?.name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$title${name != null ? ' ($name)' : ''}: $body'),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  bool _fetchingAll = false;

  Future<void> _fetchAllSessions() async {
    if (_fetchingAll) return;
    _fetchingAll = true;
    try {
      await _doFetchAllSessions();
    } finally {
      _fetchingAll = false;
    }
  }

  Future<void> _doFetchAllSessions() async {
    final serverProvider = context.read<ServerProvider>();
    final globalConfig = context.read<GlobalConfigProvider>();
    
    if (serverProvider.servers.isEmpty) return;
    if (!globalConfig.isProxyMode) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      reader_proxy.ProxyClient? proxyClient;
      
      print('[FETCH] Starting to wait for proxy client...');
      
      // Wait for proxy client to be available (up to 30 seconds)
      for (int i = 0; i < 300; i++) {
        final sessionProvider = context.read<SessionProvider>();
        proxyClient = sessionProvider.proxyClient;
        if (proxyClient != null) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }
      
      print('[FETCH] Proxy client found: ${proxyClient != null}');
      
      if (proxyClient != null) {
        // Wait for proxy client to be connected
        print('[FETCH] Waiting for whenConnected...');
        await proxyClient.whenConnected.timeout(const Duration(seconds: 15));
        print('[FETCH] Proxy client connected, fetching sessions...');
        if (mounted) setState(() => _loading = false);
        
        // Fetch servers SEQUENTIALLY (the proxy multiplexes one WS connection,
        // concurrent polls drop responses) but update the UI incrementally so a
        // slow server never hides already-loaded results.
        for (final server in serverProvider.servers) {
          try {
            print('[FETCH] Connecting to server ${server.id}...');
            await proxyClient!.connectServer(
              server.id,
              username: server.username,
              password: server.password,
              profile: server.profile,
            );
            print('[FETCH] Requesting sessions for server ${server.id}...');
            final update = await proxyClient.requestSessions(server.id,
                timeout: const Duration(seconds: 6));
            final sessions = (update['sessions'] as List? ?? [])
                .map<SessionSnapshot>((s) => SessionSnapshot.fromJson(s as Map<String, dynamic>))
                .toList();
            print('[FETCH] Got ${sessions.length} sessions for server ${server.id}');
            if (sessions.isNotEmpty) {
              final l = update['sessions'] as List;
              print('[RAW] n=${l.length} first=${jsonEncode(l.first)}');
              print('[RAW] last3=${l.reversed.take(3).map((e)=>e['last_active']).toList()}');
              for (final x in l.take(3)) {
                final p = SessionSnapshot.fromJson(x as Map<String,dynamic>);
                print('[RAW] id=${p.id} t=${p.lastActivity} st=${p.state}');
              }
            }
            if (mounted) {
              setState(() {
                _serverSessions[server.id] = sessions;
                _loading = false;
              });
            }
            serverProvider.setServerOnline(server.id, true);
          } catch (e) {
            debugPrint('Failed to fetch sessions for ${server.name}: $e');
            if (mounted) {
              setState(() {
                _serverSessions[server.id] = [];
                _loading = false;
              });
            }
            serverProvider.setServerOnline(server.id, false);
          }
        }
      } else {
        final baseUrl = globalConfig.config.proxyAdminUrl;
        final token = globalConfig.config.proxyAuthToken;
        final limit = int.tryParse(widget.sessionLimit) ?? 10;
        
        for (final server in serverProvider.servers) {
          try {
            final resp = await http.get(
              Uri.parse('$baseUrl/api/hermes/sessions?server_id=${server.id}&limit=$limit'),
              headers: {'Authorization': 'Bearer $token'},
            ).timeout(const Duration(seconds: 10));

            if (resp.statusCode == 200) {
              final data = jsonDecode(resp.body);
              final sessions = (data is List ? data : data['sessions'] ?? [])
                  .map<SessionSnapshot>((s) => SessionSnapshot.fromJson(s as Map<String, dynamic>))
                  .toList();
              _serverSessions[server.id] = sessions;
            }
          } catch (e) {
            debugPrint('Failed to fetch sessions for ${server.name}: $e');
            _serverSessions[server.id] = [];
          }
        }
      }

      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverProvider = context.watch<ServerProvider>();
    final theme = Theme.of(context);

    if (serverProvider.servers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.dns_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('暂无服务器', style: TextStyle(color: theme.disabledColor)),
            const SizedBox(height: 8),
            Text('请在菜单中添加服务器', style: TextStyle(color: theme.disabledColor, fontSize: 12)),
          ],
        ),
      );
    }

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            Text('获取会话失败', style: TextStyle(color: theme.disabledColor)),
            Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchAllSessions,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    // Show only the currently selected server's sessions.
    final activeServer =
        serverProvider.activeServer ?? serverProvider.servers.firstOrNull;
    if (activeServer == null) {
      return const Center(child: Text('No server selected'));
    }
    final all = List<SessionSnapshot>.from(
        _serverSessions[activeServer.id] ?? const <SessionSnapshot>[]);
    // Most recently active first, so live sessions surface at the top.
    all.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
    final sessions = all;

    if (sessions.isEmpty) {
      return RefreshIndicator(
        onRefresh: _fetchAllSessions,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.inbox, size: 48, color: Colors.grey),
                    const SizedBox(height: 16),
                    Text('No sessions on ${activeServer.name}',
                        style: TextStyle(color: theme.disabledColor)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _fetchAllSessions,
                      child: const Text('Refresh'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final shown = _onlyActive
        ? sessions.where((x) => x.state == SessionState.running).toList()
        : sessions;

    if (shown.isEmpty && _onlyActive) {
      return RefreshIndicator(
        onRefresh: _fetchAllSessions,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.6,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.check_circle_outline, size: 48, color: Colors.grey),
                    const SizedBox(height: 16),
                    const Text('No running sessions'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () => setState(() => _onlyActive = false),
                      child: const Text('Show all'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAllSessions,
      child: ListView.builder(
        itemCount: shown.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: theme.colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  Icon(
                    activeServer.isOnline ? Icons.cloud_done : Icons.cloud_off,
                    size: 16,
                    color: activeServer.isOnline ? Colors.green : Colors.grey,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(activeServer.name,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  Text('${shown.length} sessions',
                      style: TextStyle(color: theme.disabledColor, fontSize: 12)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => setState(() => _onlyActive = !_onlyActive),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _onlyActive
                              ? Icons.check_box
                              : Icons.check_box_outline_blank,
                          size: 16,
                          color: _onlyActive
                              ? theme.colorScheme.primary
                              : Colors.grey,
                        ),
                        const SizedBox(width: 2),
                        const Text('Active', style: TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }
          final s = shown[index - 1];
          final running = s.state == SessionState.running;
          return ListTile(
            leading: Icon(
              running
                  ? Icons.play_circle
                  : s.state == SessionState.stopped
                      ? Icons.stop_circle
                      : s.state == SessionState.pending
                          ? Icons.help_outline
                          : Icons.error,
              color: running
                  ? Colors.green
                  : s.state == SessionState.stopped
                      ? Colors.grey
                      : s.state == SessionState.pending
                          ? Colors.orange
                          : Colors.red,
            ),
            title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text(_formatTime(s.lastActivity)),
            trailing: Text(s.state.name, style: const TextStyle(fontSize: 11)),
          );
        },
      ),
    );
  }

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  Widget _oldBuild(BuildContext context) {
    final serverProvider = context.watch<ServerProvider>();
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _fetchAllSessions,
      child: ListView.builder(
        itemCount: serverProvider.servers.length,
        itemBuilder: (context, index) {
          final server = serverProvider.servers[index];
          final sessions = _serverSessions[server.id] ?? [];

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: theme.colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    Icon(
                      server.isOnline ? Icons.cloud_done : Icons.cloud_off,
                      size: 16,
                      color: server.isOnline ? Colors.green : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(server.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Text('${sessions.length} 个会话', style: TextStyle(color: theme.disabledColor, fontSize: 12)),
                  ],
                ),
              ),
              ...sessions.map((s) => ListTile(
                leading: Icon(
                  s.state == SessionState.running ? Icons.play_circle :
                  s.state == SessionState.stopped ? Icons.stop_circle :
                  s.state == SessionState.pending ? Icons.help_outline :
                  Icons.error,
                  color: s.state == SessionState.running ? Colors.green :
                         s.state == SessionState.stopped ? Colors.grey :
                         s.state == SessionState.pending ? Colors.orange : Colors.red,
                ),
                title: Text(s.title),
                subtitle: Text('${s.lastActivity}'),
                trailing: Text(s.state.name, style: const TextStyle(fontSize: 11)),
              )),
            ],
          );
        },
      ),
    );
  }
}

/// Connection dialog that tests connectivity and fetches servers
class _ConnectionDialog extends StatefulWidget {
  final Map<String, String> config;
  final Future<void> Function(String proxyUrl, String token, List<dynamic> servers) onConnected;
  final void Function(String error) onFailed;
  final VoidCallback onCancel;

  const _ConnectionDialog({
    required this.config,
    required this.onConnected,
    required this.onFailed,
    required this.onCancel,
  });

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  String _status = '正在连接...';
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final wsUrl = widget.config['ws_url'] ?? '';
    final token = widget.config['token'] ?? '';

    if (_cancelled) return;

    setState(() => _status = '正在测试连通性...');

    try {
      // Test connectivity via WebSocket DI protocol
      final proxyClient = reader_proxy.ProxyClient(
        proxyUrl: wsUrl,
        authToken: token,
      );
      
      await proxyClient.connect();
      
      if (_cancelled) return;

      setState(() => _status = '正在获取服务器列表...');

      // Fetch servers via DI protocol
      List<Map<String, dynamic>> servers = [];
      try {
        servers = await proxyClient.fetchServersDI();
      } catch (e) {
        debugPrint('Failed to fetch servers via DI: $e');
      }

      if (_cancelled) return;

      // Extract proxy URL from ws_url (strip /ws path)
      String proxyUrl = wsUrl;
      if (proxyUrl.contains('/ws')) {
        proxyUrl = proxyUrl.replaceAll('/ws', '');
      }

      print('[DIALOG] About to call onConnected, servers=${servers.length}');
      await widget.onConnected(proxyUrl, token, servers);
      print('[DIALOG] onConnected call returned');

    } catch (e) {
      if (_cancelled) return;
      widget.onFailed(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('连接'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_status),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancelled = true;
            widget.onCancel();
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _UnavailableServerTts implements SpeechSource {
  @override
  SpeechEngine get engine => SpeechEngine.server;

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<void> speak(String text) async {
    throw Exception('server TTS not configured yet');
  }

  @override
  Future<void> stop() async {}

  @override
  void setProgressHandler(NarrationProgressHandler? handler) {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async {}
}
