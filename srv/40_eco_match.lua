
-- ============================================================================
-- ECONOMIA (parte C): apuestas, cierre de partida, experiencia, torneos y compras
-- ============================================================================
local BET_TIERS = { 500, 2000, 5000, 10000, 50000, 250000, 1000000, 5000000, 15000000, 30000000 }
local BET_STALE = 1800          -- una apuesta sin cerrar en 30 min se pierde (evita "salirme si voy perdiendo")
local MATCH_MIN_GAP = 45        -- segundos minimos entre dos cierres de partida
local MATCH_MIN_DUR = 20        -- una partida de verdad dura mas que esto desde que empezo
local BET_STREAK_MAX = 8        -- tantas victorias seguidas con apuesta ya es raro: se deja de pagar ganancia ese dia
local BET_PROFIT_DAY_CAP = 60000000  -- ganancia maxima por apuestas en un dia (el resto se devuelve como la apuesta)
local REFUND_DAY_CAP = 3        -- devoluciones por "rival desconectado" al dia
local SECOND_DAY_CAP = 30       -- veces al dia que se le devuelve la apuesta al 2.o lugar (partidas de 4)
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
    -- una apuesta vieja que nunca llego a empezar se devuelve sola (por si fallo el aviso de cancelar)
    if d.bet and not d.bet.started then d.gold = d.gold + d.bet.amount; d.bet = nil end
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
    d.stats.dchg = 0            -- cambios de dados de esta partida (el precio sube con cada uno)
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
  local place = tonumber(d0.place) or 0        -- 1 = llego primero, 2 = llego segundo (partidas de 4)
  local early = d0.early == true               -- el 1.o cobra en cuanto llega; la partida sigue por el 2.o
  local payers = math.floor(tonumber(d0.payers) or 2)   -- jugadores reales que apostaron (pozo = apuesta x pagadores)
  if payers < 2 then payers = 2 end
  if payers > 4 then payers = 4 end
  local ok, res, doc = eco_update(uid, function(d)
    local now = os.time()
    if (now - (tonumber(d.stats.lastEnd) or 0)) < MATCH_MIN_GAP then
      d.bet = nil                      -- cierre demasiado seguido: la apuesta se da por perdida y no hay premios
      return true, { rejected = "muy_rapido", goldWon = 0, betPayout = 0, xp = 0 }
    end
    local st0 = tonumber(d.stats.startedAt) or 0
    if d.bet and d.bet.started and st0 > 0 and (now - st0) < MATCH_MIN_DUR then
      d.bet = nil                      -- cerrada antes de poder haber terminado: se pierde
      d.stats.lastEnd = now
      return true, { rejected = "muy_corta", goldWon = 0, betPayout = 0, xp = 0 }
    end
    d.stats.startedAt = 0
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
    -- regla del juego: si no ganas la partida, no sumas nada (ni nivel ni pase)
    local xp = won and (30 * (boost_active(d) and 2 or 1)) or 0
    out.xp = xp
    if xp > 0 then
      d.pass.pts = (tonumber(d.pass.pts) or 0) + xp
      d.xp.lvl = (tonumber(d.xp.lvl) or 0) + xp
      local lvl = tonumber(d.xp.level) or 1
      while d.xp.lvl >= level_cost(lvl) do d.xp.lvl = d.xp.lvl - level_cost(lvl); lvl = lvl + 1 end
      d.xp.level = lvl
    end
    local bet = d.bet
    d.bet = nil
    if won then
      d.stats.wins = (d.stats.wins or 0) + 1
      d.gold = d.gold + 50; out.goldWon = 50
      local tier
      if bet then
        local today = eco_day()
        if d.stats.bpDay ~= today then d.stats.bpDay = today; d.stats.bpProfit = 0; d.stats.bstreak = 0 end
        local fair = bet.started and (d.stats.bstreak or 0) < BET_STREAK_MAX
                     and ((d.stats.bpProfit or 0) + bet.amount) <= BET_PROFIT_DAY_CAP
        if fair then
          -- 4 jugadores todos contra todos: el ganador se lleva el pozo completo (apuesta x 4).
          -- 1 vs 1 y 2 vs 2 (cada ganador cobra la mitad del pozo): apuesta x 2.
          local mult = 2
          if mode ~= "1v1" and mode ~= "2v2" then mult = payers end
          out.betPayout = bet.amount * mult
          -- Podio (4 jugadores, al menos 3 con apuesta): el 2.o recupera su apuesta, asi que al 1.o se le descuenta
          -- (si el 2.o resulta ser una maquina, el celular del 1.o pide el ajuste con eco_match_adjust y se le devuelve)
          if early and place == 1 and mode ~= "1v1" and mode ~= "2v2" and payers >= 3 then
            out.betPayout = out.betPayout - bet.amount
            d.stats.adjAmt = bet.amount; d.stats.adjT = now
          end
          d.stats.bstreak = (d.stats.bstreak or 0) + 1
          d.stats.bpProfit = (d.stats.bpProfit or 0) + (out.betPayout - bet.amount)
        else
          out.betPayout = bet.amount     -- solo se devuelve lo apostado
          out.betLimited = true
        end
        d.gold = d.gold + out.betPayout
        out.goldWon = out.goldWon + out.betPayout
        tier = bet_chest_tier(bet.idx)
      else
        local roll = math.random()
        tier = roll < 0.70 and "bronce" or (roll < 0.95 and "plata" or "oro")
      end
      local slot = add_chest(d, tier)
      if slot then out.chest = { type = tier, slot = slot } end
    elseif bet and not won then
      d.stats.bstreak = 0
    end
    -- 2.o lugar en una partida de 4: no pierde nada, se le devuelve la apuesta (con tope diario)
    if (not won) and bet and place == 2 and bet.started and mode ~= "1v1" and mode ~= "2v2" and payers >= 3 then
      local today2 = eco_day()
      if d.stats.p2Day ~= today2 then d.stats.p2Day = today2; d.stats.p2N = 0 end
      if (d.stats.p2N or 0) < SECOND_DAY_CAP then
        d.stats.p2N = (d.stats.p2N or 0) + 1
        d.gold = d.gold + bet.amount
        out.betPayout = bet.amount; out.goldWon = bet.amount; out.second = true
      end
    end
    if (not won) and bet and refund and humans > 0 then
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

-- El 1.o cobro de entrada suponiendo que el 2.o tambien aposto; si el 2.o fue una maquina, se le paga la diferencia (una sola vez)
local function rpc_match_adjust(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local amt = tonumber(d.stats.adjAmt) or 0
    local t = tonumber(d.stats.adjT) or 0
    d.stats.adjAmt = 0
    if amt > 0 and (os.time() - t) <= BET_STALE then
      d.gold = d.gold + amt
      d.stats.bpProfit = (d.stats.bpProfit or 0) + amt
      return true, { paid = amt }
    end
    return true, { paid = 0 }
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { result = res })
end

-- Cambiar los dados en plena partida: el precio lo pone el servidor (el primero gratis, luego sube)
local DICE_CHANGE_COSTS = { 0, 10, 15, 20, 30, 40, 50, 75, 100 }
local function rpc_dice_change(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local n = tonumber(d.stats.dchg) or 0
    local cost = DICE_CHANGE_COSTS[n + 1]
    if cost == nil then return false, "sin_mas_cambios" end
    if d.diamonds < cost then return false, "sin_saldo" end
    d.diamonds = d.diamonds - cost
    d.stats.dchg = n + 1
    return true, { cost = cost, count = n + 1 }
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { change = res })
end

-- Video dentro de la partida: +15 gemas (un ritmo minimo entre videos y un tope por dia)
local GAME_AD_GEMS, GAME_AD_DAY_MAX = 15, 20
local function rpc_game_ad(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local today = eco_day()
    d.ads = d.ads or {}
    if d.ads.gday ~= today then d.ads.gday = today; d.ads.gn = 0 end
    local t = os.time()
    if (t - (tonumber(d.ads.glast) or 0)) < AD_MIN_GAP then return false, "muy_rapido" end
    if d.ads.gn >= GAME_AD_DAY_MAX then return false, "tope_diario" end
    d.ads.gn = d.ads.gn + 1; d.ads.glast = t
    d.diamonds = d.diamonds + GAME_AD_GEMS
    return true, GAME_AD_GEMS
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { diamonds = res })
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
nk.register_rpc(rpc_match_adjust, "eco_match_adjust")
nk.register_rpc(rpc_progress, "eco_progress")
nk.register_rpc(rpc_dice_change, "eco_dice_change")
nk.register_rpc(rpc_game_ad, "eco_game_ad")
