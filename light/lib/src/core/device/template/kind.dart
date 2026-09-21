/// 模板占位符的类型
enum Kind {
  value('value', 'value'),
  property('property', null),
  variable('variable', null),
  sequence('sequence', 'seq'),
  timestamp('timestamp', 'ts'),
  length('length', 'len'),
  checksum('checksum', 'crc'),
  bitfield('bitfield', 'bits'),
  match('match', null),
  skip('skip', null);

  const Kind(this.wire, this.defaultLabel);

  final String wire;

  /// 字段默认名，跨度与校验范围按它引用
  final String? defaultLabel;

  bool matches(String value) {
    return switch (this) {
      Kind.property => value == wire || value == 'prop' || value == 'attr',
      Kind.variable => value == wire || value == 'var',
      Kind.sequence => value == wire || value == 'seq',
      Kind.timestamp => value == wire || value == 'ts',
      Kind.length => value == wire || value == 'len',
      Kind.checksum => value == wire || value == 'crc',
      Kind.bitfield => value == wire || value == 'bits',
      _ => value == wire,
    };
  }

  /// 接受 `value`、`property.mode` 这类写法，返回类型本身
  static Kind? tryParse(String head) {
    final dot = head.indexOf('.');
    final name = dot < 0 ? head : head.substring(0, dot);
    for (final kind in values) {
      if (kind.matches(name)) return kind;
    }
    return null;
  }
}
