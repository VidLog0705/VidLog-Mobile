/// 工作模式。规格 §3.3.1。
enum WorkMode {
  /// 连续扫：首次识别到单号开录；**用户手动 / 兜底机制**停止。
  continuousScan,

  /// 同码停：首次识别到单号开录；**复扫到同一单号**停止。
  sameWaybillStop,

  /// 扫码静止停录：首次识别到单号开录；
  /// **同码包裹离场后再入场，并静止达设定时长**停止。
  scanThenStaticStop;

  /// 复扫到同一单号时，本模式是否会停止录制。
  ///
  /// ⚠️ **规格里两处不一致，2026-09-21 需求方裁定了取哪个读法。**
  ///
  /// - §3.3.1 的「停止录制」列：扫码静止停录写的是「同码离场后再入场并静止达设定时长」，
  ///   **没提复扫**。
  /// - §3.3.2 的错码保护标题写的是「**同码停 / 扫码静止停录 两个模式都启用**」，
  ///   规则是「二次扫描**只有单号相同才停止**」—— 按字面，两个模式的复扫都会停止。
  ///
  /// **裁定：取 §3.3.1**（复扫不停）。理由是 §3.3.2 的标题讲的是「错码保护」，
  /// 它要说的是「在启用错码保护的这两个模式里，同码才停」，
  /// 而不是「这两个模式的停止条件相同」—— 若相同，这个模式就没有存在理由了。
  ///
  /// 改回另一个读法只是把 `scanThenStaticStop` 那行改成 `true`，收尾逻辑不用动。
  bool get stopsOnSameWaybillRescan => switch (this) {
    WorkMode.continuousScan => false,
    WorkMode.sameWaybillStop => true,
    WorkMode.scanThenStaticStop => false,
  };

  /// 静止判定是否需要「同码包裹先离场、再入场」这个前置门槛。
  ///
  /// 规格 §3.3.1：只有扫码静止停录要求这个顺序。
  /// 其余模式的静止判定（§3.3.3）直接按画面是否静止算。
  bool get staticStopRequiresPackageReturn => this == WorkMode.scanThenStaticStop;
}
