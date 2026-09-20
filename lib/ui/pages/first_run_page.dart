import 'package:shadcn_flutter/shadcn_flutter.dart';
import '../../app_info.dart';
import '../../services/setup_service.dart';
import '../../stores/app_state.dart';
import '../../utils/app_paths.dart';
import '../theme/app_theme.dart';
import '../widgets/app_components.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_spacing.dart';
import '../widgets/app_toast.dart';
import '../widgets/cloudflare_login_notice.dart';
import '../widgets/proxy_settings_form.dart';
import '../widgets/setup_wizard_steps.dart';

/// 首次启动向导：cloudflared → 域名 → Tunnel → 完成
class FirstRunPage extends StatefulWidget {
  final AppState appState;

  const FirstRunPage({super.key, required this.appState});

  @override
  State<FirstRunPage> createState() => _FirstRunPageState();
}

class _FirstRunPageState extends State<FirstRunPage> {
  static const _stepLabels = ['Cloudflared', '域名', 'Tunnel', '完成'];

  final _setupService = SetupService();
  final _domainController = TextEditingController();
  final _tunnelNameController = TextEditingController(text: 'codex-mcp');

  late bool _proxyEnabled;
  late String _proxyUrl;
  int _step = 0;
  bool _busy = false;
  String? _status;
  String? _loginUrl;
  String? _cloudflaredBin;
  String? _cloudflaredVersion;
  bool _probed = false;
  double _downloadFraction = 0;
  String _installPath = '';

  @override
  void initState() {
    super.initState();
    _proxyEnabled = widget.appState.config.proxyEnabled;
    _proxyUrl = widget.appState.config.proxyUrl;
    _probeCloudflared();
  }

  @override
  void dispose() {
    _domainController.dispose();
    _tunnelNameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      child: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620, maxHeight: 640),
              child: Container(
                margin: const EdgeInsets.all(AppSpacing.x2l),
                decoration: BoxDecoration(
                  color: theme.colorScheme.card,
                  borderRadius: BorderRadius.circular(theme.radiusXl),
                  border: Border.all(color: theme.colorScheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(theme),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(AppSpacing.x2l),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(_stepTitle, style: AppTones.title(theme, size: 14)),
                            const Gap(AppSpacing.md),
                            _buildStepBody(),
                          ],
                        ),
                      ),
                    ),
                    if (_step >= 2) _buildStepStatusSlot(theme),
                    _buildFooter(theme),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            top: AppSpacing.lg,
            right: AppSpacing.lg,
            child: AppIconButton(
              icon: widget.appState.darkMode ? BootstrapIcons.sun : BootstrapIcons.moon,
              tooltip: widget.appState.darkMode ? '切换浅色' : '切换深色',
              onPressed: () {
                widget.appState.toggleDarkMode();
                AppToast.info(context, widget.appState.darkMode ? '已切换至深色模式' : '已切换至浅色模式');
              },
            ),
          ),
        ],
      ),
    );
  }

  String get _stepTitle => switch (_step) {
    0 => '第 1 步：安装 cloudflared',
    1 => '第 2 步：公网域名',
    2 => '第 3 步：创建 Tunnel',
    _ => '第 4 步：完成',
  };

  Widget _buildStepStatusSlot(ThemeData theme) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.x2l, 0, AppSpacing.x2l, AppSpacing.md),
        child: Align(
          alignment: Alignment.bottomLeft,
          child: _loginUrl != null
              ? CloudflareLoginNotice(url: _loginUrl!)
              : _status != null
              ? Row(
                  children: [
                    const SizedBox.square(dimension: 14, child: CircularProgressIndicator()),
                    const Gap(AppSpacing.sm),
                    Expanded(child: Text(_status!, style: AppTones.muted(theme, size: 11.5))),
                  ],
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x2l),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('欢迎使用 $appName', style: AppTones.title(theme, size: 18))),
              const Gap(AppSpacing.lg),
              Button(
                style: ButtonStyle.outline(size: ButtonSize.small),
                onPressed: _busy ? null : _showProxySettings,
                child: AppButtonLabel(
                  icon: BootstrapIcons.globe,
                  label: _proxyEnabled
                      ? '网络代理 · ${Uri.tryParse(_proxyUrl)?.scheme.toUpperCase() ?? 'HTTP'}'
                      : '网络代理',
                ),
              ),
            ],
          ),
          const Gap(AppSpacing.xs),
          Text('配置一次公网入口，之后每个工作区会自动获得独立的 UUID 地址。', style: AppTones.muted(theme)),
          const Gap(AppSpacing.xl),
          StepIndicator(labels: _stepLabels, activeIndex: _step),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    final isLastStep = _step == _stepLabels.length - 1;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.x2l),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.colorScheme.border)),
      ),
      child: Row(
        children: [
          if (_step > 0)
            Button(
              style: ButtonStyle.outline(size: ButtonSize.normal),
              onPressed: _busy ? null : () => setState(() => _step--),
              child: const Text('上一步'),
            ),
          const Spacer(),
          Button(
            style: ButtonStyle.primary(size: ButtonSize.normal),
            onPressed: _busy ? null : (isLastStep ? _finish : _next),
            child: Text(_busy ? '处理中…' : (isLastStep ? '进入主页' : '下一步')),
          ),
        ],
      ),
    );
  }

  Widget _buildStepBody() {
    return switch (_step) {
      0 => CloudflaredStep(
        probed: _probed,
        binPath: _cloudflaredBin,
        version: _cloudflaredVersion,
        busy: _busy,
        downloadFraction: _downloadFraction,
        installPath: _installPath,
        releaseAssetName: _setupService.githubAssetName,
        managedBinName: _setupService.managedBinName,
        onDownload: _downloadCloudflared,
        onRecheck: _probeCloudflared,
        onOpenRelease: () => _openUrl(SetupService.githubReleasesUrl),
      ),
      1 => DomainStep(
        controller: _domainController,
        onOpenDashboard: () => _openUrl('https://dash.cloudflare.com/'),
      ),
      2 => TunnelStep(controller: _tunnelNameController),
      _ => DoneStep(
        domain: _setupService.normalizeDomain(_domainController.text),
        onOpenDocs: () => _openUrl('https://learn.chatgpt.com/docs/mcp-server'),
      ),
    };
  }

  Future<void> _showProxySettings() async {
    final saved = await ProxySettingsDialog.show(context: context, appState: widget.appState);
    if (!mounted || !saved) return;
    setState(() {
      _proxyEnabled = widget.appState.config.proxyEnabled;
      _proxyUrl = widget.appState.config.proxyUrl;
    });
  }

  Future<void> _openUrl(String url) async {
    final ok = await _setupService.openUrl(url);
    if (!mounted) return;
    if (ok) {
      AppToast.info(context, '已在浏览器中打开');
    } else {
      AppToast.error(context, '打开浏览器失败，请稍后重试');
    }
  }

  Future<void> _probeCloudflared() async {
    final target = await AppPaths.cloudflaredPath;
    final bin = await _setupService.findCloudflaredBin();
    final version = bin == null ? null : await _setupService.probeVersion(bin);
    if (!mounted) return;
    setState(() {
      _installPath = target;
      _cloudflaredBin = bin;
      _cloudflaredVersion = version;
      _probed = true;
    });
  }

  Future<void> _downloadCloudflared() async {
    setState(() {
      _busy = true;
      _status = null;
      _downloadFraction = 0;
    });

    try {
      await _saveProxySettings();
      await _setupService.downloadCloudflared(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() => _downloadFraction = progress.fraction);
        },
      );
      await _probeCloudflared();
    } catch (error) {
      if (mounted) AppToast.error(context, '下载失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _downloadFraction = 0;
        });
      }
    }
  }

  Future<void> _next() async {
    setState(() => _status = null);

    if (_step == 0) {
      try {
        await _saveProxySettings();
      } on FormatException catch (error) {
        if (!mounted) return;
        AppToast.error(context, error.message);
        return;
      }
      if (!mounted) return;
      if (_cloudflaredBin == null) {
        AppToast.warning(context, '请先安装 cloudflared');
        return;
      }
    }
    if (!mounted) return;
    if (_step == 1 && _setupService.normalizeDomain(_domainController.text).isEmpty) {
      AppToast.warning(context, '请输入有效域名');
      return;
    }
    if (_step == 2) {
      final succeeded = await _provisionTunnel();
      if (!succeeded) return;
    }
    if (mounted) setState(() => _step++);
  }

  Future<void> _saveProxySettings() async {
    await widget.appState.saveGlobalConfig(
      widget.appState.config.copyWith(proxyEnabled: _proxyEnabled, proxyUrl: _proxyUrl),
    );
    _proxyUrl = widget.appState.config.proxyUrl;
  }

  void _updateLoginUrl(String? url) {
    if (mounted) setState(() => _loginUrl = url);
  }

  Future<bool> _provisionTunnel() async {
    if (_busy) return false;
    final bin = _cloudflaredBin;
    if (bin == null) {
      AppToast.warning(context, 'cloudflared 未安装');
      return false;
    }

    setState(() {
      _busy = true;
      _status = '正在检查 Cloudflare 登录状态…';
    });

    try {
      final domain = _setupService.normalizeDomain(_domainController.text);
      final tunnelName = _tunnelNameController.text.trim().isEmpty
          ? 'codex-mcp'
          : _tunnelNameController.text.trim();

      final login = await _setupService.loginCloudflare(bin, onLoginUrl: _updateLoginUrl);
      if (!mounted) return false;
      if (login.authorizationPending) {
        setState(() {
          _busy = false;
          _status = null;
        });
        AppToast.info(context, '浏览器授权尚未完成，完成授权后请再次点击「下一步」');
        return false;
      }
      if (!login.success) throw Exception(login.error ?? 'Cloudflare 登录未完成');
      setState(() => _status = '正在创建 Tunnel…');
      final tunnelId = await _createTunnelWithConflictHandling(bin, tunnelName);
      if (tunnelId == null) return false;

      setState(() => _status = '正在配置 DNS 路由…');
      await _setupService.ensureDnsRoute(bin, tunnelId, domain, onLoginUrl: _updateLoginUrl);

      setState(() => _status = '正在写入配置…');
      final port = await AppPaths.findAvailablePort(18920);
      final config = await _setupService.writeTunnelConfig(
        widget.appState.config.copyWith(
          domain: domain,
          port: port,
          tunnelName: tunnelName,
          cloudflaredBin: bin,
          useCloudflared: true,
        ),
        tunnelId,
      );
      await widget.appState.saveGlobalConfig(config);

      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
        AppToast.success(context, 'Tunnel 配置完成');
      }
      return true;
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
        AppToast.error(context, '配置失败：$error');
      }
      return false;
    }
  }

  Future<String?> _createTunnelWithConflictHandling(String bin, String tunnelName) async {
    try {
      return await _setupService.createTunnel(bin, tunnelName);
    } on TunnelNameConflictException catch (conflict) {
      if (!mounted) return null;
      setState(() => _status = null);

      final shouldDelete = await AppDialog.show<bool>(
        context: context,
        title: 'Tunnel 名称已存在',
        description: 'Cloudflare 中已经存在名为「${conflict.name}」的 Tunnel。',
        maxWidth: 440,
        content: Builder(
          builder: (dialogContext) => Text(
            '你可以返回修改一个新的名称，或者删除 Cloudflare 上现有的同名 Tunnel 后继续。'
            '删除会中断其他正在使用该 Tunnel 的设备，并使旧凭据失效。',
            style: AppTones.body(Theme.of(dialogContext), size: 12),
          ),
        ),
        actions: (dialogContext) => [
          Button(
            style: ButtonStyle.outline(size: ButtonSize.normal),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('修改名称'),
          ),
          ButtonStyleOverride.inherit(
            decoration: (context, states, value) {
              if (value is! BoxDecoration) return value;
              final color = states.contains(WidgetState.pressed)
                  ? const Color(0xFFB91C1C)
                  : states.contains(WidgetState.hovered)
                  ? const Color(0xFFDC2626)
                  : const Color(0xFFEF4444);
              return value.copyWith(
                color: color,
                border: Border.all(color: color),
              );
            },
            textStyle: (context, states, value) => value.copyWith(color: Colors.white),
            child: Button(
              style: ButtonStyle.destructive(size: ButtonSize.normal),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('删除旧 Tunnel'),
            ),
          ),
        ],
      );

      if (!mounted) return null;
      if (shouldDelete != true) {
        setState(() {
          _busy = false;
          _status = null;
        });
        return null;
      }

      setState(() => _status = '正在删除旧 Tunnel…');
      await _setupService.deleteTunnel(conflict.tunnelId);
      if (!mounted) return null;
      setState(() => _status = '正在重新创建 Tunnel…');
      return _setupService.createTunnel(bin, tunnelName);
    }
  }

  Future<void> _finish() async {
    setState(() {
      _busy = true;
      _status = '正在启动服务…';
    });
    try {
      await widget.appState.completeFirstRun(widget.appState.config);
    } catch (error) {
      if (mounted) AppToast.error(context, '启动服务失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = null;
        });
      }
    }
  }
}
