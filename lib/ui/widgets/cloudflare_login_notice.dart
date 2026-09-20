import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import '../theme/app_theme.dart';
import 'app_spacing.dart';
import 'app_toast.dart';

/// 仅在用户点击后复制当前授权地址，不自动再次打开浏览器。
class CloudflareLoginNotice extends StatelessWidget {
  const CloudflareLoginNotice({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(BootstrapIcons.boxArrowUpRight, size: 14, color: theme.colorScheme.mutedForeground),
        const Gap(AppSpacing.sm),
        Expanded(child: Text('请在浏览器完成 Cloudflare 授权', style: AppTones.muted(theme, size: 11.5))),
        const Gap(AppSpacing.md),
        Button(
          style: ButtonStyle.outline(size: ButtonSize.small),
          onPressed: () async {
            try {
              await Clipboard.setData(ClipboardData(text: url));
              if (context.mounted) AppToast.success(context, '完整授权链接已复制');
            } catch (_) {
              if (context.mounted) AppToast.error(context, '复制授权链接失败，请重试');
            }
          },
          child: const Text('复制链接'),
        ),
      ],
    );
  }
}
