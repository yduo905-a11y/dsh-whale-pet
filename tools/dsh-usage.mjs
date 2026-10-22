/**
 * DSH 用量接管：把「DeepSeek Harness 每次模型调用花的钱」换算成伤害，注入总线。
 *
 *   node tools/dsh-usage.mjs                 # 常驻（被启动器拉起）
 *   node tools/dsh-usage.mjs --verbose       # 每次命中都打印一行
 *   node tools/dsh-usage.mjs --once          # 只扫一轮就退出（自检用）
 *   node tools/dsh-usage.mjs --replay        # 第一次见到会话文件时把历史用量也打出来
 *
 * 数据源：~/.dsh/storages/session_projcache/sessions/session-<id>.json
 *   .record.rows.tokenUsage.val.totals = { uncachedInputTokens, outputTokens, cacheReadTokens, cacheWriteTokens }
 *   每次模型调用后这个文件会被就地更新（累积值），所以我们只吃「增量」。
 *
 * 计费：core/prices.json 里对应模型的 inputCacheMissPerM / inputCacheHitPerM /
 *       inputCacheWritePerM / outputPerM（每百万 token 单价，元）。
 * 注入：往总线发 { t:'inject', kind:'hit', costCny, model, source:'dsh' }，
 *       和 tools/demo.mjs 一样走核心的档位/连击/余额逻辑，不自己算账。
 */
import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const CONFIG = JSON.parse(fs.readFileSync(path.join(ROOT, 'core', 'config.json'), 'utf8'));
const PRICES = JSON.parse(fs.readFileSync(path.join(ROOT, 'core', 'prices.json'), 'utf8'));

const BUS_HOST = (CONFIG.bus && CONFIG.bus.host) || '127.0.0.1';
const BUS_PORT = Number((CONFIG.bus && CONFIG.bus.port) || 17777);

const args = process.argv.slice(2);
const VERBOSE = args.includes('--verbose');
const ONCE = args.includes('--once');
const REPLAY = args.includes('--replay');

const DSH_DIR = (CONFIG.dsh && CONFIG.dsh.dir) ||
  path.join(os.homedir(), '.dsh', 'storages', 'session_projcache', 'sessions');
const POLL_MS = Number((CONFIG.dsh && CONFIG.dsh.pollMs) || 2000);
const MIN_CNY = Number((CONFIG.dsh && CONFIG.dsh.minCny) || 0.00001);

const LOG = path.join(ROOT, 'logs', 'dsh-usage.log');
function log(line) {
  const s = new Date().toTimeString().slice(0, 8) + ' ' + line;
  try {
    let dir = path.dirname(LOG);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.appendFileSync(LOG, s + '\n', 'utf8');
  } catch { /* 日志写不进去也不能停 */ }
  if (VERBOSE) console.log(s);
}

function priceFor(model) {
  const models = PRICES.models || {};
  const m = models[model] || models[PRICES.defaultModel] || PRICES.fallback || {};
  const usdToCny = Number((CONFIG.currency && CONFIG.currency.usdToCny) || 7.2);
  const scale = Number((CONFIG.currency && CONFIG.currency.scale) || 1);
  const k = (String(m.currency || 'CNY').toUpperCase() === 'USD') ? usdToCny : 1;
  return {
    miss: Number(m.inputCacheMissPerM || 0) * k * scale,
    hit: Number(m.inputCacheHitPerM || 0) * k * scale,
    write: Number(m.inputCacheWritePerM || 0) * k * scale,
    out: Number(m.outputPerM || 0) * k * scale,
  };
}

function costOf(totals, model) {
  const p = priceFor(model);
  return (totals.uncachedInputTokens * p.miss + totals.cacheReadTokens * p.hit +
    totals.cacheWriteTokens * p.write + totals.outputTokens * p.out) / 1e6;
}

// 每个会话文件上次看到的累积值 + 上次算出的花费
const seen = new Map();

function readSession(file) {
  let text;
  try { text = fs.readFileSync(file, 'utf8'); } catch { return null; }
  let obj;
  try { obj = JSON.parse(text); } catch { return null; }
  const rows = (obj && obj.record && obj.record.rows) || {};
  const tu = rows.tokenUsage && rows.tokenUsage.val;
  if (!tu || !tu.totals) return null;
  const t = tu.totals;
  const totals = {
    uncachedInputTokens: Number(t.uncachedInputTokens || 0),
    outputTokens: Number(t.outputTokens || 0),
    cacheReadTokens: Number(t.cacheReadTokens || 0),
    cacheWriteTokens: Number(t.cacheWriteTokens || 0),
  };
  let model = '';
  try { model = rows.modelSelection.val.lastUsed.model || ''; } catch { /* ignore */ }
  return { totals, model };
}

function listSessions() {
  try {
    return fs.readdirSync(DSH_DIR)
      .filter((n) => n.startsWith('session-') && n.endsWith('.json'))
      .map((n) => path.join(DSH_DIR, n));
  } catch (e) {
    log('读不到会话目录 ' + DSH_DIR + '：' + e.message);
    return [];
  }
}

// ---- 总线 ----
let sock = null;
let pending = [];
let connected = false;

function connect() {
  sock = net.connect(BUS_PORT, BUS_HOST, () => {
    connected = true;
    log('[dsh] 已连接核心总线 ' + BUS_HOST + ':' + BUS_PORT + '，开始盯 ' + DSH_DIR);
    for (const m of pending) sock.write(m);
    pending = [];
  });
  sock.on('error', (e) => {
    if (connected) log('[dsh] 总线断开：' + e.message + '（1.5 秒后重连）');
    connected = false;
    pending = [];
    setTimeout(connect, 1500);
  });
  sock.on('close', () => {
    if (connected) log('[dsh] 总线关闭，1.5 秒后重连');
    connected = false;
  });
}

function inject(obj) {
  const line = JSON.stringify(obj) + '\n';
  if (connected && sock && !sock.destroyed) {
    try { sock.write(line); return; } catch { /* fallthrough */ }
  }
  if (pending.length < 200) pending.push(line);
}

// ---- 主循环 ----
function scan() {
  for (const file of listSessions()) {
    const cur = readSession(file);
    if (!cur) continue;
    const prev = seen.get(file);
    if (!prev) {
      // 第一次见到：默认只记基线，不补历史（和 config.watch.replayOnStart 一个思路）
      seen.set(file, { totals: cur.totals, cost: costOf(cur.totals, cur.model) });
      if (REPLAY) {
        const c = costOf(cur.totals, cur.model);
        if (c >= MIN_CNY) {
          log('[dsh] 补历史 ' + path.basename(file).slice(0, 16) + ' ¥' + c.toFixed(4));
          inject({ t: 'inject', kind: 'hit', costCny: c, source: 'dsh', model: cur.model || undefined });
        }
      }
      continue;
    }
    const d = {
      uncachedInputTokens: cur.totals.uncachedInputTokens - prev.totals.uncachedInputTokens,
      outputTokens: cur.totals.outputTokens - prev.totals.outputTokens,
      cacheReadTokens: cur.totals.cacheReadTokens - prev.totals.cacheReadTokens,
      cacheWriteTokens: cur.totals.cacheWriteTokens - prev.totals.cacheWriteTokens,
    };
    if (d.uncachedInputTokens < 0 || d.outputTokens < 0 || d.cacheReadTokens < 0 || d.cacheWriteTokens < 0) {
      // 会话被重置/重建：重记基线
      seen.set(file, { totals: cur.totals, cost: costOf(cur.totals, cur.model) });
      continue;
    }
    if (!d.uncachedInputTokens && !d.outputTokens && !d.cacheReadTokens && !d.cacheWriteTokens) continue;
    const prevCost = prev.cost;
    const nowCost = costOf(cur.totals, cur.model);
    const delta = nowCost - prevCost;
    seen.set(file, { totals: cur.totals, cost: nowCost });
    if (delta < MIN_CNY) continue;
    const id = path.basename(file).slice(8, 16);
    log('[dsh] 命中 ¥' + delta.toFixed(4) + ' ← ' + id +
      ' +' + d.uncachedInputTokens + '新/' + d.cacheReadTokens + '缓存/' + d.outputTokens + '出 ' +
      (cur.model || '?'));
    inject({ t: 'inject', kind: 'hit', costCny: delta, source: 'dsh', model: cur.model || undefined });
  }
}

process.on('SIGTERM', () => { try { sock && sock.end(); } catch { } process.exit(0); });
process.on('SIGINT', () => { try { sock && sock.end(); } catch { } process.exit(0); });

if (!fs.existsSync(DSH_DIR)) {
  log('[dsh] 会话目录不存在：' + DSH_DIR + '（桌宠先照常跑，收到用量再说）');
}

connect();
scan();
if (ONCE) {
  log('[dsh] --once 扫描完成，退出');
  setTimeout(() => process.exit(0), 300);
} else {
  setInterval(scan, POLL_MS);
}
