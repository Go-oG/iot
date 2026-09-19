import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/keep_alive.dart';
import '../../core/protocol/mqtt_debug_client.dart';
import '../../core/protocol/protocol.dart';
import '../../data/remote_settings.dart';
import '../../shared/app_widgets.dart';

/// QoS 候选说明，同时用于底部选择和消息气泡展示
const Map<int, String> _qosLabels = {
  0: 'QoS 0 · 最多一次',
  1: 'QoS 1 · 至少一次',
  2: 'QoS 2 · 仅一次',
};

class MqttDebugPage extends StatefulWidget {
  const MqttDebugPage({
    required this.settings,
    this.client,
    this.autoConnect = false,
    super.key,
  });

  final RemoteSettings? settings;
  final MqttDebugClient? client;

  /// 远程控制已连接时进入页面自动建立调试连接，保持连接状态一致
  final bool autoConnect;

  @override
  State<MqttDebugPage> createState() => _MqttDebugPageState();
}

class _MqttDebugPageState extends State<MqttDebugPage> {
  late final MqttDebugClient _client = widget.client ?? MqttDebugClient();
  late final TextEditingController _subscribeTopic = TextEditingController(
    text: widget.settings == null
        ? ''
        : GatewayTopics(widget.settings!.gatewayId).up,
  );
  late final TextEditingController _publishTopic = TextEditingController(
    text: widget.settings == null
        ? ''
        : GatewayTopics(widget.settings!.gatewayId).down,
  );
  final _payload = TextEditingController();
  bool _subscribing = false;
  bool _syncTopics = true;
  bool _showSettings = true;
  bool _keepAlive = false;
  bool _keepAliveFailed = false;
  int _qos = 1;
  bool _retain = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscribeTopic.addListener(_onSubscribeTopicChanged);
    _publishTopic.addListener(_onPublishTopicChanged);
    if (widget.autoConnect && widget.settings?.enabled == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_client.connected && !_client.connecting)
          unawaited(_connect());
      });
    }
  }

  @override
  void dispose() {
    _subscribeTopic.removeListener(_onSubscribeTopicChanged);
    _publishTopic.removeListener(_onPublishTopicChanged);
    if (_keepAlive) {
      _keepAlive = false;
      unawaited(KeepAliveService.stop(owner: KeepAliveService.debugOwner));
    }
    _client.dispose();
    _subscribeTopic.dispose();
    _publishTopic.dispose();
    _payload.dispose();
    super.dispose();
  }

  /// 订阅与发送 Topic 默认保持一致，用户解除同步后可分别修改
  void _onSubscribeTopicChanged() {
    if (!_syncTopics || _publishTopic.text == _subscribeTopic.text) return;
    _publishTopic.text = _subscribeTopic.text;
  }

  void _onPublishTopicChanged() {
    if (!_syncTopics || _subscribeTopic.text == _publishTopic.text) return;
    _subscribeTopic.text = _publishTopic.text;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = switch (error) {
          FormatException() => error.message,
          StateError() => error.message,
          _ => '操作失败，请检查网络、服务器、证书、账号或主题权限',
        };
      });
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(_error!)));
    }
  }

  Future<void> _connect() async {
    final settings = widget.settings;
    if (settings == null) return;
    await _run(() => _client.connect(settings));
    if (mounted && _client.connected && KeepAliveService.supported)
      unawaited(_startKeepAlive());
  }

  /// 连接成功后申请息屏保持，失败时仅提示，不影响调试连接
  Future<void> _startKeepAlive() async {
    final active = await KeepAliveService.start(
      owner: KeepAliveService.debugOwner,
      title: 'MQTT调试连接',
      text: '正在保持调试连接，避免息屏后断开',
    );
    if (!mounted || (_keepAlive == active && _keepAliveFailed == !active))
      return;
    setState(() {
      _keepAlive = active;
      _keepAliveFailed = !active;
    });
  }

  Future<void> _disconnect() async {
    final keepAlive = _keepAlive;
    setState(() {
      _keepAlive = false;
      _keepAliveFailed = false;
    });
    _client.disconnect();
    if (keepAlive) {
      await KeepAliveService.stop(owner: KeepAliveService.debugOwner);
    }
  }

  Future<void> _subscribe() async {
    setState(() => _subscribing = true);
    await _run(() => _client.subscribe(_subscribeTopic.text.trim(), qos: _qos));
    if (mounted) setState(() => _subscribing = false);
  }

  Future<void> _send() async {
    await _run(
      () => Future.sync(
        () => _client.publish(
          _publishTopic.text.trim(),
          _payload.text,
          qos: _qos,
          retain: _retain,
        ),
      ),
    );
    if (mounted && _error == null) _payload.clear();
  }

  void _toggleSync() {
    setState(() => _syncTopics = !_syncTopics);
    if (_syncTopics) _onSubscribeTopicChanged();
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      appBar: AppBar(
        title: settings == null
            ? const Text('MQTT 消息调试')
            : Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _MarqueeText(
                  text: '${settings.host}:${settings.port}',
                  maxWidth: 200,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
        actions: settings == null
            ? null
            : [
                ListenableBuilder(
                  listenable: _client,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Center(
                        child: StatusPill(
                          label: _statusLabel,
                          color: _statusColor,
                        ),
                      ),
                      Center(
                        child: TextButton(
                          onPressed: _client.connected || _client.connecting
                              ? _disconnect
                              : _connect,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            visualDensity: VisualDensity.compact,
                            textStyle: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(fontSize: 13),
                          ),
                          child: Text(_actionLabel),
                        ),
                      ),
                      IconButton(
                        tooltip: '清空消息记录',
                        onPressed: _client.entries.isEmpty
                            ? null
                            : _client.clearEntries,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                      ),
                    ],
                  ),
                ),
              ],
      ),
      body: SafeArea(
        child: settings == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('请先保存 MQTT 服务器配置'),
                    TextButton(
                      onPressed: () => context.push('/mqtt-settings'),
                      child: const Text('配置连接'),
                    ),
                  ],
                ),
              )
            : ListenableBuilder(
                listenable: _client,
                builder: (context, _) => Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                      child: _settingsCard(),
                    ),
                    if (_keepAlive || _keepAliveFailed)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: _keepAliveHint(),
                      ),
                    Expanded(child: _messageList()),
                    _composer(),
                  ],
                ),
              ),
      ),
    );
  }

  String get _statusLabel => _client.connected
      ? '已连接'
      : _client.reconnecting
      ? '重连中'
      : _client.connecting
      ? '连接中'
      : '未连接';

  Color get _statusColor => _client.connected
      ? AppColors.green
      : _client.connecting || _client.reconnecting
      ? AppColors.orange
      : AppColors.muted;

  String get _actionLabel => _client.connected
      ? '断开连接'
      : _client.connecting
      ? '取消'
      : '重新连接';

  Widget _keepAliveHint() {
    final color = _keepAlive ? AppColors.muted : AppColors.orange;
    return Row(
      children: [
        Icon(
          _keepAlive ? Icons.battery_saver_outlined : Icons.error_outline,
          size: 14,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            _keepAlive ? '息屏保持已开启，锁屏后连接不会断开' : '息屏保持未开启，请在系统中允许关闭电池优化',
            style: TextStyle(fontSize: 12, color: color),
          ),
        ),
      ],
    );
  }

  Widget _settingsCard() {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionTitle(
            '订阅与发送',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!_showSettings)
                  Text(
                    '已订阅 ${_client.topics.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                IconButton(
                  tooltip: _syncTopics
                      ? '订阅与发送 Topic 保持一致，点击后可分别修改'
                      : '订阅与发送 Topic 各自独立，点击后恢复一致',
                  onPressed: _toggleSync,
                  icon: Icon(
                    _syncTopics ? Icons.link_rounded : Icons.link_off_rounded,
                    size: 20,
                  ),
                ),
                IconButton(
                  tooltip: _showSettings ? '收起配置' : '展开配置',
                  onPressed: () =>
                      setState(() => _showSettings = !_showSettings),
                  icon: Icon(
                    _showSettings ? Icons.expand_less : Icons.expand_more,
                  ),
                ),
              ],
            ),
          ),
          if (_showSettings) ...[
            TextField(
              controller: _subscribeTopic,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '订阅 Topic',
                helperText: '支持 + 和 # 通配符，默认与发送 Topic 相同',
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _publishTopic,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '发送 Topic',
                helperText: '不支持通配符，按 UTF-8 原样发送',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonal(
                  onPressed: _client.connected && !_subscribing
                      ? _subscribe
                      : null,
                  child: Text(_subscribing ? '等待确认…' : '订阅'),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '订阅使用底部所选 QoS $_qos，可按条切换',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
            if (_client.topics.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final topic in _client.topics)
                    InputChip(
                      label: Text(topic, style: const TextStyle(fontSize: 12)),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      deleteButtonTooltipMessage: '取消订阅 $topic',
                      onDeleted: () =>
                          _run(() async => _client.unsubscribe(topic)),
                      backgroundColor: AppColors.paleBlue,
                      side: BorderSide.none,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _messageList() {
    final entries = _client.entries;
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: entries.length,
      itemBuilder: (context, index) => _MessageRow(entry: entries[index]),
    );
  }

  Widget _composer() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: AppColors.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _QosSelector(
                value: _qos,
                onChanged: (value) => setState(() => _qos = value),
              ),
              const SizedBox(width: 10),
              _RetainSelector(
                value: _retain,
                onChanged: (value) => setState(() => _retain = value),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _payload,
                  minLines: 1,
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                    hintText: '输入消息内容',
                    isDense: true,
                    filled: true,
                    fillColor: AppColors.canvas,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(14)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: '发送消息',
                onPressed: _client.connected ? _send : null,
                icon: const Icon(Icons.send_rounded, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 底部 QoS 候选选择，逐条消息决定发布等级
class _QosSelector extends StatelessWidget {
  const _QosSelector({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: '选择消息 QoS',
      initialValue: value,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final entry in _qosLabels.entries)
          PopupMenuItem(
            value: entry.key,
            child: Row(
              children: [
                Icon(
                  entry.key == value
                      ? Icons.check_circle
                      : Icons.circle_outlined,
                  size: 16,
                  color: entry.key == value ? AppColors.blue : AppColors.muted,
                ),
                const SizedBox(width: 8),
                Text(entry.value, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 9, 4, 9),
        decoration: BoxDecoration(
          color: AppColors.paleBlue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'QoS $value',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppColors.blue,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18, color: AppColors.blue),
          ],
        ),
      ),
    );
  }
}

/// 地址最长占用指定宽度，超出时自动来回滚动显示完整地址
class _MarqueeText extends StatefulWidget {
  const _MarqueeText({
    required this.text,
    required this.style,
    this.maxWidth = 200,
  });

  final String text;
  final TextStyle style;
  final double maxWidth;

  @override
  State<_MarqueeText> createState() => _MarqueeTextState();
}

/// 圆形 Retain 选择框，勾选后发送的消息带保留标志
class _RetainSelector extends StatelessWidget {
  const _RetainSelector({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = value ? AppColors.blue : AppColors.muted;
    return Tooltip(
      message: value ? '发送时保留消息，取消勾选可关闭' : '发送时设置 retain，让服务器保存这条消息',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 26,
            height: 26,
            child: Checkbox(
              value: value,
              onChanged: (checked) => onChanged(checked ?? false),
              shape: const CircleBorder(),
              side: BorderSide(color: color, width: 1.6),
              activeColor: AppColors.blue,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 2),
          GestureDetector(
            onTap: () => onChanged(!value),
            child: Text(
              'Retain',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MarqueeTextState extends State<_MarqueeText>
    with SingleTickerProviderStateMixin {
  static const _travelCurve = Interval(0.12, 0.88, curve: Curves.easeInOut);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : widget.maxWidth;
        final width = math.min(widget.maxWidth, available);
        final painter = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final travel = painter.width - width;
        if (travel <= 0) {
          _controller.stop();
          return Text(widget.text, maxLines: 1, style: widget.style);
        }
        if (!_controller.isAnimating) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_controller.isAnimating)
              _controller.repeat(reverse: true);
          });
        }
        return SizedBox(
          width: width,
          height: painter.height,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => Transform.translate(
                offset: Offset(
                  -travel * _travelCurve.transform(_controller.value),
                  0,
                ),
                child: child,
              ),
              child: SizedBox(
                width: painter.width,
                height: painter.height,
                child: Text(
                  widget.text,
                  maxLines: 1,
                  softWrap: false,
                  style: widget.style,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({required this.entry});

  final MqttDebugEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.kind == MqttEntryKind.system) return _SystemLine(entry: entry);
    final sent = entry.kind == MqttEntryKind.sent;
    final foreground = sent ? Colors.white : AppColors.navy;
    final secondary = sent
        ? Colors.white.withValues(alpha: 0.75)
        : AppColors.muted;
    final details = [
      if (entry.retained) '保留消息',
      if (sent && entry.qos != null) 'QoS ${entry.qos}',
    ];
    return Align(
      alignment: sent ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.76,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
          decoration: BoxDecoration(
            color: sent ? AppColors.blue : Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(sent ? 14 : 4),
              topRight: Radius.circular(sent ? 4 : 14),
              bottomLeft: const Radius.circular(14),
              bottomRight: const Radius.circular(14),
            ),
            border: sent ? null : Border.all(color: AppColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.topic.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    entry.topic,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: sent ? Colors.white : AppColors.blue,
                    ),
                  ),
                ),
              SelectableText(
                entry.payload.isEmpty ? '（空消息）' : entry.payload,
                style: TextStyle(fontSize: 14, height: 1.35, color: foreground),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  [_formatTime(entry.timestamp), ...details].join(' · '),
                  style: TextStyle(fontSize: 11, color: secondary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.entry});

  final MqttDebugEntry entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppColors.line.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            [
              _formatTime(entry.timestamp),
              entry.label,
              if (entry.topic.isNotEmpty) entry.topic,
              entry.payload,
            ].join(' · '),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: AppColors.muted),
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
