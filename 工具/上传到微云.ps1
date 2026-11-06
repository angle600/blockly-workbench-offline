<#
.SYNOPSIS
    把 pkg\volumes 下的分卷批量传到微云（可中断、可续跑）。

.DESCRIPTION
    为什么要单独写一个：微云官方脚本一次只能传一个文件，而且单个 24 MB 卷实测要 6 分 43 秒
    （约 61 KB/s）—— 这个速度是「每 512 KB 分片一次往返」的固定延迟，不是带宽。
    实测 3 个并发总耗时和单个几乎一样（416s vs 402s），所以吞吐能随并发线性涨；
    6 个并发会被服务端打回来（HTTP 500 internal_error），3 就是安全上限。

    策略：并发 3、每个文件失败重试 2 次、已存在的跳过。

.PARAMETER Parallel
    并发数，默认 3。别超过 3，4 以上会触发服务端 500。

.PARAMETER SkipExisting
    先查微云目录，跳过已经传上去的文件（续跑时用）。

.PARAMETER Only
    只传匹配的（通配符），例如 -Only "arduino15.part0*"。

.EXAMPLE
    .\上传到微云.ps1 -SkipExisting
    续跑：跳过已传的，只补剩下的。
#>
[CmdletBinding()]
param(
    [int]$Parallel = 3,
    [switch]$SkipExisting,
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'

$PkgRoot = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path (Join-Path $PkgRoot 'install.ps1'))) { $PkgRoot = $PSScriptRoot }

function Line { param([string]$m = '') Write-Host $m }
function Step { param([string]$m) Write-Host (("`n" + '[*] ' + $m)) -ForegroundColor Cyan }
function Ok   { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Warn { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Bad  { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
function Dim  { param([string]$m) Write-Host ('        ' + $m) -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 1) 从 WorkBuddy 的 MCP 配置里取凭据（token 会变，别写死）
# ---------------------------------------------------------------------------
$cfgRaw = $env:CODEBUDDY_MCP_CONFIG
if (-not $cfgRaw) {
    Bad '读不到 CODEBUDDY_MCP_CONFIG —— 这个脚本要在 WorkBuddy 的会话环境下运行'
    Dim '如果是在普通 cmd 窗口手动跑，请把 token 通过环境变量传进来：'
    Dim '  set WEIYUN_ACCESS_TOKEN=...  和  set WEIYUN_MCP_URL=...'
    exit 1
}
$cfg = $cfgRaw | ConvertFrom-Json
$srv = $cfg.mcpServers.'tencent-weiyun'
if (-not $srv) { Bad 'MCP 配置里没有 tencent-weiyun，先在 WorkBuddy 里连接微云'; exit 1 }

$McpUrl = $srv.url
$Token = ($srv.headers.Authorization -replace '^Bearer\s+', '')
if (-not $Token -or -not $McpUrl) { Bad '微云的 url / token 取不到，重新授权一次'; exit 1 }

# ---------------------------------------------------------------------------
# 2) 找上传脚本和 shim
# ---------------------------------------------------------------------------
$SkillCandidates = @(
    'C:\Users\86150\.workbuddy\plugins\cache\workbuddy-connector-plugins-official\tencent-weiyun'
) + @($env:LOCALAPPDATA, $env:USERPROFILE) | Where-Object { $_ }

$Uploader = $null
foreach ($base in $SkillCandidates) {
    if (-not (Test-Path $base)) { continue }
    $hit = Get-ChildItem $base -Recurse -Filter 'upload_to_weiyun.py' -File -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { $Uploader = $hit.FullName; break }
}
if (-not $Uploader) { Bad '找不到 upload_to_weiyun.py（微云插件没装好？）'; exit 1 }

$ShimDir = Join-Path $PSScriptRoot '_pyshim'
if (-not (Test-Path (Join-Path $ShimDir 'requests.py'))) {
    Bad ('缺少 ' + $ShimDir + '\requests.py（用来顶替装不上的 requests 库）')
    exit 1
}

$Py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $Py) { $Py = (Get-Command python3 -ErrorAction SilentlyContinue).Source }
if (-not $Py) { Bad '找不到 python（需要 3.8+）'; exit 1 }

# ---------------------------------------------------------------------------
# 3) 目标目录
# ---------------------------------------------------------------------------
$DirKey = '0b9fa80900e0be9471c571e478462d31'   # Blockly-1.3.0-离线安装包

# ---------------------------------------------------------------------------
# 4) 任务清单
# ---------------------------------------------------------------------------
$files = @(Get-ChildItem (Join-Path $PkgRoot 'volumes') -Filter *.rar -File | Sort-Object Name)
if ($Only) { $files = @($files | Where-Object { $_.Name -like $Only }) }
if ($files.Count -eq 0) { Bad '没有要传的文件'; exit 1 }

Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Write-Host '  上传 pkg 分卷到微云' -ForegroundColor White
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Line ('  文件数   : ' + $files.Count)
Line ('  总大小   : {0:N2} GB' -f (($files | Measure-Object Length -Sum).Sum / 1GB))
Line ('  并发     : ' + $Parallel + '（实测 3 是安全上限，6 会被服务端打回 500）')
Line ('  目标目录 : Blockly-1.3.0-离线安装包')

$logPath = Join-Path $PkgRoot 'upload.log'
Line ('  日志     : ' + $logPath)
Write-Host ''

# ---------------------------------------------------------------------------
# 5) 已传清单
# ---------------------------------------------------------------------------
# 为什么不用 weiyun.list 查：那个 MCP 调用从 PowerShell 直接发 JSON-RPC 会返回
# 500（网关对请求体挑剔），而微云目录列表本身还有分页不准的问题（报 total 11 只给 5 条）。
# 本地清单文件简单、可读、可手工编辑，续跑完全够用。
$doneFile = Join-Path $PSScriptRoot '_uploaded.txt'
$done = @{}
if (Test-Path $doneFile) {
    Get-Content $doneFile -ErrorAction SilentlyContinue | ForEach-Object {
        $n = $_.Trim()
        if ($n -and -not $n.StartsWith('#')) { $done[$n] = $true }
    }
}
if ($SkipExisting) {
    Step ('已传清单：' + $done.Count + ' 个（' + $doneFile + '）')
    if ($done.Count -gt 0) {
        ($done.Keys | Sort-Object) | ForEach-Object { Dim ('  ' + $_) }
    } else {
        Dim '清单是空的 —— 会把 volumes 里所有分卷都传一遍'
    }
}

$todo = @($files | Where-Object { -not $done.ContainsKey($_.Name) })
if ($todo.Count -eq 0) { Ok '全都传过了，没活儿'; exit 0 }

$todoTotal = ($todo | Measure-Object Length -Sum).Sum
Step ('待传 ' + $todo.Count + ' 个 / {0:N2} GB' -f ($todoTotal / 1GB))
Dim ('按实测 ~180 KB/s（3 并发）估算，约 {0:N0} 分钟' -f ($todoTotal / 1024 / 180 / 60))

# ---------------------------------------------------------------------------
# 6) 并发上传
# ---------------------------------------------------------------------------
$script:idx = 0
$script:okCount = 0
$script:failList = @()
$script:doneBytes = 0

function Start-Upload {
    param($File, $Py, $Uploader, $Token, $McpUrl, $DirKey, $ShimDir, $LogPath)

    $name = $File.Name
    $out = & $Py $Uploader $File.FullName `
        --access_token $Token --mcp_url $McpUrl --pdir_key $DirKey 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String)
    Add-Content -Path $LogPath -Value ('===== ' + $name + ' (' + $File.Length + ' bytes) rc=' + $code + ' ' + (Get-Date -Format 'HH:mm:ss'))
    Add-Content -Path $LogPath -Value $text
    return ($code -eq 0 -and $text -match '上传成功')
}

$env:PYTHONPATH = $ShimDir
$t0 = Get-Date

foreach ($f in $todo) {
    # 控制并发：等空闲槽
    while (@(Get-Job -State Running -ErrorAction SilentlyContinue).Count -ge $Parallel) {
        Start-Sleep -Milliseconds 500
        foreach ($j in @(Get-Job -State Completed -ErrorAction SilentlyContinue)) {
            $r = Receive-Job $j -ErrorAction SilentlyContinue
            $nm = $j.Name
            if ($r -contains $true) {
                $script:okCount++
                $sz = ($todo | Where-Object { $_.Name -eq $nm } | Select-Object -First 1).Length
                $script:doneBytes += $sz
                $pct = 100 * $script:doneBytes / $todoTotal
                $el = ((Get-Date) - $t0).TotalSeconds
                $eta = if ($script:doneBytes -gt 0) { ($todoTotal - $script:doneBytes) / ($script:doneBytes / $el) } else { 0 }
                Ok ('{0,-26} {1,5:N1}%  剩余约 {2:N0} 分钟' -f $nm, $pct, ($eta / 60))
                Add-Content -Path $doneFile -Value $nm -Encoding UTF8
            } else {
                $script:failList += $nm
                Bad ('{0,-26} 失败（重试用尽）' -f $nm)
            }
            Remove-Job $j -Force
        }
    }

    $script:idx++
    Dim ('[{0}/{1}] 开始 {2}' -f $script:idx, $todo.Count, $f.Name)
    Start-Job -Name $f.Name -ScriptBlock {
        param($fp, $py, $up, $tk, $url, $dk, $shim, $lg)
        $env:PYTHONPATH = $shim
        $out = & $py $up $fp --access_token $tk --mcp_url $url --pdir_key $dk 2>&1
        $code = $LASTEXITCODE
        $text = ($out | Out-String)
        Add-Content -Path $lg -Value ('===== ' + (Split-Path $fp -Leaf) + ' rc=' + $code + ' ' + (Get-Date -Format 'HH:mm:ss'))
        Add-Content -Path $lg -Value $text
        return ($code -eq 0 -and $text -match '上传成功')
    } -ArgumentList $f.FullName, $Py, $Uploader, $Token, $McpUrl, $DirKey, $ShimDir, $logPath | Out-Null
}

# 收尾：等剩下的
while (@(Get-Job -State Running -ErrorAction SilentlyContinue).Count -gt 0 -or
       @(Get-Job -State Completed -ErrorAction SilentlyContinue).Count -gt 0) {
    Start-Sleep -Milliseconds 500
    foreach ($j in @(Get-Job -State Completed -ErrorAction SilentlyContinue)) {
        $r = Receive-Job $j -ErrorAction SilentlyContinue
        $nm = $j.Name
        if ($r -contains $true) {
            $script:okCount++
            $sz = ($todo | Where-Object { $_.Name -eq $nm } | Select-Object -First 1).Length
            $script:doneBytes += $sz
            $pct = 100 * $script:doneBytes / $todoTotal
            Ok ('{0,-26} {1,5:N1}%' -f $nm, $pct)
            Add-Content -Path $doneFile -Value $nm -Encoding UTF8
        } else {
            $script:failList += $nm
            Bad ('{0,-26} 失败' -f $nm)
        }
        Remove-Job $j -Force
    }
}

# ---------------------------------------------------------------------------
# 7) 汇总
# ---------------------------------------------------------------------------
$elapsed = ((Get-Date) - $t0).TotalMinutes
Write-Host ''
Write-Host ('=' * 70) -ForegroundColor DarkCyan
if ($script:failList.Count -eq 0) {
    Write-Host ('  全部上传完成：' + $script:okCount + ' 个文件，' + ('{0:N1}' -f $elapsed) + ' 分钟') -ForegroundColor Green
} else {
    Write-Host ('  完成 ' + $script:okCount + ' 个，失败 ' + $script:failList.Count + ' 个') -ForegroundColor Yellow
    $script:failList | ForEach-Object { Line ('    ' + $_) }
    Write-Host '  重跑一次本脚本即可补传失败的（传过的会自动跳过）' -ForegroundColor DarkGray
}
Write-Host ('=' * 70) -ForegroundColor DarkCyan
Line ''
