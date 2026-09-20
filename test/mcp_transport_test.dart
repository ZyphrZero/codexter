import 'dart:convert';
import 'dart:io';

import 'package:codexter/mcp/multi_workspace_server.dart';
import 'package:codexter/mcp/ui/mcp_ui_catalog.dart';
import 'package:codexter/models/workspace.dart';
import 'package:codexter/services/capability_runtime.dart';
import 'package:codexter/stores/log_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _HttpResult {
  final int status;
  final String? sessionId;
  final Map<String, dynamic> body;

  const _HttpResult(this.status, this.sessionId, this.body);
}

Future<_HttpResult> _postJson(HttpClient client, Uri uri, Map<String, dynamic> payload) async {
  final request = await client.postUrl(uri);
  request.headers.contentType = ContentType.json;
  request.write(jsonEncode(payload));
  final response = await request.close();
  final text = await utf8.decoder.bind(response).join();
  return _HttpResult(
    response.statusCode,
    response.headers.value('mcp-session-id'),
    jsonDecode(text) as Map<String, dynamic>,
  );
}

void main() {
  test('MCP HTTP transport stays stateless across concurrent clients', () async {
    final temp = await Directory.systemTemp.createTemp('codex_mcp_transport_');
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final server = MultiWorkspaceServer();
    final logs = LogStore();
    final capabilities = CapabilityRuntime();
    final now = DateTime.now();
    final workspace = Workspace(
      uuid: '11111111-1111-4111-8111-111111111111',
      name: 'transport-test',
      projectRoot: temp.path,
      createdAt: now,
      lastActiveAt: now,
    );

    await server.start(host: '127.0.0.1', port: port);
    server.addWorkspace(workspace: workspace, logStore: logs, capabilities: capabilities);

    final client = HttpClient();
    final uri = Uri.parse('http://127.0.0.1:$port/${workspace.uuid}/mcp');

    try {
      final initializeResults = await Future.wait(
        List.generate(12, (index) {
          return _postJson(client, uri, {
            'jsonrpc': '2.0',
            'id': index + 1,
            'method': 'initialize',
            'params': {
              'protocolVersion': '2025-11-25',
              'capabilities': <String, dynamic>{},
              'clientInfo': {'name': 'client-$index', 'version': '1.0'},
            },
          });
        }),
      );

      for (final result in initializeResults) {
        expect(result.status, HttpStatus.ok);
        expect(result.sessionId, isNull);
      }

      // 用真实 HTTP 响应验证两种握手都提供同一份精简说明，工具详情仍由列表返回。
      final discovery = await _postJson(client, uri, {
        'jsonrpc': '2.0',
        'id': 50,
        'method': 'server/discover',
        'params': <String, dynamic>{},
      });
      expect(discovery.status, HttpStatus.ok);
      expect(discovery.body['error'], isNull);
      final instructions = (discovery.body['result'] as Map)['instructions'] as String;
      for (final result in initializeResults) {
        expect((result.body['result'] as Map)['instructions'], instructions);
      }
      expect(instructions, contains(workspace.projectRoot));
      expect(instructions, isNot(contains('Computer Use')));
      expect(instructions, isNot(contains('computer-use')));
      expect(instructions.toLowerCase(), isNot(contains('downstream')));
      expect(instructions, contains('- MCP: mcp_tools, mcp_call.'));
      expect(instructions.length, lessThan(2000));

      final toolList = await _postJson(client, uri, {
        'jsonrpc': '2.0',
        'id': 51,
        'method': 'tools/list',
        'params': <String, dynamic>{},
      });
      expect(toolList.status, HttpStatus.ok);
      expect(toolList.body['error'], isNull);
      final schemas = {
        for (final tool in (toolList.body['result'] as Map)['tools'] as List)
          (tool as Map)['name'] as String: tool,
      };
      expect(schemas, hasLength(14));
      for (final name in schemas.keys) {
        expect(instructions, contains(name), reason: name);
      }
      expect(schemas['exec_command']!['description'], contains('session_id'));
      for (final schema in schemas.values) {
        expect(schema['description'], isNot(contains('Computer Use')));
        final modelDescription = jsonEncode({
          'title': schema['title'],
          'description': schema['description'],
          'inputSchema': schema['inputSchema'],
          'outputSchema': schema['outputSchema'],
        });
        expect(RegExp(r'downstream|下游', caseSensitive: false).hasMatch(modelDescription), isFalse);
      }
      expect(schemas['apply_patch']!['inputSchema'], isA<Map>());
      expect((schemas['mcp_call']!['annotations'] as Map)['readOnlyHint'], isFalse);
      expect((schemas['mcp_tools']!['annotations'] as Map)['readOnlyHint'], isTrue);

      final emptyListing = await _postJson(client, uri, {
        'jsonrpc': '2.0',
        'id': 52,
        'method': 'tools/call',
        'params': {
          'name': 'mcp_tools',
          'arguments': {'purpose': '读取 MCP 服务列表'},
        },
      });
      expect(emptyListing.status, HttpStatus.ok);
      final listing = (emptyListing.body['result'] as Map)['structuredContent'] as Map;
      expect(listing['text'], 'No MCP servers enabled for this workspace.');
      expect(listing['servers'], isEmpty);
      expect(listing['tools'], isEmpty);

      for (final name in ['mcp_tools', 'mcp_call']) {
        final unknownServer = await _postJson(client, uri, {
          'jsonrpc': '2.0',
          'id': 'unknown-$name',
          'method': 'tools/call',
          'params': {
            'name': name,
            'arguments': {
              'purpose': '检查无效 MCP 服务名称',
              'server': 'missing',
              if (name == 'mcp_call') 'tool': 'capture',
            },
          },
        });
        expect(unknownServer.status, HttpStatus.ok);
        final result = unknownServer.body['result'] as Map;
        expect(result['isError'], isTrue);
        expect((result['structuredContent'] as Map)['text'], '$name: Unknown MCP server: missing');
      }

      const uiResourceUri = McpUiCatalog.summaryResourceUri;
      final readResults = await Future.wait(
        List.generate(24, (index) {
          return _postJson(client, uri, {
            'jsonrpc': '2.0',
            'id': 100 + index,
            'method': 'resources/read',
            'params': {'uri': uiResourceUri},
          });
        }),
      );

      for (final result in readResults) {
        expect(result.status, HttpStatus.ok);
        expect(result.sessionId, isNull);
        final rpcResult = result.body['result'] as Map<String, dynamic>;
        final contents = rpcResult['contents'] as List;
        final resource = contents.single as Map<String, dynamic>;
        expect(resource['uri'], uiResourceUri);
        expect(resource['mimeType'], McpUiCatalog.mimeType);
        expect((resource['text'] as String).length, greaterThan(5000));
      }
    } finally {
      client.close(force: true);
      await server.stop();
      await capabilities.shutdown();
      capabilities.dispose();
      logs.dispose();
      await temp.delete(recursive: true);
    }
  });
}
