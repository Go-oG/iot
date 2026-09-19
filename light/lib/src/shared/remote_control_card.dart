import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../app/controller.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import '../core/protocol/remote_protocol.dart';
import 'app_widgets.dart';

class RemoteControlCard extends StatelessWidget {
  const RemoteControlCard({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    final config = controller.remoteSettings;
    final snapshot = controller.remote;
    final connecting = snapshot.connection == RemoteConnection.connecting;
    final connected = snapshot.connection == RemoteConnection.connected;
    final brokerLabel = switch (snapshot.connection) {
      RemoteConnection.connected => '已连接',
      RemoteConnection.connecting => '连接中',
      RemoteConnection.disconnected => '未连接',
    };
    final seen = snapshot.lastSeen?.toLocal();
    final hints = [
      if (!controller.remoteMatchesTarget) '请启用 MQTT 连接',
      if (snapshot.message != null) snapshot.message!,
    ];
    return SurfaceCard(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            '远程控制',
            trailing: TextButton(
              onPressed: controller.applying
                  ? null
                  : () => context.push('/mqtt-settings'),
              child: Text(config == null ? '配置连接' : '编辑连接'),
            ),
          ),
          if (config == null)
            const Text(
              '配置 MQTT 服务器与网关标识后，可在外网控制鱼缸灯。',
              style: TextStyle(color: AppColors.muted),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    config.gatewayId,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                StatusPill(
                  label: config.enabled ? brokerLabel : '已停用',
                  color: !config.enabled
                      ? AppColors.muted
                      : connected
                      ? AppColors.green
                      : connecting
                      ? AppColors.orange
                      : AppColors.muted,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                StatusPill(
                  label: snapshot.deviceOnline ? '网关在线' : '网关离线',
                  color: snapshot.deviceOnline
                      ? AppColors.green
                      : AppColors.muted,
                  icon: Icons.memory_rounded,
                ),
                StatusPill(
                  label: snapshot.lampConnected ? '灯具已连接' : '灯具未连接',
                  color: snapshot.lampConnected
                      ? AppColors.green
                      : AppColors.muted,
                  icon: Icons.lightbulb_outline_rounded,
                ),
                StatusPill(
                  label: controller.connectionLabel,
                  color: controller.isConnected
                      ? AppColors.blue
                      : AppColors.muted,
                  icon: Icons.route_rounded,
                ),
              ],
            ),
            if (seen != null) ...[
              const SizedBox(height: 8),
              Text(
                '最近状态 ${seen.toIso8601String().split('.').first.replaceFirst('T', ' ')}',
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
            for (final hint in hints) ...[
              const SizedBox(height: 6),
              Text(
                hint,
                style: const TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
            const Divider(height: 22),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 8,
              runSpacing: 4,
              children: [
                _CardAction(
                  icon: Icons.terminal_rounded,
                  label: '消息调试',
                  onPressed: () => context.push('/mqtt-debug'),
                ),
                _CardAction(
                  icon: Icons.refresh_rounded,
                  label: '重连服务器',
                  onPressed: controller.applying
                      ? null
                      : controller.reconnectRemote,
                ),
                _CardAction(
                  icon: Icons.memory_rounded,
                  label: 'ESP32 管理',
                  onPressed: () => context.push('/gateway-management'),
                ),
                _CardAction(
                  icon: Icons.delete_outline_rounded,
                  label: '移除连接',
                  onPressed: controller.applying
                      ? null
                      : () => _confirmRemove(context, controller),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 移除远程连接前二次确认
  Future<void> _confirmRemove(
    BuildContext context,
    AppController controller,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除远程连接'),
        content: const Text('将删除已保存的 MQTT 服务器配置，之后无法再远程控制设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await controller.clearRemoteSettings();
    } catch (_) {
      controller.showMessage('移除连接失败，请重试');
    }
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tint = onPressed == null
        ? AppColors.muted.withValues(alpha: 0.4)
        : AppColors.blue;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: tint,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
