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
lib/                      Dart 侧：可测试的逻辑
  primitives.dart         跨端共享的硬约束值对象
  states.dart             三个显式建模的状态机（规格 §4）
  recording/
    work_mode.dart          三种工作模式（§3.3.1）
    recorder_config.dart    阈值与**硬兜底值**（I4）
    recorder_events.dart    喂给状态机的事件 / 它产出的动作
    stop_controller.dart    ★ 停录状态机（错码保护 · 静止封顶 · 时长兜底）
    recording_index.dart    录像索引（JSON Lines）
    recording_workspace.dart 会话落盘与孤儿发现
    session_finalizer.dart  ★ 收尾唯一入口（I9）+ 孤儿恢复
  scanning/
    viewfinder.dart         取景框判定（§3.2.2）
  main.dart               应用外壳
android/  ios/            原生相机模块（**未编写**，见 docs/实现决策.md §6）
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

**M0 骨架 + M1 契约 + M4 采集（Dart 侧逻辑）**

已落地：

- **M1**：`RelativePath` / `WaybillNumber` / `ContentHash` 三个硬约束值对象；
  三个状态机枚举（规格 §4）；单号归一化（§3.2.3）
- **M4 停录**：`StopController` —— 错码保护（§3.3.2）、画面静止含**封顶修正**
  （§3.3.3 / 不变量 I12）、时长兜底（§3.3.4）、三种工作模式（§3.3.1）
- **M4 取景框**：只有框内的面单被识别（§3.2.2）
- **M4 会话**：录制会话落盘、**收尾唯一入口**（I9）、孤儿分段恢复（§3.1.1）
- **M4 资源**：存储将满 / 低电量 / 过热 → 告警 + 主动收尾（§3.1.1），
  阈值带**硬兜底值**（I4）

### ⚠️ M4 未完成

**原生连续分段相机尚未编写。** 当前只有 Dart 侧的逻辑 —— 状态机、取景框判定、
会话收尾都完整且带测试，但**没有原生层就没有录像**。

其余未做：镜头缩放、语音播报（TTS）、目标跟踪、打点持久化、界面。
详见 [`docs/实现决策.md`](docs/实现决策.md) §6。

### ⚠️ 真机验收一条都没做

M4 的六条验收**全部需要真机**。按 `AGENTS.md` §9：
**编译全绿但真机行为错误的问题，只有真机能暴露。** M4 不能算完成。

其中五条（孤儿收尾、静止停录、封顶修正、错码保护、时长兜底）的**逻辑已经完整测过**，
差的只是原生层接线与真机回归；「连续录 30 分钟不断」则完全依赖尚未编写的原生相机。

CI 见 [`.github/workflows/`](.github/workflows/)。

---

## 许可

专有软件，保留所有权利。未经授权不得复制、分发或用于衍生作品。
