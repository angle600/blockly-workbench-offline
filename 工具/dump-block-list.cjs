// ---------------------------------------------------------------------------
// dump-block-list.cjs — 生成「积木位号清单.md」
// ---------------------------------------------------------------------------
// 用途：不开界面就能核对「哪些积木有位号下拉、每块板给几项、默认落在哪个脚」。
// 数据来源是打包好的 app\dist\blockly-bundle.js —— 跟界面上用的完全是同一份，
// 不是另抄一份表（抄的表迟早和代码对不上）。
//
// 用法（在任意目录）：
//     <node> pkg\工具\dump-block-list.cjs
//     <node> pkg\工具\dump-block-list.cjs --out D:\某处\清单.md
//
// node 用项目自带的即可：tools\node\node.exe
// 依赖 jsdom —— 在 app\node_modules 里（开发机上有；安装到别的机器后可能没有，
// 那时这份清单已经生成好了，不需要再跑）。
// ---------------------------------------------------------------------------
'use strict';

const fs = require('fs');
const path = require('path');

const PKG_ROOT = path.join(__dirname, '..');
const ROOT = path.join(PKG_ROOT, '..');

// bundle 可能在两个地方：开发机的 app\dist，或解压出来的 payload\app\dist
const CANDIDATES = [
  path.join(ROOT, 'app', 'dist', 'blockly-bundle.js'),
  path.join(PKG_ROOT, 'payload', 'app', 'dist', 'blockly-bundle.js'),
  path.join(PKG_ROOT, 'app', 'dist', 'blockly-bundle.js'),
];
const bundle = CANDIDATES.find((p) => fs.existsSync(p));
if (!bundle) {
  console.error('找不到 blockly-bundle.js，试过：');
  CANDIDATES.forEach((p) => console.error('  ' + p));
  process.exit(1);
}

// jsdom 要么在 app\node_modules，要么在 pkg\npm\node_modules
function loadJsdom() {
  const tries = [
    path.join(path.dirname(bundle), '..', 'node_modules', 'jsdom'),
    path.join(ROOT, 'app', 'node_modules', 'jsdom'),
    path.join(PKG_ROOT, 'npm', 'node_modules', 'jsdom'),
  ];
  for (const t of tries) {
    try { return require(t); } catch (e) { /* 下一个 */ }
  }
  try { return require('jsdom'); } catch (e) { /* 最后的希望 */ }
  console.error('找不到 jsdom。在 app 目录下跑：<node> ..\\pkg\\工具\\dump-block-list.cjs');
  process.exit(1);
}

const { JSDOM } = loadJsdom();
const dom = new JSDOM('<!DOCTYPE html><html><body></body></html>', {
  runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/',
});
dom.window.SVGSVGElement.prototype.createSVGRect = function () {};
dom.window.eval(fs.readFileSync(bundle, 'utf8'));
const B = dom.window.Blockly;
const P = dom.window.BlocklyArduino.pins;

const BOARDS = [
  ['uno', 'Uno'],
  ['pico', 'Pico'],
  ['picow', 'Pico W'],
  ['pico2', 'Pico 2'],
  ['esp32s3', 'S3'],
];

// 枚举带 PIN 字段的电子积木（和 verify-pins.cjs 同一个口径）
const types = [];
const probe = new B.Workspace();
Object.keys(B.Blocks).sort().forEach((t) => {
  if (!/^(inout_|servo_|grove_|irq_)/.test(t)) return;
  let b;
  try { b = probe.newBlock(t); } catch (e) { return; }
  const f = b.getField && b.getField('PIN');
  if (f) types.push(t);
  b.dispose();
});
probe.dispose();

const rows = types.map((t) => {
  const cells = BOARDS.map(([k]) => {
    P.setBoard(k);
    const ws = new B.Workspace();
    let cell = '—';
    try {
      const b = ws.newBlock(t);
      const f = b.getField('PIN');
      const n = (f.getOptions(true) || []).length;
      cell = n + ' 项 / 默认 ' + String(f.getValue());
    } catch (e) {
      cell = '【报错】';
    }
    ws.dispose();
    return cell;
  });
  return '| `' + t + '` | ' + cells.join(' | ') + ' |';
});

const boardTable = BOARDS.map(([k, name]) => {
  P.setBoard(k);
  const p = P.PROFILES[k];
  return '| ' + name + ' | ' + p.digital.length + ' 项 | ' + p.analog.length + ' 项 | ' +
    p.pwm.length + ' 项 | ' + (p.irq ? p.irq.length : 0) + ' 项 |';
});

const now = new Date();
const stamp = now.getFullYear() + '-' +
  String(now.getMonth() + 1).padStart(2, '0') + '-' +
  String(now.getDate()).padStart(2, '0') + ' ' +
  String(now.getHours()).padStart(2, '0') + ':' +
  String(now.getMinutes()).padStart(2, '0');

const lines = [
  '# 积木位号清单',
  '',
  '> 自动生成于 ' + stamp + '，数据来自 `' + path.relative(ROOT, bundle).split(path.sep).join('\\') + '`。',
  '> 表里是「PIN 下拉给几项 / 新拖出来默认落在哪个脚」，界面里跟着顶栏板型实时变。',
  '> 重新生成：`<node> pkg\\工具\\dump-block-list.cjs`',
  '',
  '## 带位号下拉的电子积木（' + types.length + ' 块）',
  '',
  '| 积木类型 | ' + BOARDS.map((x) => x[1]).join(' | ') + ' |',
  '| --- | ' + BOARDS.map(() => '---').join(' | ') + ' |',
  ...rows,
  '',
  '## 各板位号表规模',
  '',
  '| 板型 | 数字口 | ADC（模拟读） | PWM（模拟写 / 占空比 / 频率） | 外部中断 |',
  '| --- | --- | --- | --- | --- |',
  ...boardTable,
  '',
  '## 几个容易踩的点',
  '',
  '- **Uno 的 PWM 只有 3/5/6/9/10/11**（六个）。4、7、13 上写 `analogWrite` 只会变成高低电平。',
  '- **Uno 的 ADC 只有 A0~A5**。ESP32-S3 只给 ADC1（GP1~GP10 = A0~A9）；ADC2（GP11~GP20）与 WiFi 共用，读数不可靠所以不给。',
  '- **Uno 的外部中断只有 2/3**（INT0/INT1），其它脚 `digitalPinToInterrupt()` 返回 -1，静默失效。',
  '- **ESP32-S3 没有 GP22~GP37**：22-25 芯片上不存在，26-37 归 Flash/PSRAM。',
  '- **Pico 的模拟表只有 A0~A2**：GP29 是板内 VSYS 采样，40 针排针上接不到。',
  '- **舵机占 Timer1（Uno 的 9/10）、蜂鸣器占 Timer2（3/11）**，撞上时编译日志会打中文 `#pragma message`。',
  '- **Uno 的 PWM 频率改不了**（3/9/10/11 ≈ 490Hz、5/6 ≈ 980Hz），「PWM 频率」积木会提示而不是静默忽略。',
  '',
];

const outIdx = process.argv.indexOf('--out');
const outPath = outIdx >= 0 && process.argv[outIdx + 1]
  ? process.argv[outIdx + 1]
  : path.join(PKG_ROOT, '积木清单.md');

fs.writeFileSync(outPath, lines.join('\n'), 'utf8');
console.log('已生成 ' + outPath);
console.log('  ' + types.length + ' 块积木 × ' + BOARDS.length + ' 块板');
