
class HexCodec {
  const HexCodec._();

  static List<int> decode(String value) {
    final normalized = value
        .replaceAll(' ', '')
        .replaceAll(':', '')
        .replaceAll('-', '')
        .replaceAll('0x', '')
        .replaceAll('0X', '');

    if (normalized.length.isOdd) {
      throw FormatException('Hex string length must be even: $value');
    }

    final result = <int>[];
    for (var i = 0; i < normalized.length; i += 2) {
      result.add(int.parse(normalized.substring(i, i + 2), radix: 16));
    }
    return result;
  }

  static String encode(List<int> bytes) {
    final buffer = StringBuffer();
    for (final value in bytes) {
      buffer.write(value.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return buffer.toString();
  }
}
