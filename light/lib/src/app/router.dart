import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/shell.dart';
import 'package:light/src/page/debug/device_debug_page.dart';
import 'package:light/src/page/device_detail_page.dart';
import 'package:light/src/page/devices_page.dart';
import 'package:light/src/page/home_page.dart';
import 'package:light/src/page/plans_page.dart';
import 'package:light/src/page/profile_page.dart';

import '../core/protocol/remote_protocol.dart';
import '../page/debug/mqtt_debug_page.dart';
import '../page/device_functions_page.dart';
import '../page/gateway_management_page.dart';
import '../page/mqtt_settings_page.dart';
import 'scope.dart';

GoRouter buildAppRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(path: '/gateway-management', builder: (context, state) => const GatewayManagementPage()),
      GoRoute(path: '/mqtt-settings', builder: (context, state) => MqttSettingsPage()),
      GoRoute(
        path: '/mqtt-debug',
        builder: (context, state) {
          // 远程控制已连接时直接建立调试连接，避免两处状态不一致
          return MqttDebugPage(
            settings: AppScope.controller.remoteSettings,
            autoConnect: AppScope.controller.remote.connection == RemoteConnection.connected,
          );
        },
      ),
      GoRoute(
        path: '/device/:deviceId',
        builder: (context, state) => DeviceDetailPage(deviceId: state.pathParameters['deviceId']!),
      ),
      GoRoute(
        path: '/device-debug/:deviceId',
        builder: (context, state) => DeviceDebugPage(deviceId: state.pathParameters['deviceId']!),
      ),
      GoRoute(
        path: '/device-functions',
        builder: (context, state) {
          final controller = AppScope.controller;
          final id = state.uri.queryParameters['deviceId'];
          final existing = controller.deviceConfigurations.where((item) => item.id == id).firstOrNull;
          return DeviceFunctionsPage(
            initialConfiguration: controller.configurationForDevice(id),
            existingConfigurationId: existing?.id,
            onSave: (configuration, previousId) =>
                controller.saveDeviceConfiguration(configuration, previousId: previousId),
          );
        },
      ),
      GoRoute(path: '/scan', redirect: (context, state) => '/devices'),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) => AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [_route('/home', const HomePage())]),
          StatefulShellBranch(routes: [_route('/devices', const DevicesPage())]),
          StatefulShellBranch(routes: [_route('/plans', const PlansPage())]),
          StatefulShellBranch(routes: [_route('/profile', const ProfilePage())]),
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
