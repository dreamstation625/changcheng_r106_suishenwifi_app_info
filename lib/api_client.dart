// lib/api_client.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'md5_util.dart';

/// 自定义异常
class ApiException implements Exception {
  final int? retcode;
  final String message;
  final bool isJsonError;

  ApiException({
    this.retcode,
    required this.message,
    this.isJsonError = false,
  });

  @override
  String toString() =>
      'ApiException(retcode: $retcode, isJsonError: $isJsonError, message: $message)';
}

class LoginResult {
  final bool success;
  final String? cookie;
  final String? error;

  LoginResult({
    required this.success,
    this.cookie,
    this.error,
  });
}

class BatteryWifiInfo {
  final String? batteryPercent;
  final Map<String, String> wifiInfo;

  BatteryWifiInfo({
    this.batteryPercent,
    required this.wifiInfo,
  });
}

/// 在线设备信息
class HostInfo {
  final String type;       // rt_hosts_type
  final String hostname;   // rt_hosts_hostname
  final String mac;        // rt_hosts_mac
  final String ip;         // rt_hosts_ip
  final int? wifiApIndex;  // rt_hosts_wifi_ap_index
  final String ssid;       // rt_hosts_ssid
  final int? uptime;       // rt_hosts_uptime（秒）
  final String? onlineTime;// rt_hosts_online_time

  HostInfo({
    required this.type,
    required this.hostname,
    required this.mac,
    required this.ip,
    required this.ssid,
    this.wifiApIndex,
    this.uptime,
    this.onlineTime,
  });
}

class ApiClient {
  /// 模拟浏览器 Header
  Map<String, String> defaultHeaders({String? cookie}) {
    return {
      "Referer": "http://192.168.1.1/html/settings.html",
      "User-Agent":
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 Edg/142.0.0.0",
      "Accept": "application/json, text/javascript, */*; q=0.01",
      "Content-Type": "application/json",
      "X-Requested-With": "XMLHttpRequest",
      "Host": "192.168.1.1",
      if (cookie != null) "Cookie": cookie,
    };
  }

  /// 登录：/goform/login
  Future<LoginResult> login({
    required String baseUrl, // 例如 http://192.168.1.1
    required String username,
    required String password,
  }) async {
    final url = Uri.parse(
        '${baseUrl.trim().replaceAll(RegExp(r"/+$"), "")}/goform/login');

    // ✅ 使用 HMAC-MD5 + 固定 key "0123456789" 对用户名和密码加密
    const hmacKey = "0123456789";
    final encUsername = hexHmacMd5(hmacKey, username);
    final encPassword = hexHmacMd5(hmacKey, password);

    final bodyJson = jsonEncode({
      'username': encUsername,
      'password': encPassword,
    });

    http.Response resp;
    try {
      resp = await http.post(
        url,
        headers: defaultHeaders(),
        body: bodyJson,
      );
    } catch (e) {
      return LoginResult(success: false, error: '网络错误: $e');
    }

    if (resp.statusCode != 200) {
      return LoginResult(
          success: false, error: 'HTTP 状态码 ${resp.statusCode}');
    }

    // 解析 JSON {"retcode":0}
    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      return LoginResult(success: false, error: '返回 JSON 解析失败: $e');
    }

    final retcode = json['retcode'];
    if (retcode != 0) {
      return LoginResult(
          success: false, error: 'retcode != 0 ($retcode)');
    }

    // 取 Set-Cookie 中的 -webs-session-
    final setCookie = resp.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) {
      return LoginResult(success: false, error: '未找到 Set-Cookie');
    }

    final cookie = _extractWebsSessionCookie(setCookie);
    if (cookie == null) {
      return LoginResult(
          success: false, error: '未找到 -webs-session- Cookie');
    }

    return LoginResult(success: true, cookie: cookie);
  }

  String? _extractWebsSessionCookie(String setCookieHeader) {
    final semiIndex = setCookieHeader.indexOf(';');
    final firstSegment = semiIndex == -1
        ? setCookieHeader
        : setCookieHeader.substring(0, semiIndex);
    if (firstSegment.trim().startsWith('-webs-session-=')) {
      return firstSegment.trim();
    }

    final parts = setCookieHeader.split(',');
    for (final part in parts) {
      final seg = part.trim();
      final idx = seg.indexOf(';');
      final base = idx == -1 ? seg : seg.substring(0, idx);
      if (base.trim().startsWith('-webs-session-=')) {
        return base.trim();
      }
    }

    return null;
  }

  /// /action/get_mgdb_params
  Future<Map<String, dynamic>> getParams({
    required String baseUrl,
    required String cookie,
    required List<String> keys,
  }) async {
    final url = Uri.parse(
        '${baseUrl.trim().replaceAll(RegExp(r"/+$"), "")}/action/get_mgdb_params');

    final bodyJson = jsonEncode({
      'keys': keys,
    });

    http.Response resp;
    try {
      resp = await http.post(
        url,
        headers: defaultHeaders(cookie: cookie),
        body: bodyJson,
      );
    } catch (e) {
      throw ApiException(message: '网络错误: $e');
    }

    if (resp.statusCode != 200) {
      throw ApiException(message: 'HTTP 状态码 ${resp.statusCode}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException(
        message: '返回数据不是合法 JSON: $e',
        isJsonError: true,
      );
    }

    final retcode = json['retcode'];
    if (retcode != 0) {
      throw ApiException(retcode: retcode, message: 'retcode != 0 ($retcode)');
    }

    final data = json['data'];
    if (data is Map<String, dynamic>) {
      return data;
    }

    throw ApiException(message: '返回 data 格式不正确');
  }

  /// 电池 + WiFi 信息
  Future<BatteryWifiInfo> fetchBatteryAndWifi({
    required String baseUrl,
    required String cookie,
  }) async {
    final batteryData = await getParams(
      baseUrl: baseUrl,
      cookie: cookie,
      keys: ['device_battery_level_percent'],
    );
    final battery =
    batteryData['device_battery_level_percent']?.toString();

    final wifiData = await getParams(
      baseUrl: baseUrl,
      cookie: cookie,
      keys: [
        'wifi_freq_0',
        'wifi_state_0',
        'wifi_ssid_0',
        'wifi_security_0',
        'xmg_wifi_psk_0',
        'wifi_mode_0',
        'wifi_freq_1',
        'wifi_state_1',
        'wifi_ssid_1',
        'wifi_security_1',
        'xmg_wifi_psk_1',
        'wifi_mode_1',
      ],
    );

    final wifiInfo = <String, String>{};
    wifiData.forEach((key, value) {
      wifiInfo[key] = value?.toString() ?? '';
    });

    return BatteryWifiInfo(
      batteryPercent: battery,
      wifiInfo: wifiInfo,
    );
  }

  /// /action/router_get_hosts_info
  Future<List<HostInfo>> fetchHosts({
    required String baseUrl,
    required String cookie,
  }) async {
    final url = Uri.parse(
        '${baseUrl.trim().replaceAll(RegExp(r"/+$"), "")}/action/router_get_hosts_info');

    const bodyJson = '{}';

    http.Response resp;
    try {
      resp = await http.post(
        url,
        headers: defaultHeaders(cookie: cookie),
        body: bodyJson,
      );
    } catch (e) {
      throw ApiException(message: '网络错误: $e');
    }

    if (resp.statusCode != 200) {
      throw ApiException(message: 'HTTP 状态码 ${resp.statusCode}');
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      throw ApiException(
        message: '返回数据不是合法 JSON: $e',
        isJsonError: true,
      );
    }

    final retcode = json['retcode'];
    if (retcode != 0) {
      throw ApiException(retcode: retcode, message: 'retcode != 0 ($retcode)');
    }

    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw ApiException(message: 'data 字段格式不正确');
    }

    final list = data['rt_hosts_list'];
    if (list is! List) {
      return <HostInfo>[];
    }

    return list.map<HostInfo>((item) {
      final m = item as Map<String, dynamic>;
      return HostInfo(
        type: m['rt_hosts_type']?.toString() ?? '',
        hostname: m['rt_hosts_hostname']?.toString() ?? '',
        mac: m['rt_hosts_mac']?.toString() ?? '',
        ip: m['rt_hosts_ip']?.toString() ?? '',
        wifiApIndex: m['rt_hosts_wifi_ap_index'] is int
            ? m['rt_hosts_wifi_ap_index'] as int
            : int.tryParse(m['rt_hosts_wifi_ap_index']?.toString() ?? ''),
        ssid: m['rt_hosts_ssid']?.toString() ?? '',
        uptime: m['rt_hosts_uptime'] is int
            ? m['rt_hosts_uptime'] as int
            : int.tryParse(m['rt_hosts_uptime']?.toString() ?? ''),
        onlineTime: m['rt_hosts_online_time']?.toString(),
      );
    }).toList();
  }
}
