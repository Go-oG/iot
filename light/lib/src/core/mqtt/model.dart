enum MqttMsgKind {
  /// 订阅后由服务器推送的消息
  received,

  /// 本机发布的消息
  sent,

  /// 连接、订阅、断开等系统提示
  system,
}

class MqttEnvelope {
  final String topic;

  final String payload;

  final bool retained;

  const MqttEnvelope(this.topic, this.payload, {this.retained = false});

}