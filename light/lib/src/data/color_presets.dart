import 'models.dart';

/// 内置配色使用的五路通道属性，与 assets/devices/at5.json 的 channels 一致
const String presetChannelProperty = 'channels';

// 各通道按原值的三分之一降低，保留配色比例作为低亮观赏起点
final aquariumColorPresets = [
  for (final preset in _originalAquariumColorPresets) _dimPreset(preset),
];
final aquariumCommunityColorPresets = [
  for (final preset in _originalCommunityColorPresets) _dimPreset(preset),
];

ScenePreset _dimPreset(ScenePreset preset) {
  final channels = preset.channels;
  return preset.copyWith(
    properties: {
      ...preset.properties,
      presetChannelProperty: {
        for (final entry in channels.entries)
          entry.key: (entry.value / 3).round(),
      },
    },
  );
}

// 保留降亮前的完整默认值，配色模板与设备面板使用同一组数值
const _originalAquariumColorPresets = [
  ScenePreset(
    id: 'aquarium_daylight',
    name: '自然日光',
    subtitle: '白光为主，日常观鱼',
    accentValue: 0xFF38A7FF,
    properties: {
      'power': true,
      'channels': {'red': 45, 'green': 45, 'blue': 50, 'white': 75, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_green',
    name: '水草清透',
    subtitle: '清爽绿调，欣赏水草造景',
    accentValue: 0xFF62D3B4,
    properties: {
      'power': true,
      'channels': {'red': 45, 'green': 60, 'blue': 45, 'white': 65, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_warm',
    name: '暖色观鱼',
    subtitle: '柔暖红调，欣赏鱼体色彩',
    accentValue: 0xFFFFB449,
    properties: {
      'power': true,
      'channels': {'red': 65, 'green': 35, 'blue': 35, 'white': 60, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_blue',
    name: '蓝调观赏',
    subtitle: '偏蓝光感，水中氛围',
    accentValue: 0xFF7C6BFF,
    properties: {
      'power': true,
      'channels': {'red': 10, 'green': 15, 'blue': 65, 'white': 35, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_evening',
    name: '傍晚柔光',
    subtitle: '低亮暖光，短时观赏',
    accentValue: 0xFF465FCF,
    properties: {
      'power': true,
      'channels': {'red': 20, 'green': 10, 'blue': 10, 'white': 20, 'uv': 0},
    },
  ),
  ..._originalCommunityColorPresets,
];

// 混养观赏与主题配色，独立分组用于向已有用户增量添加
const _originalCommunityColorPresets = [
  ScenePreset(
    id: 'aquarium_boesemani',
    name: '石美人双色',
    subtitle: '红蓝均衡，欣赏蓝橙双色',
    accentValue: 0xFFFFA653,
    properties: {
      'power': true,
      'channels': {'red': 65, 'green': 40, 'blue': 60, 'white': 60, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_congo',
    name: '刚果虹彩',
    subtitle: '蓝白通透，欣赏鳞片虹彩',
    accentValue: 0xFF56CDBD,
    properties: {
      'power': true,
      'channels': {'red': 40, 'green': 50, 'blue': 65, 'white': 65, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_blue_rainbow',
    name: '蓝美人清蓝',
    subtitle: '清冷蓝调，欣赏蓝色光泽',
    accentValue: 0xFF328CFF,
    properties: {
      'power': true,
      'channels': {'red': 20, 'green': 40, 'blue': 75, 'white': 55, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_fluorescent_angel',
    name: '荧光天使',
    subtitle: '低白蓝光，短时欣赏荧光色彩',
    accentValue: 0xFF9169FF,
    properties: {
      'power': true,
      'channels': {'red': 5, 'green': 5, 'blue': 60, 'white': 10, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_community',
    name: '混养通透',
    subtitle: '均衡白光，兼顾整缸鱼体色彩',
    accentValue: 0xFF55BED8,
    properties: {
      'power': true,
      'channels': {'red': 45, 'green': 45, 'blue': 60, 'white': 70, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_volcano_orange',
    name: '火山橙',
    subtitle: '浓暖橙红，熔岩氛围',
    accentValue: 0xFFFF702E,
    properties: {
      'power': true,
      'channels': {'red': 80, 'green': 25, 'blue': 5, 'white': 15, 'uv': 0},
    },
  ),
  ScenePreset(
    id: 'aquarium_ice_blue',
    name: '冰蓝',
    subtitle: '青蓝透白，冰晶光感',
    accentValue: 0xFF79DFFF,
    properties: {
      'power': true,
      'channels': {'red': 5, 'green': 45, 'blue': 80, 'white': 40, 'uv': 0},
    },
  ),
];
