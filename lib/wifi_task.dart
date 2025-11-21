// lib/wifi_task.dart
import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'config_repository.dart';
import 'api_client.dart';

/// 前台服务入口（必须是顶层函数，并且加上 vm:entry-point）
@pragma('vm:entry-point')
void wifiTaskStartCallback() {
  FlutterForegroundTask.setTaskHandler(WifiTaskHandler());
}

/// 随身 WiFi 后台任务处理类
class WifiTaskHandler extends TaskHandler {
  final _networkInfo = NetworkInfo();

  late final ApiClient _apiClient;
  late final ConfigRepository _configRepository;

  String? _sessionCookie;

  /// 任务启动时回调
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _apiClient = ApiClient();
    _configRepository = ConfigRepository();
    await _configRepository.init();
  }

  /// 周期性事件（由 ForegroundTaskOptions.eventAction.repeat 触发）
  /// 你当前版本里 TaskHandler.onRepeatEvent 是：void onRepeatEvent(DateTime)
  @override
  void onRepeatEvent(DateTime timestamp) {
    // 后台异步跑，不阻塞回调
    _doWork();
  }

  /// 任务结束时回调
  /// 你当前版本中 TaskHandler.onDestroy 的签名是 Future<void> onDestroy(DateTime, bool)
  @override
  Future<void> onDestroy(DateTime timestamp, bool isKilled) async {
    _sessionCookie = null;
  }

  // ====================== WiFi 名校验（后台使用） ======================

  /// 在前台服务的后台 isolate 中做 Wi-Fi 校验：
  /// - 能拿到 SSID：严格等于 targetSsid 才返回 true
  /// - 拿不到 SSID（null / 空 / <unknown ssid>）：认为「无法判断」，这里折中为 true，允许继续刷新
  Future<bool> _ensureOnTargetWifi(String targetSsid) async {
    if (targetSsid.isEmpty) return false;

    String? currentSsid;
    try {
      currentSsid = await _networkInfo.getWifiName();
    } catch (_) {
      // 任何异常都视为无法读取 SSID，这里按“允许刷新”处理，防止后台完全停更
      return true;
    }

    currentSsid = currentSsid?.replaceAll('"', '');

    // 后台环境经常会拿到 null / 空 / <unknown ssid>，
    // 如果这里直接返回 false，就会导致一直不更新通知。
    if (currentSsid == null ||
        currentSsid.isEmpty ||
        currentSsid.toLowerCase() == '<unknown ssid>') {
      // 折中：当作「无法判断」，允许刷新
      return true;
    }

    // 正常情况：严格等于目标 Wi-Fi 才允许刷新
    return currentSsid == targetSsid;
  }

  // ====================== 登录和拉取数据 ======================

  Future<bool> _loginOnce({
    required String addr,
    required String username,
    required String password,
  }) async {
    final loginResult = await _apiClient.login(
      baseUrl: addr,
      username: username,
      password: password,
    );

    if (!loginResult.success || loginResult.cookie == null) {
      return false;
    }

    _sessionCookie = loginResult.cookie;
    return true;
  }

  /// 在后台定时任务中实际执行的动作
  Future<void> _doWork() async {
    final addr = _configRepository.consoleAddress.trim();
    final user = _configRepository.username.trim();
    final pwd = _configRepository.password.trim();
    final targetSsid = _configRepository.targetSsid.trim();

    // 配置不完整，直接不做
    if (addr.isEmpty || user.isEmpty || pwd.isEmpty || targetSsid.isEmpty) {
      return;
    }

    // 依赖 Wi-Fi 名：不在目标 Wi-Fi（或认为不在）就不刷新
    final onWifi = await _ensureOnTargetWifi(targetSsid);
    if (!onWifi) return;

    // 无 cookie 则登录一次
    if (_sessionCookie == null) {
      final ok = await _loginOnce(
        addr: addr,
        username: user,
        password: pwd,
      );
      if (!ok) return;
    }

    Future<void> doFetch() async {
      // 1. 电池 + WiFi
      final info = await _apiClient.fetchBatteryAndWifi(
        baseUrl: addr,
        cookie: _sessionCookie!,
      );

      // 2. 在线设备
      List<HostInfo>? hosts;
      try {
        hosts = await _apiClient.fetchHosts(
          baseUrl: addr,
          cookie: _sessionCookie!,
        );
      } catch (_) {
        hosts = [];
      }

      // 3. 解析电量
      double? batteryPercent;
      if (info.batteryPercent != null) {
        final parsed = double.tryParse(info.batteryPercent!);
        if (parsed != null) {
          batteryPercent = parsed.clamp(0, 100).toDouble();
        }
      }

      final hostCount = hosts?.length ?? 0;

      final batteryText = batteryPercent != null
          ? '${batteryPercent.toStringAsFixed(0)}%'
          : (info.batteryPercent ?? '?');

      final notifyText = '电量 $batteryText，在线设备 $hostCount 台';

      // 更新「前台服务自己的」通知
      await FlutterForegroundTask.updateService(
        notificationTitle: '随身WiFi',
        notificationText: notifyText,
      );
    }

    try {
      await doFetch();
    } on ApiException {
      // 认为可能是 session 失效，重登一次
      final ok = await _loginOnce(
        addr: addr,
        username: user,
        password: pwd,
      );
      if (!ok) return;

      try {
        await doFetch();
      } catch (_) {
        // 后台静默失败，不再抛异常
      }
    } catch (_) {
      // 其他异常直接忽略，避免前台服务被干掉
    }
  }
}
