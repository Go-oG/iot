import 'checksum_spec.dart';

class ResponseChecksumSpec {
  final CheckSumAlg alg;
  final int start;

  /// 结束位置：int 表示独占结束偏移（支持负数）
  /// ResponseChecksumEnd.beforeChecksum 表示到校验字段开始处
  /// null 等价于 beforeChecksum
  final Object? end;

  /// 支持负数，-1 表示最后一个 byte
  final int offset;
  final int length;
  final DataEndian endian;
  final Map<String, dynamic> options;

  const ResponseChecksumSpec({
    required this.alg,
    required this.offset,
    required this.length,
    this.start = 0,
    this.end,
    this.endian = DataEndian.big,
    this.options = const {},
  });

  /// 校验字节数必须与算法一致
  void validate() {
    if (length <= 0) {
      throw FormatException('response checksum length must be > 0');
    }
    if (length != alg.byteLength) {
      throw FormatException(
        'response checksum length=$length does not match '
            '${alg.wireName} (${alg.byteLength} bytes)',
      );
    }
  }
}
