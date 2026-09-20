import 'dart:math' as math;
import 'package:flutter/material.dart' as material;
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';
import '../../models/file_diff_snapshot.dart';
import '../../services/diff_syntax_service.dart';
import '../../utils/text_diff.dart';
import '../theme/app_theme.dart';
import 'app_components.dart';
import 'app_spacing.dart';
import 'app_toast.dart';

/// 只读单列 Diff：语法高亮与行内修改叠加，行号和操作符不进入复制内容。
class FileDiffPanel extends StatefulWidget {
  final FileDiffSnapshot snapshot;
  final List<FileDiffSnapshot> files;
  final String roundLabel;
  final ValueChanged<String> onSelectFile;
  final VoidCallback onClose;
  final VoidCallback onToggleExpanded;
  final bool expanded;

  const FileDiffPanel({
    super.key,
    required this.snapshot,
    required this.files,
    required this.roundLabel,
    required this.onSelectFile,
    required this.onClose,
    required this.onToggleExpanded,
    this.expanded = false,
  });

  @override
  State<FileDiffPanel> createState() => _FileDiffPanelState();
}

class _FileDiffPanelState extends State<FileDiffPanel> {
  final _vertical = ScrollController();
  final _horizontal = ScrollController();
  final _fileMenuKey = GlobalKey<_DiffMenuButtonState>();
  final _expandedGaps = <int>{};
  final _heights = <int, double>{};
  DiffSyntaxTask? _task;
  DiffSyntaxResult _syntax = const DiffSyntaxResult();
  bool? _dark;
  bool _loading = true;
  bool _wrap = false;
  int _generation = 0;
  int _hunk = 0;
  int _maxColumns = 0;
  double _measuredWidth = -1;
  double _measuredScale = -1;
  List<_DiffViewItem> _items = const [];
  List<int> _hunks = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
    if (_dark != dark) {
      _dark = dark;
      _loadSyntax();
    }
  }

  @override
  void didUpdateWidget(covariant FileDiffPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.snapshot, oldWidget.snapshot)) {
      _expandedGaps.clear();
      _heights.clear();
      _hunk = 0;
      _loadSyntax();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_vertical.hasClients) _vertical.jumpTo(0);
        if (_horizontal.hasClients) _horizontal.jumpTo(0);
      });
    }
  }

  void _loadSyntax() {
    _task?.cancel();
    final generation = ++_generation;
    _syntax = const DiffSyntaxResult();
    _loading = true;
    _rebuildItems();
    _maxColumns = 0;
    for (final row in widget.snapshot.diff?.lines ?? const <TextDiffLine>[]) {
      var columns = 0;
      for (final rune in row.text.runes) {
        columns += rune == 9
            ? 4
            : rune > 255
            ? 2
            : 1;
      }
      _maxColumns = math.max(_maxColumns, columns);
    }
    final task = DiffSyntaxTask(widget.snapshot, dark: _dark ?? false);
    _task = task;
    task.result.then((result) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _syntax = result;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _task?.cancel();
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  void _rebuildItems() {
    final rows = widget.snapshot.diff?.lines ?? const <TextDiffLine>[];
    final items = <_DiffViewItem>[];
    void addRow(int index) {
      items.add(_DiffViewItem.line(index));
      if (!rows[index].hasNewline && rows[index].kind != DiffLineKind.context) {
        items.add(const _DiffViewItem.note());
      }
    }

    for (var i = 0; i < rows.length;) {
      if (rows[i].kind != DiffLineKind.context) {
        addRow(i++);
        continue;
      }
      final start = i;
      while (i < rows.length && rows[i].kind == DiffLineKind.context) {
        i++;
      }
      final head = start == 0 ? 0 : 3;
      final tail = i == rows.length ? 0 : 3;
      if (i - start <= head + tail + 1 || _expandedGaps.contains(start)) {
        for (var j = start; j < i; j++) {
          addRow(j);
        }
      } else {
        for (var j = start; j < start + head; j++) {
          addRow(j);
        }
        items.add(_DiffViewItem.gap(start, i - start - head - tail));
        for (var j = i - tail; j < i; j++) {
          addRow(j);
        }
      }
    }
    final hunks = <int>[];
    var changed = false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].note) continue;
      final index = items[i].line;
      final nowChanged = index != null && rows[index].kind != DiffLineKind.context;
      if (nowChanged && !changed) hunks.add(i);
      changed = nowChanged;
    }
    _items = items;
    _hunks = hunks;
    _heights.clear();
  }

  void _copyText(String text) {
    Clipboard.setData(ClipboardData(text: text));
    AppToast.info(context, '已复制');
  }

  TextStyle _codeStyle(ThemeData theme) =>
      AppTones.mono(theme, size: 12, color: theme.colorScheme.foreground).copyWith(height: 1.75);

  double _extent(int index, double codeWidth, TextStyle style, TextScaler scaler) {
    final item = _items[index];
    final lineHeight = math.max(24.0, scaler.scale(12) * 1.75 + 2);
    if (!_wrap || item.line == null) return lineHeight;
    return _heights.putIfAbsent(index, () {
      final text = widget.snapshot.diff!.lines[item.line!].text.replaceAll('\t', '    ');
      final painter = TextPainter(
        text: TextSpan(text: text.isEmpty ? ' ' : text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
      )..layout(maxWidth: codeWidth);
      final height = math.max(lineHeight, painter.height + 2);
      painter.dispose();
      return height;
    });
  }

  void _jump(int direction, double codeWidth, TextStyle style, TextScaler scaler) {
    if (_hunks.isEmpty || !_vertical.hasClients) return;
    setState(() => _hunk = (_hunk + direction) % _hunks.length);
    var offset = 0.0;
    for (var i = 0; i < _hunks[_hunk]; i++) {
      offset += _extent(i, codeWidth, style, scaler);
    }
    _vertical.animateTo(
      offset.clamp(0, _vertical.position.maxScrollExtent),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
    );
  }

  List<TextSpan> _lineSpans(int index, Color inlineColor) {
    final row = widget.snapshot.diff!.lines[index];
    final source = row.kind == DiffLineKind.deletion ? _syntax.before : _syntax.after;
    final number = (row.kind == DiffLineKind.deletion ? row.oldLine : row.newLine) ?? 1;
    final tokens = number <= source.length ? source[number - 1] : <DiffSyntaxToken>[];
    final actual = tokens.isEmpty ? [DiffSyntaxToken(row.text, null, false)] : tokens;
    final ranges = _syntax.inlineChanges[index] ?? const <(int, int)>[];
    final spans = <TextSpan>[];
    var offset = 0;
    for (final token in actual) {
      final end = offset + token.text.length;
      final cuts = <int>{offset, end};
      for (final range in ranges) {
        if (range.$1 > offset && range.$1 < end) cuts.add(range.$1);
        if (range.$2 > offset && range.$2 < end) cuts.add(range.$2);
      }
      final boundaries = cuts.toList()..sort();
      for (var i = 0; i + 1 < boundaries.length; i++) {
        final start = boundaries[i];
        final highlighted = ranges.any((range) => start >= range.$1 && start < range.$2);
        spans.add(
          TextSpan(
            text: token.text
                .substring(start - offset, boundaries[i + 1] - offset)
                .replaceAll('\t', '    '),
            style: TextStyle(
              color: token.color == null ? null : Color(token.color!),
              fontStyle: token.italic ? FontStyle.italic : null,
              backgroundColor: highlighted ? inlineColor : null,
            ),
          ),
        );
      }
      offset = end;
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = widget.snapshot;
    final diff = snapshot.diff;
    final scaler = MediaQuery.textScalerOf(context);
    final style = _codeStyle(theme);
    final name = snapshot.path.split('/').last;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gutter = 58.0;
        final codeWidth = math.max(40.0, constraints.maxWidth - gutter - 16);
        if (_measuredWidth != codeWidth || _measuredScale != scaler.scale(12)) {
          _heights.clear();
          _measuredWidth = codeWidth;
          _measuredScale = scaler.scale(12);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 10, 8),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTones.borderSubtle(theme))),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(BootstrapIcons.fileDiff, size: 15),
                      const Gap(8),
                      Expanded(
                        child: AppTooltip(
                          message: snapshot.path,
                          child: GestureDetector(
                            onTap: () => _fileMenuKey.currentState?.open(),
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppTones.title(theme, size: 13),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Gap(AppSpacing.sm),
                      _DiffMenuButton(
                        key: _fileMenuKey,
                        icon: BootstrapIcons.chevronDown,
                        tooltip: '切换本轮文件',
                        width: 320,
                        actions: () => [
                          for (final file in widget.files)
                            _DiffMenuAction(
                              onPressed: () => widget.onSelectFile(file.path),
                              child: Text(file.path, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                        ],
                      ),
                      const Gap(AppSpacing.sm),
                      _DiffMenuButton(
                        icon: BootstrapIcons.clipboard,
                        tooltip: '复制内容或路径',
                        actions: () => [
                          _DiffMenuAction(
                            child: const Text('复制修改前内容'),
                            onPressed: () => _copyText(widget.snapshot.before ?? ''),
                          ),
                          _DiffMenuAction(
                            child: const Text('复制修改后内容'),
                            onPressed: () => _copyText(widget.snapshot.after ?? ''),
                          ),
                          _DiffMenuAction(
                            child: const Text('复制文件路径'),
                            onPressed: () => _copyText(widget.snapshot.path),
                          ),
                        ],
                      ),
                      const Gap(AppSpacing.sm),
                      AppIconButton(
                        icon: widget.expanded
                            ? LucideIcons.chevronsRightLeft
                            : LucideIcons.chevronsLeftRight,
                        tooltip: widget.expanded ? '恢复分栏' : '展开阅读',
                        onPressed: widget.onToggleExpanded,
                      ),
                      const Gap(AppSpacing.sm),
                      AppIconButton(
                        icon: BootstrapIcons.xLg,
                        tooltip: '关闭 Diff，返回日志',
                        onPressed: widget.onClose,
                      ),
                    ],
                  ),
                  const Gap(4),
                  Text(
                    snapshot.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTones.mono(theme, size: 10),
                  ),
                  const Gap(6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${widget.roundLabel} · 修改前 → 修改后',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTones.muted(theme, size: 11),
                        ),
                      ),
                      if (diff != null) ...[
                        Text(
                          '+${diff.additions}',
                          style: AppTones.mono(
                            theme,
                            size: 11,
                            color: (_dark ?? false)
                                ? const Color(0xFF7EE787)
                                : const Color(0xFF16703C),
                          ),
                        ),
                        const Gap(10),
                        Text(
                          '-${diff.deletions}',
                          style: AppTones.mono(
                            theme,
                            size: 11,
                            color: (_dark ?? false)
                                ? const Color(0xFFFF938A)
                                : const Color(0xFFB42318),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _loading
                          ? '正在加载语法高亮…'
                          : _syntax.notice ?? (DiffSyntaxTask.languageOf(snapshot.path) ?? '纯文本'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTones.muted(theme, size: 10),
                    ),
                  ),
                  if (_hunks.isNotEmpty) ...[
                    Text('${_hunk + 1}/${_hunks.length}', style: AppTones.muted(theme, size: 10)),
                    const Gap(AppSpacing.md),
                  ],
                  AppIconButton(
                    icon: BootstrapIcons.chevronUp,
                    tooltip: '上一个修改',
                    onPressed: () => _jump(-1, codeWidth, style, scaler),
                  ),
                  const Gap(AppSpacing.sm),
                  AppIconButton(
                    icon: BootstrapIcons.chevronDown,
                    tooltip: '下一个修改',
                    onPressed: () => _jump(1, codeWidth, style, scaler),
                  ),
                  const Gap(AppSpacing.sm),
                  AppIconButton(
                    icon: _wrap ? BootstrapIcons.textWrap : BootstrapIcons.arrowRight,
                    tooltip: _wrap ? '关闭自动换行' : '开启自动换行',
                    onPressed: () {
                      setState(() {
                        _wrap = !_wrap;
                        _heights.clear();
                      });
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: diff == null
                  ? AppEmptyState(
                      icon: BootstrapIcons.fileEarmark,
                      title: snapshot.unavailableReason ?? '没有可用的历史快照',
                    )
                  : _items.isEmpty
                  ? AppEmptyState(
                      icon: BootstrapIcons.fileEarmark,
                      title: snapshot.status == 'added' ? '已新增空文件' : '没有文本行变更',
                    )
                  : LayoutBuilder(
                      builder: (context, area) {
                        final columns = _maxColumns;
                        final painter = TextPainter(
                          text: TextSpan(text: 'M', style: style),
                          textDirection: TextDirection.ltr,
                          textScaler: scaler,
                        )..layout();
                        final contentWidth = _wrap
                            ? area.maxWidth
                            : math.max(area.maxWidth, columns * painter.width + gutter + 24);
                        painter.dispose();
                        return material.SelectionArea(
                          child: material.Scrollbar(
                            controller: _horizontal,
                            thumbVisibility: !_wrap,
                            scrollbarOrientation: material.ScrollbarOrientation.bottom,
                            notificationPredicate: (notification) =>
                                notification.metrics.axis == Axis.horizontal,
                            child: SingleChildScrollView(
                              controller: _horizontal,
                              scrollDirection: Axis.horizontal,
                              physics: _wrap ? const NeverScrollableScrollPhysics() : null,
                              child: SizedBox(
                                width: contentWidth,
                                height: area.maxHeight,
                                child: material.Scrollbar(
                                  controller: _vertical,
                                  thumbVisibility: true,
                                  child: ListView.builder(
                                    controller: _vertical,
                                    primary: false,
                                    padding: const EdgeInsets.only(bottom: 16),
                                    itemCount: _items.length,
                                    itemExtentBuilder: (index, _) =>
                                        _extent(index, codeWidth, style, scaler),
                                    itemBuilder: (context, index) =>
                                        _buildItem(index, theme, style, gutter),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildItem(int index, ThemeData theme, TextStyle style, double gutter) {
    final item = _items[index];
    if (item.line == null) {
      return SelectionContainer.disabled(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: item.note
              ? null
              : () => setState(() {
                  _expandedGaps.add(item.start!);
                  _rebuildItems();
                }),
          child: MouseRegion(
            cursor: item.note ? MouseCursor.defer : SystemMouseCursors.click,
            child: Container(
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.only(left: gutter),
              color: item.note ? null : AppTones.surfaceSunken(theme),
              child: Text(
                item.note ? '文件末尾没有换行' : '展开 ${item.count} 行未修改内容',
                style: AppTones.muted(theme, size: 10),
              ),
            ),
          ),
        ),
      );
    }
    final row = widget.snapshot.diff!.lines[item.line!];
    final dark = _dark ?? false;
    final added = row.kind == DiffLineKind.addition;
    final changed = row.kind != DiffLineKind.context;
    final accent = added ? const Color(0xFF2DA44E) : const Color(0xFFCF222E);
    final background = changed
        ? Color.alphaBlend(
            accent.withValues(alpha: dark ? 0.16 : 0.075),
            theme.colorScheme.background,
          )
        : theme.colorScheme.background;
    final inline = accent.withValues(alpha: dark ? 0.30 : 0.20);
    final lineNumber = row.kind == DiffLineKind.deletion ? row.oldLine : row.newLine ?? row.oldLine;
    return Container(
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectionContainer.disabled(
            child: SizedBox(
              key: ValueKey('diff-line-gutter-${item.line}'),
              width: gutter,
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${lineNumber ?? ''}',
                      textAlign: TextAlign.right,
                      style: style.copyWith(color: theme.colorScheme.mutedForeground),
                    ),
                  ),
                  SizedBox(
                    width: 24,
                    child: Text(
                      changed ? (added ? '+' : '−') : '',
                      textAlign: TextAlign.center,
                      style: style.copyWith(color: theme.colorScheme.mutedForeground),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text.rich(
                TextSpan(children: _lineSpans(item.line!, inline)),
                style: style,
                softWrap: _wrap,
                overflow: TextOverflow.clip,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiffMenuAction {
  final Widget child;
  final VoidCallback onPressed;

  const _DiffMenuAction({required this.child, required this.onPressed});
}

class _DiffMenuButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final double? width;
  final List<_DiffMenuAction> Function() actions;

  const _DiffMenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.actions,
    this.width,
  });

  @override
  State<_DiffMenuButton> createState() => _DiffMenuButtonState();
}

class _DiffMenuButtonState extends State<_DiffMenuButton> {
  final _link = LayerLink();
  OverlayEntry? _entry;

  void open() {
    if (_entry != null) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final actions = widget.actions();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (overlayContext) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _close,
              child: const SizedBox.expand(),
            ),
          ),
          CompositedTransformFollower(
            link: _link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.bottomRight,
            followerAnchor: Alignment.topRight,
            offset: const Offset(0, 4),
            child: IntrinsicWidth(
              child: SizedBox(
                width: widget.width,
                child: DropdownMenu(
                  children: [
                    for (final action in actions)
                      MenuButton(
                        autoClose: false,
                        onPressed: (_) {
                          _close();
                          action.onPressed();
                        },
                        child: action.child,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    if (mounted) setState(() {});
  }

  void _close() {
    final entry = _entry;
    if (entry == null) return;
    _entry = null;
    entry.remove();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _entry?.remove();
    _entry = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: AppIconButton(icon: widget.icon, tooltip: widget.tooltip, onPressed: open),
    );
  }
}

class _DiffViewItem {
  final int? line;
  final int? start;
  final int count;
  final bool note;
  const _DiffViewItem.line(this.line) : start = null, count = 0, note = false;
  const _DiffViewItem.gap(this.start, this.count) : line = null, note = false;
  const _DiffViewItem.note() : line = null, start = null, count = 0, note = true;
}
