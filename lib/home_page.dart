// lib/home_page.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config_repository.dart';
import 'api_client.dart';
import 'notification_service.dart';

class HomePage extends StatefulWidget {
  final ConfigRepository configRepository;
  final ApiClient apiClient;

  const HomePage({
    super.key,
    required this.configRepository,
    required this.apiClient,
  });

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late TextEditingController _addrController;
  late TextEditingController _userController;
  late TextEditingController _pwdController;
  late TextEditingController _ssidController;
  late TextEditingController _autoRefreshController;

  bool _isLoading = false;
  String? _batteryText;
  Map<String, String>? _wifiInfo;
  List<HostInfo>? _hosts;
  String? _lastError;

  String? _sessionCookie;
  Timer? _autoRefreshTimer;

  /// 自动刷新间隔（秒），可配置，默认 10 秒
  int _autoRefreshSeconds = 10;

  final _networkInfo = NetworkInfo();

  @override
  void initState() {
    super.initState();
    _addrController =
        TextEditingController(text: widget.configRepository.consoleAddress);
    _userController =
        TextEditingController(text: widget.configRepository.username);
    _pwdController =
        TextEditingController(text: widget.configRepository.password);
    _ssidController =
        TextEditingController(text: widget.configRepository.targetSsid);

    _autoRefreshController =
        TextEditingController(text: _autoRefreshSeconds.toString());

    // 先加载本地保存的自动刷新配置
    _loadAutoRefreshConfig();

    // 首次进入，如果已有完整配置，自动刷新一次并启动定时刷新
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final hasConfigured =
          _addrController.text.trim().isNotEmpty &&
              _userController.text.trim().isNotEmpty &&
              _pwdController.text.trim().isNotEmpty &&
              _ssidController.text.trim().isNotEmpty;

      if (hasConfigured) {
        _refreshStatus(auto: true);
        _startAutoRefresh();
      }
    });
  }

  @override
  void dispose() {
    _addrController.dispose();
    _userController.dispose();
    _pwdController.dispose();
    _ssidController.dispose();
    _autoRefreshController.dispose();
    _autoRefreshTimer?.cancel();
    // 如果你希望退出页面就把通知关掉，可以打开这一行：
    // NotificationService.instance.cancelStatusNotification();
    super.dispose();
  }

  /// 从 SharedPreferences 读取自动刷新间隔
  Future<void> _loadAutoRefreshConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final seconds = prefs.getInt('auto_refresh_seconds') ?? 10;
    setState(() {
      _autoRefreshSeconds = seconds > 0 ? seconds : 10;
      _autoRefreshController.text = _autoRefreshSeconds.toString();
    });
    _startAutoRefresh();
  }

  /// 保存自动刷新间隔到 SharedPreferences
  Future<void> _saveAutoRefreshConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('auto_refresh_seconds', _autoRefreshSeconds);
  }

  /// 开启 / 重启自动刷新
  void _startAutoRefresh() {
    _autoRefreshTimer?.cancel();
    if (_autoRefreshSeconds <= 0) return;

    _autoRefreshTimer = Timer.periodic(
      Duration(seconds: _autoRefreshSeconds),
          (_) {
        _refreshStatus(auto: true);
      },
    );
  }

  /// 保证当前连接的 WiFi SSID 等于目标 SSID
  /// showError = false 时，只返回 true/false，不修改 _lastError（用于自动刷新静默失败）
  Future<bool> _ensureOnTargetWifi({bool showError = true}) async {
    final target = _ssidController.text.trim();
    if (target.isEmpty) {
      if (showError) {
        setState(() {
          _lastError = '请先填写目标 WiFi 名称（SSID）';
        });
      }
      return false;
    }

    // 申请位置权限（Android 10+ 获取 WiFi 名称需要）
    var status = await Permission.location.status;
    if (!status.isGranted) {
      status = await Permission.location.request();
      if (!status.isGranted) {
        if (showError) {
          setState(() {
            _lastError = '需要授予“位置信息”权限才能获取当前 WiFi 名称，请在系统设置中打开后重试。';
          });
        }
        return false;
      }
    }

    String? currentSsid;
    try {
      currentSsid = await _networkInfo.getWifiName();
    } catch (e) {
      if (showError) {
        setState(() {
          _lastError = '无法获取当前 WiFi 名称：$e';
        });
      }
      return false;
    }

    // 有的机型会返回带引号的 SSID，例如 "Xiaomi Dream"
    currentSsid = currentSsid?.replaceAll('"', '');

    if (currentSsid == null ||
        currentSsid.isEmpty ||
        currentSsid.toLowerCase() == '<unknown ssid>') {
      if (showError) {
        setState(() {
          _lastError = '当前未能识别 WiFi 名称，请确认：\n'
              '1）手机已连接到 WiFi\n'
              '2）系统“位置信息”开关已打开\n'
              '3）已授予应用位置信息权限';
        });
      }
      return false;
    }

    if (currentSsid != target) {
      if (showError) {
        setState(() {
          _lastError =
          '当前连接的 WiFi 为：$currentSsid\n请连接到指定 WiFi：$target 再刷新';
        });
      }
      return false;
    }

    return true;
  }

  /// 登录一次，成功后更新 _sessionCookie
  Future<bool> _loginOnce() async {
    final addr = _addrController.text.trim();
    final user = _userController.text.trim();
    final pwd = _pwdController.text.trim();

    final loginResult = await widget.apiClient.login(
      baseUrl: addr,
      username: user,
      password: pwd,
    );

    if (!loginResult.success || loginResult.cookie == null) {
      setState(() {
        _lastError = '登录失败：${loginResult.error ?? "未知错误"}';
      });
      return false;
    }

    _sessionCookie = loginResult.cookie;
    return true;
  }

  /// 用当前 cookie 刷新：电池 + WiFi + 在线设备
  /// allowLoginRetry: 接口异常时，自动重登一次并重试
  /// auto: 是否自动刷新（自动刷新失败时不弹 WiFi 错误）
  Future<void> _fetchStatusWithCurrentCookie({
    bool allowLoginRetry = true,
    bool auto = false,
  }) async {
    final addr = _addrController.text.trim();
    if (addr.isEmpty) {
      setState(() {
        _lastError = '控制台地址为空';
      });
      return;
    }

    // WiFi 不匹配则不请求；自动刷新时不显示错误
    final onWifi = await _ensureOnTargetWifi(showError: !auto);
    if (!onWifi) return;

    // 如果没有 cookie，允许自动登录则先登录一次
    if (_sessionCookie == null && allowLoginRetry) {
      final ok = await _loginOnce();
      if (!ok) return;
    } else if (_sessionCookie == null && !allowLoginRetry) {
      setState(() {
        _lastError = '尚未登录，无 cookie 可用';
      });
      return;
    }

    // 具体请求逻辑封装成内部函数，方便重试
    Future<void> doFetch() async {
      // 1. 电池 + WiFi
      final info = await widget.apiClient.fetchBatteryAndWifi(
        baseUrl: addr,
        cookie: _sessionCookie!,
      );

      // 2. 在线设备
      List<HostInfo>? hosts;
      try {
        hosts = await widget.apiClient.fetchHosts(
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

      // 4. 更新页面状态
      setState(() {
        _batteryText = info.batteryPercent;
        _wifiInfo = info.wifiInfo;
        _hosts = hosts;
        _lastError = null;
      });

      // 5. 同步更新通知栏
      await NotificationService.instance.updateStatusNotification(
        batteryPercent: batteryPercent,
        hostCount: hostCount,
      );
    }

    try {
      await doFetch();
    } catch (e) {
      // 只要是接口返回的 ApiException（包括 session 失效 / retcode != 0 /
      // HTTP 状态码异常 / 返回 HTML 等），在允许重登的情况下重登一次并重试
      if (allowLoginRetry && e is ApiException) {
        final ok = await _loginOnce();
        if (!ok) return;
        try {
          await doFetch();
        } catch (e2) {
          setState(() {
            _lastError = '获取状态失败（重登后）：$e2';
          });
        }
      } else {
        setState(() {
          _lastError = '获取状态失败：$e';
        });
      }
    }
  }

  /// 保存配置 + 首次登录 + 获取状态 + 开启自动刷新
  Future<void> _saveAndFetch() async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      _lastError = null;
    });

    final addr = _addrController.text.trim();
    final user = _userController.text.trim();
    final pwd = _pwdController.text.trim();
    final target = _ssidController.text.trim();

    if (addr.isEmpty || user.isEmpty || pwd.isEmpty || target.isEmpty) {
      setState(() {
        _isLoading = false;
        _lastError = '请填写完整：控制台地址 / 用户名 / 密码 / 目标 WiFi 名称';
      });
      return;
    }

    // 主动操作，WiFi 出问题要提示
    final onWifi = await _ensureOnTargetWifi(showError: true);
    if (!onWifi) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    final ok = await _loginOnce();
    if (!ok) {
      setState(() {
        _isLoading = false;
      });
      return;
    }

    // 登录成功才保存配置
    await widget.configRepository.saveConfig(
      consoleAddress: addr,
      username: user,
      password: pwd,
      targetSsid: target,
    );

    // 首次获取状态，不再额外重登；是手动行为，auto=false
    await _fetchStatusWithCurrentCookie(
      allowLoginRetry: false,
      auto: false,
    );

    _startAutoRefresh();

    setState(() {
      _isLoading = false;
    });
  }

  /// 手动刷新 / 自动刷新共用
  Future<void> _refreshStatus({bool auto = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = !auto;
      if (!auto) _lastError = null;
    });

    await _fetchStatusWithCurrentCookie(
      allowLoginRetry: true,
      auto: auto,
    );

    if (!auto) {
      setState(() {
        _isLoading = false;
      });
    } else {
      // 自动刷新就不再触发一次 setState，直接标记即可
      _isLoading = false;
    }
  }

  /// 单个设备小卡片
  Widget _buildHostCard(HostInfo host) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Colors.grey.shade100,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              host.hostname.isNotEmpty ? host.hostname : host.ip,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text('IP：${host.ip}'),
            Text('MAC：${host.mac}'),
            if (host.onlineTime != null &&
                host.onlineTime!.trim().isNotEmpty)
              Text('上线时间：${host.onlineTime}'),
          ],
        ),
      ),
    );
  }

  /// WiFi 卡片（5G / 2.4G 共用）
  Widget _buildWifiCard({
    required String title,
    required String suffix, // "0" 或 "1"
    required Map<String, String> wifiInfo,
  }) {
    String getField(String keyPrefix) =>
        wifiInfo['${keyPrefix}_$suffix'] ?? '';

    final freq = getField('wifi_freq');
    final state = getField('wifi_state');
    final ssid = getField('wifi_ssid');
    final security = getField('wifi_security');
    final psk = wifiInfo['xmg_wifi_psk_$suffix'] ??
        wifiInfo['wifi_psk_$suffix'] ??
        '';
    final mode = getField('wifi_mode');

    final bool isEnabled = state == 'ap_enable';
    final Color statusColor = isEnabled ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.all(6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 状态圆点
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  isEnabled ? '状态：ap_enable' : '状态：$state',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 标题
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            if (ssid.isNotEmpty) Text('SSID：$ssid'),
            if (freq.isNotEmpty) Text('频段：$freq'),
            if (mode.isNotEmpty) Text('模式：$mode'),
            if (security.isNotEmpty) Text('加密：$security'),
            if (psk.isNotEmpty) Text('密码：$psk'),
          ],
        ),
      ),
    );
  }

  /// 电量 + WiFi + 连接设备展示区域
  Widget _buildInfoSection() {
    if (_lastError != null) {
      return Text(
        _lastError!,
        style: const TextStyle(color: Colors.red),
      );
    }

    if (_batteryText == null && _wifiInfo == null && _hosts == null) {
      return const Text('尚未获取数据');
    }

    // 解析电量
    double? batteryPercent;
    if (_batteryText != null) {
      final parsed = double.tryParse(_batteryText!);
      if (parsed != null) {
        batteryPercent = parsed.clamp(0, 100).toDouble();
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 电量
        if (_batteryText != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '电池电量',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                batteryPercent != null
                    ? '${batteryPercent.toStringAsFixed(0)}%'
                    : '${_batteryText}%',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: batteryPercent != null ? batteryPercent / 100.0 : 0.0,
              minHeight: 8,
              backgroundColor: Colors.grey.shade300,
            ),
          ),
          const SizedBox(height: 16),
        ],

        // WiFi 信息
        if (_wifiInfo != null) ...[
          const Text(
            'WiFi 信息',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, constraints) {
              final bool isWide = constraints.maxWidth >= 600;

              final card5g = _buildWifiCard(
                title: '5GHz 热点 (wifi_0)',
                suffix: '0',
                wifiInfo: _wifiInfo!,
              );
              final card24g = _buildWifiCard(
                title: '2.4GHz 热点 (wifi_1)',
                suffix: '1',
                wifiInfo: _wifiInfo!,
              );

              if (isWide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: card5g),
                    const SizedBox(width: 12),
                    Expanded(child: card24g),
                  ],
                );
              } else {
                return Column(
                  children: [
                    card5g,
                    const SizedBox(height: 12),
                    card24g,
                  ],
                );
              }
            },
          ),
        ],

        // 连接设备
        if (_hosts != null && _hosts!.isNotEmpty) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity, // 横向铺满，和 WiFi 卡片统一
            child: Card(
              margin: const EdgeInsets.all(6),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '连接设备',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Column(
                      children: _hosts!.map(_buildHostCard).toList(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final isButtonDisabled = _isLoading;

    return Scaffold(
      appBar: AppBar(
        title: const Text('随身WiFi'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: _addrController,
              decoration: const InputDecoration(
                labelText: '控制台地址',
                hintText: '例如：http://192.168.1.1',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _userController,
              decoration: const InputDecoration(
                labelText: '用户名',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pwdController,
              decoration: const InputDecoration(
                labelText: '密码',
              ),
              obscureText: true,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _ssidController,
              decoration: const InputDecoration(
                labelText: '目标 WiFi 名称 (SSID)',
                hintText: '例如：Xiaomi Dream',
              ),
            ),
            const SizedBox(height: 24),

            // 保存配置并首次获取
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                icon: isButtonDisabled
                    ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Icon(Icons.save),
                label: Text(
                  isButtonDisabled ? '处理中...' : '保存配置并获取状态',
                ),
                onPressed: isButtonDisabled ? null : _saveAndFetch,
              ),
            ),

            const SizedBox(height: 12),

            // 自动刷新间隔配置
            Row(
              children: [
                const Text('自动刷新间隔（秒）'),
                const SizedBox(width: 8),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _autoRefreshController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding:
                      EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    ),
                    onSubmitted: (value) {
                      final n = int.tryParse(value);
                      if (n == null || n <= 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('请输入大于 0 的整数')),
                        );
                        _autoRefreshController.text =
                            _autoRefreshSeconds.toString();
                        return;
                      }
                      setState(() {
                        _autoRefreshSeconds = n;
                      });
                      _saveAutoRefreshConfig();
                      _startAutoRefresh();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                            content: Text('自动刷新间隔已更新为 $n 秒')),
                      );
                    },
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // 手动刷新
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('刷新状态'),
                onPressed:
                isButtonDisabled ? null : () => _refreshStatus(auto: false),
              ),
            ),

            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: _buildInfoSection(),
            ),
          ],
        ),
      ),
    );
  }
}
