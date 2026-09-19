import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RC4 ("ARC4") stream cipher.
///
/// The MiJia app uses RC4 as a plain XOR keystream: encrypting and decrypting
/// are the same [process] call, and every call site starts from a fresh
/// instance so the keystream is never reused.
class Rc4 {
  Rc4(List<int> key) {
    if (key.isEmpty) {
      throw ArgumentError.value(key, 'key', 'RC4 key must not be empty');
    }
    for (var i = 0; i < 256; i++) {
      _state[i] = i;
    }
    var j = 0;
    for (var i = 0; i < 256; i++) {
      j = (j + _state[i] + key[i % key.length]) & 0xff;
      final t = _state[i];
      _state[i] = _state[j];
      _state[j] = t;
    }
  }

  final Uint8List _state = Uint8List(256);
  int _i = 0;
  int _j = 0;

  /// XORs [data] against the next `data.length` keystream bytes, advancing the
  /// cipher state so successive calls continue the same keystream.
  Uint8List process(List<int> data) {
    final out = Uint8List(data.length);
    var i = _i;
    var j = _j;
    final s = _state;
    for (var k = 0; k < data.length; k++) {
      i = (i + 1) & 0xff;
      j = (j + s[i]) & 0xff;
      final t = s[i];
      s[i] = s[j];
      s[j] = t;
      out[k] = data[k] ^ s[(s[i] + s[j]) & 0xff];
    }
    _i = i;
    _j = j;
    return out;
  }
}

/// Number of keystream bytes discarded before each payload, matching
/// `r.encrypt(bytes(1024))` in `miutils.py`.
final Uint8List _rc4Discard = Uint8List(1024);

/// Generates a `_nonce`: 8 random bytes followed by the minutes since the Unix
/// epoch as a minimal-length big-endian integer, base64 encoded.
///
/// [random] is injectable for deterministic tests.
String genNonce({Random? random}) {
  final rnd = random ?? Random.secure();
  final bytes = List<int>.generate(8, (_) => rnd.nextInt(256), growable: true);

  final minutes = DateTime.now().millisecondsSinceEpoch ~/ 60000;
  final length = (minutes.bitLength + 7) >> 3;
  final tail = List<int>.filled(length, 0);
  var value = minutes;
  for (var i = length - 1; i >= 0; i--) {
    tail[i] = value & 0xff;
    value >>= 8;
  }

  return base64Encode(bytes..addAll(tail));
}

/// `base64(sha256(base64_decode(ssecurity) + base64_decode(nonce)))`.
String getSignedNonce(String ssecurity, String nonce) {
  final digest = sha256.convert(<int>[
    ...base64Decode(ssecurity),
    ...base64Decode(nonce),
  ]);
  return base64Encode(digest.bytes);
}

/// `base64(sha1(METHOD&uri&k=v&...&signed_nonce))`.
///
/// Iteration order of [params] is significant and preserved, exactly as Python
/// dict ordering is in `gen_enc_signature`.
String genEncSignature(
  String uri,
  String method,
  String signedNonce,
  Map<String, String> params,
) {
  final parts = <String>[method.toUpperCase(), uri];
  params.forEach((key, value) => parts.add('$key=$value'));
  parts.add(signedNonce);
  return base64Encode(sha1.convert(utf8.encode(parts.join('&'))).bytes);
}

/// RC4-encrypts [payload] under a [password] that is itself base64 encoded.
String encryptRc4(String password, String payload) {
  final rc4 = Rc4(base64Decode(password));
  rc4.process(_rc4Discard);
  return base64Encode(rc4.process(utf8.encode(payload)));
}

/// RC4-decrypts a base64 [payload] under a base64 [password].
Uint8List decryptRc4(String password, String payload) {
  final rc4 = Rc4(base64Decode(password));
  rc4.process(_rc4Discard);
  return rc4.process(base64Decode(payload));
}

/// Builds the encrypted parameter set posted to the MiJia app API.
///
/// Mirrors `generate_enc_params`: signs the clear params into `rc4_hash__`,
/// encrypts every value with RC4, then signs the ciphertext into `signature`
/// and appends `ssecurity` and `_nonce`.
Map<String, String> generateEncParams(
  String uri,
  String method,
  String signedNonce,
  String nonce,
  Map<String, String> params,
  String ssecurity,
) {
  final signed = <String, String>{...params};
  signed['rc4_hash__'] = genEncSignature(uri, method, signedNonce, signed);

  final encrypted = <String, String>{};
  signed.forEach((key, value) {
    encrypted[key] = encryptRc4(signedNonce, value);
  });

  encrypted['signature'] = genEncSignature(uri, method, signedNonce, encrypted);
  encrypted['ssecurity'] = ssecurity;
  encrypted['_nonce'] = nonce;
  return encrypted;
}

/// Decrypts a MiJia response body, transparently inflating the gzip payload
/// the API uses when the plaintext is large.
String decrypt(String ssecurity, String nonce, String payload) {
  final raw = decryptRc4(getSignedNonce(ssecurity, nonce), payload);
  try {
    return utf8.decode(raw);
  } on FormatException {
    return utf8.decode(gzip.decode(raw));
  }
}
