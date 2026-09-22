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

  /// 扫到一个**不同**的单号时，是否收掉当前这一段、为新单号另起一段。
  ///
  /// 只有连续扫是**换段式**（规格 §3.3.1 的 2026-09-22 需求变更）。
  /// 另外两个模式的错码保护**一个字都没变**：扫到别的单号只提示、不停录。
  bool get rotatesOnNewWaybill => this == WorkMode.continuousScan;

  /// 静止判定是否需要「同码包裹先离场、再入场」这个前置门槛。
  ///
  /// 规格 §3.3.1：只有扫码静止停录要求这个顺序。
  /// 其余模式的静止判定（§3.3.3）直接按画面是否静止算。
  bool get staticStopRequiresPackageReturn => this == WorkMode.scanThenStaticStop;

  /// 读不出 / 认不出时用哪个。**改这里等于改所有新装的默认模式。**
  ///
  /// 选同码停：它是三个模式里唯一「不需要用户额外操作就能自己停」的
  /// （连续扫要人记得手动停，扫码静止停录要等静止）。漏停的代价是
  /// **录像一直录到卡满**，比多停一次严重得多。
  static const fallback = WorkMode.sameWaybillStop;

  /// 按名字解析，认不出就回 [fallback]。**绝不抛。**
  ///
  /// 存的是名字不是序号 —— 序号一旦枚举重排，老配置会被**静默**解析成
  /// 另一个模式，录制行为当场变了而没人知道。
  static WorkMode fromConfig(Object? raw) {
    if (raw is WorkMode) return raw;
    if (raw is String) {
      final name = raw.trim();
      for (final mode in WorkMode.values) {
        if (mode.name == name) return mode;
      }
    }
    return fallback;
  }
}
