import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'computer_use_tools.dart';
import 'network_proxy.dart';

class ComputerUseRuntimePaths {
  final String helperPath;
  final String codexCliPath;
  final String codexHome;
  final String? skyVersion;

  const ComputerUseRuntimePaths({
    required this.helperPath,
    required this.codexCliPath,
    required this.codexHome,
    this.skyVersion,
  });
}

class ComputerUseRuntimeLocator {
  const ComputerUseRuntimeLocator();

  Future<ComputerUseRuntimePaths> locate() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Computer Use currently supports Windows only');
    }

    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    final codexHome = _nonEmpty(Platform.environment['CODEX_HOME']) ?? p.join(home, '.codex');
    final configFile = File(p.join(codexHome, 'config.toml'));
    final config = await _readConfig(configFile);

    final moduleDirs = <String>{};
    final envModuleDirs = _nonEmpty(Platform.environment['NODE_REPL_NODE_MODULE_DIRS']);
    final configModuleDirs = _nonEmpty(config['NODE_REPL_NODE_MODULE_DIRS']);
    for (final raw in [envModuleDirs, configModuleDirs]) {
      if (raw == null) continue;
      moduleDirs.addAll(raw.split(';').map((item) => item.trim()).where((item) => item.isNotEmpty));
    }

    String? helperPath;
    String? skyVersion;
    for (final modules in moduleDirs) {
      final candidate = p.join(modules, '@oai', 'sky', 'bin', 'windows', 'codex-computer-use.exe');
      if (await File(candidate).exists()) {
        helperPath = candidate;
        skyVersion = await _readSkyVersion(p.join(modules, '@oai', 'sky', 'package.json'));
        break;
      }
    }

    helperPath ??= await _findNewestHelper();
    if (helperPath != null && skyVersion == null) {
      final skyRoot = p.dirname(p.dirname(p.dirname(helperPath)));
      skyVersion = await _readSkyVersion(p.join(skyRoot, 'package.json'));
    }

    var codexCliPath =
        _nonEmpty(Platform.environment['CODEX_CLI_PATH']) ?? _nonEmpty(config['CODEX_CLI_PATH']);
    if (codexCliPath == null || !await File(codexCliPath).exists()) {
      codexCliPath = await _findNewestCodexCli();
    }

    if (helperPath == null || !await File(helperPath).exists()) {
      throw Exception('未检测到 Codex Computer Use runtime，请安装或更新 Codex 桌面版');
    }
    if (codexCliPath == null || !await File(codexCliPath).exists()) {
      throw Exception('未检测到 Codex CLI app-server，请安装或更新 Codex 桌面版');
    }

    return ComputerUseRuntimePaths(
      helperPath: helperPath,
      codexCliPath: codexCliPath,
      codexHome: codexHome,
      skyVersion: skyVersion,
    );
  }

  Future<Map<String, String>> _readConfig(File file) async {
    if (!await file.exists()) return const {};
    try {
      final values = <String, String>{};
      for (final raw in (await file.readAsString()).replaceAll('\r\n', '\n').split('\n')) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) continue;
        final equals = line.indexOf('=');
        if (equals <= 0) continue;
        final key = line.substring(0, equals).trim();
        if (key != 'CODEX_CLI_PATH' && key != 'NODE_REPL_NODE_MODULE_DIRS') continue;
        final value = _unquoteToml(line.substring(equals + 1).trim());
        if (value.isNotEmpty) values[key] = value;
      }
      return values;
    } catch (_) {
      return const {};
    }
  }

  String _unquoteToml(String value) {
    if (value.length < 2) return value;
    if (value.startsWith("'") && value.endsWith("'")) {
      return value.substring(1, value.length - 1).replaceAll("''", "'");
    }
    if (value.startsWith('"') && value.endsWith('"')) {
      return value.substring(1, value.length - 1).replaceAll('\\\\', '\\').replaceAll(r'\"', '"');
    }
    return value;
  }

  Future<String?> _findNewestHelper() async {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    final root = Directory(p.join(local, 'OpenAI', 'Codex', 'runtimes', 'cua_node'));
    if (!await root.exists()) return null;

    final candidates = <File>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final file = File(
          p.join(
            entity.path,
            'bin',
            'node_modules',
            '@oai',
            'sky',
            'bin',
            'windows',
            'codex-computer-use.exe',
          ),
        );
        if (await file.exists()) candidates.add(file);
      }
    } catch (_) {}
    return _newest(candidates);
  }

  Future<String?> _findNewestCodexCli() async {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    final root = Directory(p.join(local, 'OpenAI', 'Codex', 'bin'));
    if (!await root.exists()) return null;

    final candidates = <File>[];
    try {
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! Directory) continue;
        final file = File(p.join(entity.path, 'codex.exe'));
        if (await file.exists()) candidates.add(file);
      }
    } catch (_) {}
    return _newest(candidates);
  }

  Future<String?> _newest(List<File> candidates) async {
    if (candidates.isEmpty) return null;
    candidates.sort((left, right) {
      try {
        return right.lastModifiedSync().compareTo(left.lastModifiedSync());
      } catch (_) {
        return 0;
      }
    });
    return candidates.first.path;
  }

  Future<String?> _readSkyVersion(String packageJsonPath) async {
    final file = File(packageJsonPath);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map && decoded['version'] is String) return decoded['version'] as String;
    } catch (_) {}
    return null;
  }

  String? _nonEmpty(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _ScreenshotBinding {
  final String nativeId;
  final String windowKey;

  const _ScreenshotBinding({required this.nativeId, required this.windowKey});
}

class ComputerUseClient {
  final ComputerUseRuntimeLocator locator;

  ComputerUseClient({this.locator = const ComputerUseRuntimeLocator()});

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<String, _ScreenshotBinding> _screenshotBindings = {};
  int _nextId = 1;
  int _screenshotGeneration = 0;
  bool _closing = false;

  ComputerUseRuntimePaths? runtimePaths;
  String? lastError;

  bool get isRunning => _process != null && !_closing;

  Future<void> start() async {
    if (isRunning) return;
    _closing = false;
    lastError = null;
    _screenshotBindings.clear();
    final paths = await locator.locate();
    runtimePaths = paths;

    final child = await Process.start(
      paths.helperPath,
      ['--parent-pid', '$pid'],
      workingDirectory: p.dirname(paths.helperPath),
      environment: NetworkProxy.processEnvironment(
        overrides: {'CODEX_CLI_PATH': paths.codexCliPath, 'CODEX_HOME': paths.codexHome},
      ),
    );
    _process = child;
    _stdoutSub = child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _handleStdoutLine,
          onError: (Object error) => _failPending(Exception('Computer Use stdout failed: $error')),
        );
    _stderrSub = child.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true).trim();
      if (text.isNotEmpty) lastError = text;
    });
    child.exitCode.then((code) {
      if (!identical(_process, child)) return;
      _process = null;
      _screenshotBindings.clear();
      if (!_closing) {
        final message = lastError == null || lastError!.isEmpty
            ? 'Computer Use helper exited with code $code'
            : 'Computer Use helper exited with code $code: $lastError';
        lastError = message;
        _failPending(Exception(message));
      }
    });

    try {
      await request('list_windows', const {}, timeoutMs: 15000);
    } catch (_) {
      await close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> callTool(
    String toolName,
    Map<String, dynamic> arguments, {
    int timeoutMs = 60000,
  }) async {
    if (!isComputerUseTool(toolName)) {
      throw ArgumentError('Unknown Computer Use tool: $toolName');
    }
    if (!isRunning) await start();

    if (toolName == 'end_turn') {
      await endTurn();
      return _renderGenericResult(null);
    }

    final params = Map<String, dynamic>.from(arguments);
    if (!(toolName == 'click' && params['element_index'] != null)) {
      _resolveScreenshotToken(params);
    }

    late final dynamic result;
    if (toolName == 'click' && params['element_index'] != null) {
      result = await request('click_element', {
        'window': params['window'],
        'element_index': params['element_index'],
        'click_count': params['click_count'] ?? 1,
        'mouse_button': params['mouse_button'] ?? 'left',
      }, timeoutMs: timeoutMs);
    } else {
      result = await request(toolName, params, timeoutMs: timeoutMs);
    }

    if (toolName == 'get_window_state' && result is Map) {
      return _renderWindowState(
        result.cast<String, dynamic>(),
        requestedWindow: params['window'],
        replaceScreenshotBindings: params['include_screenshot'] != false,
      );
    }
    return _renderGenericResult(result);
  }

  /// 结束当前 Computer Use 操作轮次，但保留可复用的 helper 进程。
  /// 同时清理临时截图和输入状态，使桌面退出当前 Computer Use 模式。
  Future<void> endTurn() async {
    _screenshotBindings.clear();
    if (!isRunning) return;
    try {
      await _send('end_turn', const {}, timeoutMs: 2000);
    } catch (error) {
      lastError = 'Computer Use end_turn failed: $error';
      rethrow;
    }
  }

  Future<dynamic> request(
    String method,
    Map<String, dynamic> params, {
    int timeoutMs = 10000,
  }) async {
    if (!isRunning) throw StateError('Computer Use helper is not running');

    Map<String, dynamic>? meta;
    for (var attempt = 0; attempt < 4; attempt++) {
      final response = await _send(method, params, meta: meta, timeoutMs: timeoutMs);
      if (response['ok'] == true) return response['result'];

      final rawApproval = response['approvalRequest'];
      if (rawApproval is Map) {
        final approval = rawApproval.cast<String, dynamic>();
        final app = '${approval['app'] ?? ''}'.trim();
        if (app.isEmpty) throw Exception('Computer Use returned an invalid approval request');
        // Codexter 是远程 ChatGPT MCP 服务，不能在桌面侧阻塞等待交互确认。
        // helper 的 approvalRequest 是调用方协议确认，不是 Windows 强制授权；
        // 按 Sky 的协议附带已批准应用并立即重试即可继续执行。
        meta = {...?meta, 'x-oai-cua-approved-app': app};
        continue;
      }

      final error = response['error'];
      throw Exception(error == null ? 'Computer Use request failed: $method' : '$error');
    }
    throw Exception('Computer Use approval loop exceeded for $method');
  }

  Future<Map<String, dynamic>> _send(
    String method,
    Map<String, dynamic> params, {
    Map<String, dynamic>? meta,
    required int timeoutMs,
  }) async {
    final child = _process;
    if (child == null) throw StateError('Computer Use helper is not running');
    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    final payload = <String, dynamic>{
      'id': id,
      'method': method,
      'params': params,
      if (meta != null && meta.isNotEmpty) 'meta': meta,
    };
    child.stdin.write('${jsonEncode(payload)}\n');
    await child.stdin.flush();

    return completer.future.timeout(
      Duration(milliseconds: timeoutMs),
      onTimeout: () {
        _pending.remove(id);
        throw TimeoutException('Computer Use $method timed out');
      },
    );
  }

  void _handleStdoutLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) return;
      message = decoded.cast<String, dynamic>();
    } catch (_) {
      lastError = 'Computer Use emitted invalid JSON';
      return;
    }

    final rawId = message['id'];
    final id = rawId is int ? rawId : int.tryParse('$rawId');
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    completer.complete(message);
  }

  Map<String, dynamic> _renderWindowState(
    Map<String, dynamic> state, {
    required dynamic requestedWindow,
    required bool replaceScreenshotBindings,
  }) {
    final sanitized = Map<String, dynamic>.from(state);
    final content = <Map<String, dynamic>>[];
    final screenshots = <Map<String, dynamic>>[];
    final rawScreenshots = state['screenshots'];
    final windowKey = _windowKey(state['window'] ?? requestedWindow);
    final hasReturnedScreenshots =
        rawScreenshots is List && rawScreenshots.any((item) => item is Map);
    final shouldReplaceBindings = replaceScreenshotBindings || hasReturnedScreenshots;
    if (shouldReplaceBindings) {
      _screenshotBindings.clear();
    }
    final generation = shouldReplaceBindings ? ++_screenshotGeneration : _screenshotGeneration;
    if (rawScreenshots is List) {
      var index = 0;
      for (final item in rawScreenshots) {
        if (item is! Map) continue;
        final shot = item.cast<String, dynamic>();
        final url = shot['url'];
        final nativeId = '${shot['id'] ?? 'screenshot-$index'}';
        final token = 'codexter-shot-$generation-$index';
        if (shouldReplaceBindings) {
          _screenshotBindings[token] = _ScreenshotBinding(nativeId: nativeId, windowKey: windowKey);
        }
        final metadata = Map<String, dynamic>.from(shot)
          ..remove('url')
          ..['id'] = token;
        screenshots.add(metadata);
        if (url is String) {
          final image = _imageContent(url);
          if (image != null) content.add(image);
        }
        index++;
      }
    }
    sanitized['screenshots'] = screenshots;
    final text = const JsonEncoder.withIndent('  ').convert(sanitized);
    content.insert(0, {'type': 'text', 'text': text});
    return {
      'content': content,
      'structuredContent': {...sanitized, 'text': text},
    };
  }

  void _resolveScreenshotToken(Map<String, dynamic> params) {
    final raw = params['screenshotId'];
    if (raw is! String || raw.trim().isEmpty) return;
    final screenshotId = raw.trim();
    final windowKey = _windowKey(params['window']);
    final binding = _screenshotBindings[screenshotId];
    if (binding != null) {
      if (binding.windowKey != windowKey) {
        throw Exception(
          'stale screenshotId $screenshotId: it belongs to a different window. '
          'Call get_window_state for the target window again and use the newly returned screenshot id.',
        );
      }
      params['screenshotId'] = binding.nativeId;
      return;
    }

    final rawMatches = _screenshotBindings.values
        .where((item) => item.nativeId == screenshotId && item.windowKey == windowKey)
        .toList();
    if (rawMatches.length == 1) {
      params['screenshotId'] = rawMatches.single.nativeId;
      return;
    }

    throw Exception(
      'stale or unknown screenshotId $screenshotId. Computer Use screenshot ids are valid only '
      'for the latest get_window_state observation. Call get_window_state again and use the newly returned id.',
    );
  }

  String _windowKey(dynamic window) {
    if (window is! Map) return '';
    return '${window['app'] ?? ''}\u0000${window['id'] ?? ''}';
  }

  Map<String, dynamic> _renderGenericResult(dynamic result) {
    final text = result == null ? 'OK' : const JsonEncoder.withIndent('  ').convert(result);
    final structured = result is Map<String, dynamic>
        ? <String, dynamic>{...result, 'text': text}
        : <String, dynamic>{'text': text};
    if (result != null && result is! Map<String, dynamic>) {
      structured['result'] = result;
    }
    return {
      'content': [
        {'type': 'text', 'text': text},
      ],
      'structuredContent': structured,
    };
  }

  Map<String, dynamic>? _imageContent(String dataUrl) {
    final comma = dataUrl.indexOf(',');
    if (comma <= 0) return null;
    final header = dataUrl.substring(0, comma);
    if (!header.startsWith('data:') || !header.contains(';base64')) return null;
    final mimeType = header.substring(5, header.indexOf(';'));
    final data = dataUrl.substring(comma + 1);
    if (mimeType.isEmpty || data.isEmpty) return null;
    return {'type': 'image', 'data': data, 'mimeType': mimeType};
  }

  Future<void> close() async {
    final child = _process;
    if (child == null) return;
    _closing = true;
    try {
      try {
        await _send('close', const {}, timeoutMs: 1500);
      } catch (_) {}
      try {
        child.kill(ProcessSignal.sigterm);
      } catch (_) {}
      await _stdoutSub?.cancel();
      await _stderrSub?.cancel();
    } finally {
      _stdoutSub = null;
      _stderrSub = null;
      if (identical(_process, child)) _process = null;
      _screenshotBindings.clear();
      _failPending(Exception('Computer Use helper closed'));
      _closing = false;
    }
  }

  void _failPending(Object error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) completer.completeError(error);
    }
  }
}
