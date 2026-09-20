import 'package:shadcn_flutter/shadcn_flutter.dart';
import '../theme/app_theme.dart';

/// 主区一直保留在树中，打开、收起、全宽预览均不丢失日志滚动和筛选状态。
class WorkspaceDiffLayout extends StatefulWidget {
  static const minMainWidth = 620.0;
  static const minPreviewWidth = 400.0;
  static const dividerWidth = 6.0;

  final Widget child;
  final Widget? preview;
  final bool expanded;

  const WorkspaceDiffLayout({super.key, required this.child, this.preview, this.expanded = false});

  @override
  State<WorkspaceDiffLayout> createState() => _WorkspaceDiffLayoutState();
}

class _WorkspaceDiffLayoutState extends State<WorkspaceDiffLayout> {
  double? _dragWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;
        final open = widget.preview != null;
        final full =
            widget.expanded ||
            available <
                WorkspaceDiffLayout.minMainWidth +
                    WorkspaceDiffLayout.minPreviewWidth +
                    WorkspaceDiffLayout.dividerWidth;
        final maxWidth =
            available - WorkspaceDiffLayout.minMainWidth - WorkspaceDiffLayout.dividerWidth;
        final width = full
            ? available
            : ((_dragWidth ?? available * 0.48).clamp(
                WorkspaceDiffLayout.minPreviewWidth,
                maxWidth,
              ));
        return Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              right: open && !full ? width + WorkspaceDiffLayout.dividerWidth : 0,
              child: Offstage(offstage: open && full, child: widget.child),
            ),
            if (open)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: width,
                child: ColoredBox(color: theme.colorScheme.background, child: widget.preview!),
              ),
            if (open && !full)
              Positioned(
                right: width,
                top: 0,
                bottom: 0,
                width: WorkspaceDiffLayout.dividerWidth,
                child: Semantics(
                  label: '调整 Diff 预览宽度',
                  child: MouseRegion(
                    cursor: SystemMouseCursors.resizeColumn,
                    child: GestureDetector(
                      key: const ValueKey('diff-resize-handle'),
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragStart: (_) => _dragWidth = width,
                      onHorizontalDragUpdate: (event) => setState(() {
                        _dragWidth = ((_dragWidth ?? width) - event.delta.dx).clamp(
                          WorkspaceDiffLayout.minPreviewWidth,
                          maxWidth,
                        );
                      }),
                      onDoubleTap: () => setState(() {
                        _dragWidth = (available * 0.48).clamp(
                          WorkspaceDiffLayout.minPreviewWidth,
                          maxWidth,
                        );
                      }),
                      child: Center(
                        child: Container(width: 1, color: AppTones.borderSubtle(theme)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
