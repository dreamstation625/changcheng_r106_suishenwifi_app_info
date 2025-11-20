// lib/md5_util.dart
import 'dart:convert';
import 'package:crypto/crypto.dart';

/// 等价于 JS 的 hex_hmac_md5(key, data)
String hexHmacMd5(String key, String data) {
  final hmac = Hmac(md5, utf8.encode(key));
  final digest = hmac.convert(utf8.encode(data));
  // digest.toString() 默认就是小写十六进制字符串
  return digest.toString();
}

/// 如果需要普通 MD5（类似 hex_md5）
String hexMd5(String s) {
  final d = md5.convert(utf8.encode(s));
  return d.toString();
}
