<#
.SYNOPSIS
    推送前的本地预检。把 CI 失败挡在推送之前。

.DESCRIPTION
    本仓是手机端（Flutter），预检覆盖：密钥泄露、大文件、pub get、analyze、test，
    以及可选的 Android 真编译。

    目的有两个：
      1. 快速反馈 —— 不用等 CI 排队
      2. 省额度 —— 私有仓库的 macOS runner 是 10× 计费（约 200 分钟/月）

    必须先跑通这个再 push。

.PARAMETER Full
    额外跑 Android APK 真编译（约 3~5 分钟）。默认跳过以保持快速。

.PARAMETER SkipTests
    只做静态检查，不跑测试。

.EXAMPLE
    pwsh -NoProfile -File scripts/precheck.ps1
    pwsh -NoProfile -File scripts/precheck.ps1 -Full
#>
[CmdletBinding()]
param(
    [switch]$Full,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$script:Failures = @()
$script:Warnings = @()

function Section($name) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Write-Host "  $name" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor DarkGray
}

function Fail($msg) { $script:Failures += $msg; Write-Host "  [FAIL] $msg" -ForegroundColor Red }
function Warn($msg) { $script:Warnings += $msg; Write-Host "  [WARN] $msg" -ForegroundColor Yellow }
function Pass($msg) { Write-Host "  [ OK ] $msg" -ForegroundColor Green }
function Info($msg) { Write-Host "  $msg" -ForegroundColor Gray }

# ─────────────────────────────────────────────────────────────
Section '0. 环境'

foreach ($c in 'flutter', 'dart') {
    $p = (Get-Command $c -ErrorAction SilentlyContinue).Source
    if ($p) { Info "$c -> $p" } else { Warn "$c 不在 PATH" }
}

# ─────────────────────────────────────────────────────────────
Section '1. 密钥泄露检查'

# 扫「有真实值的密钥」，不是扫「提到了密钥这个词」。
# 关键词匹配会误伤文档（规范里当然会写 secret 这个词）。
$valuePatterns = @(
    'gh[pousr]_[A-Za-z0-9]{20,}',                                  # GitHub token
    'github_pat_[A-Za-z0-9_]{20,}',                                # GitHub fine-grained PAT
    'sk-[A-Za-z0-9]{20,}',                                         # OpenAI 风格
    'AKIA[0-9A-Z]{16}',                                            # AWS access key
    'xox[baprs]-[A-Za-z0-9-]{10,}',                                # Slack
    '-----BEGIN [A-Z ]*PRIVATE KEY-----',                          # 私钥
    '(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})',  # JWT
    '(?i)(secret|password|passwd|pwd|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key)\s*[:=]\s*["''][^"''\s]{12,}["'']'
)

# 文档与配置元文件本来就该「提到」密钥，不参与扫描
$skipFile = '\.(md|txt|rst)$|(^|/)\.gitignore$|(^|/)\.gitattributes$|scripts/precheck\.ps1$'
$skipExt  = '\.(png|jpg|jpeg|gif|ico|pdf|zip|7z|exe|dll|so|dylib|a|aar|jar|mp4|mp3|woff2?)$'

$staged = @(& git diff --cached --name-only --diff-filter=ACM 2>$null)
if ($staged.Count -eq 0) { $staged = @(& git diff --name-only --diff-filter=ACM HEAD 2>$null) }

if ($staged.Count -gt 0) {
    $hits = @()
    foreach ($f in $staged) {
        if (-not $f) { continue }
        if (-not (Test-Path $f)) { continue }
        if ($f -match $skipExt) { continue }
        if ($f -match $skipFile) { continue }
        foreach ($pat in $valuePatterns) {
            $m = Select-String -Path $f -Pattern $pat -AllMatches -ErrorAction SilentlyContinue
            if ($m) { $hits += $m }
        }
    }
    if ($hits.Count -gt 0) {
        Fail "疑似真实密钥出现在待提交内容里（$($hits.Count) 处）"
        $hits | Select-Object -First 10 | ForEach-Object {
            $t = $_.Line.Trim()
            Info ("    {0}:{1}  {2}" -f $_.Path, $_.LineNumber, $t.Substring(0, [Math]::Min(90, $t.Length)))
        }
        Info '    确认误报就忽略；是真密钥，改用环境变量或 GitHub Secrets，并立刻轮换。'
    } else { Pass '未发现明文密钥' }
} else {
    Pass '没有待提交的改动'
}

# ─────────────────────────────────────────────────────────────
Section '2. 大文件检查'

$maxMB = 20

# ⚠️ **不要用 `Test-Path` 去量文件名。**
#
# PS 5.1 按**控制台代码页**解码 git 的 stdout，中文文件名会变成一串带非法字符的
# 乱码；`Test-Path` 对这种路径**直接抛异常**，而异常被当成「文件不存在」——
# 于是 `docs/实现决策.md` 这类文件**从来没被量过**，这一步却照样打 `[ OK ]`。
# 一个对中文文件名永远绿的大文件守卫，等于没有守卫。
#
# 改成问 git 要 **blob 大小**（`git cat-file --batch-check` 的输出全是 ASCII），
# 彻底不碰路径 —— 「有没有超过 20MB 的已跟踪文件」本来就是 blob 的属性，
# 不是路径的属性。顺带也不用管符号链接与子模块（它们的类型不是 blob，被过滤掉）。
$maxBytes = $maxMB * 1MB
$big = & git ls-files -s 2>$null |
    Where-Object { $_ } |
    ForEach-Object { ($_ -split '\s+')[1] } |
    Select-Object -Unique |
    & git cat-file --batch-check 2>$null |
    Where-Object { $_ -match '^\S+\s+blob\s+(\d+)$' -and [int64]$Matches[1] -gt $maxBytes } |
    ForEach-Object {
        $f = $_ -split '\s+'
        [pscustomobject]@{ Sha = $f[0]; MB = [Math]::Round([int64]$f[2] / 1MB, 1) }
    }
if ($big) {
    Fail "有超过 ${maxMB}MB 的已跟踪文件"
    $big | ForEach-Object { Info ("    {0}  {1} MB" -f $_.Sha, $_.MB) }
    Info '    用 `git ls-files -s | Select-String <上面那个 sha>` 找路径。大文件不该进仓库。'
} else { Pass "无超过 ${maxMB}MB 的已跟踪文件" }

# ─────────────────────────────────────────────────────────────
Section '3. Flutter'

if (-not (Test-Path (Join-Path $root 'pubspec.yaml'))) {
    Fail 'pubspec.yaml 不存在 —— 这个目录不是 Flutter 工程'
} else {
    Info 'pub get...'
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail 'flutter pub get 失败' }

    Info 'analyze...'
    & flutter analyze --no-fatal-infos
    if ($LASTEXITCODE -ne 0) { Fail 'flutter analyze 有 error' } else { Pass 'flutter analyze 通过' }

    if (-not $SkipTests) {
        Info 'test...'
        & flutter test
        if ($LASTEXITCODE -ne 0) { Fail 'flutter test 失败' } else { Pass 'flutter test 通过' }
    }

    if ($Full) {
        Info 'build apk --debug（这一步慢，约 3~5 分钟）...'
        & flutter build apk --debug
        if ($LASTEXITCODE -ne 0) { Fail 'flutter build apk 失败' } else { Pass 'Android 真编译通过' }
    } else {
        Info '已跳过 Android APK 真编译（加 -Full 可开启）'
    }
}

# ─────────────────────────────────────────────────────────────
Section '4. 不变量自查（母仓 docs/01-行为规格书.md 第 7 节）'

Info '不变量主要靠单元测试保证，此处仅作提醒：'
Info '  I1  归档回执前不清理本地      I10 无网可用（除归档与交付）'
Info '  I2  任何时刻至少一份副本       I11 改系统时间不得伪造时间'
Info '  I3  上传失败必须可见           I12 静止判定按已录时长封顶'
Info '  I4  坏配置不得影响录制'
Info '  I5  单号是唯一事实标识'
Info '  I7  分享链接不指向本地'

# ─────────────────────────────────────────────────────────────
Section '结果'

if ($script:Warnings.Count -gt 0) {
    Write-Host ("  警告 {0} 项" -f $script:Warnings.Count) -ForegroundColor Yellow
}
if ($script:Failures.Count -gt 0) {
    Write-Host ''
    Write-Host ("  预检未通过 —— {0} 项失败：" -f $script:Failures.Count) -ForegroundColor Red
    $script:Failures | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '  修完再推送。CI 排队比这里慢得多，而且 macOS 额度很贵。' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host '  预检全部通过，可以推送。' -ForegroundColor Green
Write-Host '  （iOS 编译由 GitHub CI 负责，本地跑不了）' -ForegroundColor DarkGray
exit 0
