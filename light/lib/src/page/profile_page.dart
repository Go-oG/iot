import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/app/scope.dart';
import 'package:light/src/app/theme.dart';
import 'package:light/src/data/models.dart';

import '../dialog/scene.dart';
import '../widgets/app_widgets.dart';

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('配色与数据'),
        leading: BackButton(
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/devices');
            }
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_upload_outlined),
            tooltip: '导出数据',
            onPressed: () => controller.exportData(
              sharePositionOrigin: _shareOrigin(context),
            ),
          ),
        ],
      ),
      body: SafeArea(top: false, child: _buildContent(context, controller)),
    );
  }

  Widget _buildContent(BuildContext context, AppController controller) {
    final visibleScenes = controller.scenes;
    return ListView(
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      children: [
        SurfaceCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: [
              SectionTitle(
                '我的配色 (${visibleScenes.length})',
                trailing: TextButton.icon(
                  onPressed: () => _editScene(context, controller),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('新增配色'),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '点击应用到鱼缸灯，更多菜单可编辑或删除',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (visibleScenes.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('暂无配色，点击“新增配色”从内置模板开始'),
                ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                  mainAxisExtent: 180,
                ),
                itemCount: visibleScenes.length,
                itemBuilder: (context, index) {
                  final scene = visibleScenes[index];
                  return _SceneCard(
                    scene: scene,
                    onTap: () => controller.applyScene(scene),
                    onEdit: () => _showSceneActions(context, controller, scene),
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SurfaceCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle('配色与数据工具'),
              const SizedBox(height: 10),
              GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.18,
                children: [
                  _ActionTile(
                    icon: Icons.add_to_photos_outlined,
                    label: '保存当前配色',
                    subtitle: '收藏五路调色',
                    onTap: () =>
                        _editScene(context, controller, useCurrent: true),
                  ),
                  _ActionTile(
                    icon: Icons.save_outlined,
                    label: '导入导出',
                    subtitle: '备份与分享',
                    onTap: () => _showDataActions(context, controller),
                  ),
                  _ActionTile(
                    icon: Icons.share_outlined,
                    label: '分享配色',
                    subtitle: '邀请家人使用',
                    onTap: () => _showSceneShare(context, controller),
                  ),
                  _ActionTile(
                    icon: Icons.schedule_rounded,
                    label: '照明计划',
                    subtitle: '设置亮灯时段',
                    onTap: () => context.go('/plans'),
                  ),
                  _ActionTile(
                    icon: Icons.restart_alt_rounded,
                    label: '配网与重置',
                    subtitle: '设备异常处理',
                    onTap: () => _showResetActions(context, controller),
                  ),
                  _ActionTile(
                    icon: Icons.wifi_find_rounded,
                    label: '发现设备',
                    subtitle: '经网关扫描附近设备',
                    onTap: () => context.go('/devices'),
                  ),
                  _ActionTile(
                    icon: Icons.tune_rounded,
                    label: '通用设备协议',
                    subtitle: '配置读写命令与编码',
                    onTap: () => context.go('/device-functions'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

Future<void> _editScene(
  BuildContext context,
  AppController controller, {
  ScenePreset? scene,
  bool useCurrent = false,
}) async {
  final result = await showSceneEditor(
    context,
    newId: controller.createSceneId(),
    scene: scene,
    initialState: useCurrent ? controller.lightState : null,
  );
  if (result != null) {
    controller.saveScene(result);
  }
}

Future<void> _showSceneActions(
  BuildContext context,
  AppController controller,
  ScenePreset scene,
) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            title: Text(
              scene.name,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: Text(scene.subtitle),
          ),
          ListTile(
            leading: const Icon(Icons.edit_rounded, color: AppColors.blue),
            title: const Text('编辑配色'),
            onTap: () {
              Navigator.pop(sheetContext);
              _editScene(context, controller, scene: scene);
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune_rounded, color: AppColors.blue),
            title: const Text('用当前灯光更新'),
            subtitle: const Text('载入当前五路数值，编辑后保存'),
            onTap: () {
              Navigator.pop(sheetContext);
              _editScene(context, controller, scene: scene, useCurrent: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined, color: AppColors.blue),
            title: const Text('导出配色'),
            onTap: () {
              Navigator.pop(sheetContext);
              controller.exportScene(
                scene,
                sharePositionOrigin: _shareOrigin(context),
              );
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.red,
            ),
            title: const Text('删除配色'),
            onTap: () async {
              Navigator.pop(sheetContext);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除配色'),
                  content: Text(
                    '确定删除“${scene.name}”吗？\n引用它的 ${controller.schedules.where((plan) => plan.sceneId == scene.id).length} 个本地计划也会被删除，灯具当前配色保持不变。',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('删除'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                controller.deleteScene(scene);
              }
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _showDataActions(BuildContext context, AppController controller) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          const ListTile(
            title: Text('本地数据', style: TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text('备份包含配色、计划、设备和控制设置'),
          ),
          ListTile(
            leading: const Icon(
              Icons.file_download_outlined,
              color: AppColors.blue,
            ),
            title: const Text('导入 JSON 备份'),
            onTap: () {
              Navigator.pop(sheetContext);
              controller.importData();
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.file_upload_outlined,
              color: AppColors.blue,
            ),
            title: const Text('导出全部数据'),
            onTap: () {
              Navigator.pop(sheetContext);
              controller.exportData(sharePositionOrigin: _shareOrigin(context));
            },
          ),
        ],
      ),
    ),
  );
}

Future<void> _showSceneShare(BuildContext context, AppController controller) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.6,
        child: ListView(
          children: [
            const ListTile(
              title: Text(
                '选择要导出的配色',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            if (controller.scenes.isEmpty)
              const ListTile(title: Text('暂无配色，请先新增或保存当前配色')),
            for (final scene in controller.scenes)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Color(scene.accentValue),
                ),
                title: Text(scene.name),
                subtitle: Text(scene.subtitle),
                onTap: () {
                  Navigator.pop(sheetContext);
                  controller.exportScene(
                    scene,
                    sharePositionOrigin: _shareOrigin(context),
                  );
                },
              ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _showResetActions(BuildContext context, AppController controller) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(
              Icons.bluetooth_searching_rounded,
              color: AppColors.blue,
            ),
            title: const Text('设备配网'),
            subtitle: const Text('扫描和连接附近灯具'),
            onTap: () {
              Navigator.pop(sheetContext);
              context.go('/devices');
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.restart_alt_rounded,
              color: AppColors.red,
            ),
            title: const Text('恢复默认数据'),
            subtitle: const Text('清除配色、计划、设备和控制设置'),
            onTap: () async {
              Navigator.pop(sheetContext);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('恢复默认数据'),
                  content: const Text('此操作会清除所有本地数据，且无法撤销'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('继续'),
                    ),
                  ],
                ),
              );
              if (confirmed == true) {
                await controller.resetAllData();
              }
            },
          ),
        ],
      ),
    ),
  );
}

Rect _shareOrigin(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return Rect.fromLTWH(size.width / 2, size.height / 2, 1, 1);
}

class _SceneCard extends StatelessWidget {
  const _SceneCard({
    required this.scene,
    required this.onTap,
    required this.onEdit,
  });

  final ScenePreset scene;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          children: [
            Expanded(child: SceneArtwork(accent: Color(scene.accentValue))),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.palette_outlined,
                    color: Color(scene.accentValue),
                    size: 17,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          scene.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          '平均亮度 ${scene.state.powerPercent}%',
                          style: const TextStyle(
                            color: AppColors.muted,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: onEdit,
                    tooltip: '管理${scene.name}',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    icon: const Icon(Icons.more_vert_rounded, size: 17),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(9, 0, 9, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    scene.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.muted,
                      fontSize: 10,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '红 ${scene.state.red} · 绿 ${scene.state.green} · 蓝 ${scene.state.blue}\n白 ${scene.state.white} · UV ${scene.state.uv}',
                    style: const TextStyle(fontSize: 10),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(11),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFFF8FBFF),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AppColors.line),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: AppColors.blue, size: 24),
            const SizedBox(height: 5),
            Text(
              label,
              maxLines: 1,
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800),
            ),
            Text(
              subtitle,
              maxLines: 1,
              style: const TextStyle(color: AppColors.muted, fontSize: 8),
            ),
          ],
        ),
      ),
    );
  }
}
