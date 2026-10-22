/**
 * dsh-overlay 核心：账本总线
 *   - tail Codex rollout jsonl 里的 token_usage_record（以及 Claude Code 的 usage 行）
 *   - 按价格表折算人民币，扣余额，算连击
 *   - 通过 127.0.0.1 TCP 用 NDJSON 广播给浮层插件
 * 零依赖，只用 Node 内置模块。需要 Node >= 18。
 */
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = path.join(HERE, 'config.json');
const argv = new Set(process.argv.slice(2));
const VERBOSE = argv.has('--verbose') || argv.has('-v');
const CORE_STARTED_TS = Date.now();

function loadJson(p, fallback) {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    if (fallback !== undefined) return fallback;
    throw e;
  }
}

const CONFIG = loadJson(CONFIG_PATH);
const PRICES = loadJson(path.join(HERE, CONFIG.pricesFile || 'prices.json'));
const STATE_PATH = path.join(HERE, CONFIG.balance && CONFIG.balance.persistFile ? CONFIG.balance.persistFile : 'state.json');
const FX = Number((CONFIG.currency && CONFIG.currency.usdToCny) || 7.2);
const SCALE = Number((CONFIG.currency && CONFIG.currency.scale) || 1);
const START_BALANCE = Number((CONFIG.balance && CONFIG.balance.startCny) || 100);
const DECIMALS = Number((CONFIG.display && CONFIG.display.decimals) || 4);
const SYMBOL = (CONFIG.currency && CONFIG.currency.symbol) || '¥';
let BALANCE_MODE = (CONFIG.balance && CONFIG.balance.mode) || 'ledger';

const LOG_PATH = path.join(HERE, '..', 'logs', 'core.log');
try { fs.mkdirSync(path.dirname(LOG_PATH), { recursive: true }); } catch (e) { /* 忽略 */ }

function log() {
  const line = new Date().toISOString().slice(11, 19) + ' ' + Array.from(arguments).join(' ');
  console.log(line);
  // 同时落盘：用无窗口方式启动时没有控制台，日志全靠这里
  try { fs.appendFileSync(LOG_PATH, line + '\n'); } catch (e) { /* 忽略 */ }
}

/* ---------------------------------------------------------------- real balance */
let apiKeyOverride = null;
let balancePollTimer = null;

function loadApiKey() {
  if (apiKeyOverride) return apiKeyOverride;
  const c = CONFIG.balance && CONFIG.balance.api;
  if (!c) return '';
  if (c.apiKey) return c.apiKey;
  if (process.env.DEEPSEEK_API_KEY) return process.env.DEEPSEEK_API_KEY;
  // 兜底：从 Codex 的 config.toml 里读 deepseek 的 bearer token（本机已配置）
  try {
    const home = CONFIG.codexHome || path.join(os.homedir(), '.codex');
    const toml = fs.readFileSync(path.join(home, 'config.toml'), 'utf8');
    const m = toml.match(/experimental_bearer_token\s*=\s*"([^"]+)"/);
    if (m) return m[1];
  } catch (e) { /* 忽略 */ }
  return '';
}

function startBalancePolling() {
  if (balancePollTimer) return;
  fetchRealBalance();
  balancePollTimer = setInterval(fetchRealBalance, Math.max(5000, Number((CONFIG.balance.api && CONFIG.balance.api.pollMs) || 30000)));
  log('真实余额轮询已启动');
}

async function fetchRealBalance() {
  const c = CONFIG.balance && CONFIG.balance.api;
  if (!c) return;
  const key = loadApiKey();
  if (!key) { log('真实余额：没找到 API key（DEEPSEEK_API_KEY / config.toml / config.balance.api.apiKey）'); return; }
  try {
    const res = await fetch(c.url, {
      headers: { 'Authorization': 'Bearer ' + key, 'Accept': 'application/json' },
      signal: AbortSignal.timeout(Number(c.timeoutMs || 8000))
    });
    if (!res.ok) { log('真实余额 http ' + res.status); return; }
    const data = await res.json();
    const list = data.balance_infos || [];
    const info = list.find(function (b) { return b.currency === (c.currency || 'CNY'); }) || list[0];
    if (info && Number.isFinite(Number(info.total_balance))) {
      state.realBalanceCny = Number(info.total_balance);
      state.realToppedUpCny = Number(info.topped_up_balance || info.total_balance);
      state.realGrantedCny = Number(info.granted_balance || 0);
      // 「已烧」用「见过的最高余额 - 当前余额」算：充值/赠送都适用（充值后自动归零重算）
      const prevMax = Number(state.realBalanceMaxCny || state.realBalanceCny);
      state.realBalanceMaxCny = Math.max(prevMax, state.realBalanceCny);
      state.realSpentCny = Math.max(0, state.realBalanceMaxCny - state.realBalanceCny);
      state.realBalanceAt = now();
      broadcast(Object.assign({ t: 'balance' }, publicState()));
      log('真实余额 =', state.realBalanceCny.toFixed(4), '已烧 =', state.realSpentCny.toFixed(4), info.currency || c.currency);
    } else {
      log('真实余额：响应里没找到 balance_infos');
    }
  } catch (e) {
    log('真实余额拉取失败:', e.message);
  }
}
function vlog() { if (VERBOSE) log.apply(null, arguments); }
const now = () => Date.now();

/* ---------------------------------------------------------------- state */
const state = Object.assign({
  balanceCny: START_BALANCE,
  totalSpentCny: 0,
  hits: 0,
  combo: 0,
  maxCombo: 0,
  lastHitAt: 0,
  sessionStartedAt: now(),
  updatedAt: now()
}, loadJson(STATE_PATH, {}));
state.sessionStartedAt = now();

// 本次运行的「有没有漏账」计数（每轮刷新到 state.json，对账工具直接读）
state.lastRun = {
  startedAt: state.sessionStartedAt,
  seen: 0,          // 读到的 token_usage_record 条数
  hits: 0,          // 变成伤害数字的条数
  zeroCost: 0,      // 算出来费用为 0 被跳过的
  parseFail: 0,     // JSON 解析失败的行
  dedupe: 0         // 重复读到的（启动时重读尾巴那段）
};
// 处理过的记录 id（用 response_id 去重），防止启动时重读尾巴造成重复伤害
state.seenResponseIds = state.seenResponseIds || [];

let persistTimer = null;
function persist() {
  if (persistTimer) return;
  persistTimer = setTimeout(function () {
    persistTimer = null;
    state.updatedAt = now();
    try { fs.writeFileSync(STATE_PATH, JSON.stringify(state, null, 2)); }
    catch (e) { log('persist failed:', e.message); }
  }, 800);
}

/* ---------------------------------------------------------------- pricing */
function priceFor(model) {
  const m = PRICES.models || {};
  return m[model] || m[PRICES.defaultModel] || PRICES.fallback || {
    currency: 'CNY', inputCacheMissPerM: 2, inputCacheHitPerM: 0.2, inputCacheWritePerM: 2, outputPerM: 3
  };
}

/** 一次响应的 token 用量 -> 人民币 */
function costOfUsage(usage, model) {
  const p = priceFor(model);
  const input = Number(usage.input_tokens || 0);
  const hit = Number(usage.cached_input_tokens || usage.cache_read_input_tokens || 0);
  const write = Number(usage.cache_write_input_tokens || usage.cache_creation_input_tokens || 0);
  const out = Number(usage.output_tokens || 0);
  const miss = Math.max(0, input - hit - write);
  const usd = String(p.currency || 'CNY').toUpperCase() === 'USD';
  function perToken(perM) { return (usd ? Number(perM) * FX : Number(perM)) / 1e6; }
  const cny = miss * perToken(p.inputCacheMissPerM)
    + hit * perToken(p.inputCacheHitPerM)
    + write * perToken(p.inputCacheWritePerM)
    + out * perToken(p.outputPerM);
  return cny * SCALE;
}

/* ---------------------------------------------------------------- tiers */
const TIERS = (CONFIG.tiers || []).slice().sort((a, b) => a.upToCny - b.upToCny);
function tierFor(costCny) {
  for (let i = 0; i < TIERS.length; i++) if (costCny <= TIERS[i].upToCny) return TIERS[i];
  return TIERS[TIERS.length - 1] || { name: '命中', size: 30 };
}

/* 未命中（漏账）与免费回合的显示样式：不发光、不抖屏、不闪屏，一眼和真实伤害区分开 */
const MISS_TIER = { name: '未命中', size: 34, color: '#FFB9C6D3', glow: '#FF5C6B7A', shakeMs: 0, weight: 'Bold', italic: true };
const FREE_TIER = { name: '免费回合', size: 30, color: '#FF4FC3F7', glow: '#FF1268B3', shakeMs: 0, weight: 'Bold', italic: false };

/* ---------------------------------------------------------------- bus */
const clients = new Set();

function send(sock, obj) {
  try { sock.write(JSON.stringify(obj) + '\n'); } catch (e) { clients.delete(sock); }
}
function broadcast(obj) {
  const line = JSON.stringify(obj) + '\n';
  for (const c of Array.from(clients)) {
    try { c.write(line); } catch (e) { clients.delete(c); }
  }
}
function publicState() {
  let bal = state.balanceCny;
  let spent = state.totalSpentCny;
  if (BALANCE_MODE === 'api' && state.realBalanceCny != null) bal = state.realBalanceCny;
  if (BALANCE_MODE === 'api' && state.realSpentCny != null) spent = state.realSpentCny;
  return {
    balanceCny: Number(bal.toFixed(6)),
    totalSpentCny: Number(spent.toFixed(6)),
    hits: state.hits,
    combo: state.combo,
    maxCombo: state.maxCombo,
    startBalanceCny: START_BALANCE,
    balanceMode: BALANCE_MODE,
    balanceBase: (BALANCE_MODE === 'api') ? (bal + spent) : START_BALANCE
  };
}

const server = net.createServer(function (sock) {
  clients.add(sock);
  sock.setNoDelay(true);
  vlog('client connected');
  send(sock, { t: 'hello', v: 1, startBalanceCny: START_BALANCE, decimals: DECIMALS, symbol: SYMBOL, balanceMode: BALANCE_MODE });
  send(sock, Object.assign({ t: 'state' }, publicState()));
  let buf = '';
  sock.on('data', function (chunk) {
    buf += chunk.toString('utf8');
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim();
      buf = buf.slice(i + 1);
      if (line) handleClientMessage(line);
    }
  });
  sock.on('error', function () { clients.delete(sock); });
  sock.on('close', function () { clients.delete(sock); vlog('client gone'); });
});

function handleClientMessage(line) {
  let msg;
  try { msg = JSON.parse(line); } catch (e) { return; }
  if (msg.t === 'ping') { broadcast({ t: 'pong', ts: now() }); return; }
  if (msg.t === 'state') { broadcast(Object.assign({ t: 'state' }, publicState())); return; }
  if (msg.t === 'reset') {
    state.balanceCny = START_BALANCE;
    state.totalSpentCny = 0;
    state.hits = 0;
    state.combo = 0;
    state.maxCombo = 0;
    state.sessionStartedAt = now();
    persist();
    broadcast(Object.assign({ t: 'reset' }, publicState()));
    log('balance reset ->', START_BALANCE);
    return;
  }
  if (msg.t === 'setBalance' && Number.isFinite(Number(msg.value))) {
    state.balanceCny = Number(msg.value);
    persist();
    broadcast(Object.assign({ t: 'state' }, publicState()));
    return;
  }
  if (msg.t === 'inject') {
    const cost = Math.max(0, Number(msg.costCny || 0));
    const model = msg.model || 'demo';
    const usage = msg.usage || { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 };
    const kind = String(msg.kind || 'hit');
    if (kind === 'miss') emitMiss(msg.count || 1, cost, 'demo', 'inject');
    else if (kind === 'free') emitFreeTurn('inject');
    else if (kind === 'choke') emitChoke(msg.reason || 'empty');
    else registerHit({ costCny: cost, model: model, usage: usage, source: msg.source || 'demo', ts: now() });
    return;
  }
  if (msg.t === 'setApiKey') {
    const key = String(msg.apiKey || '').trim();
    if (!key) { broadcast({ t: 'apiStatus', ok: false, msg: 'API key 为空' }); return; }
    apiKeyOverride = key;
    BALANCE_MODE = 'api';
    CONFIG.balance.mode = 'api';
    CONFIG.balance.api.apiKey = key;
    try { fs.writeFileSync(CONFIG_PATH, JSON.stringify(CONFIG, null, 2)); } catch (e) { log('保存 config 失败:', e.message); }
    startBalancePolling();
    fetchRealBalance();
    broadcast({ t: 'apiStatus', ok: true, msg: '已保存，正在同步真实余额…' });
    log('已写入 DeepSeek API key，切换到真实余额模式');
    return;
  }
  if (msg.t === 'clearApiKey') {
    apiKeyOverride = null;
    BALANCE_MODE = 'ledger';
    CONFIG.balance.mode = 'ledger';
    CONFIG.balance.api.apiKey = '';
    try { fs.writeFileSync(CONFIG_PATH, JSON.stringify(CONFIG, null, 2)); } catch (e) {}
    if (balancePollTimer) { clearInterval(balancePollTimer); balancePollTimer = null; }
    broadcast(Object.assign({ t: 'state' }, publicState()));
    broadcast({ t: 'apiStatus', ok: true, msg: '已切回本地记账' });
    return;
  }
  // 转发型消息：启动器/挂件/宿主之间用它同步「伤害数字开关」等状态
  // ui：托盘菜单发给挂件的界面指令（cmd = scale | mood | topmost），总线只负责转手
  if (msg.t === 'togglePlugin' || msg.t === 'overlayState' || msg.t === 'bye' || msg.t === 'setAnchor' || msg.t === 'pat' || msg.t === 'bubble' || msg.t === 'ui') {
    broadcast(msg);
    return;
  }
  vlog('unknown message', msg.t);
}

function registerHit(o) {
  const costCny = o.costCny;
  const usage = o.usage || {};
  const t = o.ts || now();
  const comboWindow = (CONFIG.combo && CONFIG.combo.windowMs) || 5000;
  if (t - state.lastHitAt <= comboWindow) state.combo += 1; else state.combo = 1;
  state.lastHitAt = t;
  if (state.combo > state.maxCombo) state.maxCombo = state.combo;
  state.hits += 1;
  state.totalSpentCny += costCny;
  state.balanceCny -= costCny;
  if (t > Number(state.lastProcessedTs || 0)) state.lastProcessedTs = t;
  persist();

  const tier = tierFor(costCny);
  let balanceForEvt = state.balanceCny;
  if (BALANCE_MODE === 'api' && state.realBalanceCny != null) balanceForEvt = state.realBalanceCny;
  // 「已烧」在 api 模式下以真实余额差为准，别把注入的账（demo / DSH 用量）累进展示值
  let spentForEvt = state.totalSpentCny;
  if (BALANCE_MODE === 'api' && state.realSpentCny != null) spentForEvt = state.realSpentCny;
  const evt = {
    t: 'hit',
    ts: t,
    source: o.source,
    model: o.model,
    costCny: Number(costCny.toFixed(8)),
    label: o.label || ((tier.name || '命中') + ' -' + costCny.toFixed(DECIMALS) + SYMBOL),
    tier: {
      name: tier.name, size: tier.size, color: tier.color, glow: tier.glow,
      shakeMs: tier.shakeMs, weight: tier.weight, italic: !!tier.italic
    },
    crit: TIERS.indexOf(tier) >= 1,   // 会心一击/大出血 都算暴击：闪屏 + 抖屏 + 挂件喊话
    usage: {
      input: Number(usage.input_tokens || 0),
      cached: Number(usage.cached_input_tokens || usage.cache_read_input_tokens || 0),
      write: Number(usage.cache_write_input_tokens || usage.cache_creation_input_tokens || 0),
      output: Number(usage.output_tokens || 0)
    },
    combo: state.combo,
    balanceCny: Number(balanceForEvt.toFixed(6)),
    totalSpentCny: Number(spentForEvt.toFixed(6)),
    startBalanceCny: START_BALANCE,
    balanceMode: BALANCE_MODE,
    balanceBase: (BALANCE_MODE === 'api') ? (balanceForEvt + spentForEvt) : START_BALANCE
  };
  broadcast(evt);
  log('hit ' + evt.label + '  combo=' + evt.combo + '  balance=' + evt.balanceCny.toFixed(2) + '  [' + o.source + '/' + o.model + ']');
}

/** 未命中：现实里花了钱但没能打出伤害（漏账） */
function emitMiss(count, costCny, reason, detail) {
  const n = Math.max(1, Number(count || 1));
  const cost = Math.max(0, Number(costCny || 0));
  state.missCount = Number(state.missCount || 0) + n;
  state.missedCny = Number(state.missedCny || 0) + cost;
  persist();
  const label = cost > 0.00005
    ? (n > 1 ? ('未命中 ×' + n + ' -' + cost.toFixed(DECIMALS) + SYMBOL) : ('未命中 -' + cost.toFixed(DECIMALS) + SYMBOL))
    : ('未命中 ×' + n);
  const evt = Object.assign({
    t: 'miss',
    ts: now(),
    reason: reason || 'unknown',
    detail: detail || '',
    count: n,
    costCny: Number(cost.toFixed(8)),
    label: label,
    tier: MISS_TIER,
    crit: false
  }, publicState());
  broadcast(evt);
  log('[未命中] ' + label + '（' + (reason || '') + (detail ? ' ' + detail : '') + '）累计漏账 ' + state.missCount + ' 笔 / ' + Number(state.missedCny).toFixed(4) + ' CNY');
}

/** 免费回合：这一轮没花一分钱（没有任何 token 消耗记录） */
function emitChoke(reason) {
  // 断网 / 余额见底：通知挂件演「呛到」（噎住 → 停顿 → 咳出来）
  broadcast({
    t: 'choke',
    ts: now(),
    reason: String(reason || 'empty'),
    label: reason === 'offline' ? '断网' : '余额见底'
  });
  log('[呛到] 原因 =', reason === 'offline' ? '断网' : '余额见底');
}

function emitFreeTurn(detail) {
  state.freeTurns = Number(state.freeTurns || 0) + 1;
  persist();
  const evt = Object.assign({
    t: 'freeTurn',
    ts: now(),
    detail: detail || '',
    label: '免费回合',
    tier: FREE_TIER,
    crit: false
  }, publicState());
  broadcast(evt);
  log('[免费回合] 本轮没有 token 消耗' + (detail ? '（' + detail + '）' : '') + '，累计 ' + state.freeTurns + ' 次');
}

/* ---------------------------------------------------------------- tail */
function makeTailer(file, onLine) {
  let offset = 0;
  let rest = '';
  let skipPartial = false;
  try {
    const st = fs.statSync(file);
    if (CONFIG.watch && CONFIG.watch.replayOnStart) { offset = 0; }
    else {
      // 启动时往回多读一段尾巴：避免「核心启动那一瞬间写下的记录」被漏掉。
      // 重复读到的部分靠 response_id 去重，不会打出重复伤害。
      const overlap = Math.max(0, Number((CONFIG.watch && CONFIG.watch.tailBytesOnFirstOpen) || 262144));
      offset = Math.max(0, st.size - overlap);
      skipPartial = offset > 0;   // 从文件中间开始读，第一行大概率是半截，丢掉
    }
  } catch (e) { offset = 0; }
  return {
    read: function () {
      let st;
      try { st = fs.statSync(file); } catch (e) { return; }
      if (st.size < offset) { offset = 0; rest = ''; }
      if (st.size === offset) return;
      let chunk = '';
      try {
        const fd = fs.openSync(file, 'r');
        const len = st.size - offset;
        const buf = Buffer.allocUnsafe(len);
        fs.readSync(fd, buf, 0, len, offset);
        fs.closeSync(fd);
        chunk = buf.toString('utf8');
        offset = st.size;
      } catch (e) { vlog('read failed', file, e.message); return; }
      let text = rest + chunk;
      if (skipPartial) {
        const nl = text.indexOf('\n');
        skipPartial = false;
        if (nl < 0) { rest = text; return; }
        text = text.slice(nl + 1);
      }
      const lines = text.split('\n');
      const tailLine = lines.pop();
      rest = tailLine === undefined ? '' : tailLine;
      for (const line of lines) if (line.trim()) onLine(line);
    }
  };
}

function walk(root, filter, out, depth) {
  out = out || [];
  depth = depth || 0;
  if (depth > 6) return out;
  let entries = [];
  try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (e) { return out; }
  for (const e of entries) {
    const p = path.join(root, e.name);
    if (e.isDirectory()) walk(p, filter, out, depth + 1);
    else if (e.isFile() && filter(e.name, p)) out.push(p);
  }
  return out;
}

const codexRoot = path.join(String(CONFIG.codexHome || path.join(os.homedir(), '.codex')).replace(/\\/g, '/'), 'sessions');
const claudeRoot = path.join(os.homedir(), '.claude', 'projects');
const fileMeta = new Map();

function registerCodexFile(file) {
  const meta = { model: PRICES.defaultModel || 'deepseek-flash' };
  // 免费回合检测：这一轮从 task_started 开始，到下一轮开始（或超时）都没出现 token 消耗 → 免费回合
  const turn = { id: '', hasUsage: false, startedAt: 0, flushed: true };
  state.reportedTurnIds = state.reportedTurnIds || [];
  function flushTurn(reason) {
    if (turn.flushed || !turn.id) return;
    turn.flushed = true;
    if (turn.hasUsage) return;
    if (state.reportedTurnIds.indexOf(turn.id) >= 0) return;      // 报过的不重复报
    state.reportedTurnIds.push(turn.id);
    if (state.reportedTurnIds.length > 800) state.reportedTurnIds.splice(0, state.reportedTurnIds.length - 800);
    emitFreeTurn('turn ' + turn.id.slice(0, 8) + ' ' + reason);
  }
  const runner = makeTailer(file, function (line) {
    let o;
    try { o = JSON.parse(line); } catch (e) { state.lastRun.parseFail++; persist(); return; }
    const ts = Date.parse(o.timestamp || '') || now();
    if (o.type === 'event_msg' && o.payload && o.payload.type === 'task_started') {
      flushTurn('下一轮开始');                       // 上一轮没收尾就开了新一轮
      turn.id = o.payload.turn_id || '';
      turn.hasUsage = false;
      turn.startedAt = now();
      // 只统计「核心启动之后开始的轮次」，否则每次启动重读尾巴都会把老轮次再判一遍
      turn.flushed = (Date.parse(o.timestamp || '') || 0) < CORE_STARTED_TS;
      return;
    }
    if (o.type === 'turn_context' && o.payload && o.payload.model) { meta.model = o.payload.model; return; }
    if (o.type === 'session_meta' && o.payload && o.payload.model) { meta.model = o.payload.model; return; }
    if (o.type === 'token_usage_record' && o.payload && o.payload.usage) {
      turn.hasUsage = true;                          // 有消耗，不是免费回合
      const rid = o.payload.response_id || o.payload.turn_id || '';
      if (rid) {
        if (state.seenResponseIds.indexOf(rid) >= 0) { state.lastRun.dedupe++; return; }
        state.seenResponseIds.push(rid);
        if (state.seenResponseIds.length > 2000) state.seenResponseIds.splice(0, state.seenResponseIds.length - 2000);
      }
      state.lastRun.seen++;
      const cost = costOfUsage(o.payload.usage, meta.model);
      if (cost > 0) {
        state.lastRun.hits++;
        registerHit({ costCny: cost, model: meta.model, usage: o.payload.usage, source: 'codex', ts: ts });
      } else {
        state.lastRun.zeroCost++;
        emitMiss(1, 0, 'zeroCost', 'tokens 全 0');
        log('跳过一条 0 费用记录（tokens 都为 0？）', JSON.stringify(o.payload.usage));
        persist();
      }
      return;
    }
    if (o.type === 'event_msg' && o.payload && o.payload.type === 'token_count') {
      const info = o.payload.info || {};
      const u = info.last_token_usage || info.total_token_usage;
      if (!u) return;
      const usage = {
        input_tokens: u.input_tokens, cached_input_tokens: u.cached_input_tokens,
        cache_write_input_tokens: u.cache_write_input_tokens, output_tokens: u.output_tokens
      };
      const cost = costOfUsage(usage, meta.model);
      if (cost > 0) registerHit({ costCny: cost, model: meta.model, usage: usage, source: 'codex', ts: ts });
    }
  });
  fileMeta.set(file, runner);
  vlog('watching', file);
}

function registerClaudeFile(file) {
  const meta = { model: 'claude-sonnet-4-5' };
  const runner = makeTailer(file, function (line) {
    let o;
    try { o = JSON.parse(line); } catch (e) { return; }
    const msg = o.message;
    if (!msg || !msg.usage) return;
    if (msg.model) meta.model = msg.model;
    const ts = Date.parse(o.timestamp || '') || now();
    const usage = {
      input_tokens: msg.usage.input_tokens,
      cached_input_tokens: msg.usage.cache_read_input_tokens,
      cache_write_input_tokens: msg.usage.cache_creation_input_tokens,
      output_tokens: msg.usage.output_tokens
    };
    const cost = costOfUsage(usage, meta.model);
    if (cost > 0) registerHit({ costCny: cost, model: meta.model, usage: usage, source: 'claude', ts: ts });
  });
  fileMeta.set(file, runner);
  vlog('watching', file);
}

function scanFiles() {
  if (!(CONFIG.watch && CONFIG.watch.codexSessions === false) && fs.existsSync(codexRoot)) {
    for (const f of walk(codexRoot, (n) => n.endsWith('.jsonl'))) if (!fileMeta.has(f)) registerCodexFile(f);
  }
  if (!(CONFIG.watch && CONFIG.watch.claudeProjects === false) && fs.existsSync(claudeRoot)) {
    for (const f of walk(claudeRoot, (n) => n.endsWith('.jsonl'))) if (!fileMeta.has(f)) registerClaudeFile(f);
  }
}

/** 停机对账：把「上次运行结束之后、这次启动之前」写下的记录找出来，聚合成一条未命中 */
function reconcileDowntime() {
  const since = Number(state.lastProcessedTs || 0);
  if (!since) {
    state.lastProcessedTs = now();
    persist();
    log('首次运行：不做历史对账（把当前历史当基线）');
    return;
  }
  const known = new Set(state.seenResponseIds || []);
  let count = 0, cost = 0;
  for (const f of walk(codexRoot, (n) => n.endsWith('.jsonl'))) {
    let content = '';
    try { content = fs.readFileSync(f, 'utf8'); } catch (e) { continue; }
    let model = PRICES.defaultModel || 'deepseek-flash';
    for (const line of content.split('\n')) {
      if (!line.trim()) continue;
      let o;
      try { o = JSON.parse(line); } catch (e) { continue; }
      if (o.type === 'turn_context' && o.payload && o.payload.model) { model = o.payload.model; continue; }
      if (o.type === 'session_meta' && o.payload && o.payload.model) { model = o.payload.model; continue; }
      if (o.type !== 'token_usage_record' || !o.payload || !o.payload.usage) continue;
      const ts = Date.parse(o.timestamp || '') || 0;
      if (ts < since) continue;
      const rid = o.payload.response_id || o.payload.turn_id || '';
      if (rid && known.has(rid)) continue;
      count++;
      cost += costOfUsage(o.payload.usage, model);
    }
  }
  if (count > 0) emitMiss(count, cost, 'downtime', '核心没在跑的时候写下的');
  else log('[对账] 停机期间没有漏账');
}

/* ---------------------------------------------------------------- boot */
log('dsh-overlay core starting');
log('prices: ' + Object.keys(PRICES.models || {}).length + ' models | usdToCny=' + FX + ' scale=' + SCALE);
log('balance mode: ' + BALANCE_MODE + (BALANCE_MODE === 'api' ? '（实时拉取真实余额）' : '（本地记账，起始 ' + START_BALANCE + '）'));
log('watch codex sessions: ' + codexRoot);
if (!(CONFIG.watch && CONFIG.watch.claudeProjects === false)) log('watch claude projects: ' + claudeRoot);
log('balance = ' + state.balanceCny.toFixed(2) + ' CNY (start ' + START_BALANCE + ')');

if (BALANCE_MODE === 'api') {
  startBalancePolling();
}

const HOST = (CONFIG.bus && CONFIG.bus.host) || '127.0.0.1';
const PORT = Number((CONFIG.bus && CONFIG.bus.port) || 17777);

// 写 PID 文件，stop.cmd 靠它精准收尸
try {
  const logDir = path.join(HERE, '..', 'logs');
  if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
  fs.writeFileSync(path.join(logDir, 'core.pid'), String(process.pid));
} catch (e) { log('pid file failed:', e.message); }

server.listen(PORT, HOST, function () {
  log('bus listening on tcp://' + HOST + ':' + PORT);
});
server.on('error', function (e) { log('bus error:', e.message); process.exit(1); });

scanFiles();
setInterval(function () {
  scanFiles();
  for (const runner of Array.from(fileMeta.values())) runner.read();
}, Math.max(80, Number((CONFIG.watch && CONFIG.watch.pollMs) || 400)));

// 启动 2 秒后做一次「停机期间有没有漏账」的对账（等尾巴那段先读完）
setTimeout(reconcileDowntime, 2000);

setInterval(function () {
  if (state.combo > 0 && now() - state.lastHitAt > ((CONFIG.combo && CONFIG.combo.timeoutMs) || 4000)) {
    state.combo = 0;
    broadcast(Object.assign({ t: 'combo', combo: 0 }, publicState()));
  }
}, 500);

// 对账自检：每 30s 打一次「读到多少条 token 记录 / 打出多少发伤害 / 跳过了什么」
let lastAudit = { seen: -1, zeroCost: -1, parseFail: -1 };
setInterval(function () {
  const r = state.lastRun;
  if (!r) return;
  if (r.seen === lastAudit.seen && r.zeroCost === lastAudit.zeroCost && r.parseFail === lastAudit.parseFail) return;
  lastAudit = { seen: r.seen, zeroCost: r.zeroCost, parseFail: r.parseFail };
  const gap = r.seen - r.hits - r.zeroCost;
  log('[对账] 本次运行：token 记录 ' + r.seen + ' 条 → 伤害 ' + r.hits + ' 发；0 费用跳过 ' + r.zeroCost +
      '；解析失败 ' + r.parseFail + '；重读去重 ' + (r.dedupe || 0) +
      (gap === 0 ? '（无遗漏）' : '（⚠️ 有 ' + gap + ' 条未生成伤害）'));
}, 30000);

process.on('SIGINT', function () { log('bye'); process.exit(0); });
process.on('exit', function () {
  try { fs.unlinkSync(path.join(HERE, '..', 'logs', 'core.pid')); } catch (e) { /* 忽略 */ }
});
