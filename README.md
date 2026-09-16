# VidLog · 手机端

电商打包取证系统的**手机端**：现场采集 —— 连续分段录像、扫码打点、提交归档。

Flutter + 原生相机模块（Kotlin / Swift）。

**闭源商业产品。** 本仓库为私有仓库。

---

## 需求在哪

需求规格书**只有一份**，在母仓 [VidLog0705/VidLog](https://github.com/VidLog0705/VidLog)，本仓不复制（避免多处副本漂移）：

| 文档 | 作用 |
|---|---|
| 母仓 `docs/01-行为规格书.md` | **唯一的需求来源** |
| 母仓 `docs/02-数据模型.md` | 数据概念模型（本仓实现它） |
| 母仓 `docs/03-端间契约.md` | 端间契约（本仓实现发送方侧） |
| 母仓 `IMPLEMENTATION.md` | 里程碑与开工顺序 |
| 本仓 [`AGENTS.md`](AGENTS.md) | 工程约束、12 条不变量、洁净室规则 |

**在写第一行代码之前，必须确认你理解了 `AGENTS.md` 第 0 节的洁净室规则** ——
那是这个项目唯一一件做错了没法回头的事。

> ⚠️ 这条路意味着**离线或没有母仓权限时无法开工**。这是拆仓换来的取舍，已知并接受。

---

## 仓库结构

```
lib/                      Dart 侧：可测试的逻辑与 UI
  primitives.dart         跨端共享的硬约束值对象
  states.dart             三个显式建模的状态机（规格 §4）
  main.dart               应用外壳
android/  ios/            原生相机模块（M4 起）
test/                     flutter test
scripts/precheck.ps1      推送前的本地预检
```

**为什么相机必须是原生的**：系统相机做不到「连续分段录制」
（长录不断、掉电不丢、进程重启自动收尾），这是核心功能。

---

## 开发环境

| 组件 | 最低要求 |
|---|---|
| Flutter | 3.47+ |
| JDK | 17（Android 构建） |
| Android SDK | platform 36 / build-tools 36 |

**iOS 无法在 Windows 上本地构建** —— 走 GitHub Actions 的 macOS runner，
产物为未签名 `.ipa`，用 Sideloadly 装真机。

---

## 本地开发流程

```powershell
# 快速预检：analyze + test
pwsh -NoProfile -File scripts/precheck.ps1

# 加 Android 真编译（慢，约 3~5 分钟）
pwsh -NoProfile -File scripts/precheck.ps1 -Full

# 全绿后再推送
git push
```

### ⚠️ CI 成本约束（不要改）

私有仓库 runner 计费倍率：**Linux 1× / Windows 2× / macOS 10×**。
免费额度 2000 分钟/月 = **约 200 macOS 分钟**。

- `ci.yml` —— Linux runner，analyze / test / Debug APK
- `ios-compile-check.yml` —— **只在 pull_request 与手动触发时跑**（不挂 push）
- `ios-package.yml` —— **手动触发**产 `.ipa`

---

## 当前进度

**M0 骨架 + M1 契约** —— 工程能编译、analyze 无 issue、测试能跑、模型与状态机已定。

已落地：

- Flutter 应用外壳（Android / iOS 两个 platform 目录已生成）
- `RelativePath` / `WaybillNumber` / `ContentHash` 三个硬约束值对象
- 三个状态机枚举（录制会话 / 上传任务 / 证据生命周期），规格 §4

未做（按里程碑推进）：原生连续分段相机、取景框识别、工作模式与停录机制、上传队列。

CI 见 [`.github/workflows/`](.github/workflows/)。

---

## 许可

专有软件，保留所有权利。未经授权不得复制、分发或用于衍生作品。
