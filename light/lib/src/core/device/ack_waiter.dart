import 'dart:async';

import 'spec/packer_decode_spec.dart' show PacketDecodeSpec;

class AckWaiter {
  AckWaiter(this.properties);

  final Map<String, PacketDecodeSpec> properties;
  final Completer<String> completer = Completer<String>();
}
