import '../../services/downstream_client.dart';
import '../../utils/fmt.dart';
import 'registry.dart';
import 'tool_context.dart';

/// 下游 MCP 工具：mcp_tools / mcp_call
class DownstreamTools {
  const DownstreamTools._();

  static void register(ToolRegistry registry, ToolContext context) {
    final capabilities = context.capabilities;

    DownstreamClient requireClient(String name) {
      final client = context.downstreamClientOf(name);
      if (client == null) throw ToolArgError('Unknown MCP server: $name');
      return client;
    }

    registry.register(_toolsSchema, (raw) async {
      final name = ToolArgs(raw).text('server');
      final targets = name == null ? context.downstreamClients : [requireClient(name)];

      if (targets.isEmpty) {
        return ToolResult.text(
          'No MCP servers enabled for this workspace.',
          structured: {'servers': const [], 'tools': const <String, dynamic>{}},
        );
      }

      final buffer = StringBuffer();
      final grouped = <String, dynamic>{};
      final servers = <Map<String, dynamic>>[];
      for (final client in targets) {
        final status = client.toStatusJson();
        servers.add(status);
        buffer.writeln(
          '=== ${client.name} [${client.state.name}] ${client.tools.length} tools ===',
        );
        final description = client.description?.trim();
        if (description != null && description.isNotEmpty) {
          buffer.writeln('  $description');
        }
        for (final tool in client.tools) {
          buffer.writeln('  ${tool['name']}: ${Fmt.ellipsis('${tool['description'] ?? ''}', 160)}');
        }
        grouped[client.name] = client.tools;
      }
      return ToolResult.text(buffer.toString(), structured: {'servers': servers, 'tools': grouped});
    });

    registry.register(_callSchema, (raw) async {
      final args = ToolArgs(raw);
      final server = args.requireText('server');
      var client = requireClient(server);

      // 连接管理属于内部实现细节；断线时内部自动重连一次，
      // 不额外向模型暴露 mcp_reconnect 工具。
      if (!client.isConnected) {
        await capabilities.reconnect(server);
        client = requireClient(server);
      }
      if (!client.isConnected) {
        return ToolResult.error(
          'MCP server $server is not connected${client.lastError == null ? '' : ': ${client.lastError}'}',
        );
      }

      final toolName = args.requireText('tool');
      final result = await client.callTool(toolName, args.mapOr('arguments'));
      return _toToolResult(result);
    });
  }

  /// 保留下游 MCP 的 image/resource 等原生 content；纯文本结果仍按原逻辑渲染。
  static ToolResult _toToolResult(Map<String, dynamic> result) {
    final contents = result['content'] ?? result['contents'];
    if (contents is List) {
      final normalized = contents
          .whereType<Map>()
          .map((item) => item.cast<String, dynamic>())
          .toList();
      final hasRichContent = normalized.any((item) => item['type'] != 'text');
      final rendered = _renderContent(result);
      final structuredRaw = result['structuredContent'];
      final structured = structuredRaw is Map
          ? <String, dynamic>{...structuredRaw.cast<String, dynamic>(), 'text': rendered}
          : <String, dynamic>{'text': rendered};
      if (hasRichContent && normalized.isNotEmpty) {
        return ToolResult(
          content: normalized,
          structuredContent: structured,
          isError: result['isError'] == true,
        );
      }
    }
    return ToolResult.text(_renderContent(result), structured: result);
  }

  /// 下游返回的 content 数组里抽出可读文本，抽不到就回落到 JSON。
  static String _renderContent(Map<String, dynamic> result) {
    final contents = result['content'] ?? result['contents'];
    if (contents is! List) return Fmt.json(result);

    final buffer = StringBuffer();
    for (final item in contents) {
      if (item is! Map) continue;
      final text = item['text'];
      if (text is String) {
        buffer.writeln(text);
        continue;
      }
      final type = '${item['type'] ?? ''}';
      if (type == 'image' || type == 'audio') {
        final mimeType = '${item['mimeType'] ?? ''}'.trim();
        buffer.writeln(mimeType.isEmpty ? '[$type]' : '[$type: $mimeType]');
        continue;
      }
      if (type == 'resource') {
        final resource = item['resource'];
        if (resource is Map && resource['text'] is String) {
          buffer.writeln(resource['text']);
        } else if (resource is Map && '${resource['uri'] ?? ''}'.trim().isNotEmpty) {
          buffer.writeln('[resource: ${resource['uri']}]');
        } else {
          buffer.writeln('[resource]');
        }
        continue;
      }
      buffer.writeln(Fmt.json(item));
    }
    final rendered = buffer.toString().trim();
    return rendered.isEmpty ? Fmt.json(result) : rendered;
  }

  static const _serverProperty = {
    'type': 'string',
    'description': 'MCP server name, as listed by mcp_tools.',
  };

  static const _toolsSchema = ToolSchema(
    name: 'mcp_tools',
    title: 'Discover MCP tools',
    description:
        'Lists MCP servers enabled for the current workspace and their available tools. Pass server to inspect one server.',
    inputSchema: {
      'type': 'object',
      'properties': {'server': _serverProperty},
    },
    outputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'Formatted server and tool list'},
        'servers': {'type': 'array'},
        'tools': {'type': 'object'},
      },
      'required': ['text', 'servers', 'tools'],
    },
    annotations: ToolAnnotations.openWorld,
    meta: {
      'openai/toolInvocation/invoking': '正在发现 MCP 工具…',
      'openai/toolInvocation/invoked': 'MCP 工具已加载',
    },
  );

  static const _callSchema = ToolSchema(
    name: 'mcp_call',
    title: 'Call MCP tool',
    description:
        'Calls a tool on an enabled MCP server and returns its result. Use mcp_tools to discover server names, tool names and input schemas.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'server': _serverProperty,
        'tool': {'type': 'string', 'description': 'Tool name provided by the selected MCP server.'},
        'arguments': {
          'type': 'object',
          'description': 'Input object matching the selected tool\'s input schema.',
        },
      },
      'required': ['server', 'tool'],
    },
    outputSchema: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string', 'description': 'Rendered MCP tool result'},
      },
      'required': ['text'],
    },
    // 下游工具调用可能执行写入、删除等操作，不能标为只读。
    annotations: ToolAnnotations.destructive,
    meta: {
      'openai/toolInvocation/invoking': '正在调用 MCP 工具…',
      'openai/toolInvocation/invoked': 'MCP 工具调用完成',
    },
  );
}
