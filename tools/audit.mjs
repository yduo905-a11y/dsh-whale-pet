/**
 * 对账工具：查「有没有花钱了但没打出伤害数字」的漏记录
 *   node tools\audit.mjs                 # 扫全部会话文件
 *   node tools\audit.mjs --since 2026-09-26T00:00:00Z
 *   node tools\audit.mjs --top 30        # 列出最贵的 N 条记录
 *
 * 输出：理论应显示多少发 / 我们实际记了多少发 / 差在哪（按文件、按时间）
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, 'core', 'config.json'), 'utf8'));
const PRICES = JSON.parse(fs.readFileSync(path.join(ROOT, 'core', CONFIG.pricesFile || 'prices.json'), 'utf8'));
const FX = Number((CONFIG.currency && CONFIG.currency.usdToCny) || 7.2);
const SCALE = Number((CONFIG.currency && CONFIG.currency.scale) || 1);

const args = process.argv.slice(2);
const val = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const since = val('--since', null) ? Date.parse(val('--since', null)) : 0;
const topN = Number(val('--top', 12));

function priceFor(model) {
  const m = PRICES.models || {};
  return m[model] || m[PRICES.defaultModel] || PRICES.fallback;
}
function costOf(usage, model) {
  const p = priceFor(model);
  const input = Number(usage.input_tokens || 0);
  const hit = Number(usage.cached_input_tokens || usage.cache_read_input_tokens || 0);
  const write = Number(usage.cache_write_input_tokens || usage.cache_creation_input_tokens || 0);
  const out = Number(usage.output_tokens || 0);
  const miss = Math.max(0, input - hit - write);
  const usd = String(p.currency || 'CNY').toUpperCase() === 'USD';
  const per = (v) => (usd ? Number(v) * FX : Number(v)) / 1e6;
  return (miss * per(p.inputCacheMissPerM) + hit * per(p.inputCacheHitPerM)
    + write * per(p.inputCacheWritePerM) + out * per(p.outputPerM)) * SCALE;
}

function walk(root, out = [], depth = 0) {
  if (depth > 6) return out;
  let es = [];
  try { es = fs.readdirSync(root, { withFileTypes: true }); } catch { return out; }
  for (const e of es) {
    const p = path.join(root, e.name);
    if (e.isDirectory()) walk(p, out, depth + 1);
    else if (e.isFile() && e.name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

const sessionsRoot = path.join(String(CONFIG.codexHome || path.join(os.homedir(), '.codex')).replace(/\\/g, '/'), 'sessions');
const files = walk(sessionsRoot);

const recs = [];              // 全部 token_usage_record
const perFile = new Map();
for (const f of files) {
  let content = '';
  try { content = fs.readFileSync(f, 'utf8'); } catch { continue; }
  let model = PRICES.defaultModel || 'deepseek-flash';
  let n = 0, sum = 0, firstTs = 0, lastTs = 0;
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let o;
    try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'turn_context' && o.payload && o.payload.model) model = o.payload.model;
    if (o.type === 'session_meta' && o.payload && o.payload.model) model = o.payload.model;
    if (o.type !== 'token_usage_record' || !o.payload || !o.payload.usage) continue;
    const ts = Date.parse(o.timestamp || '') || 0;
    const cost = costOf(o.payload.usage, model);
    n++; sum += cost;
    if (!firstTs) firstTs = ts;
    lastTs = ts;
    recs.push({ file: path.basename(f), ts, model, cost, usage: o.payload.usage, rid: o.payload.response_id || o.payload.turn_id || '' });
  }
  if (n > 0) perFile.set(path.basename(f), { n, sum, firstTs, lastTs });
}

recs.sort((a, b) => a.ts - b.ts);
const filtered = since ? recs.filter(r => r.ts >= since) : recs;
const totalAll = recs.reduce((s, r) => s + r.cost, 0);
const totalWin = filtered.reduce((s, r) => s + r.cost, 0);
const zeroCost = filtered.filter(r => r.cost <= 0);

// 我们的账本
let state = {};
try { state = JSON.parse(fs.readFileSync(path.join(ROOT, 'core', 'state.json'), 'utf8')); } catch { }
const startedAt = Number(state.sessionStartedAt || 0);
const ours = { hits: Number(state.hits || 0), spent: Number(state.totalSpentCny || 0) };
const afterStart = recs.filter(r => startedAt && r.ts >= startedAt);
const afterStartSum = afterStart.reduce((s, r) => s + r.cost, 0);

const f = (v) => (v).toFixed(4);
const t = (ms) => ms ? new Date(ms).toLocaleString('zh-CN') : '-';

console.log('=== dsh-overlay 伤害对账 ===');
console.log('会话目录        :', sessionsRoot);
console.log('扫描文件数      :', files.length);
console.log('token 记录总数  :', recs.length, ' 理论总费用:', f(totalAll), 'CNY');
if (since) console.log('窗口起点        :', new Date(since).toLocaleString('zh-CN'),
  ' 窗口内记录:', filtered.length, ' 理论费用:', f(totalWin), 'CNY');
console.log('');
console.log('--- 账本现状（core\\state.json）---');
console.log('本次核心启动时间 :', t(startedAt));
console.log('账本命中次数     :', ours.hits);
console.log('账本累计费用     :', f(ours.spent), 'CNY');
console.log('启动之后的理论记录:', afterStart.length, ' 理论费用:', f(afterStartSum), 'CNY');
const lr = state.lastRun || null;
if (lr) {
  const inRun = recs.filter(r => r.ts >= Number(lr.startedAt || 0));
  const known = new Set(state.seenResponseIds || []);
  const missing = inRun.filter(r => !r.rid || !known.has(r.rid));
  console.log('');
  console.log('--- 最近一次运行（core 自检）---');
  console.log('运行起点        :', t(Number(lr.startedAt || 0)));
  console.log('核心读到 token 记录:', lr.seen, ' 其中生成伤害:', lr.hits, ' 0费用跳过:', lr.zeroCost,
    ' 解析失败:', lr.parseFail, ' 重读去重:', (lr.dedupe || 0));
  console.log('同一时间窗内文件里实际有:', inRun.length, '条');
  console.log(missing.length === 0
    ? '结论             : ✅ 这个时间窗里的记录全部处理过（没有漏账）'
    : '结论             : ⚠️ 有 ' + missing.length + ' 条从未被处理（漏账），明细：');
  if (missing.length) {
    for (const m of missing.slice(0, 10)) {
      console.log('   - ' + f(m.cost) + ' CNY  ' + t(m.ts) + '  ' + m.file.slice(0, 34) + '  rid=' + (m.rid || '(无)'));
    }
    console.log('     （多半是核心没在跑的那段时间写下的；想补历史把 config.watch.replayOnStart 改成 true 再启动一次）');
  }
  const gap = lr.seen - lr.hits - lr.zeroCost;
  console.log(gap === 0 ? '                   ✅ 读到的记录全都变成了伤害数字' : '                   ⚠️ 读到但没生成伤害: ' + gap + ' 条');
}
if (startedAt) {
  console.log('');
  console.log('--- 账本累计 vs 本机全部记录（价格校准参考）---');
  console.log('账本累计费用    :', f(ours.spent), 'CNY（跨多次启动累积，含重置前）');
  console.log('本机全部理论费用:', f(totalAll), 'CNY');
  console.log('提示            : 两者口径不同（账本从某次启动开始记），差得多就说明价格表要校准：');
  console.log('                  node tools\\calibrate.mjs --real <平台账单金额> --since <起始时间>');
}
console.log('');
console.log('--- 不会被显示成伤害的（按设计或漏掉）---');
console.log('启动前就已存在   :', recs.filter(r => startedAt && r.ts < startedAt).length, '条（replayOnStart=false 不补历史）');
console.log('费用为 0 的记录  :', zeroCost.length, '条（cached 命中且单价为 0 时才会出现）');
if (zeroCost.length) for (const r of zeroCost.slice(0, 5)) console.log('   -', r.file, t(r.ts), JSON.stringify(r.usage));
console.log('');
console.log('--- 各文件明细 ---');
[...perFile.entries()].sort((a, b) => b[1].sum - a[1].sum).slice(0, 15).forEach(([name, v]) => {
  console.log(`  ${name.slice(0, 60).padEnd(62)} 记录 ${String(v.n).padStart(4)}  费用 ${f(v.sum).padStart(9)}  首条 ${t(v.firstTs)}`);
});
console.log('');
console.log(`--- 最贵的 ${topN} 条记录 ---`);
recs.slice().sort((a, b) => b.cost - a.cost).slice(0, topN).forEach(r => {
  console.log(`  ${f(r.cost).padStart(9)} CNY  ${t(r.ts)}  ${r.file.slice(0, 30)}  in=${r.usage.input_tokens} cached=${r.usage.cached_input_tokens} out=${r.usage.output_tokens}  ${r.model}`);
});
