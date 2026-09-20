import 'package:diff_match_patch/diff_match_patch.dart';

/// 行号和统计共用一份差异结果，避免总结中的增删数与预览不一致。
enum DiffLineKind { context, deletion, addition }

class TextDiffLine {
  final DiffLineKind kind;
  final String text;
  final int? oldLine;
  final int? newLine;
  final bool hasNewline;

  const TextDiffLine(this.kind, this.text, this.oldLine, this.newLine, this.hasNewline);
}

class TextDiff {
  final List<TextDiffLine> lines;
  final int additions;
  final int deletions;
  final bool coarse;

  const TextDiff(this.lines, this.additions, this.deletions, {this.coarse = false});

  static String normalize(String text) => text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  /// 保留行尾换行标记；末尾增加换行也应显示为真实变更。
  static List<String> splitLines(String text) {
    final normalized = normalize(text);
    if (normalized.isEmpty) return const [];
    final parts = normalized.split('\n');
    return [
      for (var i = 0; i < parts.length; i++)
        if (i < parts.length - 1) '${parts[i]}\n' else if (parts[i].isNotEmpty) parts[i],
    ];
  }

  static TextDiff calculate(String before, String after) {
    final data = _operations(before, after);
    final left = data.left;
    final right = data.right;
    final operations = data.operations;
    final rows = <TextDiffLine>[];
    var oldIndex = 0;
    var newIndex = 0;
    var additions = 0;
    var deletions = 0;
    for (final operation in operations) {
      final kind = switch (operation.operation) {
        DIFF_INSERT => DiffLineKind.addition,
        DIFF_DELETE => DiffLineKind.deletion,
        _ => DiffLineKind.context,
      };
      for (var i = 0; i < operation.text.length; i++) {
        final raw = kind == DiffLineKind.addition ? right[newIndex] : left[oldIndex];
        final oldLine = kind == DiffLineKind.addition ? null : ++oldIndex;
        final newLine = kind == DiffLineKind.deletion ? null : ++newIndex;
        final newline = raw.endsWith('\n');
        rows.add(
          TextDiffLine(
            kind,
            newline ? raw.substring(0, raw.length - 1) : raw,
            oldLine,
            newLine,
            newline,
          ),
        );
        if (kind == DiffLineKind.addition) additions++;
        if (kind == DiffLineKind.deletion) deletions++;
      }
    }
    return TextDiff(List.unmodifiable(rows), additions, deletions, coarse: data.coarse);
  }

  /// 只需要统计时不构建逐行对象，避免大文件为不可预览内容额外占用内存。
  static (int additions, int deletions) countChanges(String before, String after) {
    final data = _operations(before, after);
    var additions = 0;
    var deletions = 0;
    for (final operation in data.operations) {
      if (operation.operation == DIFF_INSERT) additions += operation.text.length;
      if (operation.operation == DIFF_DELETE) deletions += operation.text.length;
    }
    return (additions, deletions);
  }

  static ({List<String> left, List<String> right, List<Diff> operations, bool coarse}) _operations(
    String before,
    String after,
  ) {
    final left = splitLines(before);
    final right = splitLines(after);
    final dictionary = <String, int>{};
    int token(String line) => dictionary.putIfAbsent(line, () => dictionary.length + 1);
    final a = left.map(token).toList();
    final b = right.map(token).toList();
    // 每行编码为一个非代理区字符；唯一行过多时降级为整段替换。
    final coarse = dictionary.length >= 0xd800;
    final engine = DiffMatchPatch()..diffTimeout = 0.15;
    final operations = coarse
        ? <Diff>[Diff(DIFF_DELETE, 'a' * left.length), Diff(DIFF_INSERT, 'b' * right.length)]
        : engine.diff(String.fromCharCodes(a), String.fromCharCodes(b), false);
    return (left: left, right: right, operations: operations, coarse: coarse);
  }
}
