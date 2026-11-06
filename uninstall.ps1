<#
.SYNOPSIS
    卸载 Blockly 可视化编程工作台（以及/或者回收 pkg 里解压出来的空间）。

.DESCRIPTION
    这个脚本干两件事，可以只干第一件：

      1) 删掉装在工作台里的那一套（app / tools / arduino15 / arduino-user / 快捷方式 …）
      2) 回收 pkg 里解压出来的 8.5 GB —— 只留 volumes\*.rar，下次装会重新解压

    为什么删之前要先认一遍：删 8.5 GB 是不可逆的。脚本会先把「要删什么、
    多大、在哪」列出来，要你亲手敲 YES 才动手。认错目录的代价太大，所以还有
    三道硬护栏：
      · 目标目录里必须有 app\main.js 或 Start-Workbench.cmd（确认是工作台，不是随便一个文件夹）
      · 拒绝盘符根（D:\）、Windows、Program Files 本身、用户目录本身
      · pkg 就在目标目录里时不删 pkg（那是安装包本体，删了得重新要一份）
        真要连它一起删，加 -IncludePkg

.PARAMETER Target
    工作台装在哪。不填就自己找：先读 <目标>\.blockly-install.json，
    再看 pkg 的父目录，最后扫各盘的 Program Files\Blockly 和 \Blockly。

.PARAMETER CleanPkgOnly
    只回收 pkg 里解压出来的目录（arduino15 / runtime / npm / payload / libraries / ide），
    不动工作台。改完代码想省空间时用这个。

.PARAMETER IncludePkg
    连 pkg 目录本身一起删（包括 volumes 里的分卷）。**删了就再也装不了了**，
    除非手上还有另一份 pkg。

.PARAMETER KeepPkgFiles
    只删工作台，不动 pkg 里解压出来的目录。

.PARAMETER DryRun
    只列出会删什么，一个字节都不动。先跑这个看看再决定。

.PARAMETER Force
    跳过 YES 确认（给脚本调用用；人手操作别加）。

.EXAMPLE
    powershell -File uninstall.ps1 -DryRun
    看看会删什么。

.EXAMPLE
    powershell -File uninstall.ps1
    删工作台，pkg 保留（交互确认）。

.EXAMPLE
    powershell -File uninstall.ps1 -CleanPkgOnly
    只回收 pkg 里那 8.5 GB。
#>
[CmdletBinding()]
param(
    [string]$Target = '',
    [switch]$CleanPkgOnly,
    [switch]$IncludePkg,
    [switch]$KeepPkgFiles,
    [switch]$DryRun,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$PkgRoot = $PSScriptRoot
if (-not (Test-Path (Join-Path $PkgRoot 'install.ps1'))) {
    $PkgRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'pkg'
}
if (-not (Test-Path (Join-Path $PkgRoot 'install.ps1'))) {
    Write-Host '  [x] 这个脚本要放在 pkg 目录里（和 install.ps1 同级）' -ForegroundColor Red
    exit 1
}
$PkgRoot = [IO.Path]::GetFullPath($PkgRoot).TrimEnd('\')

function Line   { param([string]$m = '') Write-Host $m }
function Step   { param([string]$m) Write-Host (("`n" + '[*] ' + $m)) -ForegroundColor Cyan }
function Ok     { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Warn   { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Bad    { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
function Detail { param([string]$m) Write-Host ('        ' + $m) -ForegroundColor DarkGray }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Get-TreeStat {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Files = 0; Bytes = 0 } }
    $m = Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum
    return [pscustomobject]@{ Files = [int]$m.Count; Bytes = [double]$m.Sum }
}

# ---------------------------------------------------------------------------
# 护栏 1：这个目录到底是不是工作台
# ---------------------------------------------------------------------------
function Test-IsWorkbench {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    foreach ($marker in 'app\main.js', 'Start-Workbench.cmd', '.blockly-install.json') {
        if (Test-Path (Join-Path $Path $marker)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# 护栏 2：危险路径一律拒绝
# ---------------------------------------------------------------------------
function Assert-SafeTarget {
    param([string]$Path)
    $p = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($p.Length -lt 10) { Bad ('路径太短，疑似盘符根：' + $p); return $false }
    if ($p -match '^[A-Za-z]:$') { Bad ('拒绝删除盘符根：' + $p); return $false }

    $forbidden = @(
        $env:SystemRoot,
        (Join-Path $env:SystemRoot 'System32'),
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        $env:USERPROFILE,
        (Join-Path $env:USERPROFILE 'Desktop'),
        (Join-Path $env:USERPROFILE 'Documents'),
        (Join-Path $env:USERPROFILE 'Downloads')
    )
    foreach ($f in $forbidden) {
        if (-not $f) { continue }
        if ($p -eq ([IO.Path]::GetFullPath($f).TrimEnd('\'))) {
            Bad ('拒绝删除系统/个人目录：' + $p)
            return $false
        }
    }
    return $true
}

# ---------------------------------------------------------------------------
# 找安装位置
# ---------------------------------------------------------------------------
function Find-InstalledTargets {
    $found = @()

    # 1) 安装记录（最可靠）
    foreach ($cand in @((Split-Path $PkgRoot -Parent))) {
        $rec = Join-Path $cand '.blockly-install.json'
        if (Test-Path $rec) {
            try {
                $j = Get-Content -Raw $rec | ConvertFrom-Json
                if ($j.target -and (Test-Path $j.target)) {
                    $found += [pscustomobject]@{ Path = $j.target; Why = '安装记录'; When = $j.installedAt }
                }
            } catch { }
        }
    }

    # 2) pkg 的父目录（就地安装）
    $parent = Split-Path $PkgRoot -Parent
    if ((Test-IsWorkbench $parent) -and -not ($found | Where-Object { $_.Path -eq $parent })) {
        $found += [pscustomobject]@{ Path = $parent; Why = 'pkg 所在目录（就地安装）'; When = '' }
    }

    # 3) 各盘默认位置
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null })) {
        foreach ($rel in 'Program Files\Blockly', 'Blockly') {
            $p = Join-Path ($drv.Name + ':\') $rel
            if ((Test-IsWorkbench $p) -and -not ($found | Where-Object { $_.Path -eq $p })) {
                $found += [pscustomobject]@{ Path = $p; Why = '默认安装位置'; When = '' }
            }
        }
    }
    return $found
}

# ---------------------------------------------------------------------------
# pkg 里解压出来的目录（压成 volumes 之后这些本来不该存在）
# ---------------------------------------------------------------------------
$EXTRACTABLE = @('arduino15', 'ide', 'runtime', 'npm', 'payload', 'libraries', 'library-zips')

# ---------------------------------------------------------------------------
# 卸载时**保留**的东西：这些删了没法用安装包重装回来
#   designs\     你存的积木设计（.blockly.json）
#   exports\     你导出的 .ino 工程
#   samples\     你自己加的示例（包里自带的那些删了也没事，但分不清就不删）
#   .workbuddy\  开发过程记录（AI 的记忆/日志）
# pkg 本身在上面单独判断（按绝对路径）
# ---------------------------------------------------------------------------
$PROTECTED_NAMES = @('designs', 'exports', 'samples', '.workbuddy')

function Test-Protected {
    param([string]$FullName, [string]$Name)
    if ($FullName -eq $PkgRoot) {
        if ($IncludePkg) { return '' }   # 显式要求连安装包一起删
        return 'pkg（安装包本体）'
    }
    if ($PROTECTED_NAMES -contains $Name) { return '用户数据' }
    return ''
}

function Get-ExtractedDirs {
    $out = @()
    foreach ($d in $EXTRACTABLE) {
        $p = Join-Path $PkgRoot $d
        if (Test-Path $p) {
            $st = Get-TreeStat $p
            $hasVol = @(Get-ChildItem (Join-Path $PkgRoot 'volumes') -Filter ($d + '*.rar') -File -ErrorAction SilentlyContinue).Count -gt 0
            $out += [pscustomobject]@{ Name = $d; Path = $p; Files = $st.Files; Bytes = $st.Bytes; HasVolume = $hasVol }
        }
    }
    return $out
}

# ===========================================================================
# 抬头
# ===========================================================================
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host '  Blockly 可视化编程工作台 · 卸载 / 清理' -ForegroundColor White
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Line ('  安装包位置 : ' + $PkgRoot)
if ($DryRun) { Line '  模式       : 预演（-DryRun，不会删任何东西）' -ForegroundColor Yellow }

# ===========================================================================
# A) 只回收 pkg 空间
# ===========================================================================
if ($CleanPkgOnly) {
    Step '回收 pkg 里解压出来的目录'
    $ext = Get-ExtractedDirs
    if ($ext.Count -eq 0) {
        Ok 'pkg 里没有解压出来的目录，已经是压缩态了'
        exit 0
    }
    $total = ($ext | Measure-Object -Property Bytes -Sum).Sum
    foreach ($e in $ext) {
        $flag = if ($e.HasVolume) { '' } else { '  ← 没有对应分卷，删了就没法恢复！' }
        Detail ('{0,-14} {1,7} 个文件  {2,9}{3}' -f $e.Name, $e.Files, (Format-Size $e.Bytes), $flag)
    }
    Line ''
    Warn ('将删除 ' + $ext.Count + ' 个目录，共 ' + (Format-Size $total))

    $noVol = @($ext | Where-Object { -not $_.HasVolume })
    if ($noVol.Count -gt 0) {
        Line ''
        Bad ('这些目录没有对应的 rar 分卷，删了就装不回来了：' + ($noVol.Name -join '、'))
        Line '    建议先跑 pkg\工具\pack-volumes.ps1 -Only ' + ($noVol.Name -join ',') + ' -Verify 打包再删。'
        if (-not $Force) { Line '    已中止。'; exit 1 }
    }

    if ($DryRun) { Line ''; Ok '预演结束，什么都没删'; exit 0 }

    if (-not $Force) {
        Line ''
        $ans = Read-Host '    确认删除？输入 YES 继续（其它任何输入都取消）'
        if ($ans -ne 'YES') { Line '    已取消。'; exit 0 }
    }

    foreach ($e in $ext) {
        try {
            Remove-Item $e.Path -Recurse -Force -ErrorAction Stop
            Ok ('已删除 ' + $e.Name + '\')
        } catch {
            Bad ('删不掉 ' + $e.Name + '\：' + $_.Exception.Message + '（可能被占用，关掉工作台/IDE 再试）')
        }
    }
    Line ''
    Ok ('已回收 ' + (Format-Size $total) + '。下次安装会从 volumes\ 重新解压。')
    exit 0
}

# ===========================================================================
# B) 卸载工作台
# ===========================================================================
Step '找工作台装在哪'
$targets = @()
if ($Target) {
    if (-not (Test-Path $Target)) { Bad ('指定的目录不存在：' + $Target); exit 1 }
    $targets = @([pscustomobject]@{ Path = $Target; Why = '命令行指定'; When = '' })
} else {
    $targets = @(Find-InstalledTargets)
}

if ($targets.Count -eq 0) {
    Warn '没找到已安装的工作台。'
    Detail '可以手动指定：uninstall.ps1 -Target "D:\Program Files\Blockly"'
    Detail '只想回收 pkg 空间：uninstall.ps1 -CleanPkgOnly'
    exit 1
}

foreach ($t in $targets) {
    Ok ($t.Path + '    [' + $t.Why + ']' + $(if ($t.When) { '  装于 ' + $t.When } else { '' }))
}
$work = $targets[0]
if ($targets.Count -gt 1) {
    Line ''
    Warn ('找到 ' + $targets.Count + ' 个候选，默认处理第一个。要换一个请用 -Target 指定。')
}

$TargetPath = [IO.Path]::GetFullPath($work.Path).TrimEnd('\')

# ---- 护栏 ----
Step '安全校验'
if (-not (Assert-SafeTarget $TargetPath)) { exit 1 }
Ok '路径不在禁区'

if (-not (Test-IsWorkbench $TargetPath)) {
    Bad ('这个目录不像工作台（没有 app\main.js / Start-Workbench.cmd）：' + $TargetPath)
    Detail '为防止误删，已中止。'
    exit 1
}
Ok '确认是工作台（有 app\main.js 或启动脚本）'

$pkgInside = $TargetPath.StartsWith($PkgRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
             ($TargetPath -eq (Split-Path $PkgRoot -Parent))
$pkgIsChild = (Join-Path $TargetPath 'pkg') -eq $PkgRoot
$keepPkgDir = $false
if ($pkgIsChild -and -not $IncludePkg) {
    $keepPkgDir = $true
    Warn ('pkg 就在这个目录里（' + $PkgRoot + '）')
    Detail '默认**保留** pkg（那是安装包本体，删了得重新要一份）。'
    Detail '真要连它一起删：加 -IncludePkg'
}
if ($pkgInside -and -not $pkgIsChild) {
    Bad 'pkg 在当前要删的目录内部，位置关系异常，已中止（请手动处理）'
    exit 1
}

# ---- 列出会删什么 ----
Step '将要删除的内容'
$stat = Get-TreeStat $TargetPath

# 先给每个顶层项分类：删 / 保留（pkg 与用户数据保留）
$top = @(Get-ChildItem $TargetPath -Force -ErrorAction SilentlyContinue)
$keepItems = @()
$delItems = @()
foreach ($it in $top) {
    $why = Test-Protected -FullName $it.FullName -Name $it.Name
    if ($why) {
        $s = if ($it.PSIsContainer) { Get-TreeStat $it.FullName }
             else { [pscustomobject]@{ Files = 1; Bytes = [double]$it.Length } }
        $keepItems += [pscustomobject]@{ Item = $it; Why = $why; Files = $s.Files; Bytes = $s.Bytes }
    } else {
        $delItems += $it
    }
}
$keepBytes = [double](($keepItems | Measure-Object -Property Bytes -Sum).Sum)
$keepFiles = [int](($keepItems | Measure-Object -Property Files -Sum).Sum)
$willDeleteBytes = $stat.Bytes - $keepBytes
$willDeleteFiles = $stat.Files - $keepFiles

Detail ('工作台目录 : ' + $TargetPath)
Detail ('总计       : {0} 个文件  {1}' -f $stat.Files, (Format-Size $stat.Bytes))
if ($keepItems.Count -gt 0) {
    Detail ('保留       : {0} 个文件  {1}（{2} 项）' -f $keepFiles, (Format-Size $keepBytes), $keepItems.Count)
}
Line ''
Ok ('实际删除   : {0} 个文件  {1}' -f $willDeleteFiles, (Format-Size $willDeleteBytes))

# 顶层构成，让用户一眼看出删的是什么
Line ''
Line '    顶层内容：'
foreach ($it in $top) {
    $why = Test-Protected -FullName $it.FullName -Name $it.Name
    $isDir = $it.PSIsContainer
    $sz = if ($isDir) { (Get-TreeStat $it.FullName).Bytes } else { $it.Length }
    $label = if ($isDir) { $it.Name + '\' } else { $it.Name }
    if ($why) { Detail ('  [保留·' + $why + '] ' + $label + '   ' + (Format-Size $sz)) }
    else { Detail ('  ' + $label + '   ' + (Format-Size $sz)) }
}

# 桌面/开始菜单快捷方式
$lnks = @()
foreach ($dir in @([Environment]::GetFolderPath('Desktop'),
                   (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'))) {
    if (-not (Test-Path $dir)) { continue }
    $lnks += Get-ChildItem $dir -Filter 'Arduino IDE*.lnk' -File -ErrorAction SilentlyContinue
}
if ($lnks.Count -gt 0) {
    Line ''
    Line '    快捷方式：'
    $lnks | ForEach-Object { Detail ('  ' + $_.FullName) }
}

Line ''
Warn '**这个操作不可撤销**：删掉之后要重新装，得用 pkg 从头解压一遍（约 10 分钟）。'

if ($DryRun) {
    Line ''
    Ok '预演结束，什么都没删。确认无误后去掉 -DryRun 再跑一次。'
    exit 0
}

if (-not $Force) {
    Line ''
    $ans = Read-Host '    确认删除？输入 YES 继续（其它任何输入都取消）'
    if ($ans -ne 'YES') { Line ''; Line '    已取消，什么都没动。'; exit 0 }
}

# ---- 真删 ----
Step '删除'
$fail = 0
if ($keepItems.Count -eq 0) {
    # 没有要保留的东西，整目录一次性删掉（比逐项快，也更干净）
    try {
        Remove-Item $TargetPath -Recurse -Force -ErrorAction Stop
        Ok ('已删除 ' + $TargetPath)
    } catch {
        $fail++
        Bad ('删不掉 ' + $TargetPath + '：' + $_.Exception.Message)
        Detail '常见原因：工作台还开着（Start-Workbench 的窗口 / node 进程）、IDE 开着、杀软扫描。'
        Detail '关掉后重跑本脚本即可。'
    }
} else {
    foreach ($it in $delItems) {
        try {
            Remove-Item $it.FullName -Recurse -Force -ErrorAction Stop
            Detail ('删除 ' + $it.Name)
        } catch {
            $fail++
            Warn ('删不掉 ' + $it.Name + '：' + $_.Exception.Message)
        }
    }
    $kept = ($keepItems | ForEach-Object { $_.Item.Name }) -join '、'
    Ok ('已删除工作台内容，保留：' + $kept)
}

foreach ($l in $lnks) {
    try { Remove-Item $l.FullName -Force -ErrorAction Stop; Detail ('删除快捷方式 ' + $l.Name) } catch { Warn ('快捷方式删不掉：' + $l.Name) }
}

# ---- 问一句要不要顺手回收 pkg 空间 ----
$ext = Get-ExtractedDirs
if ($ext.Count -gt 0 -and -not $KeepPkgFiles) {
    $total = ($ext | Measure-Object -Property Bytes -Sum).Sum
    Line ''
    Step ('pkg 里还留着解压出来的 ' + (Format-Size $total))
    $ext | ForEach-Object { Detail ('{0,-14} {1,9}' -f $_.Name, (Format-Size $_.Bytes)) }
    Line ''
    Detail '留着的话，下次安装不用重新解压（省 11 分钟）；删掉能省下这些空间。'
    if (-not $Force) {
        $ans2 = Read-Host '    一起删掉吗？输入 YES 删除（其它输入保留）'
    } else {
        $ans2 = 'no'
    }
    if ($ans2 -eq 'YES') {
        foreach ($e in $ext) {
            try { Remove-Item $e.Path -Recurse -Force -ErrorAction Stop; Detail ('  已删 ' + $e.Name + '\') }
            catch { Warn ('  删不掉 ' + $e.Name + '\：' + $_.Exception.Message) }
        }
        Ok ('已回收 ' + (Format-Size $total))
    } else {
        Detail '保留。以后想删：uninstall.ps1 -CleanPkgOnly'
    }
}

# ---- 收尾 ----
Line ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
if ($fail -eq 0) {
    Write-Host '  卸载完成  ' -ForegroundColor Green
} else {
    Write-Host ('  卸载完成，但有 ' + $fail + ' 项没删干净  ') -ForegroundColor Yellow
    Line '  关掉占用它的程序（工作台窗口 / Arduino IDE）后再跑一次即可。'
}
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Line ''
Line '  说明：'
if ($keepItems.Count -gt 0) {
    Line '    这些没删（删了没法从安装包恢复）：'
    foreach ($k in $keepItems) {
        Detail ('  ' + $k.Item.Name + '\    ' + $k.Why + '    ' + (Format-Size $k.Bytes))
    }
    Line '    确实不要了可以自己手动删。'
    Line ''
}
Line '    想重新安装：双击 pkg\一键安装.cmd'
Line ''
