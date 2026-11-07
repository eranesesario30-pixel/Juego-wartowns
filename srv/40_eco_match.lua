
-- ============================================================================
-- ECONOMIA (parte C): apuestas, cierre de partida, experiencia, torneos y compras
-- ============================================================================
local BET_TIERS = { 500, 2000, 5000, 10000, 50000, 250000, 1000000, 5000000, 15000000, 30000000 }
local BET_STALE = 1800          -- una apuesta sin cerrar en 30 min se pierde (evita "salirme si voy perdiendo")
local MATCH_MIN_GAP = 45        -- segundos minimos entre dos cierres de partida
local REFUND_DAY_CAP = 3        -- devoluciones por "rival desconectado" al dia
local TRACK_CAPS = { capturesToday = 15, doublesToday = 10, treasureToday = 5, streaksToday = 5 }

local function level_cost(L) return L <= 10 and 100 or (L <= 30 and 150 or (L <= 60 and 200 or 300)) end
local function bet_index(amount)
  for i, a in ipairs(BET_TIERS) do if a == amount then return i end end
  return nil
end
local function bet_chest_tier(i) return i <= 4 and "bronce" or (i <= 8 and "plata" or (i <= 9 and "oro" or "diamante")) end

local function boost_active(d) return (tonumber(d.xp.boost) or 0) > now_ms() end

-- Si habia una apuesta vieja sin cerrar, se pierde (ya estaba descontada)
local function expire_bet(d)
  if d.bet and (os.time() - (tonumber(d.bet.t) or 0)) > BET_STALE then d.bet = nil end
end

local function rpc_bet_hold(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local amount = tonumber(decode(payload).amount)
  local idx = amount and bet_index(amount)
  if not idx then return eco_fail("apuesta_invalida") end
  local ok, res, doc = eco_update(uid, function(d)
    expire_bet(d)
    if d.bet then return false, "apuesta_activa" end
    if d.gold < amount then return false, "sin_saldo" end
    d.gold = d.gold - amount
    d.bet = { amount = amount, idx = idx, t = os.time() }
    local ch = ensure_challenges(d)
    if amount >= 10000 then ch.prog.bigBetToday = (ch.prog.bigBetToday or 0) + 1 end
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- La mesa no llego a empezar: se devuelve la apuesta
local function rpc_bet_cancel(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    if d.bet and not d.bet.started then d.gold = d.gold + d.bet.amount; d.bet = nil end
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- La partida empezo de verdad: desde aqui ya no se puede cancelar sin perder
local function rpc_match_start(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    if d.bet then d.bet.started = true end
    d.stats.startedAt = os.time()
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- Cierre de partida: aqui el servidor paga (o no) la apuesta, la experiencia, el pase y la anfora
local function rpc_match_end(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local d0 = decode(payload)
  local won = d0.won == true
  local mode = d0.mode
  local humans = tonumber(d0.humans) or 0
  local refund = d0.refund == true
  local ok, res, doc = eco_update(uid, function(d)
    local now = os.time()
    if (now - (tonumber(d.stats.lastEnd) or 0)) < MATCH_MIN_GAP then return false, "muy_rapido" end
    d.stats.lastEnd = now
    d.stats.games = (d.stats.games or 0) + 1
    expire_bet(d)
    local out = { goldWon = 0, betPayout = 0, xp = 0 }
    -- desafios (los que el servidor ve de verdad)
    local ch = ensure_challenges(d)
    ch.prog.gamesToday = (ch.prog.gamesToday or 0) + 1
    if won then ch.prog.winsToday = (ch.prog.winsToday or 0) + 1 end
    if mode == "1v1" then ch.prog.games1v1Today = (ch.prog.games1v1Today or 0) + 1 end
    if mode == "2v2" then ch.prog.games2v2Today = (ch.prog.games2v2Today or 0) + 1 end
    -- experiencia y pase
    local xp = (10 + (won and 20 or 0)) * (boost_active(d) and 2 or 1)
    out.xp = xp
    d.pass.pts = (tonumber(d.pass.pts) or 0) + xp
    d.xp.lvl = (tonumber(d.xp.lvl) or 0) + xp
    local lvl = tonumber(d.xp.level) or 1
    while d.xp.lvl >= level_cost(lvl) do d.xp.lvl = d.xp.lvl - level_cost(lvl); lvl = lvl + 1 end
    d.xp.level = lvl
    local bet = d.bet
    d.bet = nil
    if won then
      d.stats.wins = (d.stats.wins or 0) + 1
      d.gold = d.gold + 50; out.goldWon = 50
      local tier
      if bet then
        out.betPayout = bet.amount * 2
        d.gold = d.gold + out.betPayout
        out.goldWon = out.goldWon + out.betPayout
        tier = bet_chest_tier(bet.idx)
      else
        local roll = math.random()
        tier = roll < 0.70 and "bronce" or (roll < 0.95 and "plata" or "oro")
      end
      local slot = add_chest(d, tier)
      if slot then out.chest = { type = tier, slot = slot } end
    elseif bet and refund and humans > 0 then
      -- gano un jugador desconectado (su bot): se devuelve la apuesta (con tope diario)
      local today = eco_day()
      if d.stats.refDay ~= today then d.stats.refDay = today; d.stats.refN = 0 end
      if (d.stats.refN or 0) < REFUND_DAY_CAP then
        d.stats.refN = (d.stats.refN or 0) + 1
        d.gold = d.gold + bet.amount; out.refunded = bet.amount
      end
    end
    return true, out
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { result = res })
end

-- Eventos de partida que el servidor no puede ver (capturas, dobles, tesoros, rachas): se aceptan con tope diario
local function rpc_progress(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local d0 = decode(payload)
  local track, n = d0.track, tonumber(d0.n) or 1
  local cap = type(track) == "string" and TRACK_CAPS[track]
  if not cap then return eco_fail("pedido_invalido") end
  if n < 1 then n = 1 end
  if n > 10 then n = 10 end
  local ok, res, doc = eco_update(uid, function(d)
    local ch = ensure_challenges(d)
    ch.prog[track] = math.min(cap, (ch.prog[track] or 0) + n)
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- ---- Enganches con lo que ya existia (torneos y compras) ----
ECO_SPEND = function(uid, gold)
  local ok, err = eco_update(uid, function(d)
    if d.gold < gold then return false, "sin_saldo" end
    d.gold = d.gold - gold
    return true
  end)
  return ok, err
end

ECO_CHEST = function(uid, ctype)
  eco_update(uid, function(d)
    if not add_chest(d, ctype) then d.gold = d.gold + 20000 end   -- sin espacio: 20.000 de oro
    return true
  end)
end

ECO_IAP = function(uid, v)
  if not v then return end
  if (tonumber(v.xp_hours) or 0) > 0 or v.pass_premium then
    eco_update(uid, function(d)
      if (tonumber(v.xp_hours) or 0) > 0 then add_xp_boost(d, v.xp_hours) end
      if v.pass_premium then d.pass.premium = true end
      return true
    end)
  end
end

nk.register_rpc(rpc_bet_hold, "eco_bet_hold")
nk.register_rpc(rpc_bet_cancel, "eco_bet_cancel")
nk.register_rpc(rpc_match_start, "eco_match_start")
nk.register_rpc(rpc_match_end, "eco_match_end")
nk.register_rpc(rpc_progress, "eco_progress")
