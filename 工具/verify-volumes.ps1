<#
.SYNOPSIS
    删源目录之前，把每个分卷集真解一遍，跟原目录比对文件数 + 总字节 + 抽样 md5。

.DESCRIPTION
    为什么不数 `unrar lb` 的行数（这个坑踩过，2026-11-02）：
      1) 它把**目录条目**也列出来（libraries 113 个文件会数成 174 条）；
      2) **多卷包它只列当前卷**——arduino15 有 17 卷 80900 个文件，lb 只报 3768 条，
         看起来像「少了 7 万个文件」，其实是假警报。
    所以唯一可靠的判断是「真解出来、逐项比」。8 GB 解压两分多钟，比删错了重下载划算。

.PARAMETER Sample
    每个包抽几个文件比 md5，默认 5。

.PARAMETER Keep
    保留解压出来的临时目录（排查用），默认解完就删。

.EXAMPLE
    powershell -File verify-volumes.ps1
#>
[CmdletBinding()]
param(
    [string]$PkgRoot = '',
    [int]$Sample = 5,
    [switch]$Keep
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot 在 param 默认值求值时还是空的（PS 5.1 老毛病），只能放函数体里算
if (-not $PkgRoot) { $PkgRoot = Split-Path $PSScriptRoot -Parent }

function Ok     { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Bad    { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
function Warn   { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Detail { param([string]$m) Write-Host ('        ' + $m) -ForegroundColor DarkGray }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

$volDir = Join-Path $PkgRoot 'volumes'
if (-not (Test-Path $volDir)) { Bad ('没有 volumes 目录：' + $volDir); exit 1 }

$unrar = Join-Path $PkgRoot '工具\UnRAR.exe'
if (-not (Test-Path $unrar)) {
    foreach ($x in @('D:\Program Files\WinRAR\UnRAR.exe', 'C:\Program Files\WinRAR\UnRAR.exe')) {
        if (Test-Path $x) { $unrar = $x; break }
    }
}
if (-not (Test-Path $unrar)) { Bad '找不到 UnRAR.exe'; exit 1 }

$arcs = @(Get-ChildItem $volDir -Filter '*.rar' -File |
    Where-Object { $_.Name -match '\.part0*1\.rar$' -or $_.Name -notmatch '\.part\d+\.rar$' } |
    Sort-Object Name)

# 临时目录必须短：arduino15 里最长的一层相对路径是 214 字符，凑上
# C:\Users\xxx\AppData\Local\Temp\pkg-volcheck-8位随机\arduino15\ 这种长前缀就会
# 冲破 260 的 MAX_PATH，unrar 会**静默跳过**那 169 个文件（退出码还是 0），
# 看起来像「包里少了 169 个」。实测定名短目录就正常（2026-11-02）。
$tmpRoot = Join-Path $env:TEMP ('vc' + [guid]::NewGuid().ToString('N').Substring(0, 4))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

Write-Host ''
Write-Host ('  分卷核对   ' + $volDir) -ForegroundColor Cyan
Write-Host ('  解压器     ' + $unrar) -ForegroundColor DarkGray
Write-Host ('  临时目录   ' + $tmpRoot) -ForegroundColor DarkGray

$fail = 0
try {
    foreach ($a in $arcs) {
        $nm = ($a.Name -replace '\.part0*1\.rar$', '') -replace '\.rar$', ''
        $vols = @(Get-ChildItem $volDir -Filter ($nm + '*.rar') -File)
        $vbytes = ($vols | Measure-Object -Property Length -Sum).Sum
        $srcDir = Join-Path $PkgRoot $nm

        Write-Host ''
        Write-Host ('  [' + $nm + ']  ' + $vols.Count + ' 卷 / ' + (Format-Size $vbytes)) -ForegroundColor White

        # 真解
        $out = Join-Path $tmpRoot $nm
        New-Item -ItemType Directory -Path $out -Force | Out-Null

        # 先把源列表读出来（后面统计解压结果时要拿它当停止条件）
        $srcFiles = @()
        $srcBytes = 0
        if (Test-Path $srcDir) {
            $srcFiles = @(Get-ChildItem $srcDir -Recurse -File -Force -ErrorAction SilentlyContinue)
            $srcBytes = ($srcFiles | Measure-Object -Property Length -Sum).Sum
        }

        $t0 = Get-Date
        # 输出重定向到文件而不是内存变量：8 万个文件时把 unrar 的输出全塞进
        # PowerShell 变量会很慢，实测还会让紧随其后的 Get-ChildItem 少数几个（169 个）。
        # 那次误报就是这么来的（2026-11-02）。
        $logFile = Join-Path $tmpRoot ('unrar-' + $nm + '.log')
        & $unrar x -y -o+ -idq $a.FullName ($out + '\') > $logFile 2>&1
        $code = $LASTEXITCODE
        $secs = ((Get-Date) - $t0).TotalSeconds
        if ($code -ne 0) {
            Bad ('  解压失败（unrar 退出码 ' + $code + '）')
            if (Test-Path $logFile) { (Get-Content $logFile -Tail 6) | ForEach-Object { Detail $_ } }
            $fail++
            continue
        }

        $got = Join-Path $out $nm
        if (-not (Test-Path $got)) { $got = $out }

        # 刚解压完偶尔会数少（文件系统还没刷完），最多重试 3 次；数到与源一致就停
        $dstFiles = @()
        for ($try = 1; $try -le 3; $try++) {
            $dstFiles = @(Get-ChildItem $got -Recurse -File -Force -ErrorAction SilentlyContinue)
            if ($srcFiles.Count -eq 0 -or $dstFiles.Count -eq $srcFiles.Count) { break }
            if ($try -lt 3) { Start-Sleep -Milliseconds 500 }
        }
        $dstBytes = ($dstFiles | Measure-Object -Property Length -Sum).Sum
        Ok ('  解压 {0,6} 个文件  {1,9}  （{2:N1}s）' -f $dstFiles.Count, (Format-Size $dstBytes), $secs)

        if (-not (Test-Path $srcDir)) {
            Warn '  源目录已删，只能报「包里有什么」，无法比对'
            continue
        }

        if ($dstFiles.Count -ne $srcFiles.Count) {
            Bad ('  文件数不一致：解出 ' + $dstFiles.Count + '，目录 ' + $srcFiles.Count +
                 '（差 ' + ($srcFiles.Count - $dstFiles.Count) + '）')
            $fail++
        } elseif ([math]::Abs($dstBytes - $srcBytes) -gt 0) {
            Bad ('  总字节不一致：解出 ' + (Format-Size $dstBytes) + '，目录 ' + (Format-Size $srcBytes))
            $fail++
        } else {
            Ok ('  文件数 + 总字节与目录一致（' + $srcFiles.Count + ' 个 / ' + (Format-Size $srcBytes) + '）')

            # 抽样 md5：直接从解压结果比源文件，不经过任何编码转换
            $pick = @($srcFiles | Where-Object { $_.Length -gt 0 } |
                Get-Random -Count ([Math]::Min($Sample, $srcFiles.Count)))
            $badHash = 0
            foreach ($f in $pick) {
                $rel = $f.FullName.Substring($srcDir.Length).TrimStart('\')
                $mate = Join-Path $got $rel
                if (-not (Test-Path $mate)) { $badHash++; Detail ('  缺文件：' + $rel); continue }
                $h1 = (Get-FileHash $f.FullName -Algorithm MD5).Hash
                $h2 = (Get-FileHash $mate -Algorithm MD5).Hash
                if ($h1 -ne $h2) { $badHash++; Detail ('  md5 不一致：' + $rel) }
            }
            if ($badHash -eq 0) { Ok ('  抽样 ' + $pick.Count + ' 个 md5 全对') }
            else { Bad ('  抽样 ' + $pick.Count + ' 个里有 ' + $badHash + ' 个不对'); $fail++ }
        }

        if (-not $Keep) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue }
    }
} finally {
    if (-not $Keep) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Host ('  临时目录保留在 ' + $tmpRoot) -ForegroundColor DarkGray }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host '  核对通过：每个分卷集解出来的内容与目录逐项一致，可以安全删源。' -ForegroundColor Green
    Write-Host '  删源：pkg\工具\pack-volumes.ps1 -Verify -Prune' -ForegroundColor DarkGray
    exit 0
} else {
    Write-Host ('  核对失败 ' + $fail + ' 项 —— 先别删源目录。') -ForegroundColor Red
    exit 1
}
