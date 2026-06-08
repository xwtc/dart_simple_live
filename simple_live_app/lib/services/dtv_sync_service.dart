import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:mdns_dart/mdns_dart.dart' as mdns;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

/// DTV-compatible bidirectional sync service.
class DtvSyncService extends GetxService {
  static DtvSyncService get instance => Get.find<DtvSyncService>();

  static const int dtvSyncPort = 38999;
  static const String dtvSyncPath = '/dtv-sync';
  static const String dtvSyncPayloadPath = '/dtv-sync/payload';
  static const String defaultToken = 'dtv';
  static const String syncKind = 'dtv-lan-sync';
  static const int syncVersion = 1;
  static const String mdnsServiceType = '_dtv-lan-sync._tcp';

  final NetworkInfo _networkInfo = NetworkInfo();

  var running = false.obs;
  var ipAddress = ''.obs;
  var port = dtvSyncPort.obs;
  var errorMsg = ''.obs;
  var token = defaultToken.obs;

  var discovering = false.obs;
  var discoveredPeers = <DtvPeer>[].obs;

  HttpServer? _server;
  mdns.MDNSServer? _mdnsServer;
  final Uuid _uuid = const Uuid();

  // ======================================================================
  // Platform mapping
  // ======================================================================

  static String siteIdToPlatform(String siteId) {
    switch (siteId) {
      case Constant.kBiliBili:
        return 'BILIBILI';
      case Constant.kDouyu:
        return 'DOUYU';
      case Constant.kHuya:
        return 'HUYA';
      case Constant.kDouyin:
        return 'DOUYIN';
      default:
        return siteId.toUpperCase();
    }
  }

  static String platformToSiteId(String platform) {
    switch (platform.toUpperCase()) {
      case 'BILIBILI':
        return Constant.kBiliBili;
      case 'DOUYU':
        return Constant.kDouyu;
      case 'HUYA':
        return Constant.kHuya;
      case 'DOUYIN':
        return Constant.kDouyin;
      default:
        return platform.toLowerCase();
    }
  }

  // ======================================================================
  // DTV id helpers — handles both "12345" and "DOUYU:12345" formats
  // ======================================================================

  /// Extract bare roomId from a DTV id field (may be "12345" or "DOUYU:12345").
  static String extractRoomId(String rawId) {
    final colonIdx = rawId.indexOf(':');
    return colonIdx >= 0 ? rawId.substring(colonIdx + 1) : rawId;
  }

  /// Build Simple Live followId from DTV platform and roomId.
  static String buildFollowId(String platform, String roomId) {
    final bareRoomId = extractRoomId(roomId);
    final siteId = platformToSiteId(platform);
    return '${siteId}_$bareRoomId';
  }

  // ======================================================================
  // Export: Simple Live → DTV payload
  // ======================================================================

  Map<String, dynamic> _buildSource() {
    return {
      'client': 'mobile',
      'appVersion': Utils.packageInfo.version,
    };
  }

  List<Map<String, dynamic>> _buildFollowedStreamers() {
    final list = DBService.instance.followBox.values.toList();
    return list.map((user) {
      final platform = siteIdToPlatform(user.siteId);
      final statusStr = user.liveStatus.value == 2
          ? 'LIVE'
          : user.liveStatus.value == 1
              ? 'OFFLINE'
              : 'UNKNOWN';
      // DTV expects id as bare roomId (no platform prefix), currentRoomId as backup
      return {
        'id': user.roomId,
        'platform': platform,
        'nickname': user.userName,
        'avatarUrl': user.face,
        'roomTitle': null,
        'currentRoomId': user.roomId,
        'liveStatus': statusStr,
      };
    }).toList();
  }

  /// Convert Simple Live tag userIds ("douyu_5551871") → DTV format ("DOUYU:5551871").
  List<String> _tagUserIdsToDtvFormat(FollowUserTag tag) {
    return tag.userId.map((uid) {
      final underscoreIdx = uid.indexOf('_');
      if (underscoreIdx <= 0) return uid;
      final siteId = uid.substring(0, underscoreIdx);
      final roomId = uid.substring(underscoreIdx + 1);
      final platform = siteIdToPlatform(siteId);
      return '$platform:$roomId';
    }).toList();
  }

  List<Map<String, dynamic>> _buildFollowFolders() {
    final tags = DBService.instance.tagBox.values.toList();
    return tags.map((tag) {
      return {
        'id': tag.id,
        'name': tag.tag,
        'streamerIds': _tagUserIdsToDtvFormat(tag),
      };
    }).toList();
  }

  /// Export danmu block keywords from Simple Live shield list.
  List<String> _buildDanmuBlockKeywords() {
    return AppSettingsController.instance.shieldList.toList();
  }

  bool _checkToken(shelf.Request request) {
    final t = request.requestedUri.queryParameters['token'];
    return t == token.value;
  }

  shelf.Response _handleManifest(shelf.Request request) {
    if (!_checkToken(request)) {
      return shelf.Response.forbidden('invalid token');
    }

    final followed = DBService.instance.followBox.values.toList();
    final tags = DBService.instance.tagBox.values.toList();
    final keywords = _buildDanmuBlockKeywords();

    final manifest = {
      'kind': syncKind,
      'version': syncVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'source': _buildSource(),
      'summary': {
        'followedStreamers': followed.length,
        'followFolders': tags.length,
        'followListOrder': followed.length,
        'customCategories': 0,
        'danmuBlockKeywords': keywords.length,
        'totalBytes': 0,
      },
    };

    return shelf.Response.ok(
      json.encode(manifest),
      headers: {'Content-Type': 'application/json'},
    );
  }

  String _buildPayloadJson() {
    final followed = _buildFollowedStreamers();
    final folders = _buildFollowFolders();
    final keywords = _buildDanmuBlockKeywords();

    final entries = <String, String>{};
    entries['followedStreamers'] = json.encode(followed);
    entries['followFolders'] = json.encode(folders);
    entries['followListOrder'] = json.encode(
      followed.map((s) => {
        'type': 'streamer',
        'data': <String, dynamic>{
          'id': s['id'],
          'platform': s['platform'],
          'nickname': s['nickname'],
          'avatarUrl': s['avatarUrl'],
          'roomTitle': s['roomTitle'],
          'currentRoomId': s['currentRoomId'],
          'liveStatus': s['liveStatus'],
        },
      }).toList(),
    );
    entries['danmu_block_keywords'] = json.encode(keywords);

    final payload = {
      'kind': syncKind,
      'version': syncVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'source': _buildSource(),
      'entries': entries,
    };

    return json.encode(payload);
  }

  shelf.Response _handlePayload(shelf.Request request) {
    if (!_checkToken(request)) {
      return shelf.Response.forbidden('invalid token');
    }
    return shelf.Response.ok(
      _buildPayloadJson(),
      headers: {'Content-Type': 'application/json'},
    );
  }

  // ======================================================================
  // Server start / stop (HTTP + mDNS advertising)
  // ======================================================================

  Future<String> _getLocalIP() async {
    try {
      final ip = await _networkInfo.getWifiIP();
      if (ip != null && ip.isNotEmpty) return ip;
    } catch (_) {}
    try {
      final interfaces = await NetworkInterface.list();
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.isMulticast && addr.type.name == 'IPv4') {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '0.0.0.0';
  }

  Future<void> start() async {
    if (running.value) return;

    try {
      final router = Router();
      router.get(dtvSyncPath, _handleManifest);
      router.get(dtvSyncPayloadPath, _handlePayload);

      int tryPort = dtvSyncPort;
      HttpServer? server;
      for (var offset = 0; offset < 10; offset++) {
        try {
          server = await shelf_io.serve(router, InternetAddress.anyIPv4, tryPort + offset);
          server.autoCompress = true;
          break;
        } catch (_) {
          continue;
        }
      }

      if (server == null) {
        errorMsg.value = 'Failed to bind any port';
        return;
      }

      _server = server;
      port.value = server.port;
      running.value = true;

      final ip = await _getLocalIP();
      ipAddress.value = ip;
      Log.d('DTV sync serving at http://$ip:${server.port}$dtvSyncPath');

      // Start mDNS advertising
      try {
        final hostName = 'dtv-sync-simplelive';
        _mdnsServer = mdns.MDNSServer(mdns.MDNSServerConfig(
          zone: mdns.MDNSService(
            instance: 'dtv-sync-simplelive-${server.port}',
            service: mdnsServiceType,
            domain: 'local',
            hostName: '$hostName.local.',
            port: server.port,
            ips: [InternetAddress(ip)],
            txt: [
              'kind=$syncKind',
              'ver=$syncVersion',
              'path=$dtvSyncPath',
              'token=${token.value}',
            ],
          ),
        ));
        await _mdnsServer!.start();
        Log.d('DTV mDNS advertising started');
      } catch (e) {
        Log.logPrint('DTV mDNS advertise error (non-fatal): $e');
      }
    } catch (e) {
      errorMsg.value = e.toString();
      Log.logPrint('DTV sync start error: $e');
    }
  }

  Future<void> stop() async {
    await _mdnsServer?.stop();
    _mdnsServer = null;
    await _server?.close(force: true);
    _server = null;
    running.value = false;
    ipAddress.value = '';
    Log.d('DTV sync server stopped');
  }

  Future<void> toggle() async {
    if (running.value) {
      await stop();
    } else {
      await start();
    }
  }

  // ======================================================================
  // Client: mDNS discovery
  // ======================================================================

  Future<List<DtvPeer>> discoverPeers() async {
    if (discovering.value) return discoveredPeers.toList();

    discovering.value = true;
    discoveredPeers.clear();

    try {
      final results = await mdns.MDNSClient.discover(mdnsServiceType).timeout(
        const Duration(seconds: 5),
        onTimeout: () => <mdns.ServiceEntry>[],
      );

      for (final service in results) {
        final host = service.primaryAddress?.address;
        if (host == null) continue;

        final svcPort = service.port;
        final token = _parseTxtField(service.infoFields, 'token') ?? defaultToken;
        final baseUrl = 'http://$host:$svcPort';

        if (!discoveredPeers.any((p) => p.baseUrl == baseUrl)) {
          discoveredPeers.add(DtvPeer(
            name: service.name,
            host: host,
            port: svcPort,
            token: token,
            baseUrl: baseUrl,
          ));
        }
      }
    } catch (e) {
      Log.logPrint('mDNS discovery error: $e');
    }

    discovering.value = false;
    return discoveredPeers.toList();
  }

  String? _parseTxtField(List<String>? fields, String key) {
    if (fields == null) return null;
    final prefix = '$key=';
    for (final f in fields) {
      if (f.startsWith(prefix)) return f.substring(prefix.length);
    }
    return null;
  }

  // ======================================================================
  // Client: fetch from DTV peer
  // ======================================================================

  Future<Map<String, dynamic>?> fetchPayload(DtvPeer peer) async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);

      final url = '${peer.baseUrl}$dtvSyncPayloadPath?token=${Uri.encodeComponent(peer.token)}';
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close().timeout(const Duration(seconds: 5));

      if (response.statusCode != 200) {
        Log.logPrint('DTV fetch failed: HTTP ${response.statusCode}');
        return null;
      }

      final body = await response.transform(utf8.decoder).join();
      client.close();
      return json.decode(body) as Map<String, dynamic>;
    } catch (e) {
      Log.logPrint('DTV fetch error: $e');
      return null;
    }
  }

  // ======================================================================
  // Import: DTV payload → Simple Live
  // Handles both "12345" and "DOUYU:12345" id formats from DTV.
  // ======================================================================

  Future<DtvImportResult> importFromPayload(Map<String, dynamic> payload) async {
    final entries = payload['entries'] as Map<String, dynamic>?;
    if (entries == null) {
      return DtvImportResult(addedFollows: 0, addedTags: 0, addedKeywords: 0, error: 'No entries in payload');
    }

    var addedFollows = 0;
    var addedTags = 0;
    var addedKeywords = 0;

    try {
      // ---- 1. Import followed streamers ----
      final followedRaw = entries['followedStreamers'];
      if (followedRaw is String) {
        final List<dynamic> followedList = json.decode(followedRaw);

        for (final item in followedList) {
          if (item is! Map<String, dynamic>) continue;

          final platform = item['platform'] as String? ?? '';
          if (platform.isEmpty) continue;

          final siteId = platformToSiteId(platform);
          // Prefer currentRoomId, fallback to id (strip platform prefix if present)
          final rawId = (item['currentRoomId'] as String?)?.ifNotEmpty ??
              (item['id'] as String?)?.ifNotEmpty ?? '';
          if (rawId.isEmpty) continue;
          final roomId = extractRoomId(rawId);
          if (roomId.isEmpty) continue;

          final followId = '${siteId}_$roomId';
          if (DBService.instance.followBox.containsKey(followId)) continue;

          final userName = (item['nickname'] as String?)?.ifNotEmpty ?? roomId;
          final face = (item['avatarUrl'] as String?)?.ifNotEmpty ?? '';

          final follow = FollowUser(
            id: followId,
            roomId: roomId,
            siteId: siteId,
            userName: userName,
            face: face,
            addTime: DateTime.now(),
            tag: '全部',
          );

          await DBService.instance.followBox.put(follow.id, follow);
          addedFollows++;
        }
      }

      // ---- 2. Import followFolders → Simple Live tags ----
      final foldersRaw = entries['followFolders'];
      if (foldersRaw is String) {
        final List<dynamic> folders = json.decode(foldersRaw);
        for (final folder in folders) {
          if (folder is! Map<String, dynamic>) continue;

          final folderName = (folder['name'] as String?)?.ifNotEmpty;
          if (folderName == null) continue;

          final streamerIds = (folder['streamerIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .where((e) => e.isNotEmpty)
              .toList() ?? [];
          if (streamerIds.isEmpty) continue;

          // Find or create tag
          var tag = DBService.instance.getFollowTag(folderName);
          if (tag == null) {
            final tagId = _uuid.v4();
            tag = FollowUserTag(id: tagId, tag: folderName, userId: []);
            await DBService.instance.tagBox.put(tagId, tag);
            addedTags++;
          }

          // Map DTV streamer IDs ("DOUYU:5551871" or "5551871") → Simple Live followId ("douyu_5551871")
          for (final dtvId in streamerIds) {
            final parts = dtvId.split(':');
            final roomId = parts.length >= 2 ? parts.sublist(1).join(':') : parts[0];
            final platform = parts.length >= 2 ? parts[0] : null;
            if (platform == null) continue; // can't map without platform
            final siteId = platformToSiteId(platform);
            final followId = '${siteId}_$roomId';

            if (!tag.userId.contains(followId)) {
              tag.userId.add(followId);
            }
          }

          await DBService.instance.tagBox.put(tag.id, tag);
        }
      }

      // ---- 3. Import danmu_block_keywords ----
      final keywordsRaw = entries['danmu_block_keywords'];
      if (keywordsRaw is String) {
        final List<dynamic> keywordsList = json.decode(keywordsRaw);
        final shieldBox = LocalStorageService.instance.shieldBox;
        for (final kw in keywordsList) {
          if (kw is String && kw.trim().isNotEmpty) {
            final trimmed = kw.trim();
            if (!shieldBox.containsKey(trimmed)) {
              AppSettingsController.instance.addShieldList(trimmed);
              addedKeywords++;
            }
          }
        }
      }

      // Refresh UI
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
    } catch (e) {
      Log.logPrint('DTV import error: $e');
      return DtvImportResult(addedFollows: addedFollows, addedTags: addedTags, addedKeywords: addedKeywords, error: e.toString());
    }

    return DtvImportResult(addedFollows: addedFollows, addedTags: addedTags, addedKeywords: addedKeywords);
  }

  @override
  void onClose() {
    _mdnsServer?.stop();
    _server?.close(force: true);
    super.onClose();
  }
}

/// A DTV device discovered via mDNS.
class DtvPeer {
  final String name;
  final String host;
  final int port;
  final String token;
  final String baseUrl;

  DtvPeer({
    required this.name,
    required this.host,
    required this.port,
    required this.token,
    required this.baseUrl,
  });
}

/// Result of a DTV data import.
class DtvImportResult {
  final int addedFollows;
  final int addedTags;
  final int addedKeywords;
  final String? error;

  DtvImportResult({required this.addedFollows, required this.addedTags, required this.addedKeywords, this.error});

  bool get isSuccess => error == null;
  String get summary {
    if (error != null) return '导入失败: $error';
    final parts = <String>[];
    if (addedFollows > 0) parts.add('${addedFollows}个关注');
    if (addedTags > 0) parts.add('${addedTags}个标签');
    if (addedKeywords > 0) parts.add('${addedKeywords}个屏蔽词');
    return parts.isEmpty ? '没有新数据导入' : '导入成功: ${parts.join(', ')}';
  }
}

extension _StringExt on String? {
  String? get ifNotEmpty => (this != null && this!.isNotEmpty) ? this : null;
}

extension _StringExt2 on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
