<#
.SYNOPSIS
    把旧账户 / 旧机器上的 Arduino15 安装包并入本离线包（pkg\arduino15）

.DESCRIPTION
    场景：以前用另一个 Windows 账户（或另一台机器）装过 Arduino 核心，
          数据目录留在 C:\Users\<旧账户>\AppData\Local\Arduino15。
    本脚本以管理员身份读取那个目录，把「安装包」部分合并进 pkg\arduino15，
    让 pkg 的一键安装能覆盖对应核心 / 工具，而不是重新联网下载。

    默认（只补缺）：
      staging\packages\*            工具与核心的原始归档   -> pkg 缺同名文件才复制
      staging\libraries\*           库归档                 -> pkg 缺同名文件才复制
      packages\<厂商>\hardware\...   板卡核心               -> pkg 缺该版本才复制
      packages\<厂商>\tools\...      编译工具链             -> pkg 缺该版本才复制
      已存在的同版本一律跳过，绝不覆盖 pkg 里更新的内容。

    -Full  全量归档：整个目录（跳过 tmp / cache / logs）合并到 pkg\arduino15，
           已有文件不覆盖。

    脚本只复制，不删除源目录。确认无误后要清理，请自己手工删（脚本会打印命令）。

.PARAMETER Source
    旧数据目录，默认 C:\Users\87707\AppData\Local\Arduino15

.PARAMETER DryRun
    只打印计划，不复制

.PARAMETER Full
    全量归档，而不是只补缺

.PARAMETER NoElevate
    不自动提权（调试用）

.PARAMETER PkgRoot
    指定 pkg 目录（默认取本脚本的上一级）

.EXAMPLE
    双击 导入旧Arduino15.cmd
#>
[CmdletBinding()]
param(
    [string] $Source  = 'C:\Users\87707\AppData\Local\Arduino15',
    [string] $PkgRoot = '',
    [switch] $Full,
    [switch] $DryRun,
    [switch] $NoElevate
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((-not $isAdmin) -and (-not $NoElevate)) {
    Write-Host ''
    Write-Host '  跨账户读取 C:\Users\其它账户 需要管理员权限。' -ForegroundColor Yellow
    Write-Host '  正在请求提权，请在弹出的 UAC 窗口点「是」……' -ForegroundColor Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    if ($DryRun)  { $a += '-DryRun' }
    if ($Full)    { $a += '-Full' }
    if ($PkgRoot) { $a += @('-PkgRoot', ('"' + $PkgRoot + '"')) }
    $a += @('-Source', ('"' + $Source + '"'))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit 0
}

# ---------------------------------------------------------------- 输出helper
function Line([string] $t = '') { Write-Host $t }
function Ok([string] $t)   { Write-Host ('  [OK] ' + $t) -ForegroundColor Green }
function Info([string] $t) { Write-Host ('  [..] ' + $t) -ForegroundColor Gray }
function Wn([string] $t)   { Write-Host ('  [!!] ' + $t) -ForegroundColor Yellow }
function Bad([string] $t)  { Write-Host ('  [xx] ' + $t) -ForegroundColor Red }

function FmtSize([double] $b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

function TreeSize([string] $p) {
    if (-not (Test-Path -LiteralPath $p)) { return [double]0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    if ($null -eq $s.Sum) { return [double]0 }
    return [double]$s.Sum
}

# 双击运行时停住窗口；设 WB_NO_PAUSE=1 可脚本化调用
function Pause2() {
    if (-not $env:WB_NO_PAUSE) { Read-Host '按回车退出' | Out-Null }
}

# ---------------------------------------------------------------- 定位 pkg
if (-not $PkgRoot) { $PkgRoot = Split-Path -Parent $PSScriptRoot }
$DstRoot = Join-Path $PkgRoot 'arduino15'

Line ''
Line ('=' * 74)
Line '  旧 Arduino15 安装包  ->  并入 pkg'
Line ('=' * 74)
Info ('源目录 : ' + $Source)
Info ('包目录 : ' + $DstRoot)
if ($Full) { Info '模式   : 全量归档（不覆盖已有文件）' } else { Info '模式   : 只补缺（已存在则跳过）' }
Info ('管理员 : ' + $(if ($isAdmin) { '是' } else { '否' }))

if (-not (Test-Path -LiteralPath (Join-Path $PkgRoot 'install.ps1'))) {
    Line ''
    Bad ('这不是 pkg 目录：' + $PkgRoot)
    Wn '请把「工具」文件夹放在 pkg\ 下，或加 -PkgRoot 指定。'
    Pause2
    exit 2
}

# ---------------------------------------------------------------- 源可读性
$srcOk = $true
try { $null = Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop | Select-Object -First 1 }
catch { $srcOk = $false }

if (-not $srcOk) {
    Line ''
    Bad ('读不到源目录：' + $Source)
    Wn '常见原因：目录不存在 / 属于其它账户 / 权限被拒 / 安全软件拦截。'
    Line ''
    Wn '如果确认目录存在，先在上面的提示里点「是」提权重试；仍旧不行可在管理员 PowerShell 里放开读取：'
    Line ('    icacls "' + $Source + '" /grant "' + $env:USERNAME + ':(OI)(CI)RX" /T')
    Line ''
    Pause2
    exit 3
}
Ok ('源目录可读，' + (FmtSize (TreeSize $Source)))

# ---------------------------------------------------------------- 生成计划
$plan = New-Object System.Collections.ArrayList
$skip = New-Object System.Collections.ArrayList

function AddItem([string] $kind, [string] $rel, [string] $src, [string] $dst, [double] $bytes) {
    $null = $plan.Add([pscustomobject]@{ Kind = $kind; Rel = $rel; Src = $src; Dst = $dst; Bytes = $bytes })
}

if ($Full) {
    $excl = @('tmp', 'cache', 'logs', 'telemetry')
    foreach ($item in (Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        if ($item.PSIsContainer -and ($excl -contains $item.Name.ToLower())) {
            $null = $skip.Add([pscustomobject]@{ Rel = ($item.Name + '\'); Why = '缓存 / 临时目录，不归档' })
            continue
        }
        $dst = Join-Path $DstRoot $item.Name
        if (Test-Path -LiteralPath $dst) {
            $null = $skip.Add([pscustomobject]@{ Rel = $item.Name; Why = 'pkg 已有，保留现有版本' })
            continue
        }
        $bytes = if ($item.PSIsContainer) { TreeSize $item.FullName } else { [double]$item.Length }
        AddItem '全量' $item.Name $item.FullName $dst $bytes
    }
} else {
    $maps = @(
        @{ sub = 'staging\packages';  kind = '工具归档' },
        @{ sub = 'staging\libraries'; kind = '库归档' }
    )
    foreach ($m in $maps) {
        $s = Join-Path $Source $m.sub
        if (-not (Test-Path -LiteralPath $s)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $s -File -Force -ErrorAction SilentlyContinue)) {
            $rel = $m.sub + '\' + $f.Name
            $dst = Join-Path $DstRoot $rel
            if (Test-Path -LiteralPath $dst) {
                $null = $skip.Add([pscustomobject]@{ Rel = $rel; Why = 'pkg 已有同名文件' })
                continue
            }
            AddItem $m.kind $rel $f.FullName $dst ([double]$f.Length)
        }
    }

    $sPackages = Join-Path $Source 'packages'
    foreach ($vendor in (Get-ChildItem -LiteralPath $sPackages -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($group in @('hardware', 'tools')) {
            $g = Join-Path $vendor.FullName $group
            if (-not (Test-Path -LiteralPath $g)) { continue }

            foreach ($f in (Get-ChildItem -LiteralPath $g -File -Force -ErrorAction SilentlyContinue)) {
                $rel = 'packages\' + $vendor.Name + '\' + $group + '\' + $f.Name
                $dst = Join-Path $DstRoot $rel
                if (Test-Path -LiteralPath $dst) { continue }
                AddItem '元数据' $rel $f.FullName $dst ([double]$f.Length)
            }

            foreach ($lvl1 in (Get-ChildItem -LiteralPath $g -Directory -Force -ErrorAction SilentlyContinue)) {
                foreach ($ver in (Get-ChildItem -LiteralPath $lvl1.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    $rel = 'packages\' + $vendor.Name + '\' + $group + '\' + $lvl1.Name + '\' + $ver.Name
                    $dst = Join-Path $DstRoot $rel
                    if (Test-Path -LiteralPath $dst) {
                        $null = $skip.Add([pscustomobject]@{ Rel = $rel; Why = 'pkg 已有同版本' })
                        continue
                    }
                    $kind = if ($group -eq 'hardware') { '板卡核心' } else { '工具链' }
                    AddItem $kind $rel $ver.FullName $dst (TreeSize $ver.FullName)
                }
            }
        }
    }
}

# ---------------------------------------------------------------- 打印计划
Line ''
if ($plan.Count -eq 0) {
    Ok '没有需要搬的东西 —— pkg 已包含旧目录里的全部安装包。'
    if ($skip.Count -gt 0) { Info ('比对跳过 ' + $skip.Count + ' 项') }
    Line ''
    Pause2
    exit 0
}

$total = [double]0
foreach ($p in $plan) { $total += $p.Bytes }
Line ('  计划导入 ' + $plan.Count + ' 项，合计 ' + (FmtSize $total))
Line ''
foreach ($p in $plan) {
    Line ('    + {0}  {1}  {2}' -f $p.Kind, (FmtSize $p.Bytes), $p.Rel)
}
if ($skip.Count -gt 0) {
    Line ''
    Info ('跳过 ' + $skip.Count + ' 项（pkg 已有相同或更新的内容）')
    $i = 0
    foreach ($s in $skip) {
        if ($i -ge 6) { break }
        Info ('    - ' + $s.Rel + '   ' + $s.Why)
        $i++
    }
    if ($skip.Count -gt 6) { Info ('    …… 还有 ' + ($skip.Count - 6) + ' 项') }
}

if ($DryRun) {
    Line ''
    Wn '这是 -DryRun（预演），没有复制任何文件。'
    Pause2
    exit 0
}

# ---------------------------------------------------------------- 执行复制
Line ''
Info '开始复制……'
$okCount = 0
$failCount = 0
foreach ($p in $plan) {
    try {
        $parent = Split-Path -Parent $p.Dst
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $p.Src -PathType Container) {
            if (-not (Test-Path -LiteralPath $p.Dst)) { New-Item -ItemType Directory -Path $p.Dst -Force | Out-Null }
            $null = robocopy $p.Src $p.Dst /E /COPY:DAT /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
            if ($LASTEXITCODE -ge 8) { throw ('robocopy 退出码 ' + $LASTEXITCODE) }
        } else {
            Copy-Item -LiteralPath $p.Src -Destination $p.Dst -Force
        }
        $okCount++
        Ok ('已导入 ' + $p.Rel)
    } catch {
        $failCount++
        Bad ($p.Rel + '  失败：' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- 写报告
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$reportPath = Join-Path $PSScriptRoot ('导入报告-' + $stamp + '.md')
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine('# 旧 Arduino15 导入报告')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('- 时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$null = $sb.AppendLine('- 源目录：`' + $Source + '`')
$null = $sb.AppendLine('- 包目录：`' + $DstRoot + '`')
$null = $sb.AppendLine('- 模式：' + $(if ($Full) { '全量归档' } else { '只补缺' }))
$null = $sb.AppendLine('- 结果：成功 ' + $okCount + ' / 失败 ' + $failCount)
$null = $sb.AppendLine('- 导入总量：' + (FmtSize $total))
$null = $sb.AppendLine('- 导入后 pkg\arduino15 体积：' + (FmtSize (TreeSize $DstRoot)))
$null = $sb.AppendLine('')
$null = $sb.AppendLine('## 已导入')
$null = $sb.AppendLine('')
foreach ($p in $plan) {
    $null = $sb.AppendLine('- [' + $p.Kind + '] `' + $p.Rel + '`  ' + (FmtSize $p.Bytes))
}
if ($skip.Count -gt 0) {
    $null = $sb.AppendLine('')
    $null = $sb.AppendLine('## 跳过')
    $null = $sb.AppendLine('')
    foreach ($s in $skip) {
        $null = $sb.AppendLine('- `' + $s.Rel + '`  ' + $s.Why)
    }
}
[IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------- 汇总
Line ''
Line ('=' * 74)
Line ('  完成：成功 ' + $okCount + ' / 失败 ' + $failCount)
Line ('  pkg\arduino15 现在 ' + (FmtSize (TreeSize $DstRoot)))
Line ('  报告：' + $reportPath)
Line ''
Line '  下一步：'
Line '    1) 双击 pkg\一键安装.cmd 复验（会自检核心与库）'
Line '    2) 确认无误后可自行清理源目录，本脚本不会替你删：'
Line ('       Remove-Item -LiteralPath "' + $Source + '" -Recurse -Force')
Line ''
Pause2
if ($failCount -gt 0) { exit 1 }
exit 0
