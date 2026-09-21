import 'package:light/src/core/device/util.dart';

/// UI 渲染器类型
enum UiRenderer {
  toggle('switch'),
  slider('slider'),
  input('input'),
  stepper('stepper'),
  segmented('segmented'),
  color('color'),
  scheduleList('scheduleList'),
  hexEditor('hexEditor'),
  hidden('hidden');

  final String wireName;

  const UiRenderer(this.wireName);

  static UiRenderer valueOf(String value) {
    for (final v in values) {
      if (v.wireName == value) {
        return v;
      }
    }
    throw FormatException('Unsupported ui renderer: $value');
  }
}

class UiSpec {
  final UiRenderer renderer;
  final Map<String, dynamic> config;

  const UiSpec({required this.renderer, this.config = const {}});

  factory UiSpec.fromJson(Map<String, dynamic> json) {
    return UiSpec(
      renderer: UiRenderer.valueOf(stringOf(json['renderer'], 'ui.renderer')),
      config: json['config'] == null ? const {} : mapOf(json['config']),
    );
  }

  Map<String, dynamic> toJson() => {'renderer': renderer.wireName, if (config.isNotEmpty) 'config': config};
}
