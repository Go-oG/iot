import 'package:light/src/app/controller.dart';

import '../data/database.dart';

final class AppScope {
  static final _scope = AppScope._();

  late final AppController _controller;

  AppScope._();

  void _init() {
    _controller = AppController(AppDatabase.memory());
    _controller.initialize();
  }

  static void init() => _scope._init();

  static void dispose() {
    controller.dispose();
  }

  static AppScope of() => _scope;

  static AppController get controller => _scope._controller;
}
