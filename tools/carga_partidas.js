// Prueba de partidas en tiempo real de Parche: N jugadores falsos se emparejan de 4 en 4,
// juegan una "partida" mandandose mensajes entre ellos y vuelven a la cola.
// Uso:  node carga_partidas.js <jugadores(multiplo de 4)> <segundos> [host] [segundosPorPartida]
const N = parseInt(process.argv[2] || '40', 10);
const SECS = parseInt(process.argv[3] || '120', 10);
const HOST = process.argv[4] || 'localhost:7350';
const DUR = parseFloat(process.argv[5] || '45');
const MODE = process.argv[7] || 'quoted'; // any | plain | quoted
const CODES = parseInt(process.argv[6] || '20', 10); // cuantas mesas publicas distintas (modo+apuesta) hay; el juego real busca por codigo de mesa
const BASIC = 'Basic ' + Buffer.from('defaultkey:').toString('base64');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const rnd = (a, b) => a + Math.random() * (b - a);
const S = { login: 0, loginFail: 0, ws: 0, wsLost: 0, tickets: 0, matched: 0, joined: 0, joinFail: 0, sent: 0, recv: 0, bytes: 0, games: 0 };
const errs = {}, lat = [], wait = [];
let stop = false;
const err = k => { errs[k] = (errs[k] || 0) + 1; };
const pct = (a, p) => a.length ? a.slice().sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))].toFixed(0) : '-';
async function login(user, dev) {
  for (let t = 0; t < 3; t++) {
    try {
      const r = await fetch(`http://${HOST}/v2/account/authenticate/device?create=true&username=${user}`, { method: 'POST', headers: { Authorization: BASIC, 'Content-Type': 'application/json' }, body: JSON.stringify({ id: dev }) });
      if (r.ok) return (await r.json()).token;
      err('login:' + r.status);
    } catch (e) { err('login:red'); }
    await sleep(500 * (t + 1));
  }
  return null;
}
async function bot(i) {
  const run = Date.now();
  const tok = await login(`carga_${run % 100000}_p${i}`, `carga-part-${run}-${i}-xxxxxxxx`);
  if (!tok) { S.loginFail++; return; }
  S.login++;
  const ws = new WebSocket(`ws://${HOST}/ws?token=${tok}&format=json`);
  let cid = 0; const pend = new Map(); let matchId = null, inGame = false, onMatched = null;
  const send = (o, to = 15000) => new Promise((res, rej) => {
    const c = String(++cid); o.cid = c;
    const t = setTimeout(() => { pend.delete(c); rej(new Error('timeout')); }, to);
    pend.set(c, m => { clearTimeout(t); m.error ? rej(new Error(m.error.message || 'error')) : res(m); });
    ws.send(JSON.stringify(o));
  });
  await new Promise(r => { ws.onopen = () => { S.ws++; r(); }; ws.onerror = () => { err('ws:error'); r(); }; });
  ws.onclose = () => { if (!stop) { S.wsLost++; S.ws--; } };
  ws.onmessage = ev => {
    let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
    if (m.cid && pend.has(m.cid)) { pend.get(m.cid)(m); pend.delete(m.cid); return; }
    if (m.matchmaker_matched && onMatched) onMatched(m.matchmaker_matched);
    if (m.match_data) {
      S.recv++;
      try { const d = JSON.parse(Buffer.from(m.match_data.data, 'base64').toString()); if (d.t) lat.push(Date.now() - d.t); } catch (e) {}
    }
  };
  const mk = n => Buffer.from(JSON.stringify({ t: Date.now(), pad: 'x'.repeat(n) })).toString('base64');
  while (!stop) {
    try {
      const w0 = Date.now();
      const matched = new Promise(r => { onMatched = r; });
      const code = 'Pc' + (i % CODES) + 'A4';
      await send({ matchmaker_add: { query: MODE === 'any' ? '*' : MODE === 'plain' ? '+properties.code:' + code : '+properties.code:"' + code + '"', min_count: 4, max_count: 4, string_properties: { code }, numeric_properties: {} } });
      S.tickets++;
      const mm = await Promise.race([matched, sleep(60000).then(() => null)]);
      onMatched = null;
      if (!mm) { err('sin_pareja_60s'); continue; }
      S.matched++; wait.push(Date.now() - w0);
      let j; try { j = await send({ match_join: { token: mm.token } }); } catch (e) { S.joinFail++; err('join:' + e.message); continue; }
      matchId = j.match.match_id; S.joined++;
      if (i % 4 === 0) S.games++;
      const end = Date.now() + DUR * 1000; let last = 0;
      while (!stop && Date.now() < end) {
        await sleep(rnd(1800, 3600));
        const big = Date.now() - last > 20000; if (big) last = Date.now();
        try { ws.send(JSON.stringify({ match_data_send: { match_id: matchId, op_code: big ? 7 : 2, data: mk(big ? 1500 : 200), reliable: true } })); S.sent++; S.bytes += big ? 1500 : 200; } catch (e) { err('envio'); }
      }
      try { await send({ match_leave: { match_id: matchId } }, 5000); } catch (e) {}
      await sleep(rnd(1000, 4000));
    } catch (e) { err('ciclo:' + e.message); await sleep(2000); }
  }
  try { ws.close(); } catch (e) {}
}
(async () => {
  console.log(`Partidas en vivo: ${N} jugadores, ${SECS} s, partidas de ${DUR} s en ${HOST} ...`);
  const t0 = Date.now();
  const line = () => `[${Math.round((Date.now() - t0) / 1000)}s] conectados=${S.ws} perdidos=${S.wsLost} unidos=${S.joined} partidas=${S.games} enviados=${S.sent} recibidos=${S.recv} (esperados~${S.sent * 3}) lat(ms) p50=${pct(lat, .5)} p95=${pct(lat, .95)} max=${pct(lat, 1)} espera_pareja(s) p50=${(pct(wait, .5) / 1000).toFixed(1)} p95=${(pct(wait, .95) / 1000).toFixed(1)} fallos_login=${S.loginFail} errores=${Object.keys(errs).length ? JSON.stringify(errs) : 'ninguno'}`;
  const rep = setInterval(() => console.log(line()), 10000);
  const ps = [];
  for (let i = 0; i < N; i++) { ps.push(bot(i)); await sleep(Math.min(20000, N * 40) / N); }
  await sleep(Math.max(0, SECS * 1000 - (Date.now() - t0)));
  stop = true; await Promise.race([Promise.all(ps), sleep(8000)]); clearInterval(rep);
  console.log('\nRESULTADO ' + line());
  process.exit(0);
})();
