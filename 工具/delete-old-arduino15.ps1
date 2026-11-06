<#
.SYNOPSIS
    删除 C:\Users\87707\AppData\Local\Arduino15（已确认是误放数据，pkg 已收齐全部安装归档）

.DESCRIPTION
    安全措施：
      1. 路径写死，只允许删 C:\Users\<账户>\AppData\Local\Arduino15，绝不接受其它任意路径
      2. 删除前联锁：核对 pkg\arduino15\staging\packages 存在且包含归档、
         pkg\一键安装.cmd 存在 —— 不满足直接拒绝执行
      3. 要求手工输入 DELETE 确认（UAC 只是权限，这一步才是明确授权）
      4. 用「移入回收站」而不是硬删除，删错了可以从回收站还原
      5. 结束后报告释放的空间，并校验目录确实消失

.EXAMPLE
    双击 删除旧Arduino15.cmd
#>
[CmdletBinding()]
param(
    [switch] $NoElevate,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 提权
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ((-not $isAdmin) -and (-not $NoElevate)) {
    Write-Host ''
    Write-Host '  删除其它账户目录下的内容需要管理员权限。' -ForegroundColor Yellow
    Write-Host '  正在请求提权，请在弹出的 UAC 窗口点「是」……' -ForegroundColor Yellow
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    if ($Yes) { $a += '-Yes' }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $a -Verb RunAs
    exit 0
}

# ---------------------------------------------------------------- helpers
function Line([string] $t = '') { Write-Host $t }
function Ok([string] $t)   { Write-Host ('  [OK] ' + $t) -ForegroundColor Green }
function Info([string] $t) { Write-Host ('  [..] ' + $t) -ForegroundColor Gray }
function Wn([string] $t)   { Write-Host ('  [!!] ' + $t) -ForegroundColor Yellow }
function Bad([string] $t)  { Write-Host ('  [xx] ' + $t) -ForegroundColor Red }

function FmtSize([double] $b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

function TreeSize([string] $p) {
    if (-not (Test-Path -LiteralPath $p)) { return [double]0 }
    $s = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    if ($null -eq $s.Sum) { return [double]0 }
    return [double]$s.Sum
}

# ---------------------------------------------------------------- 定位目标（写死规则）
$Target = Join-Path 'C:\Users\87707\AppData\Local' 'Arduino15'
$PkgRoot = Split-Path -Parent $PSScriptRoot
$StagingPkgs = Join-Path $PkgRoot 'arduino15\staging\packages'

Line ''
Line ('=' * 74)
Line '  删除旧 Arduino15 数据目录（移入回收站）'
Line ('=' * 74)
Info ('目标   : ' + $Target)
Info ('包目录 : ' + $PkgRoot)
Info ('管理员 : ' + $(if ($isAdmin) { '是' } else { '否' }))

# ---------------------------------------------------------------- 安全联锁 1：路径形态
$full = [IO.Path]::GetFullPath($Target)
if (-not ($full -match '^C:\\Users\\[^\\]+\\AppData\\Local\\Arduino15$')) {
    Bad ('路径不符合预期形态，拒绝执行：' + $full)
    exit 2
}

# ---------------------------------------------------------------- 安全联锁 2：pkg 已收齐
if (-not (Test-Path -LiteralPath (Join-Path $PkgRoot '一键安装.cmd'))) {
    Bad ('找不到 pkg\一键安装.cmd，当前目录不是 pkg\工具，拒绝执行。')
    exit 3
}
if (-not (Test-Path -LiteralPath $StagingPkgs)) {
    Bad ('找不到 pkg\arduino15\staging\packages，安装归档未收齐，拒绝执行。')
    exit 3
}
$arch = @(Get-ChildItem -LiteralPath $StagingPkgs -File -Force -ErrorAction SilentlyContinue)
$archBytes = ($arch | Measure-Object Length -Sum).Sum
if ($arch.Count -lt 30 -or $archBytes -lt 2GB) {
    Bad ('staging 归档不足（' + $arch.Count + ' 个 / ' + (FmtSize $archBytes) + '），看起来没有完成导入，拒绝执行。')
    exit 3
}
Ok ('安全联锁通过：pkg 内已有 ' + $arch.Count + ' 个安装归档（' + (FmtSize $archBytes) + '）')

# ---------------------------------------------------------------- 目标存在性
$exists = $false
try { $exists = Test-Path -LiteralPath $Target -ErrorAction Stop } catch { $exists = $false }
if (-not $exists) {
    # 区分「真不存在」与「被 ACL 挡住读不到」
    $parentReadable = $true
    try { $null = Get-ChildItem -LiteralPath (Split-Path -Parent $Target) -Force -ErrorAction Stop | Select-Object -First 1 } catch { $parentReadable = $false }
    if ($parentReadable) {
        Wn ('目录不存在，无需删除（可能已删过）：' + $Target)
    } else {
        Bad ('无法确认目标是否存在：上级目录 ' + (Split-Path -Parent $Target) + ' 也读不到（非管理员）。')
        Wn '请双击本脚本并允许 UAC 提权后重试。'
    }
    exit 0
}
$srcOk = $true
try { $null = Get-ChildItem -LiteralPath $Target -Force -ErrorAction Stop | Select-Object -First 1 } catch { $srcOk = $false }
if (-not $srcOk) {
    Bad ('管理员权限下仍读不到目标目录，拒绝执行。请先在管理员 PowerShell 里放开读取：')
    Line ('    icacls "' + $Target + '" /grant "' + $env:USERNAME + ':(OI)(CI)F" /T')
    exit 4
}
$size = TreeSize $Target
$files = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue)
Ok ('目标可读：' + $files.Count + ' 个文件，' + (FmtSize $size))

# ---------------------------------------------------------------- 确认
if (-not $Yes) {
    Line ''
    Wn ('即将把 ' + $Target + ' 移入回收站（' + (FmtSize $size) + '）。')
    Wn '回收站可还原，但占用 C 盘空间，清空回收站前请确认不需要还原。'
    $inp = Read-Host '  输入大写 DELETE 并回车确认，其它任意输入取消'
    if ($inp -cne 'DELETE') {
        Wn '已取消，未做任何改动。'
        exit 0
    }
}

# ---------------------------------------------------------------- 执行（回收站）
$before = (Get-PSDrive C).Free
Line ''
Info '正在移入回收站（14.5 GB 需要几分钟，窗口可能无输出，请勿关闭）……'
Add-Type -AssemblyName Microsoft.VisualBasic
try {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
        $Target,
        [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
        [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin)
} catch {
    Bad ('移入回收站失败：' + $_.Exception.Message)
    Wn '如果报「目录不为空」或访问被拒，可改用直接删除（不可恢复）：'
    Line ('    Remove-Item -LiteralPath "' + $Target + '" -Recurse -Force')
    exit 5
}
$after = (Get-PSDrive C).Free
$freed = $after - $before

# ---------------------------------------------------------------- 校验与报告
if (Test-Path -LiteralPath $Target) {
    Bad ('目录仍然存在，删除未完成，请检查回收站/错误信息。')
    exit 6
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$reportPath = Join-Path $PSScriptRoot ('删除报告-' + $stamp + '.md')
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine('# 旧 Arduino15 删除报告')
$null = $sb.AppendLine('')
$null = $sb.AppendLine('- 时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$null = $sb.AppendLine('- 目标：`' + $Target + '`')
$null = $sb.AppendLine('- 方式：移入回收站（可还原）')
$null = $sb.AppendLine('- 删除内容：' + $files.Count + ' 个文件，' + (FmtSize $size))
$null = $sb.AppendLine('- C 盘可用空间变化：' + (FmtSize ([math]::Max($freed,0))) + '（删前 ' + (FmtSize $before) + ' → 删后 ' + (FmtSize $after) + '）')
$null = $sb.AppendLine('- pkg 安装归档：' + $arch.Count + ' 个 / ' + (FmtSize $archBytes) + '（删除前已核验）')
[IO.File]::WriteAllText($reportPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Line ''
Line ('=' * 74)
Ok ('已移入回收站：' + $files.Count + ' 个文件 / ' + (FmtSize $size))
Ok ('C 盘可用空间 ' + (FmtSize $before) + ' → ' + (FmtSize $after))
Ok ('报告：' + $reportPath)
Line ''
exit 0
