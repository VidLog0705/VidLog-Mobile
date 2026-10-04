import 'package:flutter/material.dart';

import '../recording/business_type.dart';
import 'palette.dart';

/// 一条录像的详情（需求方 2026-09-27 照备份页草图定的）。
///
/// ## 为什么要有这一页
///
/// 备份页每一行右端原来挤着**三个**图标按钮（锁定 / 交付 / 删除，每个 20 来
/// 像素）。草图把那一行收干净了：右边只剩一个状态小标和一个 `›`，
/// 三个操作搬到这里。
///
/// 搬得有道理的地方不只是「行上放不下」—— 这三个里有两个是**不可逆**的
/// （删除）或**半不可逆**的（交付：存进相册就收不回来了，而且规格 §3.6.6
/// 明确不做打码，面单上的姓名电话会原样跟出去）。放在详情页意味着用户
/// **按之前先看清这一条的完整信息**，而且可点区域大了好几倍。
///
/// ## 它是**纯展示 + 回调**，一行业务判定都没有
///
/// 「能不能删」的判定在 `manual_delete.dart`、「锁没锁」在 `label_store.dart`
/// —— 这一页只负责画出来和转发点击。这样它可以被 widget 测试直接构造出来验，
/// 而 `recorder_page` 那一层做不到（`_sessions` 恒空）。
///
/// ⚠️ 时间 / 时长 / 大小三串**由调用方格式化好传进来**，这一页不自己算 ——
/// 两处各写一套格式的话，列表上写着 `9月16日` 而详情页写着 `09-16`，
/// 同一个东西两个样子（而搜索框是按屏幕上真有的字匹配的，见 `matchesQuery`）。
class RecordDetailPage extends StatelessWidget {
  const RecordDetailPage({
    super.key,
    required this.title,
    required this.businessType,
    required this.uploadText,
    required this.uploadColor,
    required this.uploadTint,
    required this.timeText,
    required this.durationText,
    required this.sizeText,
    required this.segmentText,
    required this.location,
    required this.locked,
    required this.preview,
    this.onPlay,
    required this.onToggleLock,
    required this.onShare,
    required this.onDelete,
  });

  /// 单号（没有单号时是会话 id，由调用方决定）。
  final String title;

  /// 发货 / 退货。**判不出来时是 null** —— 不猜（见 `_businessTypeOf`）。
  final BusinessType? businessType;

  /// 备份状态那两样。文案与颜色由调用方给，**与列表上那个小标同源**
  /// （`summarizeUploadState`）—— 两处各判一套的话，会出现
  /// 「列表说已备份、点进来说没备份」。
  ///
  /// ⚠️ `uploadTint` 是那个小标的**底**，也是调用方给的同一个 `_uploadLook`。
  /// 让这一页自己拿 `uploadColor` 兑 12% 透明度的话，两个屏上会是**两个深浅**
  /// （兑出来的 `#E0F5EE` vs 采样出来的 `#E7F8F3`）—— 而这条注释上面
  /// 那句话正是要防这个。
  final String uploadText;
  final Color uploadColor;
  final Color uploadTint;

  final String timeText;
  final String durationText;
  final String sizeText;

  /// 「3 段」。分段是防崩溃的实现细节（§3.1.1），但**这一页是详情页** ——
  /// 用户来这儿常常正是因为怀疑「怎么好几条一样的单号」，那件事的答案
  /// 就是分段。
  final String segmentText;

  /// 手机上这一段的相对路径。排查时有用，平时占一行小字。
  final String location;

  final bool locked;

  /// 缩略图那块。抽帧是异步的（`ThumbnailCache`），所以由调用方给成品 widget。
  final Widget preview;

  final VoidCallback? onPlay;
  final VoidCallback onToggleLock;
  final VoidCallback onShare;

  /// 删掉了吗。**true 才 pop** —— 删不成（回查没通过、审计写不进去）时
  /// 要留在原地，用户才看得到那句为什么。
  final Future<bool> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    // ⚠️ 抄到局部变量里再用：`businessType` 是这个类的**公开 final 字段**，
    // 而 Dart 的字段提升只对**私有** final 字段生效 —— 直接写
    // `if (businessType != null) businessType.displayName` 编译不过。
    final type = businessType;
    // 与列表上那支色**同源**。`businessTypeLook` 吃 `null`（给的是灰），
    // 所以这里不用先判空。
    final typeLook = businessTypeLook(type);

    return Scaffold(
      appBar: AppBar(title: const Text('录像详情')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _preview(context),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              // 名字走 `BusinessType.displayName` —— 与列表上那个小标同一个字符串。
              // 各写一遍的话，列表写着「发货视频」而这里写着「发货」，
              // 用户会以为它们说的是两回事。
              //
              // ⚠️ 颜色也必须走同一个函数（`businessTypeLook`）。这里原先自己写了
              // 一遍 `returning ? Colors.deepOrange : Colors.blue` —— 与列表上
              // 用的那两支**不是同一个色**，于是列表上是一个橙、点进去是另一个橙，
              // 而用户会以为换了类别。
              if (type != null)
                _pill(type.displayName, typeLook.color, typeLook.tint),
              _pill(uploadText, uploadColor, uploadTint),
              if (locked) _pill('已锁定', Palette.primary, Palette.blueTint),
            ],
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  _row('录制时间', timeText),
                  _row('时长', durationText),
                  _row('大小', sizeText),
                  _row('分段', segmentText),
                  _row('手机上', location),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.tonalIcon(
            key: const Key('detail-lock'),
            onPressed: onToggleLock,
            icon: Icon(locked ? Icons.lock_open : Icons.lock_outline),
            label: Text(locked ? '解锁这一条' : '锁定这一条（不会被自动清理）'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('detail-share'),
            onPressed: onShare,
            icon: const Icon(Icons.ios_share),
            label: const Text('存相册并分享'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('detail-delete'),
            onPressed: () => _delete(context),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除这一条'),
            style: OutlinedButton.styleFrom(foregroundColor: Palette.danger),
          ),
          const SizedBox(height: 8),
          const Text(
            // ⚠️ 规格 §3.6.6：**打码整条不做**。交出去的就是原视频，
            // 面单上的姓名电话地址会原样跟着出去。这句话不说清楚，
            // 用户会以为系统替他处理过。
            '分享出去的是原视频，没有转码、没有打码 —— 面单上的姓名、电话、地址会原样跟着出去。',
            style: TextStyle(fontSize: 11, color: Palette.muted),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context) async {
    final deleted = await onDelete();
    if (!deleted) return;
    if (context.mounted) Navigator.of(context).pop();
  }

  Widget _preview(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: Palette.hairline, child: preview),
            if (onPlay != null)
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPlay,
                  child: const Center(
                    child: Icon(Icons.play_circle_fill, size: 56, color: Colors.white70),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 底与字**成对给**：浅浅的那个底是采样出来的一个值，不是「同一个色兑 12%
  /// 透明」兑出来的 —— 列表上那个小标用的是同一对，两处才会是同一个色。
  Widget _pill(String text, Color color, Color tint) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: tint,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 64,
              child: Text(
                label,
                style: const TextStyle(fontSize: 13, color: Palette.muted),
              ),
            ),
            Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
}
