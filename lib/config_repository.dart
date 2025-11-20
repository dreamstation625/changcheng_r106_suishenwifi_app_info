// lib/config_repository.dart
import 'package:shared_preferences/shared_preferences.dart';

class ConfigRepository {
  static const _keyConsoleAddress = 'console_address';
  static const _keyUsername = 'username';
  static const _keyPassword = 'password';
  static const _keyTargetSsid = 'target_ssid'; // 新增：目标 WiFi SSID

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  String get consoleAddress =>
      _prefs?.getString(_keyConsoleAddress) ?? 'http://192.168.1.1';
  String get username => _prefs?.getString(_keyUsername) ?? '';
  String get password => _prefs?.getString(_keyPassword) ?? '';
  String get targetSsid => _prefs?.getString(_keyTargetSsid) ?? ''; // 新增

  Future<void> saveConfig({
    required String consoleAddress,
    required String username,
    required String password,
    required String targetSsid, // 新增
  }) async {
    await _prefs?.setString(_keyConsoleAddress, consoleAddress);
    await _prefs?.setString(_keyUsername, username);
    await _prefs?.setString(_keyPassword, password);
    await _prefs?.setString(_keyTargetSsid, targetSsid);
  }
}
