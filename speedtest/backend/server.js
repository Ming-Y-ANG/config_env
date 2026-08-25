const express = require('express');
const crypto = require('crypto');
const app = express();

const MAX_BYTES = 250 * 1024 * 1024; // 单次下载上限，与测速引擎最大测量文件（2.5e8 字节）一致
const CHUNK_SIZE = 256 * 1024;       // 每次写入 256KB

// 预分配可复用的下载数据块，填充随机字节：
// 全 0 数据高度可压缩，若链路存在透明压缩代理会导致测速结果虚高
const DOWNLOAD_CHUNK = Buffer.alloc(CHUNK_SIZE);
crypto.randomFillSync(DOWNLOAD_CHUNK);

// CORS + Resource Timing 暴露
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  // 跨域时允许 JS 读取 server-timing（测速引擎用它从传输时长中扣除服务端耗时）
  res.set('Access-Control-Expose-Headers', 'Server-Timing, Content-Length');
  // 关键：跨域测速必须。缺失时浏览器会隐藏请求的详细计时数据，
  // PerformanceResourceTiming 全为 0，速率/延迟将完全无法计算
  res.set('Timing-Allow-Origin', '*');
  res.set('Cache-Control', 'no-store'); // 测速响应禁止任何缓存
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// 下载 & 延迟测试
app.get('/__down', (req, res) => {
  // 修复：原代码 `parseInt(req.query.bytes) || 默认值` 会把 bytes=0 吞掉变成 10MB，
  // 导致每个延迟测量请求（bytes=0）都实际下载 10MB —— 延迟阶段极慢且数值不准
  let bytes = parseInt(req.query.bytes, 10);
  if (Number.isNaN(bytes) || bytes < 0) bytes = 0;
  bytes = Math.min(bytes, MAX_BYTES); // 上限保护，防止超大请求打爆带宽

  res.set('Content-Type', 'application/octet-stream');
  // 服务端处理耗时（引擎计算带宽时会从传输时长中扣除它）。
  // 引擎会忽略 <0.01ms 的值并视为"可忽略"——本服务生成数据耗时≈0，不扣除是正确的。
  // 保持非 0 数值以兼容引擎内部的 falsy 检查
  res.set('Server-Timing', 'cfRequestDuration;dur=0.0001');

  if (bytes === 0) return res.end(); // bytes=0：延迟测量，立即返回空响应

  res.set('Content-Length', bytes);

  // 背压感知的写入循环：缓冲区写满（write 返回 false）时等待 drain 事件再继续。
  // 原实现用 setImmediate 递归且每次 Buffer.alloc 新内存，
  // 大文件（最大 250MB）时会造成内存堆积和 GC 压力
  let sent = 0;
  function pump() {
    let ok = true;
    while (sent < bytes && ok) {
      const size = Math.min(CHUNK_SIZE, bytes - sent);
      // 复用同一 buffer 的视图，零分配
      ok = res.write(size === CHUNK_SIZE ? DOWNLOAD_CHUNK : DOWNLOAD_CHUNK.subarray(0, size));
      sent += size;
    }
    if (sent < bytes) res.once('drain', pump);
    else res.end();
  }
  pump();
});

// 上传测试
app.post('/__up', (req, res) => {
  let received = 0;

  req.on('data', chunk => {
    received += chunk.length; // 只计数，不存储，直接丢弃
  });

  req.on('end', () => {
    // 上传带宽计算同样会扣除服务端处理耗时（<0.01ms 会被引擎忽略，属正常）
    res.set('Server-Timing', 'cfRequestDuration;dur=0.0001');
    res.json({ success: true, bytesReceived: received });
  });

  req.on('error', () => {
    res.status(500).json({ success: false });
  });
});

// 健康检查
app.get('/health', (req, res) => res.json({ status: 'ok' }));

// TURN 临时凭证（丢包测试用，标准 TURN REST API 格式）
// 部署 coturn 后，将 TURN_SECRET 环境变量设为与 /etc/turnserver.conf
// 中 static-auth-secret 相同的密钥；未配置时该端点返回 503
const TURN_SECRET = process.env.TURN_SECRET || '';
const TURN_CREDS_TTL = 3600; // 凭证有效期（秒）

app.get('/turn-creds', (req, res) => {
  if (!TURN_SECRET) return res.status(503).json({ error: 'TURN not configured' });
  const username = `${Math.floor(Date.now() / 1000) + TURN_CREDS_TTL}:speedtest`;
  const credential = crypto.createHmac('sha1', TURN_SECRET).update(username).digest('base64');
  res.json({ username, credential });
});

// 托管静态前端页面（把 index.html 放到 /app/public 即可，与 API 同源，前端零配置）
app.use(express.static('/app/public'));

app.listen(65000, '0.0.0.0', () => console.log('Backend on :65000'));

