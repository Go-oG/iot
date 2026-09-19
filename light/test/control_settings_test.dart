import 'package:flutter_test/flutter_test.dart';
import 'package:light/src/data/models.dart';

void main() {
  test('默认控制范围和缺省 JSON 上限为 100', () {
    expect(ControlSettings.defaults.outputLimit, 100);
    expect(ControlSettings.fromJson({}).outputLimit, 100);
  });

  test('旧版默认 30 自动升级，新版手动设置 30 保持不变', () {
    final old = ControlSettings.defaults.toJson()..remove('outputLimitVersion');
    old['outputLimit'] = 30;
    final migrated = ControlSettings.fromJson(old);
    expect(migrated.outputLimit, 100);
    final manual = migrated.toJson()..['outputLimit'] = 30;
    expect(ControlSettings.fromJson(manual).outputLimit, 30);
    old['outputLimit'] = 60;
    expect(ControlSettings.fromJson(old).outputLimit, 60);
  });
}
