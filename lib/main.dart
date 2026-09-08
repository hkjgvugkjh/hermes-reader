import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:hermes_shared/hermes_shared.dart';
import 'reader/providers/library_provider.dart';
import 'reader/providers/session_provider.dart';
import 'reader/providers/task_provider.dart';
import 'reader/providers/global_config_provider.dart';
import 'reader/providers/server_provider.dart';
import 'reader/services/library_service.dart';
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
        ChangeNotifierProvider(create: (_) => ReaderProvider()),
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

/// Startup screen that checks configuration and connection.
class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key});

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  bool _checking = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _checkConfig();
  }

  Future<void> _checkConfig() async {
    final globalConfig = context.read<GlobalConfigProvider>();
    await globalConfig.load();

    if (!mounted) return;

    if (globalConfig.config.proxyUrl.isEmpty) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen(mode: AppMode.local)),
      );
      return;
    }

    // Has config -> try to connect
    setState(() => _checking = true);

    try {
      final proxyClient = reader_proxy.ProxyClient(
        proxyUrl: globalConfig.config.proxyWsUrl,
        authToken: globalConfig.config.proxyAuthToken,
      );
      await proxyClient.connect();
      
      if (!mounted) return;

      // Fetch servers from proxy
      final servers = await proxyClient.fetchServers();
      if (mounted) {
        final serverProvider = context.read<ServerProvider>();
        serverProvider.setServers(servers);
      }

      if (!mounted) return;

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen(mode: AppMode.online)),
      );
    } catch (e) {
      // Silently handle connection errors - don't show error to user
      debugPrint('Startup connection check failed: $e');
      
      if (!mounted) return;
      
      // Silently fall back to local mode
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen(mode: AppMode.local)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              _checking ? '正在检测配置...' : '连接失败',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
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

  @override
  void initState() {
    super.initState();
    _currentMode = widget.mode;
  }

  /// Scan QR code and connect
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

    // Show connection dialog
    _showConnectionDialog(config);
  }

  /// Show connection dialog with progress
  void _showConnectionDialog(Map<String, String> config) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _ConnectionDialog(
        config: config,
        onConnected: (proxyUrl, token, servers) {
          Navigator.pop(ctx);
          _onConnected(proxyUrl, token, servers);
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

  /// Called when connection is successful
  void _onConnected(String proxyUrl, String token, List<Map<String, dynamic>> servers) {
    // Save config
    final globalConfig = context.read<GlobalConfigProvider>();
    globalConfig.updateConfig(GlobalConfig(
      mode: ConnectionMode.hermesProxy,
      proxyUrl: proxyUrl,
      proxyAuthToken: token,
    ));

    // Save servers
    final serverProvider = context.read<ServerProvider>();
    serverProvider.setServers(servers);

    // Switch to online mode
    setState(() {
      _currentMode = AppMode.online;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已连接')),
    );
  }

  /// Switch to a specific server
  void _switchServer(String? serverId) {
    if (serverId == null) {
      // Switch to local mode
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
  }

  /// Disconnect and return to local mode
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

  void _showConfigAndScan() {
    final globalConfig = context.read<GlobalConfigProvider>();
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

  void _showEditConfigDialog(String currentUrl, String currentToken) {
    final urlController = TextEditingController(text: currentUrl);
    final tokenController = TextEditingController(text: currentToken);
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑配置'),
        content: Column(
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
          ],
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
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('配置已保存')),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  void _openConfig() {
    final globalConfig = context.read<GlobalConfigProvider>();
    if (globalConfig.config.proxyUrl.isEmpty) {
      _showManualConfigDialog();
    } else {
      _showConfigAndScan();
    }
  }

  void _showManualConfigDialog() {
    final urlController = TextEditingController();
    final tokenController = TextEditingController();
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接入配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: '代理地址',
                hintText: 'https://proxy.example.com:8080',
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
          ],
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
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('配置已保存')),
              );
            },
            child: const Text('保存'),
          ),
        ],
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

  void _showMenu() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('菜单', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('接入配置'),
              subtitle: Text(context.read<GlobalConfigProvider>().config.proxyUrl.isEmpty 
                  ? '未配置' 
                  : '已配置: ${context.read<GlobalConfigProvider>().config.proxyUrl}'),
              onTap: () {
                Navigator.pop(ctx);
                _openConfig();
              },
            ),
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
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const SessionMonitorScreen(),
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
                items: [
                  const DropdownMenuItem<String>(
                    value: '__local__',
                    child: Text('本地'),
                  ),
                  ...serverProvider.servers.map((s) => DropdownMenuItem<String>(
                    value: s.id,
                    child: Text(s.name),
                  )),
                ],
                onChanged: (value) {
                  if (value == '__local__') {
                    _switchServer(null);
                  } else {
                    _switchServer(value);
                  }
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
            // Left: Menu button (always visible)
            IconButton(
              onPressed: _showMenu,
              icon: const Icon(Icons.menu),
              tooltip: '菜单',
            ),
            const Spacer(),
            // Right: Shortcut area for apps
            IconButton(
              onPressed: _openEbook,
              icon: const Icon(Icons.menu_book),
              tooltip: '电子书',
            ),
            IconButton(
              onPressed: () => setState(() => _pageIndex = 0),
              icon: const Icon(Icons.monitor_heart),
              tooltip: '会话监控',
            ),
            IconButton(
              onPressed: () => setState(() => _pageIndex = 1),
              icon: const Icon(Icons.assignment),
              tooltip: '待办事项',
            ),
          ],
        ),
      ),
    );
  }
}

/// Connection dialog that tests connectivity and fetches servers
class _ConnectionDialog extends StatefulWidget {
  final Map<String, String> config;
  final void Function(String proxyUrl, String token, List<Map<String, dynamic>> servers) onConnected;
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
    final adminUrl = widget.config['admin_url'] ?? '';

    if (_cancelled) return;

    // Parse admin URL to get base URL
    String baseUrl = adminUrl;
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }

    setState(() => _status = '正在测试连通性...');

    try {
      // Test connectivity via /health
      final healthUrl = baseUrl.replaceAll('/api/config', '/health').replaceAll('/ws', '');
      final healthResponse = await http.get(Uri.parse(healthUrl)).timeout(
        const Duration(seconds: 10),
      );
      
      if (_cancelled) return;

      if (healthResponse.statusCode != 200) {
        widget.onFailed('服务器返回 HTTP ${healthResponse.statusCode}');
        return;
      }

      setState(() => _status = '正在验证 Token...');

      // Test token validity
      final configResponse = await http.get(
        Uri.parse('$baseUrl/api/config'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      if (_cancelled) return;

      if (configResponse.statusCode == 401) {
        widget.onFailed('Token 无效（401 Unauthorized）');
        return;
      }

      if (configResponse.statusCode != 200) {
        widget.onFailed('Token 验证失败: HTTP ${configResponse.statusCode}');
        return;
      }

      setState(() => _status = '正在获取服务器列表...');

      // Fetch servers
      final serversResponse = await http.get(
        Uri.parse('$baseUrl/api/servers'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 10));

      if (_cancelled) return;

      List<Map<String, dynamic>> servers = [];
      if (serversResponse.statusCode == 200) {
        final data = jsonDecode(serversResponse.body);
        if (data is Map && data['servers'] is List) {
          servers = (data['servers'] as List).map((s) => s as Map<String, dynamic>).toList();
        }
      }

      if (_cancelled) return;

      // Extract proxy URL from admin URL
      String proxyUrl = adminUrl;
      if (proxyUrl.contains('/ws')) {
        proxyUrl = proxyUrl.replaceAll('/ws', '');
      }

      widget.onConnected(proxyUrl, token, servers);

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
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async {}
}
