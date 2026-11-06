<#
.SYNOPSIS
    核对从网盘下载回来的 pkg 副本，跟本地原始 pkg 是否完全一致。

.DESCRIPTION
    场景：你把 pkg 传到网盘，想确认「传完整了没有」。
    最可靠的办法是把它下载回来，跑这个脚本，逐文件比字节数（可选比 MD5）。

    判定标准：
      · 核心文件**一个都不能少**（默认 106 个：85 个分卷 + 根脚本 + config + 工具）
      · 每个文件**字节数必须完全相等**（差 1 字节都算失败）
      · 副本里多出来的文件只提示不报错（比如 upload.log、_uploaded.txt 这些工具产物）

.PARAMETER Copy
    下载回来的 pkg 目录路径。例如 D:\Downloads\pkg

.PARAMETER Hash
    同时比对 MD5（慢，1.9 GB 大约 1 分钟，但能发现「大小一样内容不同」的极端情况）

.PARAMETER Ignore
    额外忽略的文件名模式（默认已忽略 .cfg / upload.log / _uploaded.txt / _pyshim）

.EXAMPLE
    .\校验网盘副本.ps1 -Copy "D:\Downloads\pkg"

.EXAMPLE
    .\校验网盘副本.ps1 -Copy "D:\Downloads\pkg" -Hash
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Copy,
    [switch]$Hash,
    [string[]]$Ignore = @()
)

$ErrorActionPreference = 'Stop'

$Local = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $Local 'install.ps1'))) { $Local = $PSScriptRoot }

function Line { param([string]$m = '') Write-Host $m }
function Step { param([string]$m) Write-Host (("`n" + '[*] ' + $m)) -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Warn { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Bad  { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
function Dim  { param([string]$m) Write-Host ('        ' + $m) -ForegroundColor DarkGray }

function Fmt {
    param([double]$b)
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

if (-not (Test-Path $Copy)) { Bad ('副本目录不存在：' + $Copy); exit 1 }
$Copy = (Resolve-Path $Copy).Path

# 不是安装包内容的东西：上传时可能有、下载回来也不该算缺失
$skipPatterns = @(
    '*.baiduyun.uploading.cfg',
    'upload.log',
    '_uploaded.txt',
    '*\_pyshim\*'
) + $Ignore

function Should-Skip {
    param([string]$RelPath)
    foreach ($p in $skipPatterns) {
        if ($RelPath -like $p -or $RelPath -like ('*' + $p)) { return $true }
    }
    return $false
}

Write-Host ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Write-Host '  网盘副本完整性核对' -ForegroundColor White
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Line ('  本地原始 : ' + $Local)
Line ('  下载副本 : ' + $Copy)
Line ('  校验方式 : ' + $(if ($Hash) { '字节数 + MD5' } else { '字节数（加 -Hash 可同时比 MD5）' }))

# ---------------------------------------------------------------------------
Step '建立本地基准'
$expected = @()
Get-ChildItem $Local -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($Local.Length).TrimStart('\')
    if (Should-Skip $rel) { return }
    $expected += [pscustomobject]@{ Rel = $rel; Name = $_.Name; Size = $_.Length; Full = $_.FullName }
}
$expBytes = ($expected | Measure-Object Size -Sum).Sum
Ok ('应存在 {0} 个文件 / {1}' -f $expected.Count, (Fmt $expBytes))
Dim ('其中分卷 {0} 个' -f @($expected | Where-Object { $_.Rel -like 'volumes\*' }).Count)

# ---------------------------------------------------------------------------
Step '在副本里找对应文件'
# 副本可能被多套了一层目录（pkg\pkg\...），建一个 文件名+大小 的索引兜底
$copyFiles = @{}
Get-ChildItem $Copy -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    $rel = $_.FullName.Substring($Copy.Length).TrimStart('\')
    if (Should-Skip $rel) { return }
    $copyFiles[$rel.ToLower()] = $_
}
Ok ('副本里找到 ' + $copyFiles.Count + ' 个文件')

$missing = @()
$sizeBad = @()
$hashBad = @()
$checked = 0

foreach ($e in $expected) {
    $hit = $copyFiles[$e.Rel.ToLower()]
    if (-not $hit) {
        # 兜底：只按文件名找（防止副本多套了一层目录）
        $byName = @($copyFiles.Values | Where-Object { $_.Name -eq $e.Name })
        if ($byName.Count -eq 1) { $hit = $byName[0] }
    }
    if (-not $hit) { $missing += $e.Rel; continue }

    $checked++
    if ($hit.Length -ne $e.Size) {
        $sizeBad += [pscustomobject]@{ Rel = $e.Rel; Local = $e.Size; Copy = $hit.Length }
        continue
    }
    if ($Hash) {
        $h1 = (Get-FileHash $e.Full -Algorithm MD5).Hash
        $h2 = (Get-FileHash $hit.FullName -Algorithm MD5).Hash
        if ($h1 -ne $h2) { $hashBad += $e.Rel }
    }
}

# 副本里多出来的（按相对路径点名，忽略表里的不算）
$expNames = @{}
$expected | ForEach-Object { $expNames[$_.Rel.ToLower()] = $true }
$extra = @($copyFiles.GetEnumerator() | Where-Object { -not $expNames.ContainsKey($_.Key) } | ForEach-Object { $_.Value })

# ---------------------------------------------------------------------------
Step '结果'
Line ''
if ($missing.Count -gt 0) {
    Bad ('缺失 ' + $missing.Count + ' 个文件：')
    $missing | Sort-Object | Select-Object -First 30 | ForEach-Object { Dim ('  ' + $_) }
    if ($missing.Count -gt 30) { Dim ('  ...还有 ' + ($missing.Count - 30) + ' 个') }
} else {
    Ok '没有缺失文件'
}

if ($sizeBad.Count -gt 0) {
    Bad ('大小不符 ' + $sizeBad.Count + ' 个：')
    $sizeBad | Sort-Object Rel | Select-Object -First 20 | ForEach-Object {
        Dim ('  {0}   本地 {1:N0} / 副本 {2:N0} 字节' -f $_.Rel, $_.Local, $_.Copy)
    }
} else {
    Ok '所有文件字节数一致'
}

if ($hashBad.Count -gt 0) {
    Bad ('MD5 不一致 ' + $hashBad.Count + ' 个：')
    $hashBad | Select-Object -First 20 | ForEach-Object { Dim ('  ' + $_) }
} elseif ($Hash) {
    Ok 'MD5 全部一致'
}

if ($extra.Count -gt 0) {
    $cfgExtra = @($extra | Where-Object { $_.Name -like '*.baiduyun.uploading.cfg' })
    Warn ('副本里多出 ' + $extra.Count + ' 个文件（不影响使用，可删）：')
    $extra | Select-Object -First 10 | ForEach-Object { Dim ('  ' + $_.Name) }
    if ($extra.Count -gt 10) { Dim ('  ...还有 ' + ($extra.Count - 10) + ' 个') }
    if ($cfgExtra.Count -gt 0) {
        Bad ('其中 ' + $cfgExtra.Count + ' 个是网盘客户端的 .cfg 断点文件 —— 说明上传时把它们也传上去了')
    }
}

# ---------------------------------------------------------------------------
Line ''
Write-Host ('=' * 72) -ForegroundColor DarkCyan
$fail = $missing.Count + $sizeBad.Count + $hashBad.Count
if ($fail -eq 0) {
    Write-Host ('  核对通过：' + $checked + ' 个文件全部一致，副本是完整的') -ForegroundColor Green
} else {
    Write-Host ('  核对未通过：' + $fail + ' 处问题（缺 ' + $missing.Count + ' / 大小不符 ' + $sizeBad.Count + ($(if ($Hash) { ' / MD5 不符 ' + $hashBad.Count } else { '' })) + '）') -ForegroundColor Red
    Line '  重新下载缺失/不符的那几个文件即可，不用整包重下。'
}
Write-Host ('=' * 72) -ForegroundColor DarkCyan
Line ''
exit $(if ($fail -eq 0) { 0 } else { 1 })
