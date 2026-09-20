import 'dart:io';
import 'package:path/path.dart' as p;
import '../models/skill_entry.dart';
import '../services/downstream_client.dart';

/// 生成 initialize/server-discover 返回给 ChatGPT 的工作区说明。
class ServerInstructions {
  const ServerInstructions._();

  static String build({
    required String projectRoot,
    required List<SkillEntry> skills,
    required List<DownstreamClient> downstream,
    required int toolCount,
    String agentsMode = 'auto',
    String customAgents = '',
  }) {
    final shell = Platform.isWindows ? 'powershell' : 'bash';
    final sections = <String>[
      _environment(projectRoot, shell, toolCount),
      '',
      'This MCP server provides file, search and command tools for the current workspace and access to enabled MCP services.',
      '',
      ..._toolMap(),
      '',
      ..._playbook(),
      '',
      'One round is one user message through one final assistant response. If any tool from this server was used, call `summary` once and only once after all work, immediately before the final response; do not call it after each subtask. After calling `summary`, do not call any other tool from this server this turn. Use one short paragraph, no lists or line breaks.',
    ];

    final agents = _resolveAgents(projectRoot: projectRoot, mode: agentsMode, custom: customAgents);
    if (agents != null) {
      sections
        ..add('')
        ..add('<project_instructions>')
        ..add(agents)
        ..add('</project_instructions>');
    }

    if (skills.isNotEmpty) {
      sections
        ..add('')
        ..add('Available Skills (metadata only; use skill_read for the current SKILL.md body):');
      for (final skill in skills) {
        sections.add('- ${skill.name}: ${skill.description}');
      }
      sections.add(
        'Skills can change while the desktop app is running; use skills_list when current availability matters.',
      );
    }

    if (downstream.isNotEmpty) {
      sections
        ..add('')
        ..add('Available MCP servers (discover with mcp_tools, invoke with mcp_call):');
      for (final client in downstream) {
        final description = client.description?.trim();
        sections.add(
          '- ${client.name} [${client.state.name}] ${client.tools.length} tools'
          '${description == null || description.isEmpty ? '' : ': $description'}',
        );
      }
    }

    return sections.join('\n');
  }

  static String _environment(String projectRoot, String shell, int toolCount) {
    return [
      '<environment_context>',
      '  <project_root>$projectRoot</project_root>',
      '  <shell>$shell</shell>',
      '  <tool_count>$toolCount</tool_count>',
      '  <paths>relative to project_root unless stated otherwise</paths>',
      '</environment_context>',
    ].join('\n');
  }

  static String? _resolveAgents({
    required String projectRoot,
    required String mode,
    required String custom,
  }) {
    if (mode == 'disabled') return null;
    if (mode == 'custom') {
      final text = custom.trim();
      return text.isEmpty ? null : text;
    }
    return _loadRootAgents(projectRoot);
  }

  /// 工作区级 MCP 端点把项目根目录视为 Agent 的当前工作目录。
  /// 同一目录下优先读取 AGENTS.override.md，其次 AGENTS.md，与 Codex 的优先级一致。
  static String? _loadRootAgents(String projectRoot) {
    for (final name in const ['AGENTS.override.md', 'AGENTS.md']) {
      final file = File(p.join(projectRoot, name));
      try {
        if (file.existsSync()) return file.readAsStringSync();
      } catch (_) {}
    }
    return null;
  }

  // 保留工具名称索引便于发现；完整用途和参数只放在 tools/list 的工具定义中。
  static List<String> _toolMap() {
    return const [
      'Built-in tools (full descriptions and parameters: tools/list):',
      '- Files/search: read, read_image, ls, glob, grep, code_explore, apply_patch.',
      '- Commands: exec_command, write_stdin.',
      '- Skills: skills_list, skill_read.',
      '- MCP: mcp_tools, mcp_call.',
      '- Completion: summary.',
    ];
  }

  static List<String> _playbook() {
    return const [
      'Read relevant files before editing. Use apply_patch for file changes, exec_command for shell commands, and write_stdin to continue command sessions.',
      'Built-in tools are listed by tools/list. mcp_tools lists tools from MCP servers enabled for this workspace.',
      'Load relevant skill instructions with skill_read. Discover MCP tools with mcp_tools and invoke them with mcp_call.',
      'Include a concise, user-visible purpose with each tool call.',
    ];
  }
}
