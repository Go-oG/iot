import 'package:light/src/core/functions/light.dart';

import 'models.dart';

// 各通道按原值的三分之一降低，保留配色比例作为低亮观赏起点
final aquariumColorPresets = [
  for (final preset in originalAquariumColorPresets) _dimPreset(preset),
];
final aquariumCommunityColorPresets = [
  for (final preset in _originalCommunityColorPresets) _dimPreset(preset),
];

ScenePreset _dimPreset(ScenePreset preset) {
  final original = preset.state;
  final state = LightState(
    red: (original.red / 3).round(),
    green: (original.green / 3).round(),
    blue: (original.blue / 3).round(),
    white: (original.white / 3).round(),
    uv: (original.uv / 3).round(),
  );
  return preset.copyWith(state: state, brightness: state.powerPercent);
}

// 保留降亮前的完整默认值，用于识别并更新尚未修改的本地配色
const originalAquariumColorPresets = [
  ScenePreset(
    id: 'aquarium_daylight',
    name: '自然日光',
    subtitle: '白光为主，日常观鱼',
    temperature: 5000,
    brightness: 43,
    accentValue: 0xFF38A7FF,
    state: LightState(red: 45, green: 45, blue: 50, white: 75, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_green',
    name: '水草清透',
    subtitle: '清爽绿调，欣赏水草造景',
    temperature: 5000,
    brightness: 43,
    accentValue: 0xFF62D3B4,
    state: LightState(red: 45, green: 60, blue: 45, white: 65, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_warm',
    name: '暖色观鱼',
    subtitle: '柔暖红调，欣赏鱼体色彩',
    temperature: 4000,
    brightness: 39,
    accentValue: 0xFFFFB449,
    state: LightState(red: 65, green: 35, blue: 35, white: 60, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_blue',
    name: '蓝调观赏',
    subtitle: '偏蓝光感，水中氛围',
    temperature: 6500,
    brightness: 25,
    accentValue: 0xFF7C6BFF,
    state: LightState(red: 10, green: 15, blue: 65, white: 35, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_evening',
    name: '傍晚柔光',
    subtitle: '低亮暖光，短时观赏',
    temperature: 3200,
    brightness: 12,
    accentValue: 0xFF465FCF,
    state: LightState(red: 20, green: 10, blue: 10, white: 20, uv: 0),
  ),
  ..._originalCommunityColorPresets,
];

// 混养观赏与主题配色，独立分组用于向已有用户增量添加
const _originalCommunityColorPresets = [
  ScenePreset(
    id: 'aquarium_boesemani',
    name: '石美人双色',
    subtitle: '红蓝均衡，欣赏蓝橙双色',
    temperature: 5000,
    brightness: 45,
    accentValue: 0xFFFFA653,
    state: LightState(red: 65, green: 40, blue: 60, white: 60, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_congo',
    name: '刚果虹彩',
    subtitle: '蓝白通透，欣赏鳞片虹彩',
    temperature: 5500,
    brightness: 44,
    accentValue: 0xFF56CDBD,
    state: LightState(red: 40, green: 50, blue: 65, white: 65, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_blue_rainbow',
    name: '蓝美人清蓝',
    subtitle: '清冷蓝调，欣赏蓝色光泽',
    temperature: 6000,
    brightness: 38,
    accentValue: 0xFF328CFF,
    state: LightState(red: 20, green: 40, blue: 75, white: 55, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_fluorescent_angel',
    name: '荧光天使',
    subtitle: '低白蓝光，短时欣赏荧光色彩',
    temperature: 6500,
    brightness: 16,
    accentValue: 0xFF9169FF,
    state: LightState(red: 5, green: 5, blue: 60, white: 10, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_community',
    name: '混养通透',
    subtitle: '均衡白光，兼顾整缸鱼体色彩',
    temperature: 5200,
    brightness: 44,
    accentValue: 0xFF55BED8,
    state: LightState(red: 45, green: 45, blue: 60, white: 70, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_volcano_orange',
    name: '火山橙',
    subtitle: '浓暖橙红，熔岩氛围',
    temperature: 2700,
    brightness: 25,
    accentValue: 0xFFFF702E,
    state: LightState(red: 80, green: 25, blue: 5, white: 15, uv: 0),
  ),
  ScenePreset(
    id: 'aquarium_ice_blue',
    name: '冰蓝',
    subtitle: '青蓝透白，冰晶光感',
    temperature: 6500,
    brightness: 34,
    accentValue: 0xFF79DFFF,
    state: LightState(red: 5, green: 45, blue: 80, white: 40, uv: 0),
  ),
];
