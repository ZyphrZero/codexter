import 'dart:async';
import 'dart:isolate';
import 'package:flutter/painting.dart';
import 'package:diff_match_patch/diff_match_patch.dart';
import 'package:path/path.dart' as p;
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/github-dark.dart';
import '../models/file_diff_snapshot.dart';
import '../utils/text_diff.dart';

class DiffSyntaxToken {
  final String text;
  final int? color;
  final bool italic;
  const DiffSyntaxToken(this.text, this.color, this.italic);
}

class DiffSyntaxResult {
  final List<List<DiffSyntaxToken>> before;
  final List<List<DiffSyntaxToken>> after;
  final Map<int, List<(int, int)>> inlineChanges;
  final String? notice;
  const DiffSyntaxResult({
    this.before = const [],
    this.after = const [],
    this.inlineChanges = const {},
    this.notice,
  });
}

/// 高亮与行内差异均在可取消的隔离线程中执行，拖拽宽度不会重新计算。
class DiffSyntaxTask {
  final _port = ReceivePort();
  final _completer = Completer<DiffSyntaxResult>();
  Isolate? _isolate;
  Timer? _timeout;
  bool _finished = false;

  Future<DiffSyntaxResult> get result => _completer.future;

  DiffSyntaxTask(FileDiffSnapshot snapshot, {required bool dark}) {
    _port.listen((value) {
      _finish(value is DiffSyntaxResult ? value : const DiffSyntaxResult(notice: '高亮失败，已按普通文本显示'));
    });
    _timeout = Timer(const Duration(seconds: 4), () {
      _finish(const DiffSyntaxResult(notice: '高亮耗时较长，已按普通文本显示'));
    });
    _start(snapshot, dark);
  }

  Future<void> _start(FileDiffSnapshot snapshot, bool dark) async {
    try {
      final isolate = await Isolate.spawn(
        _worker,
        (_port.sendPort, snapshot, dark),
        onError: _port.sendPort,
        errorsAreFatal: true,
      );
      if (_finished) {
        isolate.kill(priority: Isolate.immediate);
      } else {
        _isolate = isolate;
      }
    } catch (_) {
      _finish(const DiffSyntaxResult(notice: '高亮不可用，已按普通文本显示'));
    }
  }

  void cancel() => _finish(const DiffSyntaxResult());

  void _finish(DiffSyntaxResult result) {
    if (_finished) return;
    _finished = true;
    _timeout?.cancel();
    _isolate?.kill(priority: Isolate.immediate);
    _port.close();
    _completer.complete(result);
  }

  static void _worker((SendPort, FileDiffSnapshot, bool) input) {
    try {
      input.$1.send(highlight(input.$2, dark: input.$3));
    } catch (_) {
      input.$1.send(const DiffSyntaxResult(notice: '语法解析失败，已按普通文本显示'));
    }
  }

  static const _languages = {
    '.dart': 'dart',
    '.js': 'javascript',
    '.jsx': 'javascript',
    '.mjs': 'javascript',
    '.ts': 'typescript',
    '.tsx': 'typescript',
    '.json': 'json',
    '.jsonc': 'json',
    '.py': 'python',
    '.pyi': 'python',
    '.rs': 'rust',
    '.go': 'go',
    '.java': 'java',
    '.kt': 'kotlin',
    '.kts': 'kotlin',
    '.swift': 'swift',
    '.c': 'c',
    '.h': 'cpp',
    '.cpp': 'cpp',
    '.hpp': 'cpp',
    '.cc': 'cpp',
    '.cs': 'csharp',
    '.rb': 'ruby',
    '.php': 'php',
    '.html': 'xml',
    '.xml': 'xml',
    '.vue': 'xml',
    '.css': 'css',
    '.scss': 'scss',
    '.less': 'less',
    '.yml': 'yaml',
    '.yaml': 'yaml',
    '.sql': 'sql',
    '.sh': 'bash',
    '.bash': 'bash',
    '.zsh': 'bash',
    '.ps1': 'powershell',
    '.psm1': 'powershell',
    '.bat': 'dos',
    '.cmd': 'dos',
    '.md': 'markdown',
    '.markdown': 'markdown',
    '.toml': 'ini',
    '.ini': 'ini',
    '.conf': 'ini',
    '.env': 'ini',
    '.diff': 'diff',
    '.patch': 'diff',
  };

  static String? languageOf(String path) {
    final name = p.posix.basename(path.replaceAll('\\', '/')).toLowerCase();
    if (name == 'dockerfile' || name.startsWith('dockerfile.')) return 'dockerfile';
    if (name == 'makefile') return 'makefile';
    if (name == '.env' || name.startsWith('.env.')) return 'ini';
    return _languages[p.extension(name)];
  }

  /// 先解析完整版本，再拆分成行，保留跨行注释和字符串的语法状态。
  static DiffSyntaxResult highlight(FileDiffSnapshot snapshot, {required bool dark}) {
    final language = languageOf(snapshot.path);
    final grammar = language == null ? null : builtinAllLanguages[language];
    final highlighter = Highlight();
    if (language != null && grammar != null) highlighter.registerLanguage(language, grammar);
    List<List<DiffSyntaxToken>> parse(String text) {
      if (language == null || grammar == null) return const [];
      final renderer = TextSpanRenderer(null, dark ? githubDarkTheme : githubTheme);
      highlighter.highlight(code: TextDiff.normalize(text), language: language).render(renderer);
      final lines = <List<DiffSyntaxToken>>[[]];
      void visit(TextSpan span, TextStyle parent) {
        final style = parent.merge(span.style);
        final text = span.text;
        if (text != null) {
          final parts = text.split('\n');
          for (var i = 0; i < parts.length; i++) {
            if (parts[i].isNotEmpty) {
              lines.last.add(
                DiffSyntaxToken(
                  parts[i],
                  style.color?.toARGB32(),
                  style.fontStyle == FontStyle.italic,
                ),
              );
            }
            if (i < parts.length - 1) lines.add([]);
          }
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          if (child is TextSpan) visit(child, style);
        }
      }

      if (renderer.span != null) visit(renderer.span!, const TextStyle());
      return lines;
    }

    final before = parse(snapshot.before ?? '');
    final after = parse(snapshot.after ?? '');
    final ranges = <int, List<(int, int)>>{};
    final rows = snapshot.diff?.lines ?? const <TextDiffLine>[];
    final engine = DiffMatchPatch()..diffTimeout = 0.01;
    var pairs = 0;
    for (var i = 0; i < rows.length;) {
      if (rows[i].kind == DiffLineKind.context) {
        i++;
        continue;
      }
      final deleted = <int>[];
      final added = <int>[];
      while (i < rows.length && rows[i].kind != DiffLineKind.context) {
        (rows[i].kind == DiffLineKind.deletion ? deleted : added).add(i++);
      }
      for (var j = 0; j < deleted.length && j < added.length && pairs < 400; j++, pairs++) {
        final a = rows[deleted[j]].text;
        final b = rows[added[j]].text;
        if (a.length + b.length > 4000) continue;
        final diff = engine.diff(a, b, false);
        engine.diffCleanupSemantic(diff);
        var oldOffset = 0;
        var newOffset = 0;
        for (final part in diff) {
          if (part.operation == DIFF_DELETE) {
            ranges.putIfAbsent(deleted[j], () => []).add((oldOffset, oldOffset + part.text.length));
          }
          if (part.operation == DIFF_INSERT) {
            ranges.putIfAbsent(added[j], () => []).add((newOffset, newOffset + part.text.length));
          }
          if (part.operation != DIFF_INSERT) oldOffset += part.text.length;
          if (part.operation != DIFF_DELETE) newOffset += part.text.length;
        }
      }
    }
    return DiffSyntaxResult(before: before, after: after, inlineChanges: ranges);
  }
}
