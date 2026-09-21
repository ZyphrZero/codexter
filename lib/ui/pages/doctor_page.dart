import 'package:shadcn_flutter/shadcn_flutter.dart';
import '../../services/doctor_service.dart';
import '../../stores/app_state.dart';
import '../../utils/fmt.dart';
import '../theme/app_theme.dart';
import '../widgets/app_components.dart';
import '../widgets/app_spacing.dart';
import '../widgets/app_toast.dart';

/// 环境检查：cloudflared、登录、Tunnel、服务、Git、工作区路径
class DoctorPage extends StatefulWidget {
  final AppState appState;

  const DoctorPage({super.key, required this.appState});

  @override
  State<DoctorPage> createState() => _DoctorPageState();
}

class _DoctorPageState extends State<DoctorPage> {
  String? _repairingTitle;

  Future<void> _runChecks() => widget.appState.runDoctor();

  Future<void> _repairCheck(DoctorCheck check) async {
    if (_repairingTitle != null) return;
    setState(() => _repairingTitle = check.title);
    try {
      await widget.appState.repairDoctorCheck(check);
      await _runChecks();
      if (!mounted) return;
      final error = widget.appState.doctorError;
      if (error != null) {
        AppToast.error(context, '修复后检查未完成：$error');
      } else if (widget.appState.doctorChecks.any(
        (result) => result.title == check.title && result.state == DoctorState.pass,
      )) {
        AppToast.success(context, '已修复：${check.title}');
      } else {
        AppToast.warning(context, '修复操作已完成，请查看最新检查结果');
      }
    } catch (error) {
      if (mounted) AppToast.error(context, '修复失败：$error');
    } finally {
      if (mounted) setState(() => _repairingTitle = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checks = widget.appState.doctorChecks;
    final running = widget.appState.doctorRunning;
    final starting = widget.appState.servicesStarting;
    final activeTitles = widget.appState.doctorRunningTitles;
    final completed = widget.appState.doctorCompletedCount;
    final total = widget.appState.doctorTotalCount;
    final checkedAt = widget.appState.doctorCheckedAt;
    final error = widget.appState.doctorError;
    final failed = widget.appState.doctorFailedCount;
    final warned = widget.appState.doctorWarningCount;
    final passed = widget.appState.doctorPassedCount;
    final skipped = widget.appState.doctorSkippedCount;
    final checksByTitle = {for (final check in checks) check.title: check};
    final titles = List.of(DoctorService.checkTitles)
      ..sort((left, right) {
        final priority = _checkPriority(
          checksByTitle[left]?.state,
        ).compareTo(_checkPriority(checksByTitle[right]?.state));
        if (priority != 0) return priority;
        return DoctorService.checkTitles
            .indexOf(left)
            .compareTo(DoctorService.checkTitles.indexOf(right));
      });

    return AppPageScaffold(
      title: '环境检查',
      subtitle: starting
          ? '服务正在启动，随后自动检查…'
          : running
          ? '并行检查中 · 已完成 $completed/$total · ${activeTitles.length} 项进行中'
          : error != null
          ? '检查未完成：$error'
          : checks.isEmpty
          ? '共 $total 项检查 · 异常项优先显示'
          : '$passed 项通过 · $warned 项注意 · $failed 项失败'
                '${skipped == 0 ? '' : ' · $skipped 项跳过'}'
                '${checkedAt == null ? '' : ' · 上次检查 ${Fmt.clock(checkedAt)}'}',
      actions: [
        Button(
          style: ButtonStyle.outline(size: ButtonSize.normal),
          onPressed: running || widget.appState.busy || _repairingTitle != null ? null : _runChecks,
          child: const AppButtonLabel(icon: BootstrapIcons.arrowRepeat, label: '重新检查'),
        ),
      ],
      child: Padding(
        padding: AppSpacing.pagePadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: theme.colorScheme.card,
                borderRadius: BorderRadius.circular(theme.radiusLg),
                border: Border.all(color: AppTones.borderSubtle(theme)),
              ),
              child: Column(
                children: [
                  _CheckListHeader(wide: wide),
                  Expanded(
                    child: ListView.separated(
                      padding: EdgeInsets.zero,
                      itemCount: titles.length,
                      separatorBuilder: (context, index) =>
                          Container(height: 1, color: AppTones.borderFaint(theme)),
                      itemBuilder: (context, index) {
                        final title = titles[index];
                        final check = checksByTitle[title];
                        return _CheckRow(
                          key: ValueKey(title),
                          title: title,
                          check: check,
                          wide: wide,
                          loading: activeTitles.contains(title),
                          repairing: _repairingTitle == title,
                          onRepair:
                              check?.state == DoctorState.fail &&
                                  check!.repairable &&
                                  !running &&
                                  !widget.appState.busy &&
                                  _repairingTitle == null
                              ? () => _repairCheck(check)
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static int _checkPriority(DoctorState? state) => switch (state) {
    DoctorState.fail => 0,
    DoctorState.warn => 1,
    null => 2,
    DoctorState.skip => 3,
    DoctorState.pass => 4,
  };
}

class _CheckListHeader extends StatelessWidget {
  final bool wide;

  const _CheckListHeader({required this.wide});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = AppTones.muted(theme, size: 11);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppTones.surfaceSunken(theme),
        border: Border(bottom: BorderSide(color: AppTones.borderSubtle(theme))),
      ),
      child: Row(
        children: wide
            ? [
                SizedBox(
                  width: _CheckRow.nameWidth,
                  child: Text('检查项目', style: style),
                ),
                const Gap(AppSpacing.lg),
                SizedBox(
                  width: _CheckRow.statusWidth,
                  child: Text('状态', style: style),
                ),
                const Gap(AppSpacing.lg),
                Expanded(child: Text('检查结果', style: style)),
                const Gap(AppSpacing.lg),
                SizedBox(
                  width: _CheckRow.actionWidth,
                  child: Text('操作', textAlign: TextAlign.right, style: style),
                ),
              ]
            : [Expanded(child: Text('检查项目与结果', style: style)), Text('状态', style: style)],
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  static const nameWidth = 168.0;
  static const statusWidth = 80.0;
  static const actionWidth = 64.0;

  final String title;
  final DoctorCheck? check;
  final bool wide;
  final bool loading;
  final bool repairing;
  final VoidCallback? onRepair;

  const _CheckRow({
    super.key,
    required this.title,
    required this.check,
    required this.wide,
    required this.loading,
    required this.repairing,
    this.onRepair,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = check?.state;
    final label = switch (state) {
      DoctorState.pass => '通过',
      DoctorState.warn => '注意',
      DoctorState.fail => '失败',
      DoctorState.skip => '跳过',
      null => '等待',
    };
    final color = switch (state) {
      DoctorState.pass => AppTones.success,
      DoctorState.warn => AppTones.warning,
      DoctorState.fail => theme.colorScheme.destructive,
      DoctorState.skip => theme.colorScheme.mutedForeground,
      null => theme.colorScheme.mutedForeground,
    };
    final busy = loading || repairing;
    final detail = repairing
        ? '正在修复，请稍候…'
        : loading
        ? '正在检查…'
        : check?.detail ?? '等待检查';
    final hint = busy ? null : check?.hint;
    final name = Row(
      children: [
        Icon(_iconFor(title), size: 16, color: theme.colorScheme.mutedForeground),
        const Gap(AppSpacing.md),
        Expanded(child: Text(title, style: AppTones.title(theme, size: 12))),
      ],
    );
    final status = busy
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(dimension: 12, child: CircularProgressIndicator()),
              const Gap(AppSpacing.sm),
              Text(repairing ? '修复中' : '检查中', style: AppTones.muted(theme, size: 11)),
            ],
          )
        : AppTag(label: label, color: color);
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(
          detail,
          style: AppTones.mono(theme, size: 11, color: theme.colorScheme.foreground),
          contextMenuBuilder: buildAppTextContextMenu,
        ),
        if (hint != null && hint.isNotEmpty) ...[
          const Gap(AppSpacing.xs),
          Text('建议：$hint', style: AppTones.muted(theme, size: 11)),
        ],
      ],
    );
    final action = onRepair != null || repairing
        ? Button(
            style: ButtonStyle.outline(size: ButtonSize.small),
            onPressed: repairing ? null : onRepair,
            child: const Text('修复'),
          )
        : null;

    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      color: busy
          ? AppTones.interactionSurface(theme)
          : state == DoctorState.fail
          ? theme.colorScheme.destructive.withValues(alpha: 0.035)
          : null,
      child: wide
          ? Row(
              children: [
                SizedBox(width: nameWidth, child: name),
                const Gap(AppSpacing.lg),
                SizedBox(
                  width: statusWidth,
                  child: Align(alignment: Alignment.centerLeft, child: status),
                ),
                const Gap(AppSpacing.lg),
                Expanded(child: description),
                const Gap(AppSpacing.lg),
                SizedBox(
                  width: actionWidth,
                  child: Align(alignment: Alignment.centerRight, child: action),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    const Gap(AppSpacing.md),
                    status,
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 28, top: AppSpacing.sm),
                  child: description,
                ),
                if (action != null) ...[
                  const Gap(AppSpacing.sm),
                  Align(alignment: Alignment.centerRight, child: action),
                ],
              ],
            ),
    );
  }

  static IconData _iconFor(String title) {
    return switch (title) {
      DoctorService.proxyCheckTitle => BootstrapIcons.globe,
      'Cloudflared' => BootstrapIcons.cloud,
      'Cloudflare 登录' => BootstrapIcons.check2,
      'Tunnel 配置' => BootstrapIcons.gear,
      '公网域名' => BootstrapIcons.link45deg,
      '本地 MCP 服务' => BootstrapIcons.hddRack,
      'Cloudflare Tunnel' => BootstrapIcons.cloud,
      '公网连通性' => BootstrapIcons.activity,
      'Git' => BootstrapIcons.terminal,
      '工作区路径' => BootstrapIcons.folder2Open,
      _ => BootstrapIcons.activity,
    };
  }
}
