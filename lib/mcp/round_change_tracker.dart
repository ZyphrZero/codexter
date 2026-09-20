import 'dart:io';
import '../models/file_diff_snapshot.dart';
import '../utils/text_diff.dart';
import 'package:path/path.dart' as p;

/// 一轮对话内由写入工具造成的文件净变更。
class RoundFileChange {
  final String path;
  final String status;
  final int additions;
  final int deletions;
  final FileDiffSnapshot? preview;

  const RoundFileChange({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
    this.preview,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'status': status,
    'additions': additions,
    'deletions': deletions,
  };
}

class RoundChangeSet {
  final List<RoundFileChange> files;

  const RoundChangeSet(this.files);

  int get additions => files.fold(0, (sum, item) => sum + item.additions);
  int get deletions => files.fold(0, (sum, item) => sum + item.deletions);

  Map<String, dynamic> toJson() => {
    'count': files.length,
    'additions': additions,
    'deletions': deletions,
    'files': files.map((item) => item.toJson()).toList(growable: false),
  };
}

/// 以 summary 为轮次边界，记录 apply_patch 首次修改前与最后一次提交后的内容。
///
/// 这里只追踪明确经过本 MCP 写入工具的文件，不扫描 Git 或整个工作区，避免把
/// 用户手工编辑、构建产物等变化误判为 ChatGPT 修改。
class RoundChangeTracker {
  final Map<String, _TrackedFile> _files = {};

  void recordCommitted({
    required String relativePath,
    required String absolutePath,
    required bool originalExists,
    required String? originalContent,
    required bool finalExists,
    required String? finalContent,
  }) {
    final key = _pathKey(absolutePath);
    final current = _files[key];
    if (current == null) {
      _files[key] = _TrackedFile(
        path: p.posix.normalize(relativePath.replaceAll('\\', '/')),
        originalExists: originalExists,
        originalContent: originalContent,
        finalExists: finalExists,
        finalContent: finalContent,
      );
      return;
    }

    current
      ..finalExists = finalExists
      ..finalContent = finalContent;
  }

  /// 生成当前轮次的净变更并清空状态，供下一轮重新记录基线。
  RoundChangeSet takeAndReset() {
    final tracked = _files.values.toList(growable: false);
    _files.clear();
    return _buildChangeSet(tracked);
  }

  static RoundChangeSet _buildChangeSet(List<_TrackedFile> trackedFiles) {
    final changes = <RoundFileChange>[];
    for (final tracked in trackedFiles) {
      final change = _buildChange(tracked);
      if (change != null) changes.add(change);
    }
    changes.sort((left, right) => left.path.compareTo(right.path));
    return RoundChangeSet(List.unmodifiable(changes));
  }

  static RoundFileChange? _buildChange(_TrackedFile tracked) {
    final before = tracked.originalContent ?? '';
    final after = tracked.finalContent ?? '';
    if (tracked.originalExists == tracked.finalExists &&
        _normalizeText(before) == _normalizeText(after)) {
      return null;
    }

    final status = !tracked.originalExists
        ? 'added'
        : !tracked.finalExists
        ? 'deleted'
        : 'modified';
    final reason = FileDiffSnapshot.unsupportedReason(
      tracked.path,
      tracked.originalExists ? tracked.originalContent : '',
      tracked.finalExists ? tracked.finalContent : '',
    );
    final diff = reason == null ? TextDiff.calculate(before, after) : null;
    final stats = diff == null
        ? TextDiff.countChanges(before, after)
        : (diff.additions, diff.deletions);
    return RoundFileChange(
      path: tracked.path,
      status: status,
      additions: stats.$1,
      deletions: stats.$2,
      preview: FileDiffSnapshot(
        path: tracked.path,
        status: status,
        before: reason == null ? before : null,
        after: reason == null ? after : null,
        diff: diff,
        unavailableReason: reason,
      ),
    );
  }

  static String _normalizeText(String value) => TextDiff.normalize(value);

  static String _pathKey(String value) {
    final normalized = p.normalize(value);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }
}

class _TrackedFile {
  final String path;
  final bool originalExists;
  final String? originalContent;
  bool finalExists;
  String? finalContent;

  _TrackedFile({
    required this.path,
    required this.originalExists,
    required this.originalContent,
    required this.finalExists,
    required this.finalContent,
  });
}
