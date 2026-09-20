import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/app/router.dart';
import 'package:light/src/app/scope.dart';
import 'package:light/src/app/theme.dart';
import 'package:light/src/core/device/device_model_catalog.dart';
import 'package:light/src/data/database.dart';
import 'package:light/src/data/remote_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await DeviceModelCatalog.load();
  final database = await AppDatabase.open();
  final controller = AppController(database, remoteStore: SecureRemoteSettingsStore());
  runApp(MyApp(controller: controller));
}

class MyApp extends StatefulWidget {
  const MyApp({required this.controller, super.key});

  final AppController controller;

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppScope.init(widget.controller);
    _router = buildAppRouter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.startConnections();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    AppScope.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    AppScope.controller.setForeground(state == AppLifecycleState.resumed);
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      child: MaterialApp.router(
        title: 'Light',
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: _router,
      ),
    );
  }
}
