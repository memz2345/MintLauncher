import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'downloader.dart';

/// 账户类型。
enum AccountType {
  /// 离线（HMCL OfflineAccount 同款 UUID 算法）。
  offline('offline', '离线'),

  /// 外置登录（authlib-injector，LittleSkin 等 Yggdrasil 兼容验证服务器）。
  authlib('authlib', '外置登录');

  const AccountType(this.id, this.label);
  final String id;
  final String label;

  static AccountType fromId(String? id) =>
      id == 'authlib' ? AccountType.authlib : AccountType.offline;
}

/// 启动器账户。
class OfflineAccount {
  const OfflineAccount({
    required this.name,
    required this.uuid,
    this.type = AccountType.offline,
    this.authServer = '',
  });

  final String name;

  /// 带连字符的小写 UUID。
  final String uuid;

  final AccountType type;

  /// 外置登录的验证服务器根地址（`https://littleskin.cn/api/yggdrasil`）。
  final String authServer;

  Map<String, dynamic> toJson() => {
    'name': name,
    'uuid': uuid,
    'type': type.id,
    if (authServer.isNotEmpty) 'authServer': authServer,
  };

  factory OfflineAccount.fromJson(Map<String, dynamic> json) => OfflineAccount(
    name: (json['name'] as String?) ?? '',
    uuid: (json['uuid'] as String?) ?? '',
    type: AccountType.fromId(json['type'] as String?),
    authServer: (json['authServer'] as String?) ?? '',
  );

  bool get isAuthlib => type == AccountType.authlib;
}

/// 离线账户（HMCL `OfflineAccount` 同款）：
/// UUID = UUID v3（MD5），种子为 `OfflinePlayer:<name>` 的 UTF-8 字节 ——
/// 与 Minecraft 官方的离线 UUID 算法一致（Java 的 `UUID.nameUUIDFromBytes`）。
String offlineUuid(String name) {
  final digest = crypto.md5.convert(utf8.encode('OfflinePlayer:$name')).bytes;
  final bytes = List<int>.from(digest);
  // RFC 4122：version 3 + variant
  bytes[6] = (bytes[6] & 0x0F) | 0x30;
  bytes[8] = (bytes[8] & 0x3F) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20, 32)}';
}

/// 由用户名直接构造离线账户（UUID 现算）。
OfflineAccount createOfflineAccount(String name) =>
    OfflineAccount(name: name, uuid: offlineUuid(name));

/// 由用户名 + 验证服务器构造外置登录账户。
///
/// UUID 从验证服务器查询（Yggdrasil API：`/api/users/profiles/minecraft/<name>`）；
/// 查不到（服务器离线 / 角色不存在）时回退离线 UUID 并由调用方提示。
Future<OfflineAccount> createAuthlibAccount(
  String name,
  String serverUrl,
  Downloader dl,
) async {
  final base = _normalizeServer(serverUrl);
  String uuid = '';
  try {
    final text = await dl.getString(
      '$base/api/users/profiles/minecraft/${Uri.encodeComponent(name)}',
    );
    uuid = ((jsonDecode(text) as Map<String, dynamic>)['id'] as String?) ?? '';
    // Yggdrasil 返回不带连字符的 UUID，补齐成标准形态。
    if (uuid.length == 32) {
      uuid =
          '${uuid.substring(0, 8)}-${uuid.substring(8, 12)}-'
          '${uuid.substring(12, 16)}-${uuid.substring(16, 20)}-'
          '${uuid.substring(20, 32)}';
    }
    if (uuid.length != 36) uuid = '';
  } catch (_) {}
  return OfflineAccount(
    name: name,
    uuid: uuid.isNotEmpty ? uuid : offlineUuid(name),
    type: AccountType.authlib,
    authServer: base,
  );
}

/// 规范化验证服务器地址：容忍裸域名 / yggdrasil 服务页链接，
/// 统一成 `<root>/api/yggdrasil` 的根（authlib-injector 要求的形态）。
String _normalizeServer(String input) {
  var url = input.trim();
  if (url.isEmpty) return url;
  if (!url.startsWith('http')) url = 'https://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  // LittleSkin 风格的首页 URL → API 根。
  if (!url.contains('/api/yggdrasil')) {
    final uri = Uri.tryParse(url);
    final host = uri?.host ?? '';
    if (host == 'littleskin.cn' || host.endsWith('.littleskin.cn')) {
      return 'https://littleskin.cn/api/yggdrasil';
    }
  }
  return url;
}

/// authlib-injector 注入器 jar 的下载信息（取最新版）。
class AuthlibInjectorArtifact {
  const AuthlibInjectorArtifact({required this.url, required this.version});

  final String url;
  final String version;
}

/// 查询 authlib-injector 最新构件（官方 artifact 列表）。
Future<AuthlibInjectorArtifact> latestAuthlibInjector(Downloader dl) async {
  final json = await dl.getJson(
    'https://authlib-injector.yushi.moe/~artifacts/',
  );
  final list = json['artifacts'];
  if (list is! List || list.isEmpty) {
    throw Exception('authlib-injector 构件列表为空');
  }
  final last = list.last as Map<String, dynamic>;
  return AuthlibInjectorArtifact(
    url: (last['url'] as String?) ?? '',
    version: (last['version'] as String?) ?? '',
  );
}
