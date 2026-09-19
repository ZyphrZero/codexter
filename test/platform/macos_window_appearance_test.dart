import 'dart:async';

import 'package:codexter/platform/macos/macos_window_appearance.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const light = Color(0xFFF7F7F8);
  const dark = Color(0xFF15161A);
  late MacosWindowAppearance appearance;
  final calls = <MethodCall>[];

  setUp(() {
    appearance = MacosWindowAppearance();
    calls.clear();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    appearance.dispose();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, null);
  });

  test('相同外观只同步一次，传给原生的是不透明 ARGB 底色', () async {
    await appearance.update(darkMode: false, background: light.withValues(alpha: 0));
    await appearance.update(darkMode: false, background: light);
    expect(calls, hasLength(1));
    expect(calls.single.arguments, {'dark': false, 'background': light.toARGB32()});
  });

  test('快速切换在发送前合并，最终以最新主题为准', () async {
    final first = appearance.update(darkMode: false, background: light);
    final second = appearance.update(darkMode: true, background: dark);
    await Future.wait([first, second]);
    expect(calls, hasLength(1));
    expect(calls.single.arguments, {'dark': true, 'background': dark.toARGB32()});
  });

  test('原生调用尚未返回时串行同步，旧主题不能在新主题后落地', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, (
      call,
    ) async {
      calls.add(call);
      if (calls.length == 1) {
        started.complete();
        await release.future;
      }
      return null;
    });
    final first = appearance.update(darkMode: false, background: light);
    await started.future;
    final second = appearance.update(darkMode: true, background: dark);
    expect(calls, hasLength(1));
    release.complete();
    await Future.wait([first, second]);
    expect(calls.map((call) => call.arguments['dark']), [false, true]);
  });

  test('通道失败不向界面抛出异常，下次通知可重试', () async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(MacosWindowAppearance.channel, (
      call,
    ) async {
      calls.add(call);
      if (calls.length == 1) throw PlatformException(code: 'unavailable');
      return null;
    });
    await appearance.update(darkMode: true, background: dark);
    await appearance.update(darkMode: true, background: dark);
    expect(calls, hasLength(2));
  });

  test('窗口销毁后不再同步排队的外观请求', () async {
    final pending = appearance.update(darkMode: false, background: light);
    appearance.dispose();
    await pending;
    await appearance.update(darkMode: true, background: dark);
    expect(calls, isEmpty);
  });
}
