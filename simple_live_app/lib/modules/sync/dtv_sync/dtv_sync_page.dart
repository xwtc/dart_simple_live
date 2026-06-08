import 'package:flutter/material.dart';
import 'package:get/get.dart';
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

          // ---- Client: manual input section ----
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text('从 DTV 导入', style: Get.textTheme.titleSmall),
          ),
          SettingsCard(
            child: Padding(
              padding: AppStyle.edgeInsetsA12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: controller.addressController,
                    onSubmitted: (value) => controller.connectManual(value),
                    decoration: InputDecoration(
                      labelText: '共享端地址',
                      hintText: '输入 DTV 设备的 IP 地址，如 192.168.1.100',
                      contentPadding: AppStyle.edgeInsetsH12,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  AppStyle.vGap12,
                  ElevatedButton(
                    onPressed: () => controller.connectManual(controller.addressController.text),
                    child: const Text('连接并导入'),
                  ),
                ],
              ),
            ),
          ),

          AppStyle.vGap12,

          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: const Text(
              '说明：启动共享服务后，在 DTV 桌面版手动输入本机 IP 即可导入关注列表和标签。'
              '手动输入 DTV 设备的 IP 地址可直接连接导入。',
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
