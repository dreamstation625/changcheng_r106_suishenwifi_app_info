// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'home_page.dart';
import 'config_repository.dart';
import 'api_client.dart';
import 'notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化前台服务通信端口（即便现在不收发数据，也建议先初始化）
  FlutterForegroundTask.initCommunicationPort();

  // 初始化通知插件
  await NotificationService.instance.init();

  // 初始化配置
  final configRepository = ConfigRepository();
  await configRepository.init();

  // API 客户端
  final apiClient = ApiClient();

  runApp(MyApp(
    configRepository: configRepository,
    apiClient: apiClient,
  ));
}

class MyApp extends StatelessWidget {
  final ConfigRepository configRepository;
  final ApiClient apiClient;

  const MyApp({
    super.key,
    required this.configRepository,
    required this.apiClient,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '随身WiFi',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      // WithForegroundTask 可以防止前台服务运行时直接关闭整个应用
      home: WithForegroundTask(
        child: HomePage(
          configRepository: configRepository,
          apiClient: apiClient,
        ),
      ),
    );
  }
}
