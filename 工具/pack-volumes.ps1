<#
.SYNOPSIS
    把 pkg 里的大目录压成 100MB 分卷 rar（volumes\*.partNN.rar）。

.DESCRIPTION
    离线包 8.5 GB，单个目录动辄 8 GB —— 拷 U 盘、走网盘、邮件附件都不方便。
    这里按「顶层目录」切包，每包 100 MB 一卷：

        volumes\arduino15.part01.rar ... partNN.rar
        volumes\ide.part01.rar
        volumes\runtime.part01.rar
        volumes\npm.part01.rar
        volumes\payload.part01.rar
        volumes\libraries.part01.rar
        volumes\library-zips.part01.rar

    压缩包里**带目录名**（不是只装内容），所以 `UnRAR x volumes\x.part01.rar pkg\`
    就原样还原成 `pkg\x\` —— 安装脚本只要解压到 pkg 根，后面所有部署步骤一行都不用改。

    每个卷带 3% 恢复记录（-rr3）：分卷损坏是最难查的故障，多花 3% 换「能修回来」。
    压缩级别 -m3（标准）：这些目录里大量是 .a/.o/.exe 已压缩二进制，-m5 只多花
    几十分钟换来百分之几，不划算。

.PARAMETER VolSize
    分卷大小，默认 100m。rar 的 m 单位是 1024*1024 字节。

.PARAMETER Method
    压缩级别 0-5，默认 3。

.PARAMETER Verify
    打完用 `rar t` 逐卷集测试 CRC。

.PARAMETER Prune
    **校验通过后删除源目录**。不加这个开关只打包、不动源文件。
    8.5 GB 的删除是不可逆的，所以必须显式要求。

.EXAMPLE
    powershell -File pack-volumes.ps1 -Verify
    只打包 + 校验，源目录保留。

.EXAMPLE
    powershell -File pack-volumes.ps1 -Verify -Prune
    打包 + 校验 + 删源（确认压缩包没问题之后才删）。
#>
[CmdletBinding()]
param(
    [string]$VolSize = '100m',
    [string]$Method  = '3',
    [string[]]$Only  = @(),
    [switch]$Verify,
    [switch]$Prune,
    [switch]$PruneOnly
)

$ErrorActionPreference = 'Stop'

$PkgRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $PkgRoot 'install.ps1'))) {
    throw ('这里不是 pkg 目录（找不到 install.ps1）：' + $PkgRoot)
}
$volDir = Join-Path $PkgRoot 'volumes'

function Line   { param([string]$m = '') Write-Host $m }
function Step   { param([string]$m) Write-Host (("`n" + '[*] ' + $m)) -ForegroundColor Cyan }
function Ok     { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Warn   { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Fail   { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
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

function Find-Rar {
    $cands = @(
        'D:\Program Files\WinRAR\Rar.exe',
        'C:\Program Files\WinRAR\Rar.exe',
        'C:\Program Files (x86)\WinRAR\Rar.exe',
        'D:\Program Files (x86)\WinRAR\Rar.exe'
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $x = Get-Command rar.exe -ErrorAction SilentlyContinue
    if ($x) { return $x.Source }
    return $null
}

# ---------------------------------------------------------------------------
# 0) 准备
# ---------------------------------------------------------------------------
$rar = Find-Rar
if (-not $rar -and -not $PruneOnly) {
    Fail '找不到 Rar.exe。需要装 WinRAR（Rar.exe 在安装目录里），或把 rar.exe 放到 PATH。'
    exit 1
}
if ($rar) {
    $rarVer = (& $rar 2>&1 | Select-String -Pattern 'RAR\s+([\d.]+)' | Select-Object -First 1)
    Ok ('压缩器：' + $rar)
    Detail ($rarVer -replace '^\s+', '')
}

New-Item -ItemType Directory -Path $volDir -Force | Out-Null

# 打包顺序：大的先来，能早点看到进度
$targets = @('arduino15', 'ide', 'runtime', 'npm', 'payload', 'libraries', 'library-zips')
if ($Only.Count -gt 0) {
    # capture 之后只需要重打 payload，不必把 8 GB 的 core 再压一遍。
    # powershell.exe -File 传参是「整串」的，`-Only payload,libraries` 会原样
    # 变成一个字符串，所以这里自己按逗号拆一次。
    $Only = @($Only | ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $targets = @($targets | Where-Object { $Only -contains $_ })
    if ($targets.Count -eq 0) {
        Fail ('-Only 里没有可打的目录：' + ($Only -join ', '))
        exit 1
    }
    Detail ('只处理：' + ($targets -join ', '))
}

$plan = @()
foreach ($t in $targets) {
    $p = Join-Path $PkgRoot $t
    if (-not (Test-Path $p)) { Warn ('没有 ' + $t + '，跳过'); continue }
    $st = Get-TreeStat $p
    $plan += [pscustomobject]@{ Name = $t; Path = $p; Files = $st.Files; Bytes = $st.Bytes }
}

$planTotal = ($plan | Measure-Object -Property Bytes -Sum).Sum

# 只删源、不重新打包：给「verify-volumes.ps1 已经验过，现在只想回收磁盘」用。
# 不走打包流程，省 7 分钟。
if ($PruneOnly) {
    Step '只删源目录（不重新打包）'
    Detail '前提：pkg\工具\verify-volumes.ps1 已经跑过并通过'
    $deleted = 0
    foreach ($x in $plan) {
        try {
            Remove-Item $x.Path -Recurse -Force -ErrorAction Stop
            Ok ('已删除 ' + $x.Name + '\   （' + (Format-Size $x.Bytes) + '）')
            $deleted++
        } catch {
            cmd /c rd /s /q "$($x.Path)" 2>$null
            if (Test-Path $x.Path) { Fail ('删不掉 ' + $x.Name + '\：' + $_.Exception.Message) }
            else { Ok ('已删除 ' + $x.Name + '\（走 rd）'); $deleted++ }
        }
    }
    Line ''
    Ok ('共删除 ' + $deleted + ' 个目录，安装脚本现在从 volumes\ 解压')
    exit 0
}

Step ('准备压缩 ' + $plan.Count + ' 个目录，共 ' + (Format-Size $planTotal))
foreach ($x in $plan) { Detail ('{0,-14} {1,7} 个文件  {2}' -f $x.Name, $x.Files, (Format-Size $x.Bytes)) }

$driveLetter = (Get-Item $PkgRoot).PSDrive.Name
$free = (Get-PSDrive -Name $driveLetter).Free
if ($free -lt ($planTotal * 0.9)) {
    Fail ('磁盘剩余 ' + (Format-Size $free) + '，可能不够（压缩后再删源，峰值要高 ' +
          (Format-Size ($planTotal * 0.9)) + '）')
    exit 1
}

# ---------------------------------------------------------------------------
# 1) 逐个打成分卷
# ---------------------------------------------------------------------------
$report = @()
$t0 = Get-Date
foreach ($x in $plan) {
    Step ('压缩 ' + $x.Name + '   ' + (Format-Size $x.Bytes))
    $arc = Join-Path $volDir ($x.Name + '.rar')

    # 清掉上一次的残卷，否则 rar 会接着旧卷续写。
    # 注意两种命名都要清：内容大于卷大小时是 arduino15.part01.rar…，
    # 小于一卷时 rar 只给 arduino15.rar（没有 part 编号）。
    Get-ChildItem $volDir -Filter ($x.Name + '*.rar') -File -ErrorAction SilentlyContinue |
        Remove-Item -Force

    Push-Location $PkgRoot
    try {
        # 不带 -ep：让压缩包里保留「arduino15\...」这层目录名，
        # 解压到 pkg 根就原样还原，安装脚本不用做任何路径映射。
        #
        # 注意 -m / -v 必须字符串拼接：PowerShell 的裸参数不做变量展开，
        # 直接写 `-m$Method` 会被当成字面量参数名 `m$Method`，rar 报
        # 「未知选项」退出码 7 —— 这个坑踩过一次（2026-11-02）。
        # -idq：关掉「正在添加 xxx」逐文件消息，只留百分比和错误。
        $rarOut = & $rar a -r ('-m' + $Method) ('-v' + $VolSize) -rr3 -y -idq $arc ($x.Name + '\') 2>&1
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($code -ne 0) {
        Fail ($x.Name + ' 压缩失败（rar 退出码 ' + $code + '）')
        ($rarOut | Select-Object -Last 8) | ForEach-Object { Detail ([string]$_) }
        exit 1
    }

    # 卷名两种可能：分卷时 arduino15.part01.rar…，不足一卷时 arduino15.rar
    $vols = Get-ChildItem $volDir -Filter ($x.Name + '*.rar') -File | Sort-Object Name
    $vbytes = ($vols | Measure-Object -Property Length -Sum).Sum
    $ratio = if ($x.Bytes -gt 0) { 100.0 * $vbytes / $x.Bytes } else { 0 }
    Ok ('{0,-14} {1,3} 卷  {2,9}  （原 {3}，压缩到 {4:N0}%）' -f
        $x.Name, $vols.Count, (Format-Size $vbytes), (Format-Size $x.Bytes), $ratio)

    $report += [pscustomobject]@{
        Name    = $x.Name
        Volumes = $vols.Count
        ArcBytes = [double]$vbytes
        SrcBytes = [double]$x.Bytes
        SrcFiles = $x.Files
        First   = ($vols | Select-Object -First 1).Name
    }
}

$elapsed = (Get-Date) - $t0
$arcTotal = ($report | Measure-Object -Property ArcBytes -Sum).Sum

# ---------------------------------------------------------------------------
# 2) 校验：rar t 逐卷集测试 CRC
# ---------------------------------------------------------------------------
$okVerify = $true
if ($Verify) {
    Step '校验分卷（rar t，逐卷集测 CRC）'
    foreach ($r in $report) {
        $first = Join-Path $volDir $r.First
        $out = & $rar t $first 2>&1
        $code = $LASTEXITCODE
        if ($code -eq 0) {
            Ok ($r.Name + '  CRC 全部通过（' + $r.Volumes + ' 卷）')
        } else {
            $okVerify = $false
            Fail ($r.Name + ' 校验失败（退出码 ' + $code + '）')
            ($out | Select-Object -Last 6) | ForEach-Object { Detail $_ }
        }
    }
}

# ---------------------------------------------------------------------------
# 3) 汇总
# ---------------------------------------------------------------------------
Step '汇总'
$report | ForEach-Object {
    Detail ('{0,-14} {1,3} 卷  {2,9}  ← 源 {3}' -f
        $_.Name, $_.Volumes, (Format-Size $_.ArcBytes), (Format-Size $_.SrcBytes))
}
Line ''
Ok ('原始合计 ' + (Format-Size $planTotal) + '  →  压缩合计 ' + (Format-Size $arcTotal) +
    '（省 ' + ('{0:N0}' -f (100 - 100 * $arcTotal / $planTotal)) + '%）')
Ok ('分卷共 ' + (($report | Measure-Object -Property Volumes -Sum).Sum) + ' 个，每卷上限 ' + $VolSize)
Ok ('耗时 ' + ('{0:N1}' -f $elapsed.TotalMinutes) + ' 分钟')
Detail ('输出目录：' + $volDir)

# ---------------------------------------------------------------------------
# 4) 删源（只在显式 -Prune 且校验通过时）
# ---------------------------------------------------------------------------
if ($Prune) {
    if ($Verify -and -not $okVerify) {
        Fail '校验没过，拒绝删除源目录。先修好压缩包再说。'
        exit 1
    }
    Step '删除源目录（压缩包已就位）'
    foreach ($x in $plan) {
        try {
            Remove-Item $x.Path -Recurse -Force -ErrorAction Stop
            Ok ('已删除 ' + $x.Name + '\')
        } catch {
            cmd /c rd /s /q "$($x.Path)" 2>$null
            if (Test-Path $x.Path) { Fail ('删不掉 ' + $x.Name + '\：' + $_.Exception.Message) }
            else { Ok ('已删除 ' + $x.Name + '\（走 rd）') }
        }
    }
    Ok '源目录清理完毕。安装脚本现在从 volumes\ 解压。'
} else {
    Line ''
    Warn '源目录保留着（没加 -Prune）。确认压缩包没问题后再跑：'
    Detail 'powershell -File pack-volumes.ps1 -Verify -Prune'
}

exit 0
