import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:light/src/app/controller.dart';
import 'package:light/src/app/scope.dart';
import 'package:light/src/app/theme.dart';
import 'package:light/src/data/models.dart';
import 'package:light/src/shared/app_widgets.dart';

import '../dialog/schedule.dart';

class PlansPage extends StatefulWidget {
  const PlansPage({super.key});

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  bool _showTimers = true;

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.controller;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        AppPageHeader(
          title: '计划',
          subtitle: '安排鱼缸灯的每日照明',
          action: AppIconButton(
            icon: Icons.add_rounded,
            filled: true,
            onPressed: () => _editPlan(context, controller),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: true, label: Text('定时刻')),
              ButtonSegment(value: false, label: Text('日出日落')),
            ],
            selected: {_showTimers},
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? AppColors.blue
                    : Colors.white,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? Colors.white
                    : AppColors.navy,
              ),
              side: const WidgetStatePropertyAll(BorderSide.none),
            ),
            onSelectionChanged: (selection) {
              setState(() => _showTimers = selection.first);
            },
          ),
        ),
        const SizedBox(height: 12),
        if (_showTimers)
          SurfaceCard(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.fromLTRB(12, 13, 12, 7),
            child: Column(
              children: [
                SectionTitle('定时计划 (${controller.schedules.length})'),
                const SizedBox(height: 6),
                for (final plan in controller.schedules)
                  _ScheduleRow(
                    plan: plan,
                    scene: controller.scenes.firstWhere(
                      (scene) => scene.id == plan.sceneId,
                      orElse: () => controller.scenes.first,
                    ),
                    onChanged: () => controller.toggleSchedule(plan),
                    onEdit: () => _showPlanActions(context, controller, plan),
                  ),
              ],
            ),
          )
        else
          SurfaceCard(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Column(
                children: [
                  Icon(
                    Icons.light_mode_rounded,
                    color: AppColors.orange,
                    size: 42,
                  ),
                  SizedBox(height: 10),
                  Text(
                    '灯光将跟随当地日出与日落',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  SizedBox(height: 5),
                  Text(
                    '日出前渐亮，日落后自动进入夜间模式',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 10),
        SurfaceCard(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '日出日落联动',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 3),
              const Text(
                '根据地理位置，自动调节照明亮度',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 140,
                width: double.infinity,
                child: CustomPaint(painter: const _SunCurvePainter()),
              ),
              const Row(
                children: [
                  Expanded(
                    child: _SunTime(
                      icon: Icons.wb_twilight_rounded,
                      color: AppColors.orange,
                      label: '日出',
                      time: '06:00',
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: _SunTime(
                      icon: Icons.wb_sunny_rounded,
                      color: AppColors.red,
                      label: '正午',
                      time: '18:00',
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: _SunTime(
                      icon: Icons.nightlight_round,
                      color: AppColors.blue,
                      label: '夜间',
                      time: '22:00',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: controller.isConnected
                      ? () {
                          if (controller.scenes.isNotEmpty) {
                            controller.applyScene(controller.scenes.first);
                          }
                        }
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: Text(controller.isConnected ? '预览效果' : '连接设备后预览'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _editPlan(
  BuildContext context,
  AppController controller, [
  SchedulePlan? plan,
]) async {
  final result = await showScheduleEditor(
    context,
    newId: controller.nextScheduleId,
    scenes: controller.scenes,
    plan: plan,
  );
  if (result != null) {
    controller.saveSchedule(result);
  }
}

Future<void> _showPlanActions(
  BuildContext context,
  AppController controller,
  SchedulePlan plan,
) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.edit_rounded, color: AppColors.blue),
            title: const Text('编辑计划'),
            onTap: () {
              Navigator.pop(sheetContext);
              _editPlan(context, controller, plan);
            },
          ),
          ListTile(
            leading: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.red,
            ),
            title: const Text('删除计划'),
            onTap: () async {
              Navigator.pop(sheetContext);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('删除计划'),
                  content: Text('确定删除 ${plan.timeLabel} 的计划吗？'),
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
                controller.deleteSchedule(plan);
              }
            },
          ),
        ],
      ),
    ),
  );
}

class _ScheduleRow extends StatelessWidget {
  const _ScheduleRow({
    required this.plan,
    required this.scene,
    required this.onChanged,
    required this.onEdit,
  });

  final SchedulePlan plan;
  final ScenePreset scene;
  final VoidCallback onChanged;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.line)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: AppColors.paleBlue,
            foregroundColor: AppColors.navy,
            child: Text(
              '${plan.id}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 7),
          Transform.scale(
            scale: 0.78,
            child: Switch(value: plan.enabled, onChanged: (_) => onChanged()),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  plan.timeLabel,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  plan.repeatLabel,
                  style: const TextStyle(color: AppColors.muted, fontSize: 10),
                ),
              ],
            ),
          ),
          Container(
            width: 38,
            height: 38,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(9)),
            child: SceneArtwork(accent: Color(scene.accentValue), height: 38),
          ),
          const SizedBox(width: 7),
          SizedBox(
            width: 34,
            child: Text(
              scene.name,
              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: onEdit,
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.muted,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _SunTime extends StatelessWidget {
  const _SunTime({
    required this.icon,
    required this.color,
    required this.label,
    required this.time,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String time;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FBFF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 5),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 9)),
                Text(
                  time,
                  maxLines: 1,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SunCurvePainter extends CustomPainter {
  const _SunCurvePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final chart = Rect.fromLTWH(3, 8, size.width - 6, size.height - 24);
    final gridPaint = Paint()
      ..color = AppColors.line
      ..strokeWidth = 1;
    for (var i = 0; i <= 5; i++) {
      final x = chart.left + chart.width * i / 5;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom), gridPaint);
    }
    for (var i = 0; i <= 3; i++) {
      final y = chart.top + chart.height * i / 3;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
    }

    final curve = Path()..moveTo(chart.left, chart.bottom);
    for (var i = 0; i <= 100; i++) {
      final fraction = i / 100;
      final x = chart.left + chart.width * fraction;
      final daylight = math.sin(fraction * math.pi).clamp(0.0, 1.0);
      final y = chart.bottom - daylight * chart.height * 0.88;
      curve.lineTo(x, y);
    }
    final fill = Path.from(curve)
      ..lineTo(chart.right, chart.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66FFD25A), Color(0x2238A7FF)],
        ).createShader(chart),
    );
    canvas.drawPath(
      curve,
      Paint()
        ..shader = const LinearGradient(
          colors: [AppColors.blue, AppColors.orange, AppColors.red],
        ).createShader(chart)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    canvas.drawCircle(
      Offset(chart.center.dx, chart.top + chart.height * 0.12),
      9,
      Paint()..color = AppColors.orange,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
