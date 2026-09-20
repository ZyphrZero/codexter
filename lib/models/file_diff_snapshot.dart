import 'package:path/path.dart' as p;
import '../utils/text_diff.dart';

/// 只在本地保存的本轮文本快照，不参与 MCP 序列化，也不在点击时重新读取磁盘。
class FileDiffSnapshot {
  static const maxPreviewChars = 1000000;
  static const maxPreviewLines = 20000;
  static const _binaryExtensions = {
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
    '.ico',
    '.svg',
    '.avif',
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.odt',
    '.ods',
    '.zip',
    '.gz',
    '.7z',
    '.rar',
    '.tar',
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.db',
    '.sqlite',
    '.sqlite3',
    '.woff',
    '.woff2',
    '.ttf',
    '.otf',
    '.mp3',
    '.mp4',
    '.mov',
    '.wav',
    '.wasm',
    '.bin',
    '.class',
    '.jar',
  };

  final String path;
  final String status;
  final String? before;
  final String? after;
  final TextDiff? diff;
  final String? unavailableReason;

  const FileDiffSnapshot({
    required this.path,
    required this.status,
    this.before,
    this.after,
    this.diff,
    this.unavailableReason,
  });

  bool get canPreview => diff != null && before != null && after != null;

  // 估算文本、拆行和对象开销，用于全局有界缓存，而非仅限制单文件。
  int get estimatedBytes =>
      canPreview ? ((before!.length + after!.length) * 6 + diff!.lines.length * 96) : 0;

  static String? unsupportedReason(String path, String? before, String? after) {
    if (_binaryExtensions.contains(p.extension(path).toLowerCase())) {
      return '图片或二进制文件不提供 Diff 预览';
    }
    if (before == null || after == null) return '缺少可安全解码的文本快照';
    final control = RegExp(r'[\x00-\x08\x0b\x0e-\x1f]');
    if (control.hasMatch(before) ||
        control.hasMatch(after) ||
        before.contains('\uFFFD') ||
        after.contains('\uFFFD')) {
      return '二进制或无法安全解码的文本，不提供 Diff 预览';
    }
    if (before.length + after.length > maxPreviewChars) {
      return '文件过大，已保留增删统计，暂不提供内容预览';
    }
    if (TextDiff.splitLines(before).length + TextDiff.splitLines(after).length > maxPreviewLines) {
      return '文件行数过多，暂不提供内容预览';
    }
    return null;
  }
}
