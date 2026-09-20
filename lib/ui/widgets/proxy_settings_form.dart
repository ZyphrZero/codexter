import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../theme/app_theme.dart';
import 'app_components.dart';
import 'app_spacing.dart';

/// 引导与全局设置共用的出站代理表单。
class ProxySettingsForm extends StatelessWidget {
  final bool enabled;
  final bool busy;
  final TextEditingController controller;
  final ValueChanged<bool> onEnabledChanged;

  const ProxySettingsForm({
    super.key,
    required this.enabled,
    required this.controller,
    required this.onEnabledChanged,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          decoration: BoxDecoration(
            border: Border.all(color: AppTones.borderSubtle(theme)),
            borderRadius: BorderRadius.circular(theme.radiusLg),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '启用自定义代理',
                      style: AppTones.body(theme, size: 12.5).copyWith(fontWeight: FontWeight.w600),
                    ),
                    const Gap(3),
                    Text(
                      '关闭后沿用启动应用时的代理环境变量；未设置环境变量时直连。',
                      style: AppTones.muted(theme, size: 11),
                    ),
                  ],
                ),
              ),
              const Gap(AppSpacing.xl),
              Switch(value: enabled, onChanged: busy ? null : onEnabledChanged),
            ],
          ),
        ),
        const Gap(AppSpacing.xl),
        AppField(
          label: 'HTTP 代理地址',
          controller: controller,
          placeholder: 'http://127.0.0.1:7890',
          readOnly: busy,
          hint: '用于 HTTP 和 HTTPS 请求。请填写代理软件的 HTTP 或 Mixed 端口，暂不支持 SOCKS 和账号密码认证。',
        ),
        const Gap(AppSpacing.xl),
        const AppNotice(
          message: '保存后用于新的网络请求',
          detail:
              '覆盖更新检查、下载、连通性检测和 HTTP MCP。本机回环地址默认直连。'
              '支持代理环境变量的子进程也会继承此配置；已运行的 MCP、命令和 Cloudflared 需重连或重启。'
              '浏览器及 Cloudflare Tunnel 的隧道传输不由此设置接管。',
        ),
      ],
    );
  }
}
