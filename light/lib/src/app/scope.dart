import 'package:flutter/widgets.dart';
import 'package:light/src/app/controller.dart';

final class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    required AppController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static AppController? _controller;

  static void init(AppController controller) {
    _controller = controller;
    controller.initialize();
  }

  static void dispose() {
    controller.dispose();
    _controller = null;
  }

  /// 在构建界面时订阅状态，异步回调中仍可直接读取 controller
  static AppController watch(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static AppController get controller => _controller!;
}
