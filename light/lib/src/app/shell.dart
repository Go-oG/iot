import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/scope.dart';
import 'package:light/src/app/theme.dart';

class AppShell extends StatefulWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _lastMessageVersion = 0;

  static const _destinations = [
    ('首页', Icons.home_rounded),
    ('设备', Icons.hub_rounded),
    ('智能', Icons.alarm_on_rounded),
    ('配色', Icons.palette_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    if (controller.messageVersion != _lastMessageVersion) {
      _lastMessageVersion = controller.messageVersion;
      final message = controller.userMessage;
      if (message != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(message), behavior: SnackBarBehavior.floating));
        });
      }
    }

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF8FBFF), Color(0xFFEDF6FF)],
          ),
        ),
        child: SafeArea(bottom: false, child: widget.navigationShell),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: (index) =>
            widget.navigationShell.goBranch(index, initialLocation: index == widget.navigationShell.currentIndex),
        destinations: [
          for (final destination in _destinations)
            NavigationDestination(
              icon: Icon(destination.$2, color: AppColors.muted),
              selectedIcon: Icon(destination.$2, color: AppColors.blue),
              label: destination.$1,
            ),
        ],
      ),
    );
  }
}
