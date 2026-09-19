import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:codexter/platform/macos/macos_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('重复退出请求共享一次服务清理，完成前不允许退出', () async {
    var calls = 0;
    final pending = Completer<void>();
    final lifecycle = MacosLifecycle(
      shutdown: () {
        calls++;
        return pending.future;
      },
    );
    final first = lifecycle.didRequestAppExit();
    final second = lifecycle.didRequestAppExit();
    expect(calls, 1);
    pending.complete();
    expect(await first, AppExitResponse.exit);
    expect(await second, AppExitResponse.exit);
  });

  test('同步清理异常取消退出，下一次可以重试', () async {
    var calls = 0;
    final lifecycle = MacosLifecycle(
      shutdown: () {
        calls++;
        if (calls == 1) throw StateError('模拟同步失败');
        return Future<void>.value();
      },
    );
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.cancel);
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.exit);
    expect(calls, 2);
  });

  test('异步清理异常取消退出，下一次可以重试', () async {
    var calls = 0;
    final lifecycle = MacosLifecycle(
      shutdown: () async {
        calls++;
        if (calls == 1) throw StateError('模拟异步失败');
      },
    );
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.cancel);
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.exit);
    expect(calls, 2);
  });

  test('超时后重试仍等待原任务，不并发启动另一轮清理', () async {
    var calls = 0;
    final pending = Completer<void>();
    final lifecycle = MacosLifecycle(
      shutdown: () {
        calls++;
        return pending.future;
      },
      timeout: const Duration(milliseconds: 20),
    );
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.cancel);
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.cancel);
    expect(calls, 1);
    pending.complete();
    expect(await lifecycle.didRequestAppExit(), AppExitResponse.exit);
    expect(calls, 1);
  });

  test('注册和注销幂等，注销后不再收到框架退出回调', () async {
    var calls = 0;
    final lifecycle = MacosLifecycle(
      shutdown: () async {
        calls++;
      },
    );
    addTearDown(lifecycle.detach);
    lifecycle.attach();
    final detach = lifecycle.attach();
    expect(await binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(calls, 1);
    detach();
    detach();
    expect(await binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(calls, 1);
  });
}
