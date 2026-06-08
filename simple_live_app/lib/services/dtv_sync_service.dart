import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:mdns_dart/mdns_dart.dart' as mdns;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:uuid/uuid.dart';

/// DTV-compatible bidirectional sync service.
///
/// - Runs a DTV-protocol HTTP server on port 38999 and advertises via mDNS
///   so DTV desktop/Android can discover and import Simple Live data.
/// - Can discover DTV devices via mDNS and import their data into Simple Live.
class DtvSyncService extends GetxService {
  static DtvSyncService get instance => Get.find<DtvSyncService>();

  static const int dtvSyncPort = 38999;
  static const String dtvSyncPath = '/dtv-sync';
  static const String dtvSyncPayloadPath = '/dtv-sync/payload';
  static const String defaultToken = 'dtv';
  static const String syncKind = 'dtv-lan-sync';
  static const int syncVersion = 1;
  // DTV uses _dtv-lan-sync._tcp, mdns_dart omits .local automatically
  static const String mdnsServiceType = '_dtv-lan-sync._tcp';

  final NetworkInfo _networkInfo = NetworkInfo();

  // ---- Server state ----
  var running = false.obs;
  var ipAddress = ''.obs;
  var port = dtvSyncPort.obs;
  var errorMsg = ''.obs;
  var token = defaultToken.obs;

  // ---- mDNS discovery state ----
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
  // Server: export Simple Live data as DTV payload
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

  /// Convert Simple Live tag userIds (e.g. "douyu_5551871") to DTV format
  /// (e.g. "DOUYU:5551871").
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

    final entries = <String, String>{};
    entries['followedStreamers'] = json.encode(followed);
    entries['followFolders'] = json.encode(folders);
    entries['followListOrder'] = json.encode(
      followed.map((s) => s['id']).toList(),
    );

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
  // Server start / stop (including mDNS advertising)
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
      // 1. Start HTTP server
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

      // 2. Start mDNS advertising using mdns_dart
      try {
        final ip = await _getLocalIP();
        final hostName = ip.replaceAll('.', '-');
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
        Log.d('DTV mDNS advertising started for $mdnsServiceType');
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
  // Client: mDNS discovery using mdns_dart
  // ======================================================================

  Future<List<DtvPeer>> discoverPeers() async {
    if (discovering.value) return discoveredPeers.toList();

    discovering.value = true;
    discoveredPeers.clear();

    try {
      final results = await mdns.MDNSClient.discover(mdnsServiceType).timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          Log.d('mDNS discovery timeout');
          return <mdns.ServiceEntry>[];
        },
      );

      for (final service in results) {
        final host = service.primaryAddress?.address;
        if (host == null) continue;

        final svcPort = service.port;
        // infoFields is List<String> of "key=value" TXT records
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

  /// Parse TXT records (List<String> of "key=value") to find a specific key.
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
  // Client: import DTV payload into Simple Live
  // ======================================================================

  Future<DtvImportResult> importFromPayload(Map<String, dynamic> payload) async {
    final entries = payload['entries'] as Map<String, dynamic>?;
    if (entries == null) {
      return DtvImportResult(addedFollows: 0, addedTags: 0, error: 'No entries in payload');
    }

    var addedFollows = 0;
    var addedTags = 0;

    try {
      // 1. Import followed streamers
      final followedRaw = entries['followedStreamers'];
      if (followedRaw is String) {
        final List<dynamic> followedList = json.decode(followedRaw);

        for (final item in followedList) {
          if (item is! Map<String, dynamic>) continue;

          final platform = item['platform'] as String? ?? '';
          final siteId = platformToSiteId(platform);
          // DTV id is raw roomId, currentRoomId is also roomId
          final roomId = item['currentRoomId'] as String? ??
              item['id']?.toString() ?? '';
          final userName = item['nickname'] as String? ?? '';
          final face = item['avatarUrl'] as String? ?? '';

          if (roomId.isEmpty) continue;

          final followId = '${siteId}_$roomId';
          if (DBService.instance.followBox.containsKey(followId)) continue;

          final follow = FollowUser(
            id: followId,
            roomId: roomId,
            siteId: siteId,
            userName: userName.ifEmpty(roomId),
            face: face,
            addTime: DateTime.now(),
            tag: '全部',
          );

          await DBService.instance.followBox.put(follow.id, follow);
          addedFollows++;
        }
      }

      // 2. Import follow folders → tags
      final foldersRaw = entries['followFolders'];
      if (foldersRaw is String) {
        final List<dynamic> folders = json.decode(foldersRaw);
        for (final folder in folders) {
          if (folder is! Map<String, dynamic>) continue;

          final folderName = folder['name'] as String? ?? '';
          if (folderName.isEmpty) continue;

          final streamerIds = (folder['streamerIds'] as List<dynamic>?)
              ?.map((e) => e.toString())
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

          // Map DTV streamer IDs ("DOUYU:5551871") to Simple Live IDs ("douyu_5551871")
          for (final dtvId in streamerIds) {
            final parts = dtvId.split(':');
            if (parts.length < 2) continue;
            final platform = parts[0];
            final roomId = parts.sublist(1).join(':');
            final siteId = platformToSiteId(platform);
            final followId = '${siteId}_$roomId';

            if (!tag.userId.contains(followId)) {
              tag.userId.add(followId);
            }
          }

          await DBService.instance.tagBox.put(tag.id, tag);
        }
      }

      // Refresh UI
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
    } catch (e) {
      Log.logPrint('DTV import error: $e');
      return DtvImportResult(addedFollows: addedFollows, addedTags: addedTags, error: e.toString());
    }

    return DtvImportResult(addedFollows: addedFollows, addedTags: addedTags);
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

  @override
  String toString() => 'DtvPeer($name, $baseUrl)';
}

/// Result of a DTV data import.
class DtvImportResult {
  final int addedFollows;
  final int addedTags;
  final String? error;

  DtvImportResult({required this.addedFollows, required this.addedTags, this.error});

  bool get isSuccess => error == null;
  String get summary {
    if (error != null) return '导入失败: $error';
    return '导入成功: ${addedFollows}个关注, ${addedTags}个标签';
  }
}

extension _StringExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
