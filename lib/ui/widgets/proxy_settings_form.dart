import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../../services/network_proxy.dart';
import '../../stores/app_state.dart';
import '../theme/app_theme.dart';
import 'app_components.dart';
import 'app_dialog.dart';
import 'app_spacing.dart';
import 'app_toast.dart';

class ProxySettingsDialog {
  const ProxySettingsDialog._();

  static Future<bool> show({
    required BuildContext context,
    required AppState appState,
    String description = '可选配置。仅在当前网络访问 GitHub 或 Cloudflare 需要代理时启用。',
  }) async {
    var draftEnabled = appState.config.proxyEnabled;
    var draftUrl = appState.config.proxyUrl;

    final saved = await AppDialog.show<bool>(
      context: context,
      title: '网络代理',
      description: description,
      maxWidth: 560,
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          return ProxySettingsForm(
            enabled: draftEnabled,
            url: draftUrl,
            compact: true,
            onEnabledChanged: (value) {
              setDialogState(() => draftEnabled = value);
            },
            onUrlChanged: (value) => draftUrl = value,
          );
        },
      ),
      actions: (dialogContext) => [
        Button(
          style: ButtonStyle.outline(size: ButtonSize.normal),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        Button(
          style: ButtonStyle.primary(size: ButtonSize.normal),
          onPressed: () async {
            try {
              await appState.saveGlobalConfig(
                appState.config.copyWith(proxyEnabled: draftEnabled, proxyUrl: draftUrl),
              );
              if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
            } on FormatException catch (error) {
              if (dialogContext.mounted) AppToast.error(dialogContext, error.message);
            } catch (error) {
              if (dialogContext.mounted) AppToast.error(dialogContext, '保存代理失败：$error');
            }
          },
          child: const Text('保存'),
        ),
      ],
    );

    if (saved == true && context.mounted) {
      AppToast.success(context, '网络代理设置已保存');
    }
    return saved ?? false;
  }
}

/// 全局设置、首次向导和启动检查共用的代理编辑器。
class ProxySettingsForm extends StatefulWidget {
  final bool enabled;
  final String url;
  final bool busy;
  final bool compact;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<String> onUrlChanged;

  const ProxySettingsForm({
    super.key,
    required this.enabled,
    required this.url,
    required this.onEnabledChanged,
    required this.onUrlChanged,
    this.busy = false,
    this.compact = false,
  });

  @override
  State<ProxySettingsForm> createState() => _ProxySettingsFormState();
}

class _ProxySettingsFormState extends State<ProxySettingsForm> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  String _scheme = 'http';
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final uri = Uri.tryParse(widget.url);
    _scheme = uri?.scheme == 'socks5' ? 'socks5' : 'http';
    _hostController = TextEditingController(
      text: uri != null && uri.host.isNotEmpty ? uri.host : '127.0.0.1',
    );
    _portController = TextEditingController(
      text: uri != null && uri.hasPort ? '${uri.port}' : '7890',
    );
    _hostController.addListener(_emitUrl);
    _portController.addListener(_emitUrl);
  }

  @override
  void dispose() {
    _hostController
      ..removeListener(_emitUrl)
      ..dispose();
    _portController
      ..removeListener(_emitUrl)
      ..dispose();
    super.dispose();
  }

  String get _draftUrl {
    var host = _hostController.text.trim();
    if (host.contains(':') && !host.startsWith('[')) host = '[$host]';
    return '$_scheme://$host:${_portController.text.trim()}';
  }

  void _emitUrl() {
    widget.onUrlChanged(_draftUrl);
  }

  void _selectScheme(String scheme) {
    if (_scheme == scheme) return;
    setState(() => _scheme = scheme);
    _emitUrl();
  }

  void _toggleEnabled(bool value) {
    // 启用时以当前表单字段为准，避免历史无效地址在关闭状态下被保留后再次启用失败。
    if (value) widget.onUrlChanged(_draftUrl);
    widget.onEnabledChanged(value);
  }

  Future<void> _testConnection() async {
    setState(() => _testing = true);
    try {
      await NetworkProxy.testConnection(_draftUrl);
      if (mounted) AppToast.success(context, '代理连接正常，Cloudflare HTTPS 探测通过');
    } catch (error) {
      if (mounted) AppToast.error(context, '代理测试失败：$error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = widget.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: AppTones.surfaceSunken(theme),
            borderRadius: BorderRadius.circular(theme.radiusLg),
            border: Border.all(color: AppTones.borderSubtle(theme)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('使用自定义出站代理', style: AppTones.title(theme, size: 12.5)),
                        const Gap(AppSpacing.sm),
                        AppTag(
                          label: widget.enabled ? (_scheme == 'socks5' ? 'SOCKS5' : 'HTTP') : '未启用',
                          color: widget.enabled ? AppTones.success : null,
                        ),
                      ],
                    ),
                    const Gap(3),
                    Text('关闭时沿用应用启动环境中的代理变量；未设置则直接连接。', style: AppTones.muted(theme, size: 11)),
                  ],
                ),
              ),
              const Gap(AppSpacing.lg),
              Switch(value: widget.enabled, onChanged: disabled ? null : _toggleEnabled),
            ],
          ),
        ),
        const Gap(AppSpacing.lg),
        Text('代理协议', style: AppTones.label(theme)),
        const Gap(AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: Button(
                style: _scheme == 'http'
                    ? ButtonStyle.primary(size: ButtonSize.normal)
                    : ButtonStyle.outline(size: ButtonSize.normal),
                onPressed: disabled ? null : () => _selectScheme('http'),
                child: const Text('HTTP'),
              ),
            ),
            const Gap(AppSpacing.sm),
            Expanded(
              child: Button(
                style: _scheme == 'socks5'
                    ? ButtonStyle.primary(size: ButtonSize.normal)
                    : ButtonStyle.outline(size: ButtonSize.normal),
                onPressed: disabled ? null : () => _selectScheme('socks5'),
                child: const Text('SOCKS5'),
              ),
            ),
          ],
        ),
        const Gap(AppSpacing.lg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: AppField(
                label: '代理服务器',
                controller: _hostController,
                placeholder: '127.0.0.1',
                readOnly: disabled,
                hint: '支持主机名、IPv4 与 IPv6。',
              ),
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: AppField(
                label: '端口',
                controller: _portController,
                placeholder: '7890',
                readOnly: disabled,
                hint: _scheme == 'http' ? 'HTTP 或 Mixed 端口' : 'SOCKS5 端口',
              ),
            ),
          ],
        ),
        const Gap(AppSpacing.lg),
        Row(
          children: [
            Button(
              style: ButtonStyle.outline(size: ButtonSize.small),
              onPressed: disabled || _testing ? null : _testConnection,
              child: AppButtonLabel(
                icon: BootstrapIcons.activity,
                label: _testing ? '测试中…' : '测试连接',
              ),
            ),
            const Gap(AppSpacing.md),
            Expanded(
              child: AppMonoText(_draftUrl, size: 10.5, color: theme.colorScheme.mutedForeground),
            ),
          ],
        ),
        if (!widget.compact) ...[
          const Gap(AppSpacing.xl),
          Text('生效范围', style: AppTones.label(theme)),
          const Gap(AppSpacing.sm),
          const Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              AppTag(label: '应用下载'),
              AppTag(label: '更新检查'),
              AppTag(label: 'Cloudflare 初始化'),
              AppTag(label: 'HTTP MCP'),
              AppTag(label: '新启动子进程'),
            ],
          ),
        ],
      ],
    );
  }
}
