import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import '../models/mcp_log_entry.dart';
import '../models/file_diff_snapshot.dart';

const maxLogEntriesPerWorkspace = 1000;
const logNotifyThrottleMs = 120;
const _maxPreviewBytes = 32 * 1024 * 1024;

/// 每工作区内存环形日志缓冲，不落盘。写入合并节流后再通知 UI
class LogStore extends ChangeNotifier {
  final Map<String, Queue<McpLogEntry>> _entries = {};
  final Map<String, WorkspaceLogStats> _stats = {};
  Timer? _notifyTimer;
  bool _disposed = false;
  final Map<(String, String), McpLogEntry> _previewEntries = {};
  int _previewBytes = 0;

  void attachFilePreviews(McpLogEntry entry, List<FileDiffSnapshot> previews) {
    // 清日志期间仍可能有请求返回；不让迟到结果复活已删除的快照。
    if (_disposed || !(_entries[entry.workspaceUuid]?.contains(entry) ?? false)) return;
    _releasePreviews(entry);
    entry.filePreviews = Map.unmodifiable({for (final preview in previews) preview.path: preview});
    entry.previewsExpired = false;
    _previewEntries[(entry.workspaceUuid, entry.id)] = entry;
    _previewBytes += _sizeOf(entry);
    while (_previewBytes > _maxPreviewBytes && _previewEntries.isNotEmpty) {
      _releasePreviews(_previewEntries.values.first);
    }
    _scheduleNotify();
  }

  static int _sizeOf(McpLogEntry entry) =>
      entry.filePreviews.values.fold(0, (sum, preview) => sum + preview.estimatedBytes);

  void _releasePreviews(McpLogEntry entry) {
    if (_previewEntries.remove((entry.workspaceUuid, entry.id)) != null) {
      _previewBytes -= _sizeOf(entry);
    }
    if (entry.filePreviews.isNotEmpty) entry.previewsExpired = true;
    entry.filePreviews = const {};
  }

  void _clearWorkspacePreviews(String uuid) {
    for (final entry
        in _previewEntries.values.where((entry) => entry.workspaceUuid == uuid).toList()) {
      _releasePreviews(entry);
    }
  }

  List<McpLogEntry> entriesOf(String workspaceUuid) {
    final queue = _entries[workspaceUuid];
    if (queue == null) return const [];
    return queue.toList(growable: false);
  }

  List<McpLogEntry> recentOf(String workspaceUuid, int count) {
    final all = entriesOf(workspaceUuid);
    if (all.length <= count) return all;
    return all.sublist(all.length - count);
  }

  String? latestToolPurposeOf(String workspaceUuid) {
    return latestToolOf(workspaceUuid)?.purpose;
  }

  McpLogEntry? latestToolOf(String workspaceUuid) {
    final queue = _entries[workspaceUuid];
    if (queue == null) return null;
    for (final entry in queue.toList(growable: false).reversed) {
      if (entry.isToolCall) return entry;
    }
    return null;
  }

  McpLogEntry? activeToolOf(String workspaceUuid) {
    final queue = _entries[workspaceUuid];
    if (queue == null) return null;
    for (final entry in queue.toList(growable: false).reversed) {
      if (entry.isToolCall && entry.pending && entry.toolName != 'summary') {
        return entry;
      }
    }
    return null;
  }

  WorkspaceLogStats statsOf(String workspaceUuid) {
    return _stats.putIfAbsent(workspaceUuid, WorkspaceLogStats.new);
  }

  void add(McpLogEntry entry) {
    final queue = _entries.putIfAbsent(entry.workspaceUuid, Queue<McpLogEntry>.new);
    queue.addLast(entry);
    while (queue.length > maxLogEntriesPerWorkspace) {
      _releasePreviews(queue.removeFirst());
    }
    statsOf(entry.workspaceUuid).record(entry);
    _scheduleNotify();
  }

  void completeEntry(
    McpLogEntry entry, {
    required Map<String, dynamic> response,
    required int durationMs,
    required bool success,
    String? error,
  }) {
    entry.complete(response: response, durationMs: durationMs, success: success, error: error);
    if (!success) statsOf(entry.workspaceUuid).recordFailure();
    _scheduleNotify();
  }

  void clearEntries(String workspaceUuid) {
    _clearWorkspacePreviews(workspaceUuid);
    _entries.remove(workspaceUuid);
    _scheduleNotify();
  }

  void clear(String workspaceUuid) {
    _clearWorkspacePreviews(workspaceUuid);
    _entries.remove(workspaceUuid);
    _stats.remove(workspaceUuid);
    _scheduleNotify();
  }

  void clearAll() {
    for (final entry in _previewEntries.values.toList()) {
      _releasePreviews(entry);
    }
    _entries.clear();
    _stats.clear();
    _scheduleNotify();
  }

  void _scheduleNotify() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: logNotifyThrottleMs), () {
      _notifyTimer = null;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _notifyTimer?.cancel();
    clearAll();
    super.dispose();
  }
}
