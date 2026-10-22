// 把余额重置回 config.balance.startCny（需要核心在跑）
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONFIG = JSON.parse(fs.readFileSync(path.join(HERE, '..', 'core', 'config.json'), 'utf8'));
const HOST = (CONFIG.bus && CONFIG.bus.host) || '127.0.0.1';
const PORT = Number((CONFIG.bus && CONFIG.bus.port) || 17777);

const sock = net.connect(PORT, HOST, () => {
  sock.write(JSON.stringify({ t: 'reset' }) + '\n');
  console.log('余额已重置回 ' + CONFIG.balance.startCny + ' CNY');
  setTimeout(() => { sock.end(); process.exit(0); }, 300);
});
sock.on('error', (e) => {
  console.error('核心没在跑（' + e.message + '），先双击 start.cmd');
  process.exit(1);
});
