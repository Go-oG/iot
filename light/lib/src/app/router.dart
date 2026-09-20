import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/shell.dart';
import 'package:light/src/page/debug/device_debug_page.dart';
import 'package:light/src/page/device_model_config_page.dart';
import 'package:light/src/page/device_model_page.dart';
import 'package:light/src/page/home/devices_page.dart';
import 'package:light/src/page/home/home_page.dart';
import 'package:light/src/page/home/plans_page.dart';
import 'package:light/src/page/profile_page.dart';

import '../core/protocol/remote_protocol.dart';
import '../page/debug/mqtt_debug_page.dart';
import '../page/gateway_management_page.dart';
import '../page/mqtt_settings_page.dart';
import 'scope.dart';

GoRouter buildAppRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfilePage(),
      ),
      GoRoute(
        path: '/gateway-management',
        builder: (context, state) => const GatewayManagementPage(),
      ),
      GoRoute(
        path: '/mqtt-settings',
        builder: (context, state) => MqttSettingsPage(),
      ),
      GoRoute(
        path: '/mqtt-debug',
        builder: (context, state) {
          // 远程控制已连接时直接建立调试连接，避免两处状态不一致
          return MqttDebugPage(
            settings: AppScope.controller.remoteSettings,
            autoConnect:
                AppScope.controller.remote.connection ==
                ConnectionStatus.connected,
          );
        },
      ),
      GoRoute(
        path: '/device/:deviceId',
        builder: (context, state) {
          final id = state.pathParameters['deviceId']!;
          // 所有设备都由设备模型驱动：本地配置优先，没有配置用内置 AT5 模型
          return DeviceModelDevicePage(deviceId: id);
        },
      ),
      GoRoute(
        path: '/device-debug/:deviceId',
        builder: (context, state) =>
            DeviceDebugPage(deviceId: state.pathParameters['deviceId']!),
      ),
      GoRoute(
        path: '/device-model',
        builder: (context, state) =>
            DeviceModelConfigPage(deviceId: state.uri.queryParameters['deviceId']),
      ),
      GoRoute(path: '/scan', redirect: (context, state) => '/devices'),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [_route('/home', const HomePage())]),
          StatefulShellBranch(
            routes: [_route('/devices', const DevicesPage())],
          ),
          StatefulShellBranch(routes: [_route('/plans', const PlansPage())]),
        ],
      ),
    ],
  );
}

GoRoute _route(String path, Widget child) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) => NoTransitionPage(child: child),
  );
}
