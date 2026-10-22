/**
 * 演示伤害流：往总线注入随机「命中」，只用来预览动画，不碰真实账单。
 *   node tools/demo.mjs                 # 默认跑 60 秒，每 350ms 一发
 *   node tools/demo.mjs --burst 18      # 立刻打 18 发连击然后退出（默认全是命中，好攒连击）
 *   node tools/demo.mjs --burst 18 --gap 150   # 每发间隔 150ms，看得更清楚
 *   node tools/demo.mjs --burst 8 --mix        # 连击里照样夹未命中/免费回合
 *   node tools/demo.mjs --burst 4 --gap 240 --choke-after   # 先吃 4 口，停下来再演「呛到」
 *   node tools/demo.mjs --seconds 15
 *   node tools/demo.mjs --force 大出血   # 只打某一档，方便单看效果（命中/会心一击/大出血）
 *   node tools/demo.mjs --miss 5          # 只打「未命中」（灰字）
 *   node tools/demo.mjs --free 5          # 只打「免费回合」（蓝字）
 *
 * 保底：默认循环里每 5 发必出 1 次「会心一击」+ 1 次「大出血」，其余是「命中」，
 *       所以哪怕只打 5 发也能看到三种效果。
 *       另外每 7 发夹 1 次「未命中」（灰）、每 11 发夹 1 次「免费回合」（蓝），方便测新样式。
 */
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'core', 'config.json'), 'utf8'));
const HOST = (CONFIG.bus && CONFIG.bus.host) || '127.0.0.1';
const PORT = Number((CONFIG.bus && CONFIG.bus.port) || 17777);

const args = process.argv.slice(2);
const idx = (name) => args.indexOf(name);
const burst = idx('--burst') >= 0 ? Number(args[idx('--burst') + 1] || 20) : 0;
const seconds = idx('--seconds') >= 0 ? Number(args[idx('--seconds') + 1] || 60) : 60;
const force = idx('--force') >= 0 ? String(args[idx('--force') + 1] || '') : '';
const onlyMiss = idx('--miss') >= 0 ? Number(args[idx('--miss') + 1] || 5) : 0;
const onlyFree = idx('--free') >= 0 ? Number(args[idx('--free') + 1] || 5) : 0;
const mix = idx('--mix') >= 0;   // 连击模式默认纯命中，加 --mix 才夹未命中/免费回合
const chokeAfter = idx('--choke-after') >= 0;   // 打完这几发之后再补一条「呛到」（reason=preview）
const gap = idx('--gap') >= 0 ? Number(args[idx('--gap') + 1] || 150) : (burst > 0 ? 90 : 350);

const rnd = (a, b) => a + Math.random() * (b - a);
const pick = (a) => a[Math.floor(Math.random() * a.length)];
let shot = 0;

// 三档区间要和 core/config.json 的 tiers 对齐
const BANDS = {
  '命中':     () => rnd(0.0006, 0.0022),   // < 0.02
  '会心一击': () => rnd(0.028, 0.072),     // 0.02 ~ 0.08
  '大出血':   () => rnd(0.09, 0.18),       // > 0.08
};

function nextCost(i) {
  if (BANDS[force]) return BANDS[force]();
  if (i % 5 === 4) return BANDS['大出血']();       // 每 5 发保底一次大出血
  if (i % 3 === 2) return BANDS['会心一击']();      // 每 3 发保底一次会心一击
  return BANDS['命中']();
}

// 返回这次要发什么：hit / miss / free
function nextKind(i) {
  if (onlyMiss || onlyFree) return onlyMiss ? 'miss' : 'free';
  if (burst > 0 && !mix) return 'hit';           // 连击演示：全是命中，连击数才拉得起来
  if (i % 11 === 5) return 'free';                 // 每 11 发夹一个免费回合
  if (i % 7 === 3) return 'miss';                  // 每 7 发夹一个未命中
  return 'hit';
}

// 每条注入单独开一个连接，写完整行后 end()（发 FIN，不是 RST）。
// 之前是常驻 socket 一口气写 12 行、然后 sock.end() + process.exit(0)，
// 核心来不及读完就收到 RST，实测 12 发只有 1 发真正落账——演示动画当然就演不出来。
function sendLine(obj) {
  const c = net.connect(PORT, HOST, () => { c.end(JSON.stringify(obj) + String.fromCharCode(10)); });
  c.on('error', () => {});
}

function fire() {
  const i = shot++;
  const kind = nextKind(i);
  if (kind === 'miss') {
    sendLine({ t: 'inject', kind: 'miss', count: 1, costCny: rnd(0.004, 0.35), source: 'demo' });
    return;
  }
  if (kind === 'free') {
    sendLine({ t: 'inject', kind: 'free', source: 'demo' });
    return;
  }
  const costCny = nextCost(i);
  sendLine({
    t: 'inject', kind: 'hit', costCny, source: 'demo',
    model: pick(['deepseek-flash', 'deepseek-flash', 'deepseek-v4-pro'])
  });
}

console.log(`[demo] ${HOST}:${PORT}  burst=${burst} seconds=${seconds} gap=${gap}`);
if (burst > 0) {
  for (let i = 0; i < burst; i++) setTimeout(fire, i * gap);
  const endAt = burst * gap + 300;
  if (chokeAfter) {
    // 停下来之后再「呛到」：和真断网/余额见底的节奏一致（先吃着，钱/网突然断）
    setTimeout(() => sendLine({ t: 'inject', kind: 'choke', reason: 'preview' }), endAt + 250);
  }
  setTimeout(() => process.exit(0), endAt + (chokeAfter ? 1200 : 600));
} else {
  const timer = setInterval(fire, gap);
  setTimeout(() => { clearInterval(timer); process.exit(0); }, seconds * 1000);
}
