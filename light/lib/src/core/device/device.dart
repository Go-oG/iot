import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../widgets/app_widgets.dart';
import '../protocol/remote_protocol.dart';

enum Priority {
  maxHigh(-100),
  high(-50),
  normal(0),
  low(50),
  minLow(100);

  final int v;

  const Priority(this.v);
}

/// 同组功能共用卡片，卡片顺序由首个功能的优先级决定
enum DeviceControlGroup { primary, lighting, climate, other }

abstract class DeviceFunction<T> extends ChangeNotifier {
  DeviceFunction(T initialStatus) : _status = initialStatus;

  T _status;

  T get status => _status;

  set status(T value) {
    _status = value;
    notifyStatusChange();
  }

  Priority get priority;

  String get label;

  bool get hasControl => true;

  DeviceControlGroup get controlGroup => DeviceControlGroup.other;

  FutureOr<bool> execute(covariant Device device, T value);

  FutureOr<bool> refresh(covariant Device device);

  void notifyStatusChange() => notifyListeners();

  Widget buildWidget(BuildContext context, covariant Device device, CardSize size);
}

abstract class Device<T> implements RemoteDeviceCodec {
  late final List<DeviceFunction> supportFunctions = _sortedFunctions();

  List<DeviceFunction> _sortedFunctions() {
    final entries = onSupportFunctions().indexed.toList()
      ..sort((a, b) {
        final order = a.$2.priority.v.compareTo(b.$2.priority.v);
        return order == 0 ? a.$1.compareTo(b.$1) : order;
      });
    return List.unmodifiable(entries.map((entry) => entry.$2));
  }

  late T status;
  bool _initialized = false;
  bool _connection = false;

  String get id;

  String get name;

  String get macd;

  Future<void> init() async {
    if (_initialized) return;
    status = await onInit();
    _initialized = true;
  }

  FutureOr<T> onInit();

  List<BleServiceDesc> bleServices();

  @protected
  List<DeviceFunction> onSupportFunctions();

  F? function<F extends DeviceFunction>() => supportFunctions.whereType<F>().firstOrNull;

  F requireFunction<F extends DeviceFunction>() => function<F>() ?? (throw UnsupportedError('$name 不支持 $F'));

  Future<bool> execute<TValue, F extends DeviceFunction<TValue>>(TValue value) async {
    return requireFunction<F>().execute(this, value);
  }

  @nonVirtual
  Future<bool> connection() async {
    if (_connection) return true;
    await init();
    return _connection = await onConnection();
  }

  FutureOr<bool> onConnection();

  @nonVirtual
  Future<bool> disConnection() async {
    if (!_connection) return true;
    final disconnected = await onDisConnection();
    if (disconnected) _connection = false;
    return disconnected;
  }

  FutureOr<bool> onDisConnection();

  void markDisconnected() => _connection = false;

  bool get isConnection => _connection;

  Widget buildDeviceCart(BuildContext context, CardSize size) {
    final groups = <DeviceControlGroup, List<DeviceFunction>>{};
    for (final function in supportFunctions.where((function) => function.hasControl)) {
      groups.putIfAbsent(function.controlGroup, () => []).add(function);
    }
    final sections = groups.values.toList();
    final compact = size == CardSize.small;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var section = 0; section < sections.length; section++) ...[
          if (section > 0) SizedBox(height: compact ? 8 : 12),
          SurfaceCard(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < sections[section].length; index++) ...[
                  if (index > 0)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: compact ? 12 : 16),
                      child: const Divider(),
                    ),
                  ListenableBuilder(
                    listenable: sections[section][index],
                    builder: (context, _) => sections[section][index].buildWidget(context, this, size),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  void dispose() {
    markDisconnected();
    for (final function in supportFunctions) {
      function.dispose();
    }
  }
}

class BleServiceDesc {
  final String uuid;
  final String name;
  final List<CharacteristicDesc> characteristicList;

  BleServiceDesc({required this.uuid, required this.name, required this.characteristicList});
}

class CharacteristicDesc {
  final String uuid;
  final String name;

  CharacteristicDesc({required this.uuid, required this.name});
}

enum CardSize { large, small }

String toHex(List<int> data) {
  return data.map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');
}
