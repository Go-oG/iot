import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/core/protocol/protocol.dart';

void main() {
  test('主题只随网关变化，不随 BLE 设备数量增长', () {
    const topics = MqttTopics('gw-001');
    expect(topics.down, 'iot/v1/gw-001/down');
    expect(topics.up, 'iot/v1/gw-001/up');
    expect(topics.presence, 'iot/v1/gw-001/presence');
    expect(topics.subscriptions, [
      'iot/v1/gw-001/up',
      'iot/v1/gw-001/presence',
    ]);
  });

  test('一个帧可以携带多条独立请求并原样还原', () {
    final frame = GatewayFrame(
      gatewayId: 'gw-001',
      clientId: 'app-01',
      ts: 1712345678901,
      messages: [
        GatewayMessage.request(
          op: GatewayOption.write,
          reqId: 'r1',
          deviceId: 'dev-001',
          service: 'fff0',
          characteristic: 'fff1',
          value: '01',
          timeout: 5000,
          queueTimeout: 10000,
          data: const {'writeType': 'withResponse'},
        ),
        GatewayMessage.request(op: GatewayOption.snapshot, reqId: 'r2'),
      ],
    );
    final decoded = GatewayFrame.decode(frame.encode());
    expect(decoded.gatewayId, 'gw-001');
    expect(decoded.clientId, 'app-01');
    expect(decoded.ts, 1712345678901);
    expect(decoded.messages, hasLength(2));
    final write = decoded.messages.first;
    expect(write.version, 1);
    expect(write.type, GatewayMessageType.request);
    expect(write.op, GatewayOption.write);
    expect(write.reqId, 'r1');
    expect(write.deviceId, 'dev-001');
    expect(write.service, 'fff0');
    expect(write.characteristic, 'fff1');
    expect(write.value, '01');
    expect(write.timeout, 5000);
    expect(write.queueTimeout, 10000);
    expect(write.data, {'writeType': 'withResponse'});
    expect(decoded.messages.last.op, GatewayOption.snapshot);
  });

  test('消息 JSON 使用协议字段名并省略空值', () {
    final json = GatewayMessage.request(
      op: GatewayOption.read,
      reqId: 'r1',
      characteristic: 'fff1',
    ).toJson();
    expect(json['v'], 1);
    expect(json.keys, contains('char'));
    expect(json.containsKey('service'), isFalse);
    expect(json.containsKey('code'), isFalse);
    expect(json['type'], 'req');
  });

  test('拒绝非法帧与非法消息', () {
    expect(() => GatewayFrame.decode('[]'), throwsFormatException);
    expect(
      () => GatewayFrame.decode('{"v":2,"gatewayId":"gw","messages":[]}'),
      throwsFormatException,
    );
    expect(
      () => GatewayFrame.decode('{"v":1,"messages":[]}'),
      throwsFormatException,
    );
    expect(
      () => GatewayFrame.decode('{"v":1,"gatewayId":"gw"}'),
      throwsFormatException,
    );
    expect(
      () => GatewayFrame.decode(
        '{"v":1,"gatewayId":"gw","messages":[{"type":"push"}]}',
      ),
      throwsFormatException,
    );
  });

  test('兼容固件事件缺失消息版本', () {
    final event = GatewayMessage.fromJson({'type': 'event', 'op': 'hello'});
    expect(event.version, 1);
  });

  test('解析批量步骤结果与错误码', () {
    final message = GatewayMessage.fromJson({
      'v': 1,
      'type': 'res',
      'reqId': 'b1',
      'op': 'batch',
      'code': 4003,
      'message': 'batch failed',
      'data': {
        'steps': [
          {'id': 's1', 'code': 0},
          {'id': 's2', 'code': 4201, 'message': 'gatt write failed'},
          {'id': 's3', 'code': 4999, 'message': 'skipped'},
        ],
      },
    });
    expect(message.error!.code, 4003);
    expect(message.steps.map((step) => step.id), ['s1', 's2', 's3']);
    expect(message.steps.first.ok, isTrue);
    expect(message.steps[1].error!.message, 'gatt write failed');
    expect(message.steps.last.skipped, isTrue);
    expect(GatewayErrorCode.labelOf(4201), 'WRITE_FAILED');
    expect(GatewayErrorCode.batchFailed.code, 4003);
    expect(GatewayErrorCode.labelOf(1234), 'UNKNOWN_ERROR');
  });

  test('协议枚举覆盖最新管理、连接与错误码', () {
    expect(GatewayManageAction.seen.wire, 'seen');
    expect(GatewayConnectPolicy.reject.wire, 'reject');
    expect(GatewayErrorCode.batchFailed.label, 'BATCH_FAILED');
  });

  test('值编码支持 hex、base64 与 utf8', () {
    const bytes = [0x01, 0xab, 0xff];
    expect(ValueFormat.encode(bytes), '01abff');
    expect(ValueFormat.decode('01 AB FF'), bytes);
    expect(
      ValueFormat.decode(
        ValueFormat.encode(bytes, ValueFormat.base64),
        ValueFormat.base64,
      ),
      bytes,
    );
    const text = [0x41, 0x54, 0x35];
    expect(ValueFormat.encode(text, ValueFormat.utf8), 'AT5');
    expect(ValueFormat.decode('AT5', ValueFormat.utf8), text);
    expect(() => ValueFormat.decode('abc'), throwsFormatException);
    expect(() => ValueFormat.decode('zz'), throwsFormatException);
  });

  test('UUID 支持 16、32 与 128 位写法', () {
    const base = '0000-1000-8000-00805f9b34fb';
    expect(GatewayUuid.normalize('fff0'), '0000fff0-$base');
    expect(GatewayUuid.normalize('12345678'), '12345678-$base');
    expect(
      GatewayUuid.normalize('11223344-5566-7788-99AA-BBCCDDEEFF00'),
      '11223344-5566-7788-99aa-bbccddeeff00',
    );
    expect(() => GatewayUuid.normalize('fff'), throwsFormatException);
  });
}
