import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/shell.dart';
import 'package:light/src/page/debug/device_debug_page.dart';
import 'package:light/src/page/device_config_page.dart';
import 'package:light/src/page/device_page.dart';
import 'package:light/src/page/home/devices_page.dart';
import 'package:light/src/page/home/home_page.dart';
import 'package:light/src/page/home/plans_page.dart';
import 'package:light/src/page/profile_page.dart';

import '../page/gateway_management_page.dart';
import '../page/mqtt_settings_page.dart';

/// 应用内所有页面的路由定义
enum AppRoute {
  home('/home'),
  devices('/devices'),
  plans('/plans'),
  profile('/profile'),
  gatewayManagement('/gateway-management'),
  mqttSettings('/mqtt-settings'),
  device('/device/:deviceId'),
  deviceDebug('/device-debug/:deviceId'),
  deviceModel('/device-model'),
  scan('/scan');

  const AppRoute(this.path);

  final String path;
}

extension AppRouterNavigation on BuildContext {
  void goHome() => goNamed(AppRoute.home.name);

  void goDevices() => goNamed(AppRoute.devices.name);

  void goPlans() => goNamed(AppRoute.plans.name);

  void pushProfile() => pushNamed(AppRoute.profile.name);

  void pushGatewayManagement() => pushNamed(AppRoute.gatewayManagement.name);

  void pushMqttSettings() => pushNamed(AppRoute.mqttSettings.name);

  void pushDevice(String deviceId) =>
      pushNamed(AppRoute.device.name, pathParameters: {'deviceId': deviceId});

  void pushDeviceDebug(String deviceId) => pushNamed(
    AppRoute.deviceDebug.name,
    pathParameters: {'deviceId': deviceId},
  );

  /// 打开协议模板页，传入模板标识时表示编辑已有模板
  void pushDeviceModel({String? modelId}) {
    final queryParameters = <String, dynamic>{};
    if (modelId != null) queryParameters['modelId'] = modelId;
    pushNamed(AppRoute.deviceModel.name, queryParameters: queryParameters);
  }
}

GoRouter buildAppRouter() {
  return GoRouter(
    initialLocation: AppRoute.home.path,
    routes: [
      GoRoute(
        name: AppRoute.profile.name,
        path: AppRoute.profile.path,
        builder: (context, state) => const ProfilePage(),
      ),
      GoRoute(
        name: AppRoute.gatewayManagement.name,
        path: AppRoute.gatewayManagement.path,
        builder: (context, state) => const GatewayManagementPage(),
      ),
      GoRoute(
        name: AppRoute.mqttSettings.name,
        path: AppRoute.mqttSettings.path,
        builder: (context, state) => MqttSettingsPage(),
      ),
      GoRoute(
        name: AppRoute.device.name,
        path: AppRoute.device.path,
        builder: (context, state) {
          final id = state.pathParameters['deviceId']!;
          // 所有设备都由设备模型驱动：本地配置优先，没有配置用内置 AT5 模型
          return DeviceRoutePage(deviceId: id);
        },
      ),
      GoRoute(
        name: AppRoute.deviceDebug.name,
        path: AppRoute.deviceDebug.path,
        builder: (context, state) =>
            DeviceDebugPage(deviceId: state.pathParameters['deviceId']!),
      ),
      GoRoute(
        name: AppRoute.deviceModel.name,
        path: AppRoute.deviceModel.path,
        builder: (context, state) =>
            DeviceConfigPage(modelId: state.uri.queryParameters['modelId']),
      ),
      GoRoute(
        name: AppRoute.scan.name,
        path: AppRoute.scan.path,
        redirect: (context, state) => AppRoute.devices.path,
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            AppShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [_route(AppRoute.home, const HomePage())],
          ),
          StatefulShellBranch(
            routes: [_route(AppRoute.devices, const DevicesPage())],
          ),
          StatefulShellBranch(
            routes: [_route(AppRoute.plans, const PlansPage())],
          ),
        ],
      ),
    ],
  );
}

GoRoute _route(AppRoute route, Widget child) {
  return GoRoute(
    name: route.name,
    path: route.path,
    pageBuilder: (context, state) => NoTransitionPage(child: child),
  );
}
