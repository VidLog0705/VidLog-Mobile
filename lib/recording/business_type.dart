/// 业务类型：发货还是退货。
///
/// **两端同名同值** —— 电脑端 `Labels/LabelStore.cs` 的 `BusinessType`
/// 与 `BusinessTypes.ToValue()` 就是这三个词。磁盘上写的是
/// `outbound` / `return`（**全小写**），不是枚举名、不是序号。
///
/// 它**不是**「这一段录像是怎么录的」（那是 [WorkMode]，停在设置里），
/// 而是「操作员当时在做哪件事」。两栏的采集流程一模一样，差别只在这个标签。
enum BusinessType {
  outbound('outbound'),
  returning('return');

  const BusinessType(this.wire);

  /// 落盘的取值。与电脑端逐字一致。
  final String wire;

  /// 标签表里这个标签的键名。
  ///
  /// 与电脑端 `LabelKeys.BusinessType` 逐字一致。**键名写错的代价是静默的**：
  /// 电脑端按 `business-type` 去查，查不到就当「没打过这个标签」，
  /// 不报错、不崩，检索结果里那一列显示 `unknown`。
  static const String labelKey = 'business-type';

  /// 认不出来返回 `null` —— **标签宁可不写，也不写错的**。
  ///
  /// 电脑端那边的兜底是「认不出当发货」（`BusinessTypes.TryParse`），
  /// 这里刻意不照抄：写一个猜出来的标签，事后没人分得清它是真的还是猜的。
  /// 不写，检索时显示 `unknown`，至少是句实话。
  static BusinessType? tryParse(Object? raw) {
    if (raw is BusinessType) return raw;
    if (raw is String) {
      for (final type in BusinessType.values) {
        // 逐字比较，**不 trim、不忽略大小写** —— 两端对「什么算合法取值」
        // 必须是同一套，否则手机端认了、电脑端不认，那条标签就是个死值。
        if (type.wire == raw) return type;
      }
    }
    return null;
  }
}
