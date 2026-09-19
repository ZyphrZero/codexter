import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'app_components.dart';
import 'app_spacing.dart';
import 'app_toast.dart';

/// 仅在用户点击后复制当前授权地址，不自动再次打开浏览器。
class CloudflareLoginNotice extends StatelessWidget {
  const CloudflareLoginNotice({super.key, required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppNotice(message: '请在浏览器完成 Cloudflare 授权。若未自动打开，可复制完整链接后粘贴到浏览器。'),
        const Gap(AppSpacing.sm),
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
          child: const Text('复制授权链接'),
        ),
      ],
    );
  }
}
