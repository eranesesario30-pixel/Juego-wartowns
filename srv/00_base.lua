-- Parche — guardia de economía (Nakama, runtime Lua)
-- Qué hace: el teléfono sigue guardando su oro y sus diamantes como siempre, pero el
-- servidor vigila cada guardado y NO deja que el saldo suba más de lo que puede subir
-- jugando de verdad. Si alguien edita su saldo, el servidor lo recorta y lo anota en el registro.
local nk = require("nakama")

-- Límites (ajustables). Se miden contra el último saldo que el servidor aceptó.
local LIMITS = {
  gold_per_save     = 130000000, -- mayor premio posible en una partida (4 jugadores x apuesta máxima de 30M)
  gold_per_hour     = 400000000,
  diamonds_per_save = 1000,
  diamonds_per_hour = 2500,
  gold_hard_cap     = 5000000000,
  diamonds_hard_cap = 1000000,
  start_gold        = 2000,      -- perfil nuevo
  start_diamonds    = 50,
}
local GUARD = "econ_guard"
local ECO_PROFILE = nil   -- si el jugador ya tiene saldo en el servidor, el telefono no puede cambiarlo
local HOUR = 3600

local function num(v)
  v = tonumber(v)
  if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
  if v < 0 then v = 0 end
  return math.floor(v)
end

local function read_state(uid)
  local r = nk.storage_read({{ collection = GUARD, key = "state", user_id = uid }})
  if r and #r > 0 then return r[1].value, r[1].version end
  return nil, nil
end

local function write_state(uid, st)
  nk.storage_write({{ collection = GUARD, key = "state", user_id = uid, value = st,
                      permission_read = 0, permission_write = 0 }})
end

local function read_profile(uid)
  local r = nk.storage_read({{ collection = "profile", key = "main", user_id = uid }})
  if r and #r > 0 then
    local ok, v = pcall(nk.json_decode, r[1].value)
    if ok and type(v) == "table" then return v end
  end
  return nil
end

-- Recorta un valor nuevo al máximo permitido. Devuelve valor final y si hubo recorte.
local function limit_one(new, prev, per_save, hour_gain, per_hour, hard)
  if new > hard then new = hard end
  local gain = new - prev
  if gain <= 0 then return new, 0, false end
  local room = per_hour - hour_gain
  if room < 0 then room = 0 end
  local allowed = math.min(per_save, room)
  if gain > allowed then
    return prev + allowed, allowed, true
  end
  return new, gain, false
end

local function guard_profile(uid, obj)
  local ok, v = pcall(nk.json_decode, obj.value)
  if not ok or type(v) ~= "table" then return false end
  if ECO_PROFILE and ECO_PROFILE(uid, obj, v) then return true end
  local now = os.time()
  local st = read_state(uid)
  if not st then
    local p = read_profile(uid)
    if p then
      st = { gold = num(p.gold) or LIMITS.start_gold, diamonds = num(p.diamonds) or LIMITS.start_diamonds }
    else
      st = { gold = LIMITS.start_gold, diamonds = LIMITS.start_diamonds }
    end
    st.win_start = now; st.gold_gain = 0; st.diamonds_gain = 0; st.strikes = 0
  end
  if now - (st.win_start or 0) >= HOUR then st.win_start = now; st.gold_gain = 0; st.diamonds_gain = 0 end

  local ng = num(v.gold); local nd = num(v.diamonds)
  if ng == nil then ng = st.gold end
  if nd == nil then nd = st.diamonds end

  local fg, gg, cg = limit_one(ng, st.gold, LIMITS.gold_per_save, st.gold_gain, LIMITS.gold_per_hour, LIMITS.gold_hard_cap)
  local fd, gd, cd = limit_one(nd, st.diamonds, LIMITS.diamonds_per_save, st.diamonds_gain, LIMITS.diamonds_per_hour, LIMITS.diamonds_hard_cap)

  if cg or cd then
    st.strikes = (st.strikes or 0) + 1
    nk.logger_warn(string.format("ECON_GUARD recorte user=%s oro %d->%d (pidio %d) diamantes %d->%d (pidio %d) avisos=%d",
      uid, st.gold, fg, ng, st.diamonds, fd, nd, st.strikes))
  end

  st.gold = fg; st.diamonds = fd
  st.gold_gain = (st.gold_gain or 0) + gg
  st.diamonds_gain = (st.diamonds_gain or 0) + gd
  write_state(uid, st)

  -- Ojo: NO se vuelve a codificar todo el perfil (json_encode convertia las listas con null,
  -- como las anforas, en objetos y rompia el juego). Solo se corrigen los dos numeros dentro del texto.
  local out = obj.value
  if v.gold ~= nil and fg ~= ng then
    out = out:gsub('("gold"%s*:%s*)-?[%d%.eE%+%-]+', '%1' .. string.format("%.0f", fg), 1)
  end
  if v.diamonds ~= nil and fd ~= nd then
    out = out:gsub('("diamonds"%s*:%s*)-?[%d%.eE%+%-]+', '%1' .. string.format("%.0f", fd), 1)
  end
  obj.value = out
  return true
end

local function before_write(context, payload)
  local uid = context.user_id
  if not uid then return payload end
  local keep = {}
  for _, obj in ipairs(payload.objects or {}) do
    if obj.collection == GUARD then
      nk.logger_warn("ECON_GUARD intento de escribir la colección protegida user=" .. tostring(uid))
    else
      if obj.collection == "profile" and obj.key == "main" then guard_profile(uid, obj) end
      keep[#keep + 1] = obj
    end
  end
  payload.objects = keep
  return payload
end

local function before_delete(context, payload)
  local keep = {}
  for _, o in ipairs(payload.object_ids or {}) do
    if o.collection ~= GUARD then keep[#keep + 1] = o end
  end
  payload.object_ids = keep
  return payload
end


-- ============================================================================
-- COMPRAS REALES (Google Play / App Store)
-- Regla de oro: el teléfono NUNCA decide qué se compró ni cuánto se da. El servidor
-- le pregunta a Google/Apple si el pago es real, mira qué producto es EN SU CATÁLOGO
-- y apunta el premio como "pendiente". El teléfono lo cobra con iap_claim y lo
-- confirma con iap_ack. Cada compra (transaction_id) solo se puede dar UNA vez.
-- ============================================================================
local IAP = "iap_grants"

-- IDs EXACTOS que hay que crear en Play Console / App Store Connect.
local CATALOG = {
  gem_150   = { diamonds = 150 },
  gem_300   = { diamonds = 300 },
  gem_700   = { diamonds = 700 },
  gem_1500  = { diamonds = 1500 },
  gem_3500  = { diamonds = 3500 },
  gem_10000 = { diamonds = 10000 },
  gold_40k  = { gold = 40000 },
  gold_100k = { gold = 100000 },
  gold_250k = { gold = 250000 },
  gold_1m   = { gold = 1000000 },
  gold_5m   = { gold = 5000000 },
  gold_7m   = { gold = 7000000 },
  xp_boost_6h   = { xp_hours = 6 },
  xp_boost_3d   = { xp_hours = 72 },
  xp_boost_7d   = { xp_hours = 168 },
  xp_boost_30d  = { xp_hours = 720 },
  xp_boost_70d  = { xp_hours = 1680 },
  xp_boost_150d = { xp_hours = 3600 },
  welcome_offer    = { gold = 5000000, diamonds = 500, once = true },
  bigwin_gold_15m  = { gold = 15000000 },
  parche_pass_s1   = { pass_premium = true },
}

local function safe_key(store, tid)
  local k = (tostring(store) .. "_" .. tostring(tid)):gsub("[^%w%._%-]", "_")
  return k
end

local function reply(t) return nk.json_encode(t) end

-- Suma el premio a lo que la guardia considera "saldo aceptado", para que el
-- siguiente guardado del teléfono (saldo + compra) no se recorte como trampa.
local ECO_CREDIT = nil   -- lo define el modulo de economia (cartera en el servidor)
local ECO_SPEND = nil    -- descuenta oro del saldo del servidor (entradas de torneo)
local ECO_IAP = nil      -- aplica elixires y pase premium de una compra
local ECO_CHEST = nil    -- entrega un anfora (premios de liga)
local function credit_guard(uid, gold, diamonds)
  if ECO_CREDIT then ECO_CREDIT(uid, gold, diamonds); return end
  local st = read_state(uid)
  if not st then
    local p = read_profile(uid)
    st = { gold = (p and num(p.gold)) or LIMITS.start_gold, diamonds = (p and num(p.diamonds)) or LIMITS.start_diamonds,
           win_start = os.time(), gold_gain = 0, diamonds_gain = 0, strikes = 0 }
  end
  st.gold = (st.gold or 0) + (gold or 0)
  st.diamonds = (st.diamonds or 0) + (diamonds or 0)
  write_state(uid, st)
end

local function rpc_iap_validate(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" or type(d.receipt) ~= "string" or d.receipt == "" then
    return reply({ ok = false, error = "recibo_invalido" })
  end
  local ok, res
  if d.platform == "apple" then
    ok, res = pcall(nk.purchase_validate_apple, uid, d.receipt, true)
  else
    ok, res = pcall(nk.purchase_validate_google, uid, d.receipt, true)
  end
  if not ok or type(res) ~= "table" then
    nk.logger_warn("IAP validacion fallo user=" .. tostring(uid) .. " err=" .. tostring(res))
    return reply({ ok = false, error = "validacion_fallida" })
  end
  local made, seen = 0, 0
  for _, vp in ipairs(res.validated_purchases or {}) do
    local prod = CATALOG[vp.product_id]
    local refunded = vp.refund_time and tonumber(vp.refund_time) and tonumber(vp.refund_time) > 0
    local pending = false
    if vp.provider_response and vp.provider_response ~= "" then
      local okp, pr = pcall(nk.json_decode, vp.provider_response)
      if okp and type(pr) == "table" and pr.purchaseState ~= nil and tonumber(pr.purchaseState) ~= 0 then pending = true end
    end
    if prod and not refunded and not pending then
      local key = safe_key(vp.store or d.platform or "google", vp.transaction_id)
      local ex = nk.storage_read({{ collection = IAP, key = key, user_id = uid }})
      if ex and #ex > 0 then
        seen = seen + 1
      else
        local blocked = false
        if prod.once then
          local o = nk.storage_read({{ collection = IAP, key = "once_" .. vp.product_id, user_id = uid }})
          if o and #o > 0 then blocked = true end
        end
        if blocked then
          nk.logger_warn("IAP oferta unica repetida user=" .. tostring(uid) .. " prod=" .. tostring(vp.product_id))
        else
          local dia = prod.diamonds or 0
          local first = false
          if dia > 0 and string.sub(vp.product_id, 1, 4) == "gem_" then
            local f = nk.storage_read({{ collection = IAP, key = "first_" .. vp.product_id, user_id = uid }})
            if not (f and #f > 0) then first = true; dia = dia * 2 end
          end
          local writes = {{ collection = IAP, key = key, user_id = uid, permission_read = 0, permission_write = 0,
            value = { product_id = vp.product_id, transaction_id = vp.transaction_id, store = vp.store,
                      gold = prod.gold or 0, diamonds = dia, xp_hours = prod.xp_hours or 0, first = first,
                      pass_premium = prod.pass_premium or false, status = "pending", credited = false, created = os.time() } }}
          if first then
            writes[#writes + 1] = { collection = IAP, key = "first_" .. vp.product_id, user_id = uid,
              permission_read = 0, permission_write = 0, value = { t = os.time() } }
          end
          if prod.once then
            writes[#writes + 1] = { collection = IAP, key = "once_" .. vp.product_id, user_id = uid,
              permission_read = 0, permission_write = 0, value = { t = os.time() } }
          end
          nk.storage_write(writes)
          nk.logger_info("IAP compra registrada user=" .. tostring(uid) .. " prod=" .. tostring(vp.product_id))
          made = made + 1
        end
      end
    end
  end
  return reply({ ok = true, new = made, already_seen = seen })
end

local function rpc_iap_claim(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local objs = nk.storage_list(uid, IAP, 100, nil)
  local out = {}
  for _, o in ipairs(objs or {}) do
    local v = o.value
    if type(v) == "table" and v.transaction_id and v.status ~= "granted" then
      if not v.credited then
        credit_guard(uid, v.gold, v.diamonds)
        if ECO_IAP then ECO_IAP(uid, v) end
        v.credited = true
        nk.storage_write({{ collection = IAP, key = o.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
      end
      out[#out + 1] = { transaction_id = v.transaction_id, key = o.key, product_id = v.product_id,
                        gold = v.gold or 0, diamonds = v.diamonds or 0, xp_hours = v.xp_hours or 0,
                        pass_premium = v.pass_premium or false }
    end
  end
  return reply({ ok = true, grants = out, count = #out })
end

local function rpc_iap_ack(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" or type(d.key) ~= "string" then return reply({ ok = false, error = "pedido_invalido" }) end
  local r = nk.storage_read({{ collection = IAP, key = d.key, user_id = uid }})
  if r and #r > 0 and type(r[1].value) == "table" then
    local v = r[1].value
    v.status = "granted"; v.granted_at = os.time()
    nk.storage_write({{ collection = IAP, key = d.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
    return reply({ ok = true })
  end
  return reply({ ok = false, error = "no_existe" })
end

nk.register_rpc(rpc_iap_validate, "iap_validate")
nk.register_rpc(rpc_iap_claim, "iap_claim")
local function rpc_iap_firsts(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local out = {}
  for _, pid in ipairs({ "gem_150", "gem_300", "gem_700", "gem_1500", "gem_3500", "gem_10000" }) do
    local f = nk.storage_read({{ collection = IAP, key = "first_" .. pid, user_id = uid }})
    if f and #f > 0 then out[#out + 1] = pid end
  end
  return reply({ ok = true, bought = out })
end
nk.register_rpc(rpc_iap_ack, "iap_ack")
nk.register_rpc(rpc_iap_firsts, "iap_firsts")


-- ============================================================================
-- LIGA GLOBAL SEMANAL
-- Cada partida (ganada +25, perdida +8) se apunta en una tabla del servidor que se
-- reinicia sola cada lunes a las 00:00 UTC (domingo en la noche en América).
-- El teléfono solo avisa "gané" o "perdí"; los puntos los pone el servidor, y no deja
-- apuntar partidas con menos de 60 segundos de diferencia.
-- El #1 de la semana pasada cobra su premio UNA sola vez con liga_claim (el oro y los
-- diamantes entran por la guardia, igual que las compras, sin recortes).
-- ============================================================================
local GLOBAL_BOARD = "global_weekly"
local LIGA_RL = "liga_rl"
local LIGA_GRANTS = "liga_grants"
local LIGA_MIN_GAP = 90
local GLOBAL_PRIZE = { gold = 500000, diamonds = 15000 }
local GLOBAL_TOP_N = 50

pcall(function()
  nk.leaderboard_create(GLOBAL_BOARD, true, "desc", "incr", "0 0 * * 1", {})
end)

local function clean_text(v, maxlen)
  if type(v) ~= "string" then return nil end
  v = v:gsub("[%c<>\"\\]", ""):sub(1, maxlen)
  if v == "" then return nil end
  return v
end

local function board_info()
  local ok, r = pcall(nk.leaderboards_get_id, { GLOBAL_BOARD })
  if ok and r and r[1] then return r[1] end
  return nil
end

-- ---------- Ligas por nivel + anti-trampa ----------
-- El servidor lleva los puntos acumulados de cada jugador (de ahi sale su liga: cada 300 sube)
-- y una tabla semanal por liga. SOLO cuentan partidas online contra personas reales
-- (el telefono manda el id de los rivales y el servidor comprueba que existen), con tope
-- por dia y tope por rival por dia, para que nadie pueda inflar puntos con partidas falsas,
-- bots o cuentas gemelas.
local LIGA_STATE = "liga_state"
local LIGA_TIERS = { "bronce", "plata", "oro", "elite" }
local LIGA_TIER_PTS = 300
local LIGA_DAY_CAP = 40
local LIGA_OPP_CAP = 4
local LIGA_MIN_PLAYERS = 3
local LIGA_MIN_SCORE = 50
local LIGA_TOP_PRIZES = 7
local function lg(g, d, a) return { gold = g, diamonds = d, amphora = a } end
local LIGA_REWARDS = {
  bronce = { lg(40000, 800, "plata"), lg(30000, 800), lg(30000, 800), lg(20000, 0), lg(20000, 0), lg(20000, 0), lg(20000, 0) },
  plata  = { lg(80000, 1500, "oro"), lg(60000, 1500, "plata"), lg(60000, 1500, "plata"), lg(40000, 0), lg(40000, 0), lg(40000, 0), lg(40000, 0) },
  oro    = { lg(150000, 2500, "oro"), lg(100000, 2500, "plata"), lg(100000, 2500, "plata"), lg(70000, 25), lg(70000, 25), lg(70000, 25), lg(70000, 25) },
  elite  = { lg(300000, 5000, "diamante"), lg(200000, 5000, "oro"), lg(200000, 5000, "oro"), lg(100000, 50), lg(100000, 50), lg(100000, 50), lg(100000, 50) },
}
for _, t in ipairs(LIGA_TIERS) do
  pcall(function() nk.leaderboard_create("liga_" .. t, true, "desc", "incr", "0 0 * * 1", {}) end)
end

local function tier_of_pts(pts)
  local t = math.floor((tonumber(pts) or 0) / LIGA_TIER_PTS) + 1
  if t > #LIGA_TIERS then t = #LIGA_TIERS end
  if t < 1 then t = 1 end
  return t
end

local function today_key() return os.date("!%Y%m%d") end

local function read_liga(uid, key)
  local r = nk.storage_read({{ collection = LIGA_STATE, key = key, user_id = uid }})
  if r and #r > 0 and type(r[1].value) == "table" then return r[1].value end
  return { pts = 0 }
end

local function write_liga(uid, key, st)
  nk.storage_write({{ collection = LIGA_STATE, key = key, user_id = uid, value = st,
                      permission_read = 0, permission_write = 0 }})
end

-- Lista de amigos que manda el telefono (solo ids validos, maximo 100).
local function clean_friends(v)
  local out = {}
  if type(v) ~= "table" then return out end
  for _, f in ipairs(v) do
    if type(f) == "string" and #f > 0 and #f <= 64 then out[#out + 1] = f end
    if #out >= 100 then break end
  end
  return out
end

-- Rivales validos de una partida: ids distintos al propio, que existan de verdad y
-- que NO sean amigos (ni mios, ni de ellos: si el rival me tiene de amigo tampoco cuenta).
local function match_opps(uid, d, friends)
  if d.online ~= true or type(d.opps) ~= "table" then return nil end
  local fset = {}
  for _, f in ipairs(friends or {}) do fset[f] = true end
  local seen, opps = {}, {}
  for _, o in ipairs(d.opps) do
    if type(o) == "string" and o ~= uid and #o > 0 and #o <= 64 and not seen[o] then
      seen[o] = true
      if not fset[o] then
        local ost = read_liga(o, "main")
        local theirs = false
        for _, f in ipairs(type(ost.fr) == "table" and ost.fr or {}) do if f == uid then theirs = true; break end end
        if not theirs then opps[#opps + 1] = o end
      end
    end
    if #opps >= 3 then break end
  end
  if #opps == 0 then return nil end
  local ok, us = pcall(nk.users_get_id, opps)
  if not ok or type(us) ~= "table" or #us ~= #opps then return nil end
  return opps
end

-- Topes diarios (en el mismo registro `st`). Devuelve true si esta partida puede contar.
local function farm_ok(st, opps, day_cap, opp_cap)
  local day = today_key()
  if st.day ~= day then st.day = day; st.n = 0; st.opp = {} end
  if type(st.opp) ~= "table" then st.opp = {} end
  if (st.n or 0) >= day_cap then return false end
  local fresh = false
  for _, o in ipairs(opps) do
    if (st.opp[o] or 0) < opp_cap then fresh = true end
  end
  if not fresh then return false end
  st.n = (st.n or 0) + 1
  for _, o in ipairs(opps) do st.opp[o] = (st.opp[o] or 0) + 1 end
  return true
end

local function rpc_global_report(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" then return reply({ ok = false, error = "pedido_invalido" }) end
  local st = read_liga(uid, "main")
  local total = tonumber(st.pts) or 0
  local friends = clean_friends(d.friends)
  if type(d.friends) == "table" then st.fr = friends end
  local opps = match_opps(uid, d, friends)
  if not opps then
    -- partida sin personas reales (bots / amigos / sin conexion): no suma
    if type(d.friends) == "table" then write_liga(uid, "main", st) end
    return reply({ ok = true, counted = false, reason = "sin_rivales", total = total, tier = tier_of_pts(total) })
  end
  local now = os.time()
  local rl = nk.storage_read({{ collection = LIGA_RL, key = "main", user_id = uid }})
  if rl and #rl > 0 and type(rl[1].value) == "table" and (now - (tonumber(rl[1].value.t) or 0)) < LIGA_MIN_GAP then
    return reply({ ok = false, error = "muy_rapido", total = total, tier = tier_of_pts(total) })
  end
  nk.storage_write({{ collection = LIGA_RL, key = "main", user_id = uid, value = { t = now },
                      permission_read = 0, permission_write = 0 }})
  if not farm_ok(st, opps, LIGA_DAY_CAP, LIGA_OPP_CAP) then
    write_liga(uid, "main", st)
    return reply({ ok = true, counted = false, reason = "tope_diario", total = total, tier = tier_of_pts(total) })
  end
  local pts = (d.won == true) and 25 or 8
  local tier_before = tier_of_pts(total)
  st.pts = total + pts
  write_liga(uid, "main", st)
  local name = clean_text(d.name, 24) or "Jugador"
  local meta = {}
  local av = clean_text(d.avatar, 200)
  if av then meta.av = av end
  local ok, rec = pcall(nk.leaderboard_record_write, GLOBAL_BOARD, uid, name, pts, 0, meta)
  if not ok then
    nk.logger_warn("LIGA no se pudo apuntar user=" .. tostring(uid) .. " err=" .. tostring(rec))
    return reply({ ok = false, error = "no_se_pudo" })
  end
  pcall(nk.leaderboard_record_write, "liga_" .. LIGA_TIERS[tier_before], uid, name, pts, 0, meta)
  return reply({ ok = true, counted = true, points = rec and rec.score or pts, total = st.pts, tier = tier_of_pts(st.pts) })
end

local function rpc_global_top(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local ok, recs, owner_recs = pcall(nk.leaderboard_records_list, GLOBAL_BOARD, { uid }, GLOBAL_TOP_N, nil, nil)
  if not ok then return reply({ ok = false, error = "no_se_pudo" }) end
  local rows = {}
  for _, r in ipairs(recs or {}) do
    local m = r.metadata
    if type(m) == "string" then local okm, mm = pcall(nk.json_decode, m); m = okm and mm or nil end
    rows[#rows + 1] = { rank = r.rank, name = r.username or "Jugador", points = r.score,
                        av = type(m) == "table" and m.av or nil, me = (r.owner_id == uid) }
  end
  local me = nil
  if owner_recs and owner_recs[1] then me = { rank = owner_recs[1].rank, points = owner_recs[1].score } end
  local info = board_info()
  local st = read_liga(uid, "main")
  return reply({ ok = true, rows = rows, me = me, next_reset = info and info.next_reset or nil,
                 prize = GLOBAL_PRIZE, total = tonumber(st.pts) or 0, tier = tier_of_pts(st.pts) })
end

-- Tabla semanal de MI liga (la que me toca segun mis puntos acumulados en el servidor).
local function rpc_liga_tier_top(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local st = read_liga(uid, "main")
  local tier = tier_of_pts(st.pts)
  local board = "liga_" .. LIGA_TIERS[tier]
  local ok, recs, owner_recs = pcall(nk.leaderboard_records_list, board, { uid }, 20, nil, nil)
  if not ok then return reply({ ok = false, error = "no_se_pudo" }) end
  local rows = {}
  for _, r in ipairs(recs or {}) do
    local m = r.metadata
    if type(m) == "string" then local okm, mm = pcall(nk.json_decode, m); m = okm and mm or nil end
    rows[#rows + 1] = { rank = r.rank, name = r.username or "Jugador", points = r.score,
                        av = type(m) == "table" and m.av or nil, me = (r.owner_id == uid) }
  end
  local me = nil
  if owner_recs and owner_recs[1] then me = { rank = owner_recs[1].rank, points = owner_recs[1].score } end
  local okb, bi = pcall(nk.leaderboards_get_id, { board })
  local info = okb and bi and bi[1] or nil
  return reply({ ok = true, tier = tier, total = tonumber(st.pts) or 0, rows = rows, me = me,
                 next_reset = info and info.next_reset or nil, rewards = LIGA_REWARDS[LIGA_TIERS[tier]] })
end

-- Premio de la semana pasada: solo si fuiste el #1 y solo una vez.
local function rpc_liga_claim(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  -- 1) crear el premio pendiente si ganaste la semana pasada
  local info = board_info()
  local prev = info and tonumber(info.prev_reset) or 0
  if prev > 0 then
    local ok, recs = pcall(nk.leaderboard_records_list, GLOBAL_BOARD, nil, 1, nil, prev)
    if ok and recs and recs[1] and recs[1].owner_id == uid and (tonumber(recs[1].score) or 0) > 0 then
      local key = "global_" .. tostring(prev)
      local ex = nk.storage_read({{ collection = LIGA_GRANTS, key = key, user_id = uid }})
      if not (ex and #ex > 0) then
        nk.storage_write({{ collection = LIGA_GRANTS, key = key, user_id = uid, permission_read = 0, permission_write = 0,
          value = { kind = "global_weekly", gold = GLOBAL_PRIZE.gold, diamonds = GLOBAL_PRIZE.diamonds,
                    status = "pending", credited = false, created = os.time() } }})
        nk.logger_info("LIGA premio global creado user=" .. tostring(uid) .. " semana=" .. key)
      end
    end
  end
  -- 1b) premios por puesto de cada liga (semana pasada): top 7, con minimo de jugadores y de puntos
  for _, t in ipairs(LIGA_TIERS) do
    local okb, bi = pcall(nk.leaderboards_get_id, { "liga_" .. t })
    local binfo = okb and bi and bi[1] or nil
    local bprev = binfo and tonumber(binfo.prev_reset) or 0
    local bnext = binfo and tonumber(binfo.next_reset) or 0
    if bprev <= 0 and bnext > 0 then bprev = bnext - 7 * 86400 end
    if bprev > 0 then
      local gkey = "tier_" .. t .. "_" .. tostring(bprev)
      local gex = nk.storage_read({{ collection = LIGA_GRANTS, key = gkey, user_id = uid }})
      if not (gex and #gex > 0) then
        local okl, lrecs = pcall(nk.leaderboard_records_list, "liga_" .. t, nil, 100, nil, bprev)
        if okl and lrecs then
          local active, myrank, myscore = 0, nil, 0
          for i, r in ipairs(lrecs) do
            if (tonumber(r.score) or 0) > 0 then active = active + 1 end
            if r.owner_id == uid then myrank = i; myscore = tonumber(r.score) or 0 end
          end
          if myrank then
            if myrank <= LIGA_TOP_PRIZES and active >= LIGA_MIN_PLAYERS and myscore >= LIGA_MIN_SCORE then
              local pz = LIGA_REWARDS[t][myrank]
              nk.storage_write({{ collection = LIGA_GRANTS, key = gkey, user_id = uid, permission_read = 0, permission_write = 0,
                value = { kind = "league_rank", tier = t, rank = myrank, gold = pz.gold, diamonds = pz.diamonds,
                          amphora = pz.amphora or nil, status = "pending", credited = false, created = os.time() } }})
              nk.logger_info("LIGA premio de liga creado user=" .. tostring(uid) .. " " .. gkey .. " puesto=" .. tostring(myrank))
            else
              nk.storage_write({{ collection = LIGA_GRANTS, key = gkey, user_id = uid, permission_read = 0, permission_write = 0,
                value = { kind = "none", tier = t, gold = 0, diamonds = 0, status = "granted", credited = true, created = os.time() } }})
            end
          end
        end
      end
    end
  end
  -- 2) entregar lo pendiente (igual que las compras)
  local objs = nk.storage_list(uid, LIGA_GRANTS, 50, nil)
  local out = {}
  for _, o in ipairs(objs or {}) do
    local v = o.value
    if type(v) == "table" and v.status ~= "granted" then
      if not v.credited then
        credit_guard(uid, v.gold, v.diamonds)
        if v.amphora and ECO_CHEST then ECO_CHEST(uid, v.amphora) end
        v.credited = true
        nk.storage_write({{ collection = LIGA_GRANTS, key = o.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
      end
      out[#out + 1] = { key = o.key, kind = v.kind, gold = v.gold or 0, diamonds = v.diamonds or 0,
                        tier = v.tier, rank = v.rank, amphora = v.amphora }
    end
  end
  return reply({ ok = true, grants = out, count = #out })
end

local function rpc_liga_ack(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" or type(d.key) ~= "string" then return reply({ ok = false, error = "pedido_invalido" }) end
  local r = nk.storage_read({{ collection = LIGA_GRANTS, key = d.key, user_id = uid }})
  if r and #r > 0 and type(r[1].value) == "table" then
    local v = r[1].value
    v.status = "granted"; v.granted_at = os.time()
    nk.storage_write({{ collection = LIGA_GRANTS, key = d.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
    return reply({ ok = true })
  end
  return reply({ ok = false, error = "no_existe" })
end

nk.register_rpc(rpc_global_report, "global_report")
nk.register_rpc(rpc_global_top, "global_top")
nk.register_rpc(rpc_liga_tier_top, "liga_tier_top")
nk.register_rpc(rpc_liga_claim, "liga_claim")
nk.register_rpc(rpc_liga_ack, "liga_ack")


-- ============================================================================
-- TORNEOS (copas de 24 horas, por puntos)
-- Tres copas (bronce, plata, elite). Cada una se reinicia sola todos los dias a las
-- 00:00 UTC. Entras pagando la entrada (el telefono la descuenta; el servidor solo
-- anota que entraste). Cada partida online ganada suma 10 puntos a las copas donde
-- estes anotado (maximo 1 reporte por minuto). Al cerrar, el premio sale de lo
-- recaudado: 50% al 1ro, 30% al 2do, 20% al 3ro. Con
-- menos de 5 anotados se devuelve la entrada. Cada premio se cobra
-- UNA sola vez con tour_claim.
-- ============================================================================
local TOUR_CUPS = {
  bronce = { fee = 1000 },
  plata  = { fee = 5000 },
  elite  = { fee = 20000 },
}
local TOUR_ORDER = { "bronce", "plata", "elite" }
local TOUR_ENTRY = "tour_entry"
local TOUR_GRANTS = "tour_grants"
local TOUR_RL = "tour_rl"
local TOUR_MIN_GAP = 90
local TOUR_MIN_ENTRANTS = 5   -- con menos inscritos se devuelve la entrada
local TOUR_DAY_CAP = 30
local TOUR_OPP_CAP = 3
local TOUR_WIN_PTS = 10
local TOUR_SPLIT = { 0.5, 0.3, 0.2 }

for _, c in ipairs(TOUR_ORDER) do
  pcall(function()
    nk.leaderboard_create("tour_" .. c, true, "desc", "incr", "0 0 * * *", {})
  end)
end

local function tour_info_of(cup)
  local ok, r = pcall(nk.leaderboards_get_id, { "tour_" .. cup })
  if ok and r and r[1] then return r[1] end
  return nil
end

local function tour_pid(info)
  -- inicio del periodo actual = proximo reinicio - 1 dia
  local nr = info and tonumber(info.next_reset) or 0
  if nr <= 0 then return nil end
  return nr - 86400
end

local function tour_joined(uid, cup, pid)
  local r = nk.storage_read({{ collection = TOUR_ENTRY, key = cup .. "_" .. tostring(pid), user_id = uid }})
  return r and #r > 0
end

local function rpc_tour_info(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local cups = {}
  for _, cup in ipairs(TOUR_ORDER) do
    local info = tour_info_of(cup)
    local pid = tour_pid(info)
    local entry = { id = cup, fee = TOUR_CUPS[cup].fee, ends_at = info and info.next_reset or nil,
                    joined = false, entrants = 0, pool = 0, points = 0, rank = nil, top = {} }
    if pid then
      entry.joined = tour_joined(uid, cup, pid) and true or false
      local ok, recs, owner_recs = pcall(nk.leaderboard_records_list, "tour_" .. cup, { uid }, 100, nil, nil)
      if ok then
        entry.entrants = #(recs or {})
        entry.pool = entry.entrants * TOUR_CUPS[cup].fee
        for i, r in ipairs(recs or {}) do
          if i <= 3 and (tonumber(r.score) or 0) > 0 then
            entry.top[#entry.top + 1] = { rank = r.rank, name = r.username or "Jugador", points = r.score, me = (r.owner_id == uid) }
          end
        end
        if entry.joined and owner_recs and owner_recs[1] then
          entry.points = owner_recs[1].score; entry.rank = owner_recs[1].rank
        end
      end
    end
    cups[#cups + 1] = entry
  end
  return reply({ ok = true, cups = cups, split = TOUR_SPLIT })
end

local function rpc_tour_join(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" or type(d.cup) ~= "string" or not TOUR_CUPS[d.cup] then
    return reply({ ok = false, error = "pedido_invalido" })
  end
  local cup = d.cup
  local info = tour_info_of(cup)
  local pid = tour_pid(info)
  if not pid then return reply({ ok = false, error = "no_disponible" }) end
  -- no dejar entrar en el ultimo minuto del torneo
  if (tonumber(info.next_reset) or 0) - os.time() < 60 then return reply({ ok = false, error = "cerrando" }) end
  if tour_joined(uid, cup, pid) then return reply({ ok = false, error = "ya_anotado" }) end
  local name = clean_text(d.name, 24) or "Jugador"
  -- la entrada se cobra AQUI, del saldo del servidor (el telefono ya no decide)
  if ECO_SPEND then
    local paid, perr = ECO_SPEND(uid, TOUR_CUPS[cup].fee)
    if not paid then return reply({ ok = false, error = (perr == "sin_saldo") and "sin_saldo" or "no_se_pudo" }) end
  end
  local ok, err = pcall(nk.leaderboard_record_write, "tour_" .. cup, uid, name, 0, 0, {})
  if not ok then
    nk.logger_warn("TORNEO no se pudo anotar user=" .. tostring(uid) .. " err=" .. tostring(err))
    if ECO_CREDIT then ECO_CREDIT(uid, TOUR_CUPS[cup].fee, 0) end   -- devolver la entrada
    return reply({ ok = false, error = "no_se_pudo" })
  end
  nk.storage_write({{ collection = TOUR_ENTRY, key = cup .. "_" .. tostring(pid), user_id = uid,
                      value = { fee = TOUR_CUPS[cup].fee, t = os.time() }, permission_read = 0, permission_write = 0 }})
  return reply({ ok = true, fee = TOUR_CUPS[cup].fee })
end

local function rpc_tour_report(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" then return reply({ ok = false, error = "pedido_invalido" }) end
  if d.won ~= true then return reply({ ok = true, added = 0 }) end
  local mst = read_liga(uid, "main")
  local friends = clean_friends(d.friends)
  if type(d.friends) == "table" then mst.fr = friends; write_liga(uid, "main", mst) else friends = type(mst.fr) == "table" and mst.fr or {} end
  local opps = match_opps(uid, d, friends)
  if not opps then return reply({ ok = true, added = 0, reason = "sin_rivales" }) end
  local tst = read_liga(uid, "tour")
  if not farm_ok(tst, opps, TOUR_DAY_CAP, TOUR_OPP_CAP) then
    write_liga(uid, "tour", tst)
    return reply({ ok = true, added = 0, reason = "tope_diario" })
  end
  write_liga(uid, "tour", tst)
  local now = os.time()
  local rl = nk.storage_read({{ collection = TOUR_RL, key = "main", user_id = uid }})
  if rl and #rl > 0 and type(rl[1].value) == "table" and (now - (tonumber(rl[1].value.t) or 0)) < TOUR_MIN_GAP then
    return reply({ ok = false, error = "muy_rapido" })
  end
  nk.storage_write({{ collection = TOUR_RL, key = "main", user_id = uid, value = { t = now },
                      permission_read = 0, permission_write = 0 }})
  local name = clean_text(d.name, 24) or "Jugador"
  local added = 0
  for _, cup in ipairs(TOUR_ORDER) do
    local pid = tour_pid(tour_info_of(cup))
    if pid and tour_joined(uid, cup, pid) then
      local ok = pcall(nk.leaderboard_record_write, "tour_" .. cup, uid, name, TOUR_WIN_PTS, 0, {})
      if ok then added = added + TOUR_WIN_PTS end
    end
  end
  return reply({ ok = true, added = added })
end

-- Premios (o devolucion) de la copa anterior. Cada uno se crea una sola vez.
local function rpc_tour_claim(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  for _, cup in ipairs(TOUR_ORDER) do
    local info = tour_info_of(cup)
    local prev = info and tonumber(info.prev_reset) or 0
    local nr = info and tonumber(info.next_reset) or 0
    -- si el servidor no da prev_reset, sale de next_reset (la copa se reinicia cada 24 h)
    if prev <= 0 and nr > 0 then prev = nr - 86400 end
    -- la entrada se guarda con el INICIO del periodo; el periodo que acaba de cerrar empezo un dia antes de prev_reset
    if prev > 0 and tour_joined(uid, cup, prev - 86400) then
      local key = cup .. "_" .. tostring(prev)
      local ex = nk.storage_read({{ collection = TOUR_GRANTS, key = key, user_id = uid }})
      if not (ex and #ex > 0) then
        local ok, recs = pcall(nk.leaderboard_records_list, "tour_" .. cup, nil, 100, nil, prev)
        if ok and recs then
          local n = #recs
          local fee = TOUR_CUPS[cup].fee
          local gold, kind = 0, nil
          if n < TOUR_MIN_ENTRANTS then
            gold = fee; kind = "tour_refund"
          else
            local pool = n * fee
            for i = 1, 3 do
              local r = recs[i]
              if r and r.owner_id == uid and (tonumber(r.score) or 0) > 0 then
                gold = math.floor(pool * TOUR_SPLIT[i]); kind = "tour_prize"
              end
            end
          end
          if kind then
            nk.storage_write({{ collection = TOUR_GRANTS, key = key, user_id = uid, permission_read = 0, permission_write = 0,
              value = { kind = kind, cup = cup, gold = gold, diamonds = 0, status = "pending", credited = false, created = os.time() } }})
            nk.logger_info("TORNEO premio creado user=" .. tostring(uid) .. " " .. key .. " " .. kind .. " oro=" .. tostring(gold))
          else
            -- sin premio: marcar como revisado para no recalcular cada vez
            nk.storage_write({{ collection = TOUR_GRANTS, key = key, user_id = uid, permission_read = 0, permission_write = 0,
              value = { kind = "none", cup = cup, gold = 0, diamonds = 0, status = "granted", credited = true, created = os.time() } }})
          end
        end
      end
    end
  end
  local objs = nk.storage_list(uid, TOUR_GRANTS, 50, nil)
  local out = {}
  for _, o in ipairs(objs or {}) do
    local v = o.value
    if type(v) == "table" and v.status ~= "granted" then
      if not v.credited then
        credit_guard(uid, v.gold, 0)
        v.credited = true
        nk.storage_write({{ collection = TOUR_GRANTS, key = o.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
      end
      out[#out + 1] = { key = o.key, kind = v.kind, cup = v.cup, gold = v.gold or 0 }
    end
  end
  return reply({ ok = true, grants = out, count = #out })
end

local function rpc_tour_ack(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" or type(d.key) ~= "string" then return reply({ ok = false, error = "pedido_invalido" }) end
  local r = nk.storage_read({{ collection = TOUR_GRANTS, key = d.key, user_id = uid }})
  if r and #r > 0 and type(r[1].value) == "table" then
    local v = r[1].value
    v.status = "granted"; v.granted_at = os.time()
    nk.storage_write({{ collection = TOUR_GRANTS, key = d.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
    return reply({ ok = true })
  end
  return reply({ ok = false, error = "no_existe" })
end

nk.register_rpc(rpc_tour_info, "tour_info")
nk.register_rpc(rpc_tour_join, "tour_join")
nk.register_rpc(rpc_tour_report, "tour_report")
nk.register_rpc(rpc_tour_claim, "tour_claim")
nk.register_rpc(rpc_tour_ack, "tour_ack")

nk.register_req_before(before_write, "WriteStorageObjects")
nk.register_req_before(before_delete, "DeleteStorageObjects")
nk.logger_info("Parche: guardia de economía activa")
