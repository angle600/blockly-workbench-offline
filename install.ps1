<#
.SYNOPSIS
    Blockly 可视化编程工作台 —— 离线一键安装 / 还原脚本

.DESCRIPTION
    本脚本与 pkg 目录内的离线包配合工作，完全不需要联网：
      pkg\runtime\node\node.exe            Node.js 运行时
      pkg\runtime\arduino-cli\*.exe        arduino-cli 编译器
      pkg\arduino15\                       整个 Arduino 数据目录（4 个板卡核心 + 索引 + 配置）
      pkg\libraries\                       外置库（Servo / ESP32Servo / SerialLCD / EspSoftwareSerial / ghostl）
      pkg\library-zips\                    上面这些库的原始 zip（离线 lib install 备用）
      pkg\npm\node_modules\                Blockly / esbuild / jsdom 等 npm 依赖
      pkg\payload\                         本工程的全部改造（源码、生成器、服务端、脚本、文档）

    安装 = 把上面这些东西按原样铺到目标目录，并按目标目录重写 arduino-cli.yaml。

.PARAMETER Target
    安装目标目录。默认：
      * 如果 pkg 的上一级目录已经是一个装好的工作台 → 就地修复 / 升级
      * 否则 → D:\Program Files\Blockly（D 盘不存在则退到系统盘 \Blockly）

.PARAMETER Force
    核心包（8 GB 级）已存在时也强制覆盖。默认不覆盖，避免无谓拷贝。

.PARAMETER SkipVerify
    跳过最后的 headless 自检（app\verify.cjs）。

.PARAMETER Capture
    反向操作：把 Target 目录里当前的改造回写进 pkg\payload，用来刷新安装包。
    改完源码后跑这个，安装包才会带上新改动。

.PARAMETER KeepBackup
    覆盖已有文件时先备份到 <Target>\.pkg-backup\<时间戳>\。默认开启。

.EXAMPLE
    install.ps1
    就地安装 / 修复（双击「一键安装.cmd」走的就是这条）

.EXAMPLE
    install.ps1 -Target "E:\Blockly" -Force
    装到别的位置，并强制覆盖核心包

.EXAMPLE
    install.ps1 -Capture
    把当前工程的改动重新收进 pkg\payload
#>

[CmdletBinding()]
param(
    [string]$Target = '',
    [switch]$Force,
    [switch]$SkipVerify,
    [switch]$Capture,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$PkgRoot  = $PSScriptRoot
$PkgName  = 'Blockly 可视化编程工作台 离线安装包'
$PkgVer   = '1.5.0'

function Line   { param([string]$m = '') Write-Host $m }
function Step   { param([string]$m) Write-Host (("`n" + '[*] ' + $m)) -ForegroundColor Cyan }
function Ok     { param([string]$m) Write-Host ('    [+] ' + $m) -ForegroundColor Green }
function Warn   { param([string]$m) Write-Host ('    [!] ' + $m) -ForegroundColor Yellow }
function Fail   { param([string]$m) Write-Host ('    [x] ' + $m) -ForegroundColor Red }
function Detail { param([string]$m) Write-Host ('        ' + $m) -ForegroundColor DarkGray }

function Get-TreeStat {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return [pscustomobject]@{ Files = 0; Bytes = 0 } }
    $s = Get-ChildItem $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
         Measure-Object Length -Sum
    return [pscustomobject]@{ Files = [int]$s.Count; Bytes = [long]$s.Sum }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

# ---------------------------------------------------------------------------
# 分卷还原：pkg 里的大目录可能已经压成 volumes\*.partNN.rar（24 MiB 一卷，
# 受 GitHub 网页上传 25 MiB 上限约束；见 pkg\校验清单.md「为什么是 24 MiB」）
# ---------------------------------------------------------------------------
# 为什么「解压回 pkg 原地」而不是直接解压到安装目标：
#   后面 8 个部署步骤（payload / runtime / npm / arduino15 / libraries / IDE）
#   都以 $PkgRoot 为源、各自算目标路径，还带「同内容跳过 / 不同内容备份」的逻辑。
#   就地还原等于让这些步骤一行都不用改 —— 改动越小越不容易出错。
#   代价是多占一份磁盘（解压出来的 + 装到目标的），装完可以直接删掉整个 pkg。
function Find-UnRar {
    $cands = @(
        (Join-Path $PkgRoot '工具\UnRAR.exe'),
        'D:\Program Files\WinRAR\UnRAR.exe',
        'C:\Program Files\WinRAR\UnRAR.exe',
        'C:\Program Files (x86)\WinRAR\UnRAR.exe'
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $x = Get-Command unrar.exe -ErrorAction SilentlyContinue
    if ($x) { return $x.Source }
    return $null
}

function Expand-Volumes {
    $volDir = Join-Path $PkgRoot 'volumes'
    if (-not (Test-Path $volDir)) { return }      # 老式包：目录还在，不需要还原

    # 只取「卷集首卷」。注意编号位数跟卷数走：17 卷是 part01…part17，
    # 3 卷是 part1…part3，不足一卷时干脆没有编号（xxx.rar）。
    # 所以正则必须是 part0*1 而不是 part01 —— 只认两位会漏掉 ide（3 卷）那一套（实测踩过）。
    $arcs = @(Get-ChildItem $volDir -Filter '*.rar' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.part0*1\.rar$' -or $_.Name -notmatch '\.part\d+\.rar$' } |
        Sort-Object Name)
    if ($arcs.Count -eq 0) { return }

    $todo = @()
    foreach ($a in $arcs) {
        $nm = ($a.Name -replace '\.part0*1\.rar$', '') -replace '\.rar$', ''
        $dst = Join-Path $PkgRoot $nm
        $hasFiles = $false
        if (Test-Path $dst) {
            $one = Get-ChildItem $dst -Recurse -File -Force -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($one) { $hasFiles = $true }
        }
        if ($hasFiles) { Ok ('{0,-14} 已解压，跳过' -f $nm) }
        else { $todo += [pscustomobject]@{ Arc = $a; Name = $nm } }
    }
    if ($todo.Count -eq 0) { return }

    $unrar = Find-UnRar
    if (-not $unrar) {
        Fail '需要 UnRAR.exe 解压分卷，但没找到'
        Detail '放到 pkg\工具\UnRAR.exe（包里本该带着），或装 WinRAR 后重跑'
        exit 1
    }
    Step ('从分卷还原 ' + $todo.Count + ' 个目录（volumes\*.rar，每卷 24 MiB）')
    Detail ('解压器：' + $unrar)
    foreach ($t in $todo) {
        $sz = 0
        Get-ChildItem $volDir -Filter ($t.Name + '*.rar') -File -ErrorAction SilentlyContinue |
            ForEach-Object { $sz += $_.Length }
        Detail ('解开 ' + $t.Name + '（' + (Format-Size $sz) + '）…')
        $t0 = Get-Date
        $out = & $unrar x -y -o+ -idq $t.Arc.FullName ($PkgRoot + '\') 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Fail ('解压失败：' + $t.Name + '（unrar 退出码 ' + $code + '）')
            ($out | Select-Object -Last 6) | ForEach-Object { Detail ([string]$_) }
            Detail '若 pkg 在只读位置（U 盘写保护 / Program Files 无权限），先整个拷到可写目录再装'
            exit 1
        }
        $st = Get-TreeStat (Join-Path $PkgRoot $t.Name)
        Ok ('{0,-14} {1,6} 个文件  {2,9}  {3:N1}s' -f $t.Name, $st.Files,
            (Format-Size $st.Bytes), ((Get-Date) - $t0).TotalSeconds)
    }
}

# ---------------------------------------------------------------------------
# 文件铺设：同内容跳过，不同内容备份后覆盖
# ---------------------------------------------------------------------------
$script:StatNew     = 0
$script:StatSame    = 0
$script:StatUpdated = 0
$script:StatNewer   = 0
$script:BackupRoot  = ''

function Backup-One {
    param([string]$Path, [string]$TargetRoot)
    if ($NoBackup -or -not $script:BackupRoot) { return }
    $rel = $Path.Substring($TargetRoot.Length).TrimStart('\')
    $dst = Join-Path $script:BackupRoot $rel
    $dir = Split-Path $dst -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $Path -Destination $dst -Force
}

function Deploy-Tree {
    param(
        [string]$Source,
        [string]$Dest,
        [string]$TargetRoot,
        [string[]]$Exclude = @()
    )

    if (-not (Test-Path $Source)) { Warn ('源目录不存在，跳过：' + $Source); return }

    foreach ($f in (Get-ChildItem $Source -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($Source.Length).TrimStart('\')
        $skip = $false
        foreach ($e in $Exclude) {
            if ($rel -like ($e + '\*') -or $rel -eq $e) { $skip = $true; break }
        }
        if ($skip) { continue }

        $dst = Join-Path $Dest $rel
        $dir = Split-Path $dst -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        if (Test-Path $dst) {
            $a = $f.Length
            $b = (Get-Item -LiteralPath $dst -Force).Length
            if ($a -eq $b) {
                $ha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                $hb = (Get-FileHash -LiteralPath $dst        -Algorithm SHA256).Hash
                if ($ha -eq $hb) { $script:StatSame++; continue }
            }
            # 目标文件比安装包里的新 → 有人在打包之后改过它。
            # 这时不能静默回退成旧版本（会把改动吃掉），只提示去刷新安装包。
            $dstTime = (Get-Item -LiteralPath $dst -Force).LastWriteTime
            if ((-not $Force) -and ($dstTime -gt $f.LastWriteTime.AddSeconds(2))) {
                $script:StatNewer++
                if ($script:StatNewer -le 5) { Detail ('跳过（目标更新）：' + $rel) }
                continue
            }
            Backup-One -Path $dst -TargetRoot $TargetRoot
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            $script:StatUpdated++
        } else {
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            $script:StatNew++
        }
    }
}

# ===========================================================================
Write-Host ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Write-Host ('  ' + $PkgName + '  v' + $PkgVer) -ForegroundColor White
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Line ('  安装包位置 : ' + $PkgRoot)
Line ('  开始时间   : ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

# ===========================================================================
# 0.5) 分卷还原（安装模式才需要；capture 是要重建 payload，不用解开旧的）
# ===========================================================================
if (-not $Capture) { Expand-Volumes }

# ===========================================================================
# 1) 预检：安装包是否完整
# ===========================================================================
# capture 模式整块跳过：它只重建 payload，其余目录可能还压在 volumes\*.rar 里
# （第 0.5 步在 capture 下是不展开的）。这时候要求 arduino15 / npm\node_modules
# 存在，会误报「安装包不完整」然后把一次正常的 capture 打断。
if (-not $Capture) {

Step '检查安装包完整性'

$checks = @(
    @{ p = 'runtime\node\node.exe';                  n = 'Node.js 运行时';   need = $true },
    @{ p = 'runtime\arduino-cli\arduino-cli.exe';    n = 'arduino-cli';      need = $true },
    @{ p = 'arduino15\packages';                      n = '板卡核心包';       need = $true },
    @{ p = 'libraries';                               n = '外置库';           need = $false },
    @{ p = 'npm\node_modules';                        n = 'npm 离线依赖';     need = $true },
    @{ p = 'payload\app\index.html';                  n = '工作台源码';       need = $true },
    @{ p = 'payload\firmware';                        n = 'MicroPython固件';  need = $false }
)
$missing = @()
foreach ($c in $checks) {
    $full = Join-Path $PkgRoot $c.p
    if (Test-Path $full) {
        $st = if ((Get-Item $full).PSIsContainer) { Get-TreeStat $full } else {
            [pscustomobject]@{ Files = 1; Bytes = (Get-Item $full).Length } }
        Ok ('{0,-16} {1}' -f $c.n, (Format-Size $st.Bytes))
    } else {
        if ($c.need) { $missing += $c.n; Fail ('{0,-16} 缺失' -f $c.n) }
        else { Warn ('{0,-16} 缺失（可选项）' -f $c.n) }
    }
}
if ($missing.Count -gt 0) {
    Line ''
    Fail ('安装包不完整，缺少：' + ($missing -join '、'))
    $volHint = Join-Path $PkgRoot 'volumes'
    if (Test-Path $volHint) {
        Line '    pkg\volumes 里有分卷但没解开 —— 可能是 UnRAR.exe 缺失或分卷损坏，'
        Line '    也可以手动解开：pkg\工具\UnRAR.exe x -y -o+ volumes\<名字>.part01.rar '
        Line ''
    } else {
        Line '    这个 pkg 目录被删过东西。请重新获取完整的 pkg 目录后再运行。'
    }
    exit 1
}

}   # end if (-not $Capture) —— 预检结束

# ===========================================================================
# 2) 决定目标目录
# ===========================================================================
$parent = Split-Path $PkgRoot -Parent

if ($Capture) {
    if (-not $Target) { $Target = $parent }
} elseif (-not $Target) {
    if (Test-Path (Join-Path $parent 'app\main.js')) {
        $Target = $parent
        $inPlace = $true
    } elseif (Test-Path 'D:\') {
        $Target = 'D:\Program Files\Blockly'
    } else {
        $Target = Join-Path $env:SystemDrive 'Blockly'
    }
}
if (-not $Target) { $Target = $parent }
$Target = [IO.Path]::GetFullPath($Target).TrimEnd('\')

$isInPlace = ($Target -eq $parent)

# ===========================================================================
# 3) Capture：把当前改造回写进 pkg\payload
# ===========================================================================
if ($Capture) {
    Step ('收集改造 → pkg\payload    （来源：' + $Target + '）')
    if (-not (Test-Path (Join-Path $Target 'app\main.js'))) {
        Fail ('目标目录不是工作台（找不到 app\main.js）：' + $Target)
        exit 1
    }
    $payDir = Join-Path $PkgRoot 'payload'
    # 每次重建成全新快照最干净：/MIR 遇到被 /XD 排除的目录不会清理残留。
    # 但整目录删除在部分环境会被「批量删除保护 / 杀软」拒绝，
    # 所以删不掉就退回到 robocopy /MIR 增量覆盖——效果基本一致，
    # 只是源里已删掉的文件可能在 payload 里留下残留。
    if (Test-Path $payDir) {
        try { Remove-Item $payDir -Recurse -Force -ErrorAction Stop } catch { }
        if (Test-Path $payDir) {
            cmd /c rd /s /q "$payDir" 2>$null
            if (Test-Path $payDir) {
                Warn '旧 payload 无法整目录清空 → 改用增量覆盖（源里已删的文件可能残留）'
            }
        }
    }
    New-Item -ItemType Directory -Path $payDir -Force | Out-Null
    $jobs = @(
        @{ s = 'app';      d = 'app';      xd = @('node_modules') },
        @{ s = 'tools';    d = 'tools';    xd = @('node', 'arduino-cli') },
        @{ s = 'examples'; d = 'examples'; xd = @('build') },
        @{ s = 'samples';  d = 'samples';  xd = @() },
        @{ s = 'modules';  d = 'modules';  xd = @() },
        @{ s = 'static';   d = 'static';   xd = @() },
        @{ s = 'arduino-user'; d = 'arduino-user'; xd = @() },
        @{ s = 'firmware'; d = 'firmware'; xd = @() }
    )
    foreach ($j in $jobs) {
        $src = Join-Path $Target $j.s
        $dst = Join-Path $payDir $j.d
        if (-not (Test-Path $src)) { Warn ('没有 ' + $j.s + '，跳过'); continue }
        $xdArgs = @()
        foreach ($x in $j.xd) { $xdArgs += @('/XD', $x) }   # 注意：只认目录名，传完整路径在这里不生效
        $null = robocopy $src $dst /MIR /NFL /NDL /NJH /NJS /NP @xdArgs
        $st = Get-TreeStat $dst
        Ok ('{0,-10} {1,5} 个文件  {2}' -f $j.s, $st.Files, (Format-Size $st.Bytes))
    }
    foreach ($f in @('Start-Workbench.cmd','Start-Blockly.cmd','Flash-Sketch.cmd','Flash-Sketch.ps1',
                     'Install-Cores.cmd','Run-Installer.cmd','Install-Blockly.ps1','README.md')) {
        $src = Join-Path $Target $f
        if (Test-Path $src) { Copy-Item $src (Join-Path $payDir $f) -Force }
    }
    Ok '根目录脚本与 README 已收好'

    # 配置模板
    $cfg = Join-Path $Target 'arduino15\arduino-cli.yaml'
    if (-not (Test-Path $cfg)) { $cfg = Join-Path $Target 'pkg\arduino15\arduino-cli.yaml' }
    $urls = @()
    if (Test-Path $cfg) {
        foreach ($ln in (Get-Content $cfg)) {
            if ($ln -match '^\s*-\s*(https?://\S+)') { $urls += $Matches[1] }
        }
    }
    if ($urls.Count -eq 0) {
        $urls = @(
            'https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json',
            'https://espressif.github.io/arduino-esp32/package_esp32_index.json'
        )
    }
    $tmpl = @(
        '# 由 pkg\install.ps1 生成，路径随安装目标自动改写',
        'board_manager:',
        '    additional_urls:'
    ) + ($urls | ForEach-Object { '        - ' + $_ }) + @(
        'directories:',
        '    user: __USER_DIR__'
    )
    [IO.File]::WriteAllText((Join-Path $PkgRoot 'config\arduino-cli.yaml.tmpl'),
        (($tmpl -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Ok ('配置模板已刷新（' + $urls.Count + ' 个板管理器地址）')

    # 清单
    # 分卷模式下 capture 时 arduino15 / npm 可能还压在 volumes 里（第 0.5 步不展开），
    # Get-TreeStat 会给 0 —— manifest 的体积统计就废了。目录不在时沿用旧清单的值。
    $oldMf = $null
    $mfPath = Join-Path $PkgRoot 'manifest.json'
    if (Test-Path $mfPath) { try { $oldMf = Get-Content -Raw $mfPath | ConvertFrom-Json } catch { } }
    $statOf = {
        param([string]$rel, [string]$key)
        $p = Join-Path $PkgRoot $rel
        if (Test-Path $p) { return (Get-TreeStat $p) }
        if ($oldMf -and $oldMf.$key) { return $oldMf.$key }
        return (Get-TreeStat $p)
    }

    # runtime / ide 也可能压在 volumes 里：直接执行 exe 会报
    # 「The term ... is not recognized」把整个 capture 打断（实测踩过）。
    # 目录在就现取，不在就沿用旧清单里的值。
    $nodeExePath = Join-Path $PkgRoot 'runtime\node\node.exe'
    $cliExePath  = Join-Path $PkgRoot 'runtime\arduino-cli\arduino-cli.exe'
    $nodeVer = if (Test-Path $nodeExePath) { (& $nodeExePath --version 2>$null) }
               elseif ($oldMf) { $oldMf.node } else { '' }
    $cliVer  = if (Test-Path $cliExePath) { (& $cliExePath version 2>$null) }
               elseif ($oldMf) { $oldMf.cli } else { '' }

    # 外置库清单的数据源：优先 pkg\libraries（安装时用的那份）；它被压进
    # volumes\libraries.*.rar 时改看 payload\arduino-user\libraries —— capture 刚
    # 重建过 payload，那边是展开的，能读到最新内容（含这次新加的库）。
    $libDirForManifest = Join-Path $PkgRoot 'libraries'
    if (-not (Test-Path $libDirForManifest)) {
        $libDirForManifest = Join-Path $PkgRoot 'payload\arduino-user\libraries'
    }

    $manifest = [ordered]@{
        name        = $PkgName
        version     = $PkgVer
        capturedAt  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        sourceDir   = $Target
        node        = $nodeVer
        cli         = $cliVer
        payload     = (& $statOf 'payload' 'payload')
        cores       = (& $statOf 'arduino15' 'cores')
        libraries   = @(Get-ChildItem $libDirForManifest -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $lp  = Join-Path $_.FullName 'library.properties'
            $ver = ''
            if (Test-Path $lp) {
                $m = Select-String -Path $lp -Pattern '^version\s*=\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($m) { $ver = $m.Matches[0].Groups[1].Value.Trim() }
            }
            [pscustomobject]@{ name = $_.Name; version = $ver }
        })
        npmDeps     = (& $statOf 'npm\node_modules' 'npmDeps')
    }
    # libraries 目录被压走时列表会是空的，同样沿用旧清单
    if ($manifest['libraries'].Count -eq 0 -and $oldMf -and $oldMf.libraries) {
        $manifest['libraries'] = $oldMf.libraries
    }
    # IDE 是可选项：有 pkg\ide\arduino-ide_*.zip 就记进清单，没有就不写这个键
    $ideZip = Get-ChildItem (Join-Path $PkgRoot 'ide') -Filter 'arduino-ide_*.zip' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if ($ideZip) {
        $ideVer = ''
        if ($ideZip.Name -match 'arduino-ide_([0-9][0-9.]*?)_') { $ideVer = $Matches[1] }
        $manifest['ide'] = [ordered]@{
            file    = 'ide/' + $ideZip.Name
            version = $ideVer
            Bytes   = $ideZip.Length
            note    = '官方免安装版重新打包（内容一致，仅容器重压）：压缩包根目录就是 Arduino IDE.exe，install.ps1 用 Expand-Archive 解压即用；不需要可整个删掉 pkg\ide'
        }
    } elseif ($oldMf -and $oldMf.ide) {
        # pkg\ide 被压成 volumes\ide.partN.rar 了，沿用旧清单里的记录
        $manifest['ide'] = $oldMf.ide
    }
    # 分卷统计：安装时由 Expand-Volumes 自动解开
    $volDirMf = Join-Path $PkgRoot 'volumes'
    if (Test-Path $volDirMf) {
        $vst = Get-TreeStat $volDirMf
        $manifest['volumes'] = [ordered]@{
            dir   = 'volumes'
            Files = $vst.Files
            Bytes = $vst.Bytes
            note  = '24 MiB 一卷的 rar（-v24m -m3 -rr3，受 GitHub 网页上传 25 MiB 上限约束）；install.ps1 装之前会自动解开到 pkg 原地'
        }
    }

    # 分卷模式：payload 刚被重建，得重新压回 volumes\ 并删掉展开出来的目录 ——
    # 否则包里会同时存在「payload 目录」和「payload 分卷」，安装时用到哪份全看运气。
    # 只重打 payload：8 GB 的 core 没动过，重压一遍要半小时。
    #
    # 顺序要求：manifest 必须等重打**完成之后**再写盘。
    # 原来是先写清单（本函数上面几行）再重打，于是清单里的 volumes.Bytes 记的是
    # 重打**前**那个 payload.rar 的体积 —— 2026-11-06 实测差 828 字节，按清单校验
    # 包大小会误判成「不符」。
    # 注意 payload 自身的统计不受影响：它取自重打前的展开目录，而重打后该目录会被
    # -Prune 删掉，所以那个值只能在重打前算，正好。改的只是写盘时机。
    $volDir2 = Join-Path $PkgRoot 'volumes'
    $hasPayVol = (Test-Path (Join-Path $volDir2 'payload.part01.rar')) -or
                 (Test-Path (Join-Path $volDir2 'payload.part1.rar')) -or
                 (Test-Path (Join-Path $volDir2 'payload.rar'))
    if ($hasPayVol) {
        Step '重打 payload 分卷'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
            (Join-Path $PkgRoot '工具\pack-volumes.ps1') -Only payload -Verify -Prune
        if ($LASTEXITCODE -ne 0) {
            Fail 'payload 分卷重打失败。payload 目录还在，手动跑一遍 pack-volumes.ps1 -Only payload -Verify -Prune'
            exit 1
        }
        Ok 'payload 分卷已更新，展开的 payload 目录已清掉'

        # 卷的体积刚变过，重新统计一遍覆盖上去，别让清单留着重打前的数字
        if (Test-Path $volDir2) {
            $vst2 = Get-TreeStat $volDir2
            $manifest['volumes'] = [ordered]@{
                dir   = 'volumes'
                Files = $vst2.Files
                Bytes = $vst2.Bytes
                note  = '24 MiB 一卷的 rar（-v24m -m3 -rr3，受 GitHub 网页上传 25 MiB 上限约束）；install.ps1 装之前会自动解开到 pkg 原地'
            }
            Ok ('分卷统计已重算：' + $vst2.Files + ' 卷 / ' + (Format-Size $vst2.Bytes))
        }
    }

    [IO.File]::WriteAllText((Join-Path $PkgRoot 'manifest.json'),
        ($manifest | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
    Ok '已写入 manifest.json'

    Line ''
    Ok '安装包已刷新。换机器时整目录拷走 pkg，双击「一键安装.cmd」即可。'
    exit 0
}

# ===========================================================================
# 4) 部署
# ===========================================================================
Step ('安装目标：' + $Target)
if ($isInPlace) { Detail '检测到 pkg 就在工作台里 → 就地安装 / 修复' }

try {
    if (-not (Test-Path $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    $probe = Join-Path $Target ('.pkg-write-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    Set-Content -Path $probe -Value 'x' -Encoding ASCII
    # 只以「写入成功」判定可写；清理探针失败（杀软占用 / 回收站策略）不应误判成不可写
    try { Remove-Item $probe -Force -ErrorAction Stop } catch { }
} catch {
    Fail ('目标目录不可写：' + $Target)
    Line '    如果装到 C:\Program Files，请右键「一键安装.cmd」→ 以管理员身份运行。'
    exit 1
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$script:BackupRoot = Join-Path $Target ('.pkg-backup\' + $stamp)

Step '铺设工作台源码（payload）'
Deploy-Tree -Source (Join-Path $PkgRoot 'payload') -Dest $Target -TargetRoot $Target
Ok ('新增 {0} · 更新 {1} · 未变 {2}' -f $script:StatNew, $script:StatUpdated, $script:StatSame)
if ($script:StatNewer -gt 0) {
    Warn ($script:StatNewer.ToString() + ' 个文件比安装包里的新，已保留新版、没有回退')
    Detail '想让安装包带上这些改动：双击 pkg\更新安装包.cmd'
}

Step '部署运行时（node / arduino-cli）'
$rtNew = $script:StatNew
Deploy-Tree -Source (Join-Path $PkgRoot 'runtime\node')         -Dest (Join-Path $Target 'tools\node')         -TargetRoot $Target
Deploy-Tree -Source (Join-Path $PkgRoot 'runtime\arduino-cli')  -Dest (Join-Path $Target 'tools\arduino-cli')  -TargetRoot $Target
Ok ('node.exe / arduino-cli.exe 就位')

$nodeExe = Join-Path $Target 'tools\node\node.exe'
$cliExe  = Join-Path $Target 'tools\arduino-cli\arduino-cli.exe'
if (-not (Test-Path $nodeExe)) { Fail 'node.exe 部署失败'; exit 1 }
if (-not (Test-Path $cliExe))  { Fail 'arduino-cli.exe 部署失败'; exit 1 }

Step '部署 npm 离线依赖（Blockly / esbuild / jsdom）'
$nmSrc = Join-Path $PkgRoot 'npm\node_modules'
$nmDst = Join-Path $Target 'app\node_modules'
$nmCount = 0
if (Test-Path $nmDst) {
    $nmCount = (Get-ChildItem $nmDst -Recurse -File -Force -ErrorAction SilentlyContinue).Count
}
$srcCount = (Get-ChildItem $nmSrc -Recurse -File -Force).Count
if ((Test-Path (Join-Path $nmDst 'blockly\package.json')) -and ($nmCount -ge $srcCount)) {
    Ok ('已存在且完整（' + $nmCount + ' 个文件），跳过')
} else {
    if (Test-Path $nmDst) {
        if (-not $NoBackup) {
            $bk = Join-Path $script:BackupRoot 'app\node_modules'
            New-Item -ItemType Directory -Path (Split-Path $bk -Parent) -Force | Out-Null
            Move-Item $nmDst $bk -Force
            Detail ('旧的 node_modules 已备份到 ' + $bk)
        } else {
            Remove-Item $nmDst -Recurse -Force
        }
    }
    New-Item -ItemType Directory -Path $nmDst -Force | Out-Null
    $null = robocopy $nmSrc $nmDst /E /NFL /NDL /NJH /NJS /NP
    Ok ('已复制 ' + $srcCount + ' 个文件（' + (Format-Size (Get-TreeStat $nmDst).Bytes) + '）')
}

Step '部署板卡核心（arduino AVR / builtin / esp32 / rp2040）'
# 注意：arduino-cli 拒绝跟随 symlink / junction，packages 必须是真实目录。
# 所以这里搬的是「整个 Arduino 数据目录」，不是给 packages 建联接。
$pkgData = Join-Path $PkgRoot 'arduino15'
$dstData = Join-Path $Target 'arduino15'
$userDir = Join-Path $Target 'arduino-user'
if (-not (Test-Path $userDir)) { New-Item -ItemType Directory -Path $userDir -Force | Out-Null }
if (-not (Test-Path (Join-Path $userDir 'libraries'))) {
    New-Item -ItemType Directory -Path (Join-Path $userDir 'libraries') -Force | Out-Null
}

if ($isInPlace -and (Test-Path (Join-Path $pkgData 'packages'))) {
    $dataDir = $pkgData
    $st = Get-TreeStat $dataDir
    Ok ('数据目录已在安装包内 → ' + $dataDir)
    Detail ($st.Files.ToString() + ' 个文件 / ' + (Format-Size $st.Bytes) + '，不重复拷贝')
} elseif (Test-Path (Join-Path $dstData 'packages')) {
    $dataDir = $dstData
    if ($Force) {
        Remove-Item (Join-Path $dstData 'packages') -Recurse -Force
        $null = robocopy (Join-Path $pkgData 'packages') (Join-Path $dstData 'packages') /E /NFL /NDL /NJH /NJS /NP
        Ok '已强制覆盖核心包'
    } else {
        $st = Get-TreeStat $dstData
        Ok ('已存在（' + $st.Files + ' 个文件 / ' + (Format-Size $st.Bytes) + '），跳过')
        Detail '要强制重装核心包，加 -Force'
    }
} else {
    Line '        正在复制 8 GB 级数据目录，请耐心等待……'
    if (-not (Test-Path $dstData)) { New-Item -ItemType Directory -Path $dstData -Force | Out-Null }
    $null = robocopy $pkgData $dstData /E /NFL /NDL /NJH /NJS /NP
    $dataDir = $dstData
    $st = Get-TreeStat $dstData
    Ok ('已安装 ' + $st.Files + ' 个文件 / ' + (Format-Size $st.Bytes))
}

Step '部署外置库（Servo / ESP32Servo / SerialLCD / EspSoftwareSerial / ghostl）'
$libSrc = Join-Path $PkgRoot 'libraries'
$libDst = Join-Path $Target 'arduino-user\libraries'
$copiedNames = @()
foreach ($d in (Get-ChildItem $libSrc -Directory -ErrorAction SilentlyContinue)) {
    $to = Join-Path $libDst $d.Name
    if (Test-Path $to) { Detail ($d.Name + ' 已存在，跳过'); continue }
    Copy-Item $d.FullName $libDst -Recurse -Force
    $copiedNames += $d.Name
}
if ($copiedNames.Count -gt 0) {
    Ok ('新装 ' + $copiedNames.Count + ' 个库：' + ($copiedNames -join ' / '))
} else {
    $total = @(Get-ChildItem $libSrc -Directory -ErrorAction SilentlyContinue).Count
    Ok ('库都已就位（' + $total + ' 个）')
}

Step '生成 arduino-cli 配置'
$cfgOut = Join-Path $dataDir 'arduino-cli.yaml'
$tmplPath = Join-Path $PkgRoot 'config\arduino-cli.yaml.tmpl'
if (Test-Path $tmplPath) {
    $body = Get-Content $tmplPath -Raw -Encoding UTF8
} else {
    $body = "board_manager:`n    additional_urls:`n        - https://github.com/earlephilhower/arduino-pico/releases/download/global/package_rp2040_index.json`n        - https://espressif.github.io/arduino-esp32/package_esp32_index.json`ndirectories:`n    user: __USER_DIR__`n"
}
$body = $body.Replace('__USER_DIR__', ($userDir -replace '\\', '/'))
$existing = ''
if (Test-Path $cfgOut) { try { $existing = [IO.File]::ReadAllText($cfgOut) } catch {} }
if ($existing -eq $body) {
    Ok '配置内容未变，跳过（不重复备份）'
} else {
    if (Test-Path $cfgOut) { Backup-One -Path $cfgOut -TargetRoot $Target }
    [IO.File]::WriteAllText($cfgOut, $body, (New-Object System.Text.UTF8Encoding($false)))
    Ok '配置已写入'
}
Ok ('数据目录 : ' + $dataDir)
Ok ('库目录   : ' + $userDir)
Ok ('配置     : ' + $cfgOut)

# ===========================================================================
# 4.5) Arduino IDE（可选：离线包里有 pkg\ide\*.zip 就装）
# ===========================================================================
# 为什么单独一步、而且允许不存在：
#   IDE 是可选的（工作台自己带 arduino-cli，不装 IDE 也能编译烧录），
#   但用户希望「一键装完连 IDE 都有」，所以离线包里带了一份官方免安装 ZIP
#   （不写注册表）。zip 不在就跳过，不影响主流程。
#
# 三个细节：
#   · 装到工作台**同级目录**，不写死 D 盘 —— 换到 E:\Blockly 时 IDE 跟着走；
#   · 快捷方式用 tools\mklnk.cjs 手写（这台机器禁用 COM，WScript.Shell 用不了）；
#   · IDE 的 %LOCALAPPDATA%\Arduino15\packages 做成 junction 指向我们的数据目录，
#     否则打开 IDE 还要再下 8 GB 内核。这一步失败只警告，不影响安装。
Step '安装 Arduino IDE（可选）'
$ideZip = Join-Path $PkgRoot 'ide\arduino-ide_2.3.10_Windows_64bit.zip'
$ideVer = '2.3.10'
$ideDir = Join-Path (Split-Path $Target -Parent) ('Arduino IDE ' + $ideVer)
$ideExe = Join-Path $ideDir 'Arduino IDE.exe'

if (-not (Test-Path $ideZip)) {
    Warn '离线包里没有 IDE（pkg\ide\arduino-ide_*.zip），跳过'
} elseif ((Test-Path $ideExe) -and (-not $Force)) {
    Ok ('IDE 已安装：' + $ideDir)
} else {
    try {
        if (-not (Test-Path $ideDir)) { New-Item -ItemType Directory -Path $ideDir -Force | Out-Null }
        Detail ('解压到 ' + $ideDir + '（约 540 MB，慢一点）……')
        Expand-Archive -LiteralPath $ideZip -DestinationPath $ideDir -Force
        if (Test-Path $ideExe) { Ok ('IDE ' + $ideVer + ' 已解压') }
        else { Fail '解压后没找到 Arduino IDE.exe'; $allOk = $false }
    } catch {
        Fail ('解压失败：' + $_.Exception.Message)
        $allOk = $false
    }
}

if (Test-Path $ideExe) {
    # ---- 快捷方式（桌面 + 开始菜单）----
    # 优先用目标目录里已铺好的，其次退回离线包里的（就地安装时两边都存在，无所谓）
    $mkLnk = Join-Path $Target 'tools\mklnk.cjs'
    if (-not (Test-Path $mkLnk)) { $mkLnk = Join-Path $PkgRoot 'payload\tools\mklnk.cjs' }
    if (Test-Path $mkLnk) {
        $lnks = @(
            (Join-Path ([Environment]::GetFolderPath('Desktop')) ('Arduino IDE ' + $ideVer + '.lnk')),
            (Join-Path $env:APPDATA ('Microsoft\Windows\Start Menu\Programs\Arduino IDE ' + $ideVer + '.lnk'))
        )
        $made = 0
        foreach ($l in $lnks) {
            if (Test-Path $l) { continue }
            try {
                & $nodeExe $mkLnk $ideExe $l | Out-Null
                if (Test-Path $l) { $made++ }
            } catch { Detail ('快捷方式没建成：' + $l) }
        }
        if ($made -gt 0) { Ok ('快捷方式已创建 ' + $made + ' 个（桌面 / 开始菜单）') }
        else { Detail '快捷方式已存在（或路径含中文，mklnk 只支持 ASCII 路径）' }
    } else {
        Warn '找不到 tools\mklnk.cjs，跳过快捷方式'
    }

    # ---- 内核复用：把 IDE 的数据目录接到我们的 packages ----
    $pkSrc = Join-Path $dataDir 'packages'
    $pkDst = Join-Path $env:LOCALAPPDATA 'Arduino15\packages'
    if (Test-Path $pkSrc) {
        if (-not (Test-Path $pkDst)) { New-Item -ItemType Directory -Path $pkDst -Force | Out-Null }
        $linked = @()
        foreach ($v in @('arduino', 'esp32', 'rp2040')) {
            $src = Join-Path $pkSrc $v
            $dst = Join-Path $pkDst $v
            if (-not (Test-Path $src)) { continue }
            if (Test-Path $dst) { Detail ($v + ' 已有目录/联接，跳过'); continue }
            try {
                New-Item -ItemType Junction -Path $dst -Target $src -ErrorAction Stop | Out-Null
                $linked += $v
            } catch { Detail ($v + ' 联接失败：' + $_.Exception.Message) }
        }
        if ($linked.Count -gt 0) {
            Ok ('IDE 内核已接入（junction）：' + ($linked -join ' / ') + ' → ' + $pkSrc)
            Detail '打开 IDE 直接就能编；别在 IDE 的板卡管理器里卸载这些核心（会动到工作台的包）'
        } else {
            Ok 'IDE 内核联接已就位'
        }
    }
}

# ===========================================================================
# 5) 校验
# ===========================================================================
Line ''
Step '校验安装结果'

$env:ARDUINO_DIRECTORIES_DATA = $dataDir
$env:ARDUINO_DIRECTORIES_USER = $userDir

$allOk = $true

try {
    $nv = & $nodeExe --version 2>&1
    Ok ('node          ' + $nv)
} catch { Fail 'node.exe 无法运行'; $allOk = $false }

try {
    $cv = & $cliExe version 2>&1
    Ok ('arduino-cli   ' + $cv)
} catch { Fail 'arduino-cli.exe 无法运行'; $allOk = $false }

try {
    $cores = & $cliExe core list 2>&1
    $want  = @('arduino:avr', 'esp32:esp32', 'rp2040:rp2040')
    $got   = @()
    foreach ($w in $want) {
        $hit = $cores | Where-Object { $_ -match ([regex]::Escape($w)) } | Select-Object -First 1
        if ($hit) { $got += $w; Detail ($hit.Trim()) } else { Fail ('缺核心：' + $w); $allOk = $false }
    }
    if ($got.Count -eq $want.Count) { Ok ('板卡核心      ' + $got.Count + ' / ' + $want.Count + ' 就绪') }
} catch { Warn '无法列出核心（可忽略，编译时才会真正用到）' }

try {
    $libs = & $cliExe lib list 2>&1
    $wantLibs = @(
        @{ n = 'Servo';             u = '舵机积木' },
        @{ n = 'ESP32Servo';        u = 'ESP32 舵机积木' },
        @{ n = 'SerialLCD';         u = 'Grove 串口 LCD 积木' },
        @{ n = 'EspSoftwareSerial'; u = 'ESP32 上的串口 LCD 驱动' },
        @{ n = 'ghostl';            u = 'EspSoftwareSerial 的依赖' }
    )
    $missingLib = @()
    foreach ($w in $wantLibs) {
        $hit = $libs | Where-Object { $_ -match ('^\s*' + [regex]::Escape($w.n) + '\s') } | Select-Object -First 1
        if ($hit) { Detail ('  ' + $hit.Trim()) } else { $missingLib += ($w.n + '（' + $w.u + '）') }
    }
    if ($missingLib.Count -eq 0) {
        Ok ('外置库        ' + $wantLibs.Count + ' / ' + $wantLibs.Count + ' 就绪')
    } else {
        Fail ('缺库：' + ($missingLib -join '，'))
        $allOk = $false
    }
} catch { Warn '无法列出库（可忽略，编译时才会真正用到）' }

$verifyScript = Join-Path $Target 'app\verify.cjs'
$bundlePath   = Join-Path $Target 'app\dist\blockly-bundle.js'
if ((-not $SkipVerify) -and (Test-Path $verifyScript) -and (Test-Path $bundlePath)) {
    Line ''
    Write-Host '    运行 headless 自检（生成器 + 引脚表）……' -ForegroundColor Gray
    Push-Location (Join-Path $Target 'app')
    try {
        & $nodeExe 'verify.cjs' 'dist/blockly-bundle.js'
        if ($LASTEXITCODE -ne 0) { Warn '自检有失败项（见上面输出）'; $allOk = $false }
        else { Ok '自检通过' }
    } finally { Pop-Location }
} elseif ($SkipVerify) {
    Warn '已按 -SkipVerify 跳过自检'
}

# ===========================================================================
# 6) 汇总
# ===========================================================================
# 安装记录：uninstall.ps1 靠这个文件找到工作台装在哪儿。
# 没有它就只能靠猜（pkg 父目录 / 各盘 Program Files\Blockly），容易认错。
# 放在安装目标根下，卸载时连它一起删。
try {
    $rec = [ordered]@{
        installedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        target      = $Target
        fromPkg     = $PkgRoot
        pkgVersion  = $PkgVer
        node        = (& $nodeExe --version 2>$null)
        cli         = (& $cliExe version 2>$null)
        cores       = @('arduino:avr', 'esp32:esp32', 'rp2040:rp2040')
    }
    [IO.File]::WriteAllText((Join-Path $Target '.blockly-install.json'),
        ($rec | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
} catch {
    Warn ('安装记录写入失败（不影响使用，但卸载时要手动指定目录）：' + $_.Exception.Message)
}

if ($script:BackupRoot -and (Test-Path $script:BackupRoot)) {
    Line ''
    Detail ('被覆盖的旧文件已备份到 ' + $script:BackupRoot)
}

Line ''
Write-Host ('=' * 74) -ForegroundColor DarkCyan
if ($allOk) {
    Write-Host '  安装完成  ' -ForegroundColor Green -NoNewline
    Write-Host ('（新增 {0} / 更新 {1} / 未变 {2} / 保留新版 {3}）' -f $script:StatNew, $script:StatUpdated, $script:StatSame, $script:StatNewer)
} else {
    Write-Host '  安装完成，但有告警  ' -ForegroundColor Yellow -NoNewline
    Write-Host '（请检查上面的 [!] / [x]）'
}
Write-Host ('=' * 74) -ForegroundColor DarkCyan
Line ''
Line '  怎么用：'
Line ('    1) 双击  ' + (Join-Path $Target 'Start-Workbench.cmd'))
Line '       浏览器会自动打开 http://127.0.0.1:8765/'
Line '       工具栏右上角可切换 Pico / Pico W / Pico 2 / UNO / ESP32-S3，'
Line '       所有积木的引脚会跟着板型自动换。'
Line ''
Line '    2) 改完积木点「编译并烧录」，插上板子选串口即可。'
Line ''
Line '  说明：'
Line ('    * 安装日志与备份都在  ' + (Join-Path $Target '.pkg-backup'))
Line ('    * 改了源码想刷新安装包，双击  ' + (Join-Path $PkgRoot '更新安装包.cmd'))
Line ''
if (Test-Path (Join-Path $PkgRoot 'volumes')) {
    Line '    * 这个包是分卷模式（volumes\*.rar，24 MiB 一卷），刚才已经解开到 pkg 里。'
    Line ('      确认工作台能跑之后，pkg 里解出来的 arduino15 / runtime / npm / payload /')
    Line ('      libraries / ide 都可以删，只留 volumes\ 和脚本 —— 下次安装会重新解压。')
    Line ('      想重新打包分卷：pkg\工具\pack-volumes.ps1 -Verify -Prune')
    Line ''
}
