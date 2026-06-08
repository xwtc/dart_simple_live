import 'package:get/get.dart';
import 'package:simple_live_app/services/dtv_sync_service.dart';

class DtvSyncController extends GetxController {
  final DtvSyncService service = DtvSyncService.instance;

  @override
  void onInit() {
    super.onInit();
  }

  Future<void> toggleServer() async {
    await service.toggle();
  }

  Future<void> refreshPeers() async {
    await service.discoverPeers();
  }

  Future<void> importFromPeer(DtvPeer peer) async {
    final payload = await service.fetchPayload(peer);
    if (payload == null) {
      Get.snackbar('错误', '无法从 ${peer.name} 获取数据');
      return;
    }

    final result = await service.importFromPayload(payload);
    Get.snackbar(
      result.isSuccess ? '导入成功' : '导入失败',
      result.summary,
    );
  }
}
