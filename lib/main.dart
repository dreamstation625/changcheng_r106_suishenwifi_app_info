// lib/main.dart
import 'package:flutter/material.dart';
import 'home_page.dart';
import 'config_repository.dart';
import 'api_client.dart';
import 'notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化通知插件
  await NotificationService.instance.init();

  // 这里如果想在启动时就请求 Android 13 的通知权限，
  // 可以结合 permission_handler 做一次询问（可选）

  final configRepo = ConfigRepository();
  await configRepo.init();

  final apiClient = ApiClient();

  runApp(MyApp(
    configRepository: configRepo,
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
      ),
      home: HomePage(
        configRepository: configRepository,
        apiClient: apiClient,
      ),
    );
  }
}
