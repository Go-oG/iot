import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/router.dart';
import '../app/scope.dart';
import '../app/theme.dart';
import 'app_widgets.dart';

class RemoteControlCard extends StatelessWidget {
  final EdgeInsets margin;

  const RemoteControlCard({super.key, this.margin = const EdgeInsets.symmetric(horizontal: 16)});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.watch(context);
    final config = controller.remoteSettings;
    final snapshot = controller.remote;
    final connected = snapshot.connection.isConnected;

    final hints = [if (!controller.remoteMatchesTarget) '请启用 MQTT 连接', if (snapshot.message != null) snapshot.message!];

    List<Widget> wList = [];
    wList.add(
      SectionTitle(
        config?.gatewayId ?? "暂未连接",
        titleIcon: OnlineStatusView(online: config != null && connected),
        trailing: IconButton(
          tooltip: config == null ? '配置连接' : '编辑连接',
          onPressed: controller.devicesBusy
              ? null
              : context.pushMqttSettings,
          icon: const Icon(Icons.edit, color: AppColors.blue, size: 24),
        ),
      ),
    );
    if (config == null) {
      wList.add(const Text('配置 MQTT 服务器与网关标识后，可在外网控制鱼缸灯。', style: TextStyle(color: AppColors.grey)));
    } else {
      for (final hint in hints) {
        wList.add(Text(hint, style: const TextStyle(fontSize: 12, color: AppColors.muted)));
      }
      wList.add(const Divider(height: 22));
      wList.add(
        // 窄屏下四个入口按可用宽度换行，避免长标签横向溢出
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.spaceBetween,
          children: [
            _CardAction(
              icon: Icons.terminal_rounded,
              label: '消息调试',
              onPressed: context.pushMqttDebug,
            ),
            _CardAction(
              icon: Icons.refresh_rounded,
              label: '重连服务器',
              onPressed: controller.devicesBusy ? null : controller.reconnectRemote,
            ),
            _CardAction(
              icon: Icons.memory_rounded,
              label: 'ESP32 管理',
              onPressed: context.pushGatewayManagement,
            ),
            _CardAction(
              icon: Icons.delete_outline_rounded,
              label: '移除连接',
              onPressed: controller.devicesBusy
                  ? null
                  : () => _confirmRemove(context, controller),
            ),
          ],
        ),
      );
    }

    return SurfaceCard(
      margin: margin,
      padding: EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: wList),
    );
  }

  /// 移除远程连接前二次确认
  Future<void> _confirmRemove(BuildContext context, AppController controller) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('移除远程连接'),
        content: const Text('将删除已保存的 MQTT 服务器配置，之后无法再远程控制设备。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('移除')),
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
  const _CardAction({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tint = onPressed == null ? AppColors.muted.withValues(alpha: 0.4) : AppColors.blue;
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
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: tint),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
