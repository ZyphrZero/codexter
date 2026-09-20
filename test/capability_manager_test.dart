import 'dart:io';

import 'package:codexter/services/capability_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('导入 Codex HTTP MCP 的直接请求头', () async {
    final temp = await Directory.systemTemp.createTemp('codex_capability_manager_');
    try {
      await File(p.join(temp.path, 'config.toml')).writeAsString('''
[mcp_servers.apipost-mcp]
url = "https://open.apipost.net/mcp"

[mcp_servers.apipost-mcp.http_headers]
api-token = "secret-token"
x-client = "codexter-test"
''');

      final mcps = await CapabilityManager(codexDir: temp.path).scanCodexMcps();

      expect(mcps, hasLength(1));
      expect(mcps.single.transport, {
        'url': 'https://open.apipost.net/mcp',
        'headers': {
          'api-token': 'secret-token',
          'x-client': 'codexter-test',
        },
      });
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('导入 Codex 环境变量请求头且忽略缺失变量', () async {
    final temp = await Directory.systemTemp.createTemp('codex_capability_manager_');
    final pathValue = Platform.environment['PATH'];
    if (pathValue == null || pathValue.isEmpty) {
      await temp.delete(recursive: true);
      return;
    }

    try {
      await File(p.join(temp.path, 'config.toml')).writeAsString('''
[mcp_servers.env-header]
url = "https://example.com/mcp"

[mcp_servers.env-header.env_http_headers]
x-path = "PATH"
x-missing = "CODEXTER_TEST_MISSING_HEADER"
''');

      final mcps = await CapabilityManager(codexDir: temp.path).scanCodexMcps();

      final headers = (mcps.single.transport['headers'] as Map).cast<String, String>();
      expect(headers['x-path'], pathValue);
      expect(headers.containsKey('x-missing'), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  });

  test('导入请求头不会改变 stdio MCP 的环境变量', () async {
    final temp = await Directory.systemTemp.createTemp('codex_capability_manager_');
    try {
      await File(p.join(temp.path, 'config.toml')).writeAsString('''
[mcp_servers.local]
type = "stdio"
command = "node"

[mcp_servers.local.env]
API_MODE = "test"
''');

      final mcps = await CapabilityManager(codexDir: temp.path).scanCodexMcps();

      expect(mcps.single.transport, {
        'command': 'node',
        'env': {'API_MODE': 'test'},
      });
    } finally {
      await temp.delete(recursive: true);
    }
  });
}
