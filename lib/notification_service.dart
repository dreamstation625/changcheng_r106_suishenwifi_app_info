// lib/notification_service.dart
import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  NotificationService._internal();

  static final NotificationService _instance = NotificationService._internal();

  static NotificationService get instance => _instance;

  final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 初始化通知插件（在 main() 里调用一次）
  Future<void> init() async {
    if (_initialized) return;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(initSettings);
    _initialized = true;
  }

  /// 更新状态栏通知：显示电量和在线设备数量
  ///
  /// batteryPercent: 0~100 或 null
  /// hostCount: 在线设备数量
  Future<void> updateStatusNotification({
    double? batteryPercent,
    int hostCount = 0,
  }) async {
    if (!_initialized) return;

    final intBattery =
    batteryPercent != null ? batteryPercent.round().clamp(0, 100) : null;

    final title = '随身WiFi 状态';
    final String body;
    if (intBattery != null) {
      body = '电量：$intBattery%，在线设备：$hostCount 台';
    } else {
      body = '在线设备：$hostCount 台';
    }

    const androidDetails = AndroidNotificationDetails(
      'wifi_status_channel', // 通知渠道 id
      'WiFi 状态',             // 渠道名称（设置里会显示）
      channelDescription: '显示随身 WiFi 电量与在线设备数量',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true, // 常驻通知，不被轻易划掉
      showWhen: false,
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      1, // 通知 id，固定为 1 表示覆盖更新同一条
      title,
      body,
      details,
    );
  }

  /// 如有需要，可以提供取消通知的方法
  Future<void> cancelStatusNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(1);
  }
}
