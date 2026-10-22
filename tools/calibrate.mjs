/**
 * 校准价格：拿真实账单总额反推价格系数。
 *   node tools/calibrate.mjs --real 12.34 --since 2026-09-22T00:00:00Z
 * 输出当前价格表算出来的总额 / 建议的 currency.scale。
 * 用 --since 限定时间窗（对齐你在平台后台看到的区间），不带则统计全部本地记录。
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'core', 'config.json'), 'utf8'));
const PRICES = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'core', CONFIG.pricesFile || 'prices.json'), 'utf8'));
const FX = Number((CONFIG.currency && CONFIG.currency.usdToCny) || 7.2);

const args = process.argv.slice(2);
const val = (n, d) => { const i = args.indexOf(n); return i >= 0 ? args[i + 1] : d; };
const real = Number(val('--real', 0));
const sinceArg = val('--since', null);
const since = sinceArg ? Date.parse(sinceArg) : 0;
const verbose = args.includes('--verbose');

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
  return miss * per(p.inputCacheMissPerM) + hit * per(p.inputCacheHitPerM) + write * per(p.inputCacheWritePerM) + out * per(p.outputPerM);
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

const codexRoot = path.join(String(CONFIG.codexHome || path.join(os.homedir(), '.codex')).replace(/\\/g, '/'), 'sessions');
const buckets = { miss: 0, hit: 0, write: 0, out: 0 };
let total = 0, lines = 0, model = PRICES.defaultModel;

for (const f of walk(codexRoot)) {
  let content = '';
  try { content = fs.readFileSync(f, 'utf8'); } catch { continue; }
  for (const line of content.split('\n')) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.type === 'turn_context' && o.payload && o.payload.model) model = o.payload.model;
    if (o.type === 'session_meta' && o.payload && o.payload.model) model = o.payload.model;
    if (o.type !== 'token_usage_record' || !o.payload || !o.payload.usage) continue;
    const ts = Date.parse(o.timestamp || '') || 0;
    if (since && ts < since) continue;
    const u = o.payload.usage;
    const hit = Number(u.cached_input_tokens || 0);
    const write = Number(u.cache_write_input_tokens || 0);
    const input = Number(u.input_tokens || 0);
    buckets.miss += Math.max(0, input - hit - write);
    buckets.hit += hit;
    buckets.write += write;
    buckets.out += Number(u.output_tokens || 0);
    total += costOf(u, model);
    lines++;
  }
}

console.log('区间起点 : ' + (since ? new Date(since).toISOString() : '(全部)'));
console.log('记录条数 : ' + lines);
console.log('token 桶 : miss=' + buckets.miss + ' hit=' + buckets.hit + ' write=' + buckets.write + ' out=' + buckets.out);
console.log('当前价格表算出 : ' + total.toFixed(4) + ' CNY');
if (real > 0) {
  console.log('真实账单      : ' + real.toFixed(4) + ' CNY');
  console.log('建议 scale    : ' + (real / total).toFixed(4) + '   <- 写进 core/config.json 的 currency.scale');
} else {
  console.log('（加 --real <账单金额> 可得到建议 scale）');
}
if (verbose) console.log('使用模型:', model);
