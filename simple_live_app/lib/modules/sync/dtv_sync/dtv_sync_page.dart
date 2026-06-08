import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/sync/dtv_sync/dtv_sync_controller.dart';
import 'package:simple_live_app/services/dtv_sync_service.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class DtvSyncPage extends GetView<DtvSyncController> {
  const DtvSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('DTV 数据互通'),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          // ---- Server section ----
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text('共享给 DTV', style: Get.textTheme.titleSmall),
          ),
          SettingsCard(
            child: Column(
              children: [
                Obx(() => SwitchListTile(
                      title: const Text('启动 DTV 同步服务'),
                      subtitle: Text(
                        controller.service.running.value
                            ? '运行中 — http://${controller.service.ipAddress.value}:${controller.service.port.value}'
                            : '启动后 DTV 桌面版可通过局域网发现并导入数据',
                      ),
                      value: controller.service.running.value,
                      onChanged: (_) => controller.toggleServer(),
                    )),
                Obx(() {
                  if (!controller.service.running.value) return const SizedBox.shrink();
                  return Padding(
                    padding: AppStyle.edgeInsetsH16.copyWith(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _InfoRow(label: '地址', value: 'http://${controller.service.ipAddress.value}:${controller.service.port.value}'),
                        _InfoRow(label: 'Token', value: controller.service.token.value),
                      ],
                    ),
                  );
                }),
                Obx(() {
                  if (controller.service.errorMsg.value.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: AppStyle.edgeInsetsH16.copyWith(bottom: 12),
                    child: Text(
                      '错误: ${controller.service.errorMsg.value}',
                      style: const TextStyle(color: Colors.red),
                    ),
                  );
                }),
              ],
            ),
          ),

          // ---- Client section ----
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text('从 DTV 导入', style: Get.textTheme.titleSmall),
          ),
          SettingsCard(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Remix.search_eye_line),
                  title: const Text('搜索局域网 DTV 设备'),
                  subtitle: Obx(() => Text(
                        '发现 ${controller.service.discoveredPeers.length} 个设备',
                      )),
                  trailing: Obx(() => controller.service.discovering.value
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right)),
                  onTap: controller.refreshPeers,
                ),
                AppStyle.divider,
                Obx(() {
                  final peers = controller.service.discoveredPeers;
                  if (peers.isEmpty) {
                    return ListTile(
                      title: Text(
                        controller.service.discovering.value
                            ? '正在搜索...'
                            : '点击上方搜索设备',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    );
                  }
                  return Column(
                    children: peers.map((peer) => Column(
                      children: [
                        ListTile(
                          title: Text(peer.name),
                          subtitle: Text('${peer.host}:${peer.port}'),
                          trailing: TextButton(
                            onPressed: () => controller.importFromPeer(peer),
                            child: const Text('导入'),
                          ),
                        ),
                        if (peer != peers.last) AppStyle.divider,
                      ],
                    )).toList(),
                  );
                }),
              ],
            ),
          ),

          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: const Text(
              '说明：启动共享服务后，DTV 桌面版可自动通过 mDNS 发现此设备并导入关注列表和标签。'
              '点击搜索可发现局域网内的 DTV 设备，导入其数据。',
              style: TextStyle(color: Colors.grey, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(width: 50, child: Text(label, style: const TextStyle(color: Colors.grey, fontSize: 13))),
          const SizedBox(width: 8),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontFamily: 'monospace'))),
        ],
      ),
    );
  }
}
