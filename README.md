# Blockly 可视化编程工作台 · 离线安装包

拖积木出 Arduino C++ 代码，一键编译烧录。支持 **Raspberry Pi Pico / Pico W / Pico 2 /
Arduino Uno R3 / ESP32-S3**，插上就能用，**全程不需要联网**。

| 项 | 值 |
| --- | --- |
| 包版本 | 1.3.0 |
| 包大小 | 1.88 GB（1,925 MiB · 85 个 24 MiB 分卷） |
| 装完占用 | 约 8.3 GB（含三套板卡核心与工具链） |
| 系统要求 | Windows 10 / 11 64 位，需要 9 GB 以上空闲磁盘 |
| 联网 | 不需要。板卡核心、外置库、Node 运行时、离线依赖全在包里 |

---

## 一、安装方法

### 1. 最简单：双击

```
双击  pkg\一键安装.cmd
```

脚本会自己判断装哪儿：

| 情况 | 行为 |
| --- | --- |
| pkg 里只有 `volumes\*.rar`（当前形态） | 先把分卷解压回 `pkg\`（**约 10 分钟**，见下方说明） |
| pkg 就在一个已装好的工作台里 | 就地安装 / 修复，缺什么补什么，不重拷 8 GB 核心 |
| pkg 被单独拷到别处 | 装到 `D:\Program Files\Blockly`（没有 D 盘则用系统盘 `\Blockly`） |

**关于那 10 分钟**：包是按 24 MiB 一卷压过的，安装前要先解开成真实目录才能用。
解压是一次性的 —— 已经解开的目录会跳过，重装不会再等。它占的是 pkg 自己的空间，
装完想回收见「三、删除方法」第 2 节。

> **pkg 必须放在可写位置**。解压是写回 pkg 原地，写保护的 U 盘 / 只读网络盘会失败。
> 遇到这个情况，先把整个 pkg 拷到本地硬盘再装。

### 2. 装到别的位置

```cmd
:: 装到指定目录
pkg\一键安装.cmd -Target "E:\Tools\Blockly"

:: 跳过最后那步自检（更快，但少一道验证）
pkg\一键安装.cmd -SkipVerify

:: 不装 Arduino IDE（省 540 MB 和几分钟）
pkg\一键安装.cmd -NoIde
```

也可以直接调 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File "pkg\install.ps1" -Target "E:\Tools\Blockly"
```

### 3. 安装过程做了什么

1. **解开分卷** —— 把 `volumes\*.rar` 还原成 `arduino15 / runtime / npm / payload / libraries / ide`
2. **预检** —— 逐项确认 Node、arduino-cli、板卡核心、离线依赖、工作台源码都在
3. **铺源码** —— `payload\app` 等铺到目标目录；同名文件内容相同就跳过，不同会先备份到 `.pkg-backup\`
4. **部署运行时** —— `tools\node\node.exe`、`tools\arduino-cli\arduino-cli.exe`
5. **部署核心** —— `arduino:avr 1.8.8` / `esp32 3.3.12` / `rp2040 6.3.1` 共 80900 个文件
6. **部署外置库** —— Servo / ESP32Servo / SerialLCD / EspSoftwareSerial / ghostl / PubSubClient
7. **写配置** —— `arduino15\arduino-cli.yaml`，数据目录指向工作台自己的 `arduino15`
8. **装 IDE（可选）** —— 解压 Arduino IDE 2.3.10，并把它和本包的核心用目录联接打通
9. **自检** —— 跑一遍 headless 测试（生成器 + 引脚表），应显示 `ALL PASS`

### 4. 装完怎么确认

安装结束会打印三行关键信息：

```
[+] arduino:avr   1.8.8    1.8.8  Arduino AVR Boards
[+] esp32:esp32   3.3.12   3.3.12 esp32
[+] rp2040:rp2040 6.3.1    6.3.1  Raspberry Pi Pico/RP2040/RP2350
[+] 板卡核心      3 / 3 就绪
[+] 外置库        5 / 5 就绪
[+] 自检通过
```

三行核心都在、自检通过，就说明装好了。

---

## 二、使用方法

### 1. 打开工作台

```
双击  桌面\Blockly 工作台\Start-Workbench.cmd
或    直接双击安装目录里的 Start-Workbench.cmd
```

浏览器会自动打开 **http://127.0.0.1:8765/**。关掉那个黑窗口就是退出。

### 2. 先选板型（很重要）

工具栏右上角有个板型下拉：**Pico / Pico W / Pico 2 / UNO / ESP32-S3 / ESP32-S3·USB**。

**所有积木的引脚下拉都会跟着板型变**：Uno 上你只能选 `0~13` 和 `A0~A5`，
Pico 上则是 `GP0~GP28`。换板型时，已有积木的引脚会自动映射到新板能用的脚上
（映射了哪些会在状态栏告诉你）。

所以：**先选板型，再拖积木**。反过来的话引脚会被改掉。

### 3. 一个最小例子：让 Pico 上的 LED 闪

1. 板型选 **Pico**
2. 从「事件 Events」拖「当开始时」→ 从「引脚 Pin」拖「数字输出 引脚 15 高」
3. 从「Timing 时间」拖「等待 500 毫秒」→ 再来一个「数字输出 15 低」→「等待 500 毫秒」
4. 把这几块都塞进「一直重复」
5. 右侧自动出代码，点 **编译并烧录**
6. 插上 Pico（按住 BOOTSEL 再插，或直接插也可以）→ 选串口 → 烧

**能调试的地方**：右侧代码区实时生成，看得到每一块拼出了什么。

### 4. 引脚相关的三个坑（工具已经帮你挡了大部分）

| 坑 | 表现 | 工具怎么处理 |
| --- | --- | --- |
| Uno 只有 6 个 PWM 脚 | 4/7/13 上写 PWM 灯不亮 | PWM 下拉里只给 `3/5/6/9/10/11` |
| 舵机抢 Timer1、蜂鸣器抢 Timer2 | 用了舵机，9/10 的 PWM 悄悄失效 | 编译日志打中文 `#pragma message` 提示 |
| ESP32-S3 的 GP22~37 不可用 | 接上去没反应，或板子起不来 | 下拉里直接不出现 |

完整位号表（35 块积木 × 5 块板）见 **`pkg\积木清单.md`**。

### 5. 里面都有什么

- **35 块带位号下拉的电子积木** + 串口 / 时间 / 数学 / 文本 / 事件 / 函数 / 网络 / BLE / USB 键盘鼠标等
- **示例工程**：`examples\`（Uno 点灯、Pico IO、ESP32 联网等）
- **示例积木文件**：`samples\`（拖进界面就能打开）
- **MicroPython 视图**：同一份积木可以生成 Python 并烧进板子
- **帮助**：每块积木右键有说明；README 里有逐板型的引脚对照

### 6. 改了代码想更新界面

改完 `app\` 下的源码，需要重新打包前端：

```cmd
cd /d "D:\Program Files\Blockly\app"
..\tools\node\node.exe build.mjs
```

然后浏览器 **Ctrl+F5** 强刷。

> 如果改的是 **pkg 里那份源码**、想让安装包也跟着更新：双击 `pkg\更新安装包.cmd`。
> 它只重打 `payload.rar`（约 5 MB / 40 秒），**不会**碰那 8 GB 板卡核心。

---

## 三、删除方法

### 1. 一键卸载（推荐）

```
双击  pkg\一键删除.cmd
```

它会：

1. 找出工作台装在哪（读安装记录，没有就扫默认位置）
2. **列出要删的每一项和体积**，让你看清楚
3. 要你**亲手输入 `YES`** 才动手（输别的就取消）
4. 删完之后问一句：pkg 里解压出来的 8.5 GB 要不要一起回收

**想先看看会删什么、不真删**：

```cmd
pkg\一键删除.cmd -DryRun
```

**装在了自定义位置**：

```cmd
pkg\一键删除.cmd -Target "E:\Tools\Blockly"
```

### 2. 只回收空间，不卸载

装完之后 pkg 里会多出解压出来的 8.5 GB（`arduino15 / runtime / npm / payload / libraries / ide`）。
只想把这部分清掉、工作台继续用：

```cmd
pkg\一键删除.cmd -CleanPkgOnly
```

删完 pkg 回到 1.88 GB（只剩分卷和脚本），下次安装会重新解压（再等 10 分钟）。
也可以手动删那几个目录，效果一样。

### 3. 不想跑脚本，手动删

> 先把 `designs\`（积木设计）和 `exports\`（导出的 .ino）拷出来，否则会一起删掉。

1. 删掉安装目录（默认 `D:\Program Files\Blockly`）
2. 删掉桌面和开始菜单里的 `Arduino IDE 2.3.10.lnk`（如果你装过 IDE）
3. 如果装过 IDE，还要删 `%LOCALAPPDATA%\Arduino15\packages` 下指向工作台的三个联接
   （`arduino` / `esp32` / `rp2040`，都是目录联接，删链接不会动目标内容）

> 安装时会在安装目录写一个 `.blockly-install.json`，记着「装在哪、什么时候装的、从哪个 pkg 装的」。
> 一键删除就是靠它找到位置的；手动删时一起删掉即可。

### 4. 卸载会删什么、不会删什么

| 会删 | 不会删（脚本特意保护） |
| --- | --- |
| 安装目录里的 `app` `tools` `arduino15` `arduino-user` `examples` `static` `modules` `build` `firmware` `sch` | **`pkg\`** —— 安装包本体（除非加 `-IncludePkg`） |
| `.pkg-backup`（安装时覆盖前的旧文件备份） | **`designs\`** —— 你自己存的积木设计 |
| 桌面 / 开始菜单的 IDE 快捷方式 | **`exports\`** —— 你导出的 `.ino` 工程 |
| `%LOCALAPPDATA%\Arduino15\packages` 下的联接（手动步骤） | **`samples\`** —— 你自己加的示例 |
| | **`.workbuddy\`** —— 开发过程记录 |
| | `volumes\*.rar`（分卷）+ 包内脚本 |

被保护的那几项，脚本会逐条标成 `[保留·用户数据]` 或 `[保留·pkg（安装包本体）]` 列出来，
删完还会再提示一遍「这些没删，确实不要了可以自己手动删」。

> ⚠️ **pkg 就在安装目录里时**（现在的形态：`D:\Program Files\Blockly\pkg`），
> 卸载默认**保留 pkg**，只清掉工作台其余内容。真要连 pkg 一起删：
> `pkg\一键删除.cmd -IncludePkg` —— 删了就没有安装包了，下次得重新要一份。

---

## 四、常见问题

**装完打开是空白页 / 一直转圈**
看那个黑窗口有没有报错。多半是端口被占用，关掉重复启动的窗口，或改端口：
`set PORT=8766` 再启动。

**编译报 `Platform 'arduino:avr' not found`**
板卡核心没找到。检查 `<安装目录>\arduino15\packages\` 下有没有 `arduino`、`esp32`、`rp2040`。
如果是你把 pkg 压成 volumes 之后核心不见了，重跑一次 `一键安装.cmd` 让它解压回来。

**编译报 `Access is denied`（写不进去）**
装到了 `C:\Program Files` 这类需要管理员的地方。要么右键「以管理员身份运行」，
要么换到普通目录装（推荐 `D:\Program Files\Blockly`）。

**卸载提示「删不掉」**
工作台窗口还开着、Arduino IDE 还开着、或者杀软在扫。全部关掉再双击一次。

**装 IDE 报 `Access to 'D:\Arduino IDE 2.3.10\Arduino IDE.exe' is denied`**
那个目录已存在且文件被占用（IDE 正在运行）。跳过 IDE 完全不影响工作台使用，
也可以关掉 IDE 后重装。

**安装很慢 / 卡在「解开 arduino15」**
8.1 GB 解压约 10 分钟，属正常。机械硬盘会更久。

---

## 五、目录结构

```
pkg\
├─ 一键安装.cmd          ← 双击安装
├─ 一键删除.cmd          ← 双击卸载 / 清理
├─ 更新安装包.cmd        ← 改了源码后，把改动收进安装包
├─ README.md             ← 本文件
├─ 安装说明.md           ← 更细的安装/目录说明（含踩坑记录）
├─ 积木清单.md           ← 35 块积木 × 5 块板的位号表
├─ install.ps1           安装主逻辑（含分卷还原）
├─ uninstall.ps1         卸载主逻辑
├─ manifest.json         版本 / 时间 / 各部分体积
├─ volumes\              85 个 24 MiB 分卷（安装时自动解开）
├─ config\               arduino-cli 配置模板
└─ 工具\
    ├─ UnRAR.exe         解压分卷（目标机不用装 WinRAR）
    ├─ pack-volumes.ps1  重新打包分卷
    ├─ verify-volumes.ps1 删源前校验分卷完整性
    ├─ dump-block-list.cjs 重新生成「积木清单.md」
    └─ 导入旧Arduino15 系列  把旧账户的 Arduino 环境并进来
```

---

**许可**：本包内的 Arduino 板卡核心、工具链、外置库分别遵循其原项目许可
（arduino:avr / esp32 / rp2040 为 LGPL 或 Apache-2.0，各库见其 `library.properties`）。
UnRAR.exe 可自由分发，但不得用于重建 RAR 压缩算法。
