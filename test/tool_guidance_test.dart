import 'dart:convert';
import 'dart:io';

import 'package:codexter/mcp/instructions.dart';
import 'package:codexter/mcp/tools/registry.dart';
import 'package:codexter/mcp/tools/tool_bundle.dart';
import 'package:codexter/mcp/tools/tool_context.dart';
import 'package:codexter/models/downstream_mcp_entry.dart';
import 'package:codexter/models/workspace.dart';
import 'package:codexter/services/capability_runtime.dart';
import 'package:codexter/services/computer_use_tools.dart';
import 'package:codexter/services/downstream_client.dart';
import 'package:codexter/services/process_session_manager.dart';
import 'package:codexter/stores/log_store.dart';
import 'package:codexter/utils/path_guard.dart';
import 'package:flutter_test/flutter_test.dart';

// 仅提供下游目录数据，不建立连接或启动桌面运行时。
class _CatalogCapabilities extends CapabilityRuntime {
  final List<DownstreamClient> catalog;

  _CatalogCapabilities(this.catalog);

  @override
  List<DownstreamClient> get clients => List.unmodifiable(catalog);
}

void main() {
  late Directory temp;
  late ProcessSessionManager processes;
  late CapabilityRuntime capabilities;
  late LogStore logs;
  late ToolContext context;
  late ToolRegistry registry;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp_guidance_');
    processes = ProcessSessionManager();
    capabilities = CapabilityRuntime();
    logs = LogStore();
    final now = DateTime.now();
    context = ToolContext(
      workspace: Workspace(
        uuid: '11111111-1111-4111-8111-111111111114',
        name: '任意连接名称',
        projectRoot: temp.path,
        createdAt: now,
        lastActiveAt: now,
      ),
      pathGuard: PathGuard(temp.path),
      processManager: processes,
      capabilities: capabilities,
      logStore: logs,
    );
    registry = ToolBundle.build(context);
  });

  tearDown(() async {
    await processes.shutdown();
    processes.dispose();
    await capabilities.shutdown();
    capabilities.dispose();
    logs.dispose();
    await temp.delete(recursive: true);
  });

  String instructions({List<DownstreamClient> downstream = const []}) {
    return ServerInstructions.build(
      projectRoot: temp.path,
      skills: const [],
      downstream: downstream,
      toolCount: registry.count,
      agentsMode: 'disabled',
    );
  }

  test('固定说明保留全部工具名称，不复制参数，不绑定连接名称或特定下游', () {
    final text = instructions();
    expect(registry.count, 14);
    for (final name in registry.names) {
      expect(text, contains(name), reason: name);
    }
    for (final parameter in ['oldText', 'newText', 'yield_time_ms', 'max_output_tokens']) {
      expect(text, isNot(contains(parameter)), reason: parameter);
    }
    for (final name in ['codexter', 'Computer Use', 'computer-use', 'IDE', 'fallback']) {
      expect(text, isNot(contains(name)), reason: name);
    }
    expect(text, contains('tools/list'));
    expect(text, contains('- MCP: mcp_tools, mcp_call.'));
    // 仅约束项目固定说明的预算，不代表协议或客户端的官方上限。
    expect(text.length, lessThan(2000));
  });

  test('模型侧说明与工具定义使用 MCP 服务称呼，界面标签保持不变', () async {
    final terminology = RegExp(r'downstream|gateway|下游|网关', caseSensitive: false);
    final descriptions = jsonEncode([
      instructions(),
      for (final schema in registry.listSchemas())
        {
          'title': schema.title,
          'description': schema.description,
          'inputSchema': schema.toJson()['inputSchema'],
          'outputSchema': schema.outputSchema,
        },
    ]);
    expect(terminology.hasMatch(descriptions), isFalse);

    final listing = await registry.invoke('mcp_tools', {'purpose': '读取 MCP 服务列表'});
    expect(terminology.hasMatch(jsonEncode(listing.content)), isFalse);
    expect(terminology.hasMatch(jsonEncode(listing.structuredContent)), isFalse);
    // 界面元数据仍保留管理视角的分组名称，不属于模型侧工具说明。
    expect((listing.meta!['codexMcpUi'] as Map)['groupLabel'], '下游 MCP');
  });

  test('关闭 Computer Use 时说明和下游目录均不包含它', () async {
    await capabilities.syncMcps([DownstreamMcpEntry.builtinComputerUse(enabled: false)]);
    expect(context.downstreamClients, isEmpty);
    final text = instructions(downstream: context.downstreamClients);
    expect(text, isNot(contains('Computer Use')));
    expect(text, isNot(contains(computerUseMcpName)));
    expect(text, isNot(contains('end_turn')));
    final result = await registry.invoke('mcp_tools', {'purpose': '检查关闭后的下游目录'});
    expect(result.isError, isFalse);
    expect(result.structuredContent!['servers'], isEmpty);
    expect(result.structuredContent!['tools'], isEmpty);
    expect(result.structuredContent!['text'], 'No MCP servers enabled for this workspace.');
  });

  test('所有下游使用相同的动态说明区，不改变固定工具说明', () {
    final computer = DownstreamClient(DownstreamMcpEntry.builtinComputerUse(enabled: true));
    final ordinary = DownstreamClient(
      DownstreamMcpEntry(name: 'document-service', transportJson: '{}', source: 'manual'),
    )..serverInfo = {'description': 'Read project documents.'};
    final base = instructions();
    for (final client in [computer, ordinary]) {
      final text = instructions(downstream: [client]);
      expect(text, startsWith('$base\n\nAvailable MCP servers'));
      expect(
        text,
        contains('- ${client.name} [${client.state.name}] ${client.tools.length} tools'),
      );
      expect(text, contains(client.description!));
      expect(client.description!.allMatches(text), hasLength(1));
    }
    expect(instructions(), base);
  });

  test('工作区排除已启用的 Computer Use 时不泄漏其说明或工具', () async {
    final computer = DownstreamClient(DownstreamMcpEntry.builtinComputerUse(enabled: true));
    final ordinary = DownstreamClient(
      DownstreamMcpEntry(name: 'document-service', transportJson: '{}', source: 'manual'),
    )..serverInfo = {'description': 'Read project documents.'};
    final catalog = _CatalogCapabilities([computer, ordinary]);
    try {
      final scoped = ToolContext(
        workspace: context.workspace.copyWith(selectedMcpNames: [ordinary.name]),
        pathGuard: context.pathGuard,
        processManager: processes,
        capabilities: catalog,
        logStore: logs,
      );
      final text = instructions(downstream: scoped.downstreamClients);
      expect(text, contains(ordinary.name));
      expect(text, isNot(contains('Computer Use')));
      expect(text, isNot(contains(computerUseMcpName)));
      final scopedRegistry = ToolBundle.build(scoped);
      expect(scopedRegistry.names, registry.names);
      final result = await scopedRegistry.invoke('mcp_tools', {'purpose': '检查工作区下游范围'});
      expect((result.structuredContent!['tools'] as Map).keys, [ordinary.name]);
      expect(result.structuredContent!['text'], isNot(contains(computerUseMcpName)));
    } finally {
      await catalog.shutdown();
      catalog.dispose();
    }
  });

  test('工具描述不绑定特定下游，接口保持实际支持的 JSON 编辑和命令参数', () {
    final schemas = {for (final schema in registry.listSchemas()) schema.name: schema.toJson()};
    for (final schema in schemas.values) {
      final description = schema['description'] as String;
      for (final term in ['Codexter', 'Computer Use', 'IDE', 'terminal window', 'fallback']) {
        expect(description, isNot(contains(term)), reason: '${schema['name']}: $term');
      }
    }
    final patchInput = schemas['apply_patch']!['inputSchema'] as Map;
    expect(patchInput['type'], 'object');
    final patchProperties = patchInput['properties'] as Map;
    expect(patchProperties.keys.toSet(), {'purpose', 'edits'});
    final editProperties = ((patchProperties['edits'] as Map)['items'] as Map)['properties'] as Map;
    expect(editProperties.keys.toSet(), {'path', 'oldText', 'newText', 'delete'});
    for (final parameter in editProperties.keys) {
      expect((editProperties[parameter] as Map)['description'], isNotEmpty, reason: '$parameter');
    }
    expect(schemas['apply_patch']!['description'], contains('JSON edits'));
    final commandProperties = (schemas['exec_command']!['inputSchema'] as Map)['properties'] as Map;
    expect(commandProperties.keys.toSet(), {
      'purpose',
      'cmd',
      'workdir',
      'yield_time_ms',
      'max_output_tokens',
    });
    expect(schemas['exec_command']!['description'], isNot(contains('PTY')));
    expect(schemas['exec_command']!['description'], contains('session_id'));
    expect(schemas['write_stdin']!['description'], contains('exec_command'));
  });

  test('Computer Use 自身只说明桌面能力与生命周期，不依赖上游工具', () {
    final windows = computerUseToolDefinitions.singleWhere(
      (tool) => tool['name'] == 'list_windows',
    );
    for (final text in [computerUseMcpDescription, windows['description'] as String]) {
      for (final term in ['apply_patch', 'exec_command', 'parent server', 'fallback']) {
        expect(text, isNot(contains(term)), reason: term);
      }
    }
    expect(computerUseMcpDescription, contains('end_turn'));
    expect(computerUseToolDefinitions.map((tool) => tool['name']), contains('end_turn'));
  });

  test('MCP 服务提供的名称和说明原样保留，不做全局词语替换', () {
    final client = DownstreamClient(
      DownstreamMcpEntry(name: 'downstream-data', transportJson: '{}', source: 'manual'),
    )..serverInfo = {'description': 'Inspect downstream data. 检查下游数据。'};
    final text = instructions(downstream: [client]);
    expect(text, contains('Available MCP servers'));
    expect(text, contains(client.name));
    expect(text, contains(client.description!));
  });

  test('自定义项目说明保留原文，不为固定长度预算静默截断', () {
    final custom = List.filled(2200, '项目约定').join();
    final text = ServerInstructions.build(
      projectRoot: temp.path,
      skills: const [],
      downstream: const [],
      toolCount: registry.count,
      agentsMode: 'custom',
      customAgents: custom,
    );
    expect(text, contains('<project_instructions>\n$custom\n</project_instructions>'));
    expect(text, contains('apply_patch'));
  });
}
