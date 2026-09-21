import '../wire_enum.dart';

class DecodedNotification {
  /// 用哪个 property.notify 规则命中的
  final String sourceProperty;

  /// 本帧带来的状态增量 一帧可以更新多个 property
  final Map<String, Object?> values;

  const DecodedNotification({required this.sourceProperty, required this.values});
}

/// 属性上报值及其校验依据
class DevicePropertyState {
  const DevicePropertyState(
    this.value, {
    required this.receivedAt,
    required this.epoch,
    required this.verified,
    this.sampledAt,
    this.bootId,
    this.sequence,
  });

  final Object? value;

  /// 本机会话收到该值的时间
  final DateTime receivedAt;

  /// 连接纪元，重连或网关重启后旧值不再新鲜
  final int epoch;

  /// 是否通过设备顺序校验
  final bool verified;

  /// 设备采样时间，缺失时只能按接收时间判断
  final DateTime? sampledAt;
  final String? bootId;
  final int? sequence;
}

/// 一次属性写入：属性标识与按声明类型校验过的值
class DevicePropertyWrite {
  const DevicePropertyWrite(this.property, this.value);

  final String property;
  final Object? value;
}

/// 一次下发/读取的记录
///
/// [DeviceCommandState.written] 只表示网关完成 BLE 写入，不代表设备已执行
class DeviceCommandRecord {
  const DeviceCommandRecord({
    required this.operation,
    required this.state,
    required this.at,
    this.requestId,
    this.message,
  });

  final String operation;
  final String? requestId;
  final DeviceCommandState state;
  final DateTime at;
  final String? message;
}

enum DeviceCommandState implements WireEnum {
  /// 网关完成 GATT 写入
  written('written'),

  /// 收到设备按模型匹配的响应帧
  deviceAck('device_ack'),

  /// 设备主动回报了属性状态
  deviceState('device_state'),

  /// 读取成功
  read('read'),

  /// 执行失败
  failed('failed'),

  /// 结果未确认
  unknown('unknown');

  const DeviceCommandState(this.wire);

  @override
  final String wire;
}

class NotifyTarget {
  const NotifyTarget(this.service, this.characteristic);

  final String service;
  final String characteristic;
}