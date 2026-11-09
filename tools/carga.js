// Prueba de carga de Parche: N jugadores falsos (invitados "carga_N") que piden datos al servidor.
// Uso:  node carga.js <jugadores> <segundos> [host]
const N = parseInt(process.argv[2] || '100', 10);
const SECS = parseInt(process.argv[3] || '60', 10);
const HOST = process.argv[4] || 'localhost:7350';
const PAUSE = parseFloat(process.argv[5] || '0'); // segundos promedio entre peticiones de cada jugador (0 = muy seguido, como estres)
const KEY = 'defaultkey';
const BASIC = 'Basic ' + Buffer.from(KEY + ':').toString('base64');
const lat = [], errs = {}; let relogin = 0, ok = 0, wsOpen = 0, authFail = 0, stop = false;
const rnd = (a, b) => a + Math.random() * (b - a);
const sleep = ms => new Promise(r => setTimeout(r, ms));
function err(k) { errs[k] = (errs[k] || 0) + 1; }
async function rpc(B, id, body) {
  const t0 = performance.now();
  try {
    const r = await fetch(`http://${HOST}/v2/rpc/${id}?unwrap`, { method: 'POST', headers: { Authorization: 'Bearer ' + B.tok, 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
    lat.push(performance.now() - t0);
    if (r.ok) ok++; else if (r.status === 401) { relogin++; await login(B); } else err(id + ':' + r.status);
  } catch (e) { err(id + ':red'); }
}
async function login(B) {
  for (let t = 0; t < 3; t++) {
    try {
      const r = await fetch(`http://${HOST}/v2/account/authenticate/device?create=true&username=${B.user}`, { method: 'POST', headers: { Authorization: BASIC, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: B.dev }) });
      if (r.ok) { B.tok = (await r.json()).token; if (t) err('login_ok_en_reintento_' + t); return true; }
      err('login:' + r.status);
    } catch (e) { err('login:red:' + (e.cause && e.cause.code || e.name)); }
    await sleep(500 * (t + 1) + Math.random() * 500);
  }
  return false;
}
async function bot(i) {
  const run = Date.now();
  const B = { tok: null, user: `carga_${run % 100000}_${i}`, dev: `carga-test-${run}-${i}-xxxxxxxx` };
  if (!(await login(B))) { authFail++; return; }
  const tok = B.tok;
  let ws = null;
  if (typeof WebSocket !== 'undefined') {
    try { ws = new WebSocket(`ws://${HOST}/ws?token=${B.tok}&format=json`); ws.onopen = () => wsOpen++; ws.onclose = () => { if (!stop) wsOpen--; }; ws.onerror = () => {}; } catch (e) {}
  }
  const calls = ['eco_get', 'liga_tier_top', 'global_top', 'tour_info', 'eco_get'];
  await rpc(B, 'eco_get');
  while (!stop) {
    await sleep(PAUSE > 0 ? rnd(PAUSE * 500, PAUSE * 1500) : rnd(1500, 4000));
    const c = calls[Math.floor(Math.random() * calls.length)];
    await rpc(B, c, c === 'liga_tier_top' ? { tier: 'bronce' } : {});
  }
  try { ws && ws.close(); } catch (e) {}
}
const pct = (a, p) => a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))].toFixed(0) : '-';
(async () => {
  console.log(`Probando con ${N} jugadores falsos durante ${SECS} s en ${HOST} ...`);
  const t0 = Date.now();
  const rep = setInterval(() => {
    const e = Object.keys(errs).length ? JSON.stringify(errs) : 'ninguno';
    console.log(`[${Math.round((Date.now() - t0) / 1000)}s] conexiones=${wsOpen} ok=${ok} lat(ms) p50=${pct(lat, .5)} p95=${pct(lat, .95)} max=${pct(lat, 1)} fallos_login=${authFail} renovaciones=${relogin} errores=${e}`);
  }, 10000);
  const rampMs = Math.min(SECS * 400, Math.max(20000, N * 60));
  const ps = [];
  for (let i = 0; i < N; i++) { ps.push(bot(i)); await sleep(rampMs / N); }
  await sleep(Math.max(0, SECS * 1000 - (Date.now() - t0)));
  stop = true; await Promise.all(ps); clearInterval(rep);
  const tot = ok + Object.values(errs).reduce((a, b) => a + b, 0);
  console.log(`\nRESULTADO ${N} jugadores: peticiones=${tot} correctas=${ok} (${tot ? (100 * ok / tot).toFixed(1) : 0}%) p50=${pct(lat, .5)}ms p95=${pct(lat, .95)}ms max=${pct(lat, 1)}ms fallos_login=${authFail}`);
  console.log('Errores:', JSON.stringify(errs));
  process.exit(0);
})();
