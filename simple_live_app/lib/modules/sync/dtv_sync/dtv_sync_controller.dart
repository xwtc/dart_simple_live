import 'package:get/get.dart';
import 'package:simple_live_app/services/dtv_sync_service.dart';

class DtvSyncController extends GetxController {
  final DtvSyncService service = DtvSyncService.instance;

  final addressController = TextEditingController();

  @override
  void onInit() {
    super.onInit();
  }

  @override
  void onClose() {
    addressController.dispose();
    super.onClose();
  }

  Future<void> toggleServer() async {
    await service.toggle();
  }

  Future<void> refreshPeers() async {
    await service.discoverPeers();
  }

  Future<void> connectManual(String address) async {
    final trimmed = address.trim();
    if (trimmed.isEmpty) {
      Get.snackbar('错误', '请输入共享端 IP 或 URL');
      return;
    }

    // Parse input: supports "192.168.1.x", "192.168.1.x:38999", "http://192.168.1.x:38999"
    String host;
    int port = DtvSyncService.dtvSyncPort;
    String token = DtvSyncService.defaultToken;

    var input = trimmed;
    // Strip http:// prefix
    if (input.startsWith('http://')) input = input.substring(7);
    if (input.startsWith('https://')) input = input.substring(8);

    // Strip trailing path
    final slashIdx = input.indexOf('/');
    if (slashIdx > 0) {
      final query = input.substring(slashIdx + 1);
      input = input.substring(0, slashIdx);
      // Extract token from query if present
      final tokenMatch = RegExp(r'token=([^&]+)').firstMatch(query);
      if (tokenMatch != null) {
        token = Uri.decodeComponent(tokenMatch.group(1)!);
      }
    }

    // Split host:port
    final colonIdx = input.lastIndexOf(':');
    if (colonIdx > 0) {
      host = input.substring(0, colonIdx);
      port = int.tryParse(input.substring(colonIdx + 1)) ?? DtvSyncService.dtvSyncPort;
    } else {
      host = input;
    }

    if (host.isEmpty) {
      Get.snackbar('错误', '请输入有效的 IP 地址');
      return;
    }

    final peer = DtvPeer(
      name: host,
      host: host,
      port: port,
      token: token,
      baseUrl: 'http://$host:$port',
    );

    await importFromPeer(peer);
  }

  Future<void> importFromPeer(DtvPeer peer) async {
    Get.snackbar('提示', '正在从 ${peer.name} 获取数据...');
    final payload = await service.fetchPayload(peer);
    if (payload == null) {
      Get.snackbar('错误', '无法从 ${peer.name} 获取数据，请检查地址和端口是否正确');
      return;
    }

    final result = await service.importFromPayload(payload);
    Get.snackbar(
      result.isSuccess ? '导入成功' : '导入失败',
      result.summary,
    );
  }
}
