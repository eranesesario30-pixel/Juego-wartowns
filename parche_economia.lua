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

-- Cache corta en memoria (por instancia del servidor). Solo guarda datos COMPARTIDOS (tablas de
-- posiciones, fechas de reinicio), nunca datos de un jugador. Si algo falla, se vuelve a pedir.
local CACHE, CACHE_N = {}, 0
local function cached(key, ttl, fn)
  local now = os.time()
  local e = CACHE[key]
  if e and (now - e.t) < ttl then return e.v end
  local v = fn()
  if not e then
    CACHE_N = CACHE_N + 1
    if CACHE_N > 400 then CACHE = {}; CACHE_N = 1 end   -- tope de memoria
  end
  CACHE[key] = { t = now, v = v }
  return v
end

local function board_info_of(id)
  return cached("bi:" .. id, 5, function()
    local ok, r = pcall(nk.leaderboards_get_id, { id })
    if ok and r and r[1] then return r[1] end
    return false
  end) or nil
end

local function board_info()
  return board_info_of(GLOBAL_BOARD)
end

-- Filas de una tabla de posiciones (compartidas): rank, nombre, puntos, avatar, dueño.
local function board_rows(board, limit, ttl)
  return cached("rows:" .. board .. ":" .. tostring(limit), ttl, function()
    local ok, recs = pcall(nk.leaderboard_records_list, board, nil, limit, nil, nil)
    if not ok then return false end
    local rows = {}
    for _, r in ipairs(recs or {}) do
      local m = r.metadata
      if type(m) == "string" then local okm, mm = pcall(nk.json_decode, m); m = okm and mm or nil end
      rows[#rows + 1] = { rank = r.rank, name = r.username or "Jugador", points = r.score,
                          av = type(m) == "table" and m.av or nil, owner = r.owner_id }
    end
    return rows
  end)
end

-- Mi posicion en una tabla (una sola consulta pequena por jugador).
local function my_record(board, uid)
  local ok, _, owner_recs = pcall(nk.leaderboard_records_list, board, { uid }, 1, nil, nil)
  if ok and owner_recs and owner_recs[1] then return { rank = owner_recs[1].rank, points = owner_recs[1].score } end
  return nil
end

local function rows_for(uid, rows)
  local out = {}
  for i, r in ipairs(rows) do
    out[i] = { rank = r.rank, name = r.name, points = r.points, av = r.av, me = (r.owner == uid) }
  end
  return out
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
  if d.won ~= true then
    -- regla del juego: si no ganas la partida, no sumas puntos de liga
    if type(d.friends) == "table" then write_liga(uid, "main", st) end
    return reply({ ok = true, counted = false, reason = "no_gano", total = total, tier = tier_of_pts(total) })
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
  local shared = board_rows(GLOBAL_BOARD, GLOBAL_TOP_N, 5)
  if not shared then return reply({ ok = false, error = "no_se_pudo" }) end
  local rows = rows_for(uid, shared)
  local me = my_record(GLOBAL_BOARD, uid)
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
  local shared = board_rows(board, 20, 5)
  if not shared then return reply({ ok = false, error = "no_se_pudo" }) end
  local rows = rows_for(uid, shared)
  local me = my_record(board, uid)
  local info = board_info_of(board)
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
    -- la semana pasada ya no cambia: se guarda 5 minutos
    local recs = cached("gp:" .. tostring(prev), 300, function()
      local ok, r = pcall(nk.leaderboard_records_list, GLOBAL_BOARD, nil, 1, nil, prev)
      if ok and r then return r end
      return false
    end)
    local ok = recs and true or false
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
    local binfo = board_info_of("liga_" .. t)
    local bprev = binfo and tonumber(binfo.prev_reset) or 0
    local bnext = binfo and tonumber(binfo.next_reset) or 0
    if bprev <= 0 and bnext > 0 then bprev = bnext - 7 * 86400 end
    if bprev > 0 then
      local gkey = "tier_" .. t .. "_" .. tostring(bprev)
      local gex = nk.storage_read({{ collection = LIGA_GRANTS, key = gkey, user_id = uid }})
      if not (gex and #gex > 0) then
        local lrecs = cached("tp:" .. t .. ":" .. tostring(bprev), 300, function()
          local okq, r = pcall(nk.leaderboard_records_list, "liga_" .. t, nil, 100, nil, bprev)
          if okq and r then return r end
          return false
        end)
        local okl = lrecs and true or false
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
    local info = board_info_of("tour_" .. cup)
    local pid = tour_pid(info)
    local entry = { id = cup, fee = TOUR_CUPS[cup].fee, ends_at = info and info.next_reset or nil,
                    joined = false, entrants = 0, pool = 0, points = 0, rank = nil, top = {} }
    if pid then
      entry.joined = tour_joined(uid, cup, pid) and true or false
      -- inscritos y los 3 primeros son iguales para todos: se guardan 5 segundos
      local shared = cached("tour:" .. cup, 5, function()
        local ok, recs = pcall(nk.leaderboard_records_list, "tour_" .. cup, nil, 100, nil, nil)
        if not ok then return false end
        local rows = {}
        for i, r in ipairs(recs or {}) do
          rows[i] = { rank = r.rank, name = r.username or "Jugador", points = r.score, owner = r.owner_id }
        end
        return rows
      end)
      if shared then
        entry.entrants = #shared
        entry.pool = entry.entrants * TOUR_CUPS[cup].fee
        for i, r in ipairs(shared) do
          if i <= 3 and (tonumber(r.points) or 0) > 0 then
            entry.top[#entry.top + 1] = { rank = r.rank, name = r.name, points = r.points, me = (r.owner == uid) }
          end
        end
        if entry.joined then
          local mine = my_record("tour_" .. cup, uid)
          if mine then entry.points = mine.points; entry.rank = mine.rank end
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

-- GENERADO por gen_catalog.py: no editar a mano
local CAT = {}
CAT.dice={["mascara"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["astronauta"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["calavera"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["casete"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dragon"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["boombox"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["reloj"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["volcan"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["pulpo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["platillo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["corona"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["fenix"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["lobo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["tigre"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["aguila"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["zorro"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["buho"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["unicornio"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["pirata"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["ancla"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["brujula"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["rayo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["copo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["cometa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["trebol"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["herradura"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dona"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["helado"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["cupcake"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["pizza"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["hamburguesa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["sandia"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["robot"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["cohete"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["saturno"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["luna"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["sol"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["arcoiris"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["medusa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["tiburon"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["caballito"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["mariposa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["rosa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["girasol"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["loto"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["cactus"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["hongo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["pocion"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["gato"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["calabaza"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["fantasma"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["espada"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_billar"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_boxeo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_baloncesto"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_futbol"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_beisbol"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_carreras"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_arbolito"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_globo_nieve"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["dep_santa"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["ex_geoda"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_aurora"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_corona_oro"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_tormenta"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_lava"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_perla"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_hielo"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_nebulosa"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_engranajes"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_mascara"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_ojo_dragon"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_mariposa"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_pluma"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_arcana"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_corona_rey"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_cerezo"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_zafiro"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_reloj_arena"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["ex_dragon_jade"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["pd_galaxia"]={["price"]=nil,["pass"]=true,["anfora"]=false,["easy"]=false,["exotic"]=false},["pd_dragon"]={["price"]=nil,["pass"]=true,["anfora"]=false,["easy"]=false,["exotic"]=false},["pd_cristal"]={["price"]=nil,["pass"]=true,["anfora"]=false,["easy"]=false,["exotic"]=false},["ex_loto"]={["price"]=1500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=true},["an_brujula"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=true,["exotic"]=false},["an_llave"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=true,["exotic"]=false},["an_mapa"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=true,["exotic"]=false},["an_lampara"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_rayo"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_lobo"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_cuerno"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_ancla"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=true,["exotic"]=false},["an_telescopio"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_linterna"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=true,["exotic"]=false},["an_guantelete"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_estrella"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_anillo"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_escudo"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_medalla"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_trebol"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_copa"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_flor"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_barco"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["an_buho"]={["price"]=nil,["pass"]=false,["anfora"]=true,["easy"]=false,["exotic"]=false},["n_pastel"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_rubi"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_pez"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_guitarra"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_zorro"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_cangrejo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_tambor"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_semaforo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_dragon"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_tortuga"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_pinguino"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_panda"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_rana"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_abeja"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_tucan"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_faro"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_castillo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_tren"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_submarino"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["n_globo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false},["xd_reno"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_muneco"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_baston"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_gorro"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_campana"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_estrella"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_galleta"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true},["xd_regalo"]={["price"]=500,["pass"]=false,["anfora"]=false,["easy"]=false,["exotic"]=false,["xmas"]=true}}
CAT.avatars={["av0"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av1"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av2"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av3"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av4"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av5"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av6"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av7"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av8"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av9"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av11"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av12"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av13"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av14"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av15"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av16"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av17"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av18"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av19"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av20"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av21"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av22"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av23"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av24"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av25"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av26"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av27"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av28"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av29"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av30"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["av31"]={["price"]=nil,["pass"]=false,["pieces"]=nil,["basic"]=true},["spx1"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx2"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx3"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx4"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx5"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx6"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spx7"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["pa1"]={["price"]=nil,["pass"]=true,["pieces"]=4,["basic"]=false},["pa2"]={["price"]=nil,["pass"]=true,["pieces"]=4,["basic"]=false},["pa3"]={["price"]=nil,["pass"]=true,["pieces"]=4,["basic"]=false},["pa4"]={["price"]=nil,["pass"]=true,["pieces"]=4,["basic"]=false},["spx8"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy1"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy2"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy3"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy4"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy5"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy6"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy7"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy8"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy9"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy10"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy11"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy12"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy13"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy15"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["spy14"]={["price"]=50,["pass"]=false,["pieces"]=nil,["basic"]=false},["sp1"]={["price"]=100,["pass"]=false,["pieces"]=nil,["basic"]=false},["sp2"]={["price"]=100,["pass"]=false,["pieces"]=nil,["basic"]=false},["sp3"]={["price"]=200,["pass"]=false,["pieces"]=nil,["basic"]=false},["sp4"]={["price"]=200,["pass"]=false,["pieces"]=nil,["basic"]=false},["sp5"]={["price"]=300,["pass"]=false,["pieces"]=4,["basic"]=false},["sp6"]={["price"]=300,["pass"]=false,["pieces"]=4,["basic"]=false},["sp7"]={["price"]=500,["pass"]=false,["pieces"]=4,["basic"]=false},["sp8"]={["price"]=800,["pass"]=false,["pieces"]=4,["basic"]=false},["sp9"]={["price"]=1000,["pass"]=false,["pieces"]=4,["basic"]=false}}
CAT.boards={["sized100"]={["price"]=500,["pass"]=false},["sized125"]={["price"]=500,["pass"]=false},["sized150"]={["price"]=500,["pass"]=false},["rd"]={["price"]=1500,["pass"]=false},["pk"]={["price"]=1500,["pass"]=false},["in"]={["price"]=1500,["pass"]=false},["bd"]={["price"]=1500,["pass"]=false},["np"]={["price"]=1500,["pass"]=false},["es"]={["price"]=1500,["pass"]=false},["mx"]={["price"]=1500,["pass"]=false},["co"]={["price"]=1500,["pass"]=false},["ar"]={["price"]=1500,["pass"]=false},["sa"]={["price"]=1500,["pass"]=false},["pr"]={["price"]=1500,["pass"]=false},["ve"]={["price"]=1500,["pass"]=false},["cu"]={["price"]=1500,["pass"]=false},["hn"]={["price"]=1500,["pass"]=false},["ec"]={["price"]=1500,["pass"]=false},["pe"]={["price"]=1500,["pass"]=false},["cl"]={["price"]=1500,["pass"]=false},["br"]={["price"]=1500,["pass"]=false},["us"]={["price"]=1500,["pass"]=false},["ht"]={["price"]=1500,["pass"]=false},["it"]={["price"]=1500,["pass"]=false},["fr"]={["price"]=1500,["pass"]=false},["de"]={["price"]=1500,["pass"]=false},["ng"]={["price"]=1500,["pass"]=false},["jm"]={["price"]=1500,["pass"]=false},["tr"]={["price"]=1500,["pass"]=false},["ph"]={["price"]=1500,["pass"]=false},["eg"]={["price"]=1500,["pass"]=false},["ca"]={["price"]=1500,["pass"]=false},["pt"]={["price"]=1500,["pass"]=false},["p_cr"]={["price"]=1500,["pass"]=false},["p_bo"]={["price"]=1500,["pass"]=false},["p_sr"]={["price"]=1500,["pass"]=false},["p_pa"]={["price"]=1500,["pass"]=false},["p_uy"]={["price"]=1500,["pass"]=false},["p_gt"]={["price"]=1500,["pass"]=false},["p_sv"]={["price"]=1500,["pass"]=false},["p_ni"]={["price"]=1500,["pass"]=false},["p_py"]={["price"]=1500,["pass"]=false},["p_bz"]={["price"]=1500,["pass"]=false},["p_ie"]={["price"]=1500,["pass"]=false},["p_be"]={["price"]=1500,["pass"]=false},["p_nl"]={["price"]=1500,["pass"]=false},["p_ru"]={["price"]=1500,["pass"]=false},["p_pl"]={["price"]=1500,["pass"]=false},["p_ua"]={["price"]=1500,["pass"]=false},["p_at"]={["price"]=1500,["pass"]=false},["p_hu"]={["price"]=1500,["pass"]=false},["p_bg"]={["price"]=1500,["pass"]=false},["p_ro"]={["price"]=1500,["pass"]=false},["p_lt"]={["price"]=1500,["pass"]=false},["p_ee"]={["price"]=1500,["pass"]=false},["p_lv"]={["price"]=1500,["pass"]=false},["p_lu"]={["price"]=1500,["pass"]=false},["p_mc"]={["price"]=1500,["pass"]=false},["p_se"]={["price"]=1500,["pass"]=false},["p_no"]={["price"]=1500,["pass"]=false},["p_dk"]={["price"]=1500,["pass"]=false},["p_fi"]={["price"]=1500,["pass"]=false},["p_is"]={["price"]=1500,["pass"]=false},["p_ch"]={["price"]=1500,["pass"]=false},["p_gr"]={["price"]=1500,["pass"]=false},["p_gb"]={["price"]=1500,["pass"]=false},["p_cz"]={["price"]=1500,["pass"]=false},["p_rs"]={["price"]=1500,["pass"]=false},["p_hr"]={["price"]=1500,["pass"]=false},["p_si"]={["price"]=1500,["pass"]=false},["p_sk"]={["price"]=1500,["pass"]=false},["p_th"]={["price"]=1500,["pass"]=false},["p_id"]={["price"]=1500,["pass"]=false},["p_ye"]={["price"]=1500,["pass"]=false},["p_jp"]={["price"]=1500,["pass"]=false},["p_cn"]={["price"]=1500,["pass"]=false},["p_vn"]={["price"]=1500,["pass"]=false},["p_sg"]={["price"]=1500,["pass"]=false},["p_jo"]={["price"]=1500,["pass"]=false},["p_kw"]={["price"]=1500,["pass"]=false},["p_az"]={["price"]=1500,["pass"]=false},["p_am"]={["price"]=1500,["pass"]=false},["p_mm"]={["price"]=1500,["pass"]=false},["p_la"]={["price"]=1500,["pass"]=false},["p_my"]={["price"]=1500,["pass"]=false},["p_ae"]={["price"]=1500,["pass"]=false},["p_mv"]={["price"]=1500,["pass"]=false},["p_kr"]={["price"]=1500,["pass"]=false},["p_ge"]={["price"]=1500,["pass"]=false},["p_ir"]={["price"]=1500,["pass"]=false},["p_iq"]={["price"]=1500,["pass"]=false},["p_lb"]={["price"]=1500,["pass"]=false},["p_mn"]={["price"]=1500,["pass"]=false},["p_lk"]={["price"]=1500,["pass"]=false},["p_kh"]={["price"]=1500,["pass"]=false},["p_et"]={["price"]=1500,["pass"]=false},["p_gh"]={["price"]=1500,["pass"]=false},["p_sn"]={["price"]=1500,["pass"]=false},["p_ml"]={["price"]=1500,["pass"]=false},["p_gn"]={["price"]=1500,["pass"]=false},["p_ci"]={["price"]=1500,["pass"]=false},["p_bj"]={["price"]=1500,["pass"]=false},["p_ne"]={["price"]=1500,["pass"]=false},["p_cm"]={["price"]=1500,["pass"]=false},["p_bf"]={["price"]=1500,["pass"]=false},["p_td"]={["price"]=1500,["pass"]=false},["p_dz"]={["price"]=1500,["pass"]=false},["p_tn"]={["price"]=1500,["pass"]=false},["p_ma"]={["price"]=1500,["pass"]=false},["p_ly"]={["price"]=1500,["pass"]=false},["p_rw"]={["price"]=1500,["pass"]=false},["p_mg"]={["price"]=1500,["pass"]=false},["p_ga"]={["price"]=1500,["pass"]=false},["p_so"]={["price"]=1500,["pass"]=false},["p_bw"]={["price"]=1500,["pass"]=false},["p_sd"]={["price"]=1500,["pass"]=false},["p_mr"]={["price"]=1500,["pass"]=false},["p_cv"]={["price"]=1500,["pass"]=false},["p_ke"]={["price"]=1500,["pass"]=false},["p_zw"]={["price"]=1500,["pass"]=false},["p_zm"]={["price"]=1500,["pass"]=false},["p_ug"]={["price"]=1500,["pass"]=false},["p_ao"]={["price"]=1500,["pass"]=false},["p_au"]={["price"]=1500,["pass"]=false},["p_nz"]={["price"]=1500,["pass"]=false},["muertos"]={["price"]=1000,["pass"]=false},["playa"]={["price"]=1000,["pass"]=false},["coral"]={["price"]=1000,["pass"]=false},["px_galaxia"]={["price"]=nil,["pass"]=true},["px_dragon"]={["price"]=nil,["pass"]=true},["px_bosque"]={["price"]=nil,["pass"]=true},["bosque"]={["price"]=1000,["pass"]=false},["galaxia"]={["price"]=1000,["pass"]=false},["nieve"]={["price"]=1000,["pass"]=false},["volcan"]={["price"]=1000,["pass"]=false},["cerezo"]={["price"]=1000,["pass"]=false},["caramelo"]={["price"]=1000,["pass"]=false},["egipto"]={["price"]=1000,["pass"]=false},["jardin"]={["price"]=1000,["pass"]=false},["halloween1"]={["price"]=1000,["pass"]=false},["halloween2"]={["price"]=1000,["pass"]=false},["navidad1"]={["price"]=1000,["pass"]=false},["navidad2"]={["price"]=1000,["pass"]=false},["carreras"]={["price"]=1000,["pass"]=false},["baloncesto"]={["price"]=1000,["pass"]=false},["boxeo"]={["price"]=1000,["pass"]=false},["billar"]={["price"]=1000,["pass"]=false},["futbol"]={["price"]=1000,["pass"]=false},["beisbol"]={["price"]=1000,["pass"]=false},["xtaller"]={["price"]=1000,["pass"]=false,["xmas"]=true},["xpueblo"]={["price"]=1000,["pass"]=false,["xmas"]=true}}
CAT.tokens={["caballo"]={["price"]=nil,["pass"]=true,["free"]=false},["leon"]={["price"]=nil,["pass"]=true,["free"]=false},["aguila"]={["price"]=nil,["pass"]=true,["free"]=false},["ancla"]={["price"]=nil,["pass"]=true,["free"]=false},["torre"]={["price"]=250,["pass"]=false,["free"]=false},["corona"]={["price"]=250,["pass"]=false,["free"]=false},["estrella"]={["price"]=250,["pass"]=false,["free"]=false},["diamante"]={["price"]=250,["pass"]=false,["free"]=false},["cohete"]={["price"]=250,["pass"]=false,["free"]=false},["corazon"]={["price"]=250,["pass"]=false,["free"]=false},["rayo"]={["price"]=250,["pass"]=false,["free"]=false},["luna"]={["price"]=250,["pass"]=false,["free"]=false},["escudo"]={["price"]=250,["pass"]=false,["free"]=false},["copa"]={["price"]=250,["pass"]=false,["free"]=false},["canica"]={["price"]=250,["pass"]=false,["free"]=true},["domo"]={["price"]=250,["pass"]=false,["free"]=true},["trompo"]={["price"]=250,["pass"]=false,["free"]=true},["perla"]={["price"]=250,["pass"]=false,["free"]=true},["piramide"]={["price"]=250,["pass"]=false,["free"]=true},["gota"]={["price"]=250,["pass"]=false,["free"]=true},["campana"]={["price"]=250,["pass"]=false,["free"]=true},["barril"]={["price"]=250,["pass"]=false,["free"]=true},["cono"]={["price"]=250,["pass"]=false,["free"]=true},["farol"]={["price"]=250,["pass"]=false,["free"]=true},["caliz"]={["price"]=250,["pass"]=false,["free"]=true},["anillo"]={["price"]=250,["pass"]=false,["free"]=true},["nieve"]={["price"]=250,["pass"]=false,["free"]=true},["peonza"]={["price"]=250,["pass"]=false,["free"]=true},["gema"]={["price"]=250,["pass"]=false,["free"]=true}}
CAT.retired={"torre","corona","estrella","diamante","cohete","corazon","rayo","luna","escudo","copa"}
CAT.chests={["bronce"]={["name"]="Bronce",["icon"]="🟫",["hours"]=3,["gold"]={200,600},["diamonds"]={0,2}},["plata"]={["name"]="Plata",["icon"]="⬜",["hours"]=8,["gold"]={600,1800},["diamonds"]={2,6}},["oro"]={["name"]="Oro Místico",["icon"]="🟨",["hours"]=12,["gold"]={2000,6000},["diamonds"]={6,15}},["diamante"]={["name"]="Diamante",["icon"]="💎",["hours"]=24,["gold"]={6000,15000},["diamonds"]={15,40}}}
CAT.pass={{["tier"]=1,["points"]=100,["free"]={["gold"]=500},["premium"]={["diamonds"]=100}},{["tier"]=2,["points"]=200,["free"]={["diamonds"]=5},["premium"]={["xp"]=6}},{["tier"]=3,["points"]=300,["free"]={["gold"]=800},["premium"]={["dice"]="pd_galaxia"}},{["tier"]=4,["points"]=400,["free"]={["diamonds"]=5},["premium"]={["gold"]=5000}},{["tier"]=5,["points"]=500,["free"]={["gold"]=1200},["premium"]={["diamonds"]=120}},{["tier"]=6,["points"]=600,["free"]={["diamonds"]=5},["premium"]={["diamonds"]=150}},{["tier"]=7,["points"]=700,["free"]={["gold"]=2000},["premium"]={["avatar"]="pa1"}},{["tier"]=8,["points"]=800,["free"]={["diamonds"]=10},["premium"]={["chest"]="plata"}},{["tier"]=9,["points"]=900,["free"]={["gold"]=3000},["premium"]={["xp"]=24}},{["tier"]=10,["points"]=1000,["free"]={["diamonds"]=15},["premium"]={["token"]="caballo"}},{["tier"]=11,["points"]=1100,["free"]={["gold"]=2500},["premium"]={["gold"]=8000}},{["tier"]=12,["points"]=1200,["free"]={["diamonds"]=10},["premium"]={["board"]="px_galaxia"}},{["tier"]=13,["points"]=1300,["free"]={["gold"]=3000},["premium"]={["dice"]="pd_dragon"}},{["tier"]=14,["points"]=1400,["free"]={["diamonds"]=10},["premium"]={["diamonds"]=200}},{["tier"]=15,["points"]=1500,["free"]={["chest"]="bronce"},["premium"]={["chest"]="oro"}},{["tier"]=16,["points"]=1600,["free"]={["gold"]=3500},["premium"]={["xp"]=72}},{["tier"]=17,["points"]=1700,["free"]={["diamonds"]=10},["premium"]={["avatar"]="pa2"}},{["tier"]=18,["points"]=1800,["free"]={["gold"]=4000},["premium"]={["gold"]=12000}},{["tier"]=19,["points"]=1900,["free"]={["diamonds"]=15},["premium"]={["dice"]="pd_cristal"}},{["tier"]=20,["points"]=2000,["free"]={["token"]="ancla"},["premium"]={["token"]="leon"}},{["tier"]=21,["points"]=2100,["free"]={["gold"]=4500},["premium"]={["diamonds"]=250}},{["tier"]=22,["points"]=2200,["free"]={["diamonds"]=15},["premium"]={["board"]="px_dragon"}},{["tier"]=23,["points"]=2300,["free"]={["gold"]=5000},["premium"]={["chest"]="oro"}},{["tier"]=24,["points"]=2400,["free"]={["diamonds"]=15},["premium"]={["xp"]=168}},{["tier"]=25,["points"]=2500,["free"]={["chest"]="plata"},["premium"]={["token"]="aguila"}},{["tier"]=26,["points"]=2600,["free"]={["gold"]=6000},["premium"]={["avatar"]="pa3"}},{["tier"]=27,["points"]=2700,["free"]={["diamonds"]=20},["premium"]={["diamonds"]=400}},{["tier"]=28,["points"]=2800,["free"]={["gold"]=7000},["premium"]={["avatar"]="pa4"}},{["tier"]=29,["points"]=2900,["free"]={["diamonds"]=20},["premium"]={["chest"]="oro"}},{["tier"]=30,["points"]=3000,["free"]={["chest"]="oro"},["premium"]={["board"]="px_bosque"}}}
CAT.daily={1000,1600,2500,3500,5000,8000,"chest"}
CAT.challenges={{["id"]="play3",["title"]="Juega 3 partidas hoy",["target"]=3,["track"]="gamesToday",["reward"]={["gold"]=6000},["rewardLabel"]="+6,000 🪙"},{["id"]="win1",["title"]="Gana 1 partida hoy",["target"]=1,["track"]="winsToday",["reward"]={["gold"]=10000},["rewardLabel"]="+10,000 🪙"},{["id"]="bet10k",["title"]="Apuesta al menos 10,000 oro",["target"]=1,["track"]="bigBetToday",["reward"]={["diamonds"]=10},["rewardLabel"]="+10 💎"},{["id"]="chest1",["title"]="Rompe 1 ánfora hoy",["target"]=1,["track"]="chestsToday",["reward"]={["gold"]=4000,["diamonds"]=5},["rewardLabel"]="+4,000 🪙 +5 💎"}}
CAT.challenge_pool={{["id"]="play1v1_2",["title"]="Juega 2 partidas 1 vs 1",["target"]=2,["track"]="games1v1Today",["reward"]={["gold"]=6000},["rewardLabel"]="+6,000 🪙"},{["id"]="capture3",["title"]="Captura 3 fichas rivales",["target"]=3,["track"]="capturesToday",["reward"]={["diamonds"]=10},["rewardLabel"]="+10 💎"},{["id"]="chest1",["title"]="Rompe 1 ánfora",["target"]=1,["track"]="chestsToday",["reward"]={["gold"]=4000,["diamonds"]=5},["rewardLabel"]="+4,000 🪙 +5 💎"},{["id"]="win1",["title"]="Gana 1 partida",["target"]=1,["track"]="winsToday",["reward"]={["gold"]=10000},["rewardLabel"]="+10,000 🪙"},{["id"]="play3",["title"]="Juega 3 partidas (cualquier modo)",["target"]=3,["track"]="gamesToday",["reward"]={["gold"]=6000},["rewardLabel"]="+6,000 🪙"},{["id"]="bet10k",["title"]="Apuesta al menos 10,000 de oro",["target"]=1,["track"]="bigBetToday",["reward"]={["diamonds"]=10},["rewardLabel"]="+10 💎"},{["id"]="double2",["title"]="Saca 2 dobles",["target"]=2,["track"]="doublesToday",["reward"]={["diamonds"]=5},["rewardLabel"]="+5 💎"},{["id"]="play2v2_1",["title"]="Juega 1 partida 2 vs 2",["target"]=1,["track"]="games2v2Today",["reward"]={["gold"]=5000},["rewardLabel"]="+5,000 🪙"},{["id"]="treasure1",["title"]="Encuentra 1 tesoro",["target"]=1,["track"]="treasureToday",["reward"]={["diamonds"]=5},["rewardLabel"]="+5 💎"},{["id"]="streak1",["title"]="Come 2 fichas seguidas (racha)",["target"]=1,["track"]="streaksToday",["reward"]={["diamonds"]=10},["rewardLabel"]="+10 💎"}}
CAT.frames={["classic"]=1,["bronze"]=5,["fr2"]=8,["fr3"]=12,["fr13"]=15,["fr1"]=20,["fr8"]=25,["neon"]=30,["fr5"]=35,["fr6"]=40,["fr4"]=45,["fr7"]=50,["fr11"]=55,["fr10"]=60,["fr12"]=70,["fr9"]=80}


-- ============================================================================
-- ECONOMIA EN EL SERVIDOR
-- El oro, las gemas, lo desbloqueado y los premios viven en el servidor (coleccion "eco").
-- El telefono SOLO muestra lo que dice el servidor y pide acciones; nunca decide cuanto se
-- gana ni se gasta. Todo cambio pasa por eco_update (con control de version, para que dos
-- pedidos a la vez no se pisen).
-- ============================================================================
local ECO = "eco"
local ECO_GOLD_CAP = 5000000000
local ECO_DIA_CAP = 1000000

local function eco_now() return os.time() end
local function eco_day(t) return os.date("!%Y-%m-%d", t or os.time()) end

local function eco_new_doc(uid)
  -- Migracion: parte del saldo que la guardia antigua ya habia aceptado (nunca de lo que diga el telefono ahora)
  local st = read_state(uid)
  local p = read_profile(uid)
  local gold = (st and num(st.gold)) or (p and num(p.gold)) or LIMITS.start_gold
  local dia = (st and num(st.diamonds)) or (p and num(p.diamonds)) or LIMITS.start_diamonds
  local chest = {}
  if p and type(p.chestSlots) == "table" then
    for i = 1, 4 do
      local s = p.chestSlots[i]
      if type(s) == "table" and CAT.chests[s.type] then
        local state = (s.state == "unlocking" or s.state == "ready") and s.state or "idle"
        chest[i] = { type = s.type, state = state, endsAt = tonumber(s.endsAt) or 0 }
      end
    end
  end
  -- Si ya habia comprado el Pase Premium (compra validada por Google/Apple), se conserva
  local premium = false
  local okl, objs = pcall(nk.storage_list, uid, IAP, 100, nil)
  if okl and type(objs) == "table" then
    for _, o in ipairs(objs) do
      if type(o.value) == "table" and o.value.product_id == "parche_pass_s1" and o.value.transaction_id then premium = true end
    end
  end
  return {
    v = 1, gold = gold, diamonds = dia, chest = chest, imported = false, created = eco_now(),
    own = { tokens = { clasico = true }, dice = { classic = true }, boards = { classic = true }, avatars = {}, frames = {} },
    pass = { pts = 0, premium = premium, cf = {}, cp = {} },
    daily = { last = "", streak = 0 },
    ads = { day = "", n = 0, step = 0 },
    xp = { level = 1, lvl = 0, boost = 0 },
    ch = { day = "", prog = {}, claimed = {} },
    stats = { games = 0, wins = 0 },
  }
end

-- Lee el documento (lo crea si no existe). Devuelve doc, version
local function eco_read(uid)
  local r = nk.storage_read({{ collection = ECO, key = "main", user_id = uid }})
  if r and #r > 0 and type(r[1].value) == "table" then return r[1].value, r[1].version end
  return nil, nil
end

-- Aplica un cambio de forma segura. fn(doc) devuelve (true, resultado) o (false, "codigo_error").
-- opts.skip_if_same: si el documento queda IGUAL despues de fn (nadie cambio nada), no se escribe
-- en la base de datos. Una lectura (eco_get) ya no cuesta una escritura. Si hay duda, se escribe.
local function eco_update(uid, fn, opts)
  for _ = 1, 6 do
    local doc, ver = eco_read(uid)
    local isnew = false
    if not doc then doc = eco_new_doc(uid); isnew = true; ver = "*" end
    local before = nil
    if opts and opts.skip_if_same and not isnew then before = nk.json_encode(doc) end
    local ok, res, extra = fn(doc)
    if not ok then return false, res end
    if before and nk.json_encode(doc) == before then return true, res, doc, extra end
    if doc.gold < 0 or doc.diamonds < 0 then return false, "sin_saldo" end
    if doc.gold > ECO_GOLD_CAP then doc.gold = ECO_GOLD_CAP end
    if doc.diamonds > ECO_DIA_CAP then doc.diamonds = ECO_DIA_CAP end
    local wok = pcall(nk.storage_write, {{ collection = ECO, key = "main", user_id = uid, value = doc, version = ver,
                                           permission_read = 1, permission_write = 0 }})
    if wok then return true, res, doc, extra end
  end
  return false, "ocupado"
end

-- Suma/resta saldo (lo usan compras, ligas y torneos). Los premios entran sin pasar por topes: los decide el servidor.
local function eco_credit(uid, gold, diamonds)
  local ok = eco_update(uid, function(d)
    d.gold = d.gold + (gold or 0); d.diamonds = d.diamonds + (diamonds or 0)
    return true
  end)
  return ok
end
ECO_CREDIT = eco_credit

local function eco_public(d)
  if d.ch and d.ch.day == nil then d.ch = nil end
  local chest = {}
  for i = 1, 4 do chest[i] = d.chest[i] or false end   -- lista fija de 4 (false = hueco vacio)
  return { gold = d.gold, diamonds = d.diamonds, chest = chest, own = d.own, pass = d.pass, daily = d.daily,
           ads = d.ads, xp = d.xp, ch = d.ch, imported = d.imported, drops = d.drops, nameChanges = d.nameChanges or 0,
           stats = d.stats, bet = d.bet, xmas = d.xmas, gifts = d.gifts, now = eco_now() }
end

local function eco_fail(code) return reply({ ok = false, error = code }) end
local function eco_ok(d, extra)
  local t = { ok = true, eco = eco_public(d) }
  if extra then for k, v in pairs(extra) do t[k] = v end end
  return reply(t)
end

local function decode(payload)
  local ok, d = pcall(nk.json_decode, payload or "{}")
  if ok and type(d) == "table" then return d end
  return {}
end

-- ---- eco_get: estado completo (crea el documento la primera vez) ----
local function rpc_eco_get(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d) ensure_challenges(d); return true end, { skip_if_same = true })
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- ---- eco_import: UNA sola vez, trae lo que ya tenia el telefono (solo ids que existan en el catalogo) ----
local function rpc_eco_import(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local d0 = decode(payload)
  local ok, res, doc = eco_update(uid, function(d)
    if d.imported then return true end
    local function take(list, set, catalog, allowPass)
      if type(list) ~= "table" then return end
      local n = 0
      for _, id in ipairs(list) do
        n = n + 1; if n > 400 then break end
        local c = type(id) == "string" and catalog[id] or nil
        if c and (allowPass or not c.pass) then set[id] = true end
      end
    end
    take(d0.tokens, d.own.tokens, CAT.tokens, false)
    take(d0.dice, d.own.dice, CAT.dice, false)
    take(d0.boards, d.own.boards, CAT.boards, false)
    take(d0.avatars, d.own.avatars, CAT.avatars, false)
    -- progreso de colecciones (caras de dado, colores de ficha, piezas de avatar), solo ids y valores que existen
    local function take_drops(src, dst, catalog, vals, maxv)
      if type(src) ~= "table" then return end
      local n = 0
      for id, list in pairs(src) do
        n = n + 1; if n > 300 then break end
        local c = type(id) == "string" and catalog[id] or nil
        if c and not c.pass and type(list) == "table" and not (dst[id] and #dst[id] > 0) then
          local seen, out = {}, {}
          for _, v in ipairs(list) do
            if vals[v] and not seen[v] and #out < maxv - 1 then seen[v] = true; out[#out + 1] = v end
          end
          if #out > 0 then dst[id] = out end
        end
      end
    end
    local dr = d0.drops
    if type(dr) == "table" then
      d.drops = d.drops or {}; d.drops.dice = d.drops.dice or {}; d.drops.tok = d.drops.tok or {}; d.drops.av = d.drops.av or {}
      take_drops(dr.dice, d.drops.dice, CAT.dice, { true, true, true, true, true, true }, 6)
      take_drops(dr.tok, d.drops.tok, CAT.tokens, { red = true, blue = true, yellow = true, green = true }, 4)
      take_drops(dr.av, d.drops.av, CAT.avatars, { true, true, true, true }, 4)
    end
    -- nivel y puntos del pase que ya llevaba (con tope). El Pase Premium NUNCA se importa: viene de las compras.
    local lv, lx, pts = tonumber(d0.level), tonumber(d0.lvl), tonumber(d0.pts)
    if lv and lv >= 1 and lv <= 150 then d.xp.level = math.floor(lv) end
    if lx and lx >= 0 and lx < 300 then d.xp.lvl = math.floor(lx) end
    if pts and pts >= 0 and pts <= 3000 then d.pass.pts = math.floor(pts) end
    d.imported = true
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- ---- eco_buy: compra con gemas, al precio del catalogo ----
local BUY_CAT = { token = "tokens", dice = "dice", board = "boards", avatar = "avatars" }
local BUY_SET = { token = "tokens", dice = "dice", board = "boards", avatar = "avatars" }
local function rpc_eco_buy(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local d0 = decode(payload)
  local kind, id = d0.kind, d0.id
  if type(kind) ~= "string" or type(id) ~= "string" or not BUY_CAT[kind] then return eco_fail("pedido_invalido") end
  local item = CAT[BUY_CAT[kind]][id]
  if not item then return eco_fail("no_existe") end
  if item.pass then return eco_fail("solo_pase") end
  if item.anfora then return eco_fail("solo_anforas") end
  if kind == "token" then
    for _, r in ipairs(CAT.retired) do if r == id then return eco_fail("retirado") end end
  end
  local ok, res, doc = eco_update(uid, function(d)
    local set = d.own[BUY_SET[kind]]
    if set[id] then return false, "ya_lo_tienes" end
    local price = item.price
    if kind == "token" and item.free then price = 0 end
    if not price then return false, "no_se_vende" end
    if d.diamonds < price then return false, "sin_saldo" end
    d.diamonds = d.diamonds - price
    set[id] = true
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

nk.register_rpc(rpc_eco_get, "eco_get")
nk.register_rpc(rpc_eco_import, "eco_import")
nk.register_rpc(rpc_eco_buy, "eco_buy")


-- ---- Desafios del dia (mismas reglas que el juego: 3 al azar con semilla = fecha UTC) ----
local function pick_daily_ids(date)
  local seed = 0
  for i = 1, #date do seed = (seed * 31 + string.byte(date, i)) % 100000 end
  local pool = {}
  for _, c in ipairs(CAT.challenge_pool) do pool[#pool + 1] = c.id end
  local picked = {}
  while #picked < 3 and #pool > 0 do
    seed = (seed * 9301 + 49297) % 233280
    local idx = seed % #pool
    picked[#picked + 1] = table.remove(pool, idx + 1)
  end
  return picked
end

function ensure_challenges(d)
  local today = eco_day()
  if type(d.ch) ~= "table" or d.ch.day ~= today then
    d.ch = { day = today, ids = pick_daily_ids(today), prog = {}, claimed = {} }
  end
  d.ch.prog = d.ch.prog or {}; d.ch.claimed = d.ch.claimed or {}
  return d.ch
end


-- ============================================================================
-- ECONOMIA (parte B): anforas, premio diario, anuncios, pase, desafios, nombre
-- ============================================================================
math.randomseed(os.time())
local COLORS4 = { "red", "blue", "yellow", "green" }
local DICE_FACE_CHANCE = { bronce = 0.06, plata = 0.10, oro = 0.18, diamante = 0.24 }
local TOKEN_COLOR_CHANCE = { bronce = 0.05, plata = 0.08, oro = 0.15, diamante = 0.20 }
local AV_PIECE_CHANCE = { bronce = 0.03, plata = 0.04, oro = 0.06, diamante = 0.08 }
local CHEST_GEM_COST = { bronce = 30, plata = 60, oro = 100, diamante = 150 }
local AD_LADDER = {
  { "diamond", 5 }, { "gold", 100 }, { "diamond", 10 }, { "gold", 150 },
  { "diamond", 15 }, { "gold", 200 }, { "diamond", 20 }, { "gold", 400 },
}
local AD_DAILY_DIAMOND_LIMIT = 8
local AD_DAILY_MAX = 30        -- tope de videos que se pagan por dia
local AD_MIN_GAP = 20          -- segundos minimos entre un video y otro

local function now_ms() return os.time() * 1000 end
local function drops(d) d.drops = d.drops or {}; d.drops.dice = d.drops.dice or {}; d.drops.tok = d.drops.tok or {}; d.drops.av = d.drops.av or {}; return d.drops end
local function has(set, id) return set[id] == true end
local function tok_owned(d, id)
  local c = CAT.tokens[id]
  return id == "clasico" or (c and c.free) or has(d.own.tokens, id)
end
local function dice_owned(d, id) return id == "classic" or has(d.own.dice, id) end
local function av_owned(d, id)
  local c = CAT.avatars[id]
  return (c and c.basic) or has(d.own.avatars, id)
end
local function list_keys(t) local o = {} for k in pairs(t) do o[#o + 1] = k end table.sort(o) return o end
local function pick(t) return t[math.random(1, #t)] end
local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Pone una anfora en el primer hueco libre. Devuelve el numero de hueco o nil.
local function add_chest(d, ctype)
  if not CAT.chests[ctype] then return nil end
  for i = 1, 4 do
    if not d.chest[i] then d.chest[i] = { type = ctype, state = "idle", endsAt = 0 }; return i end
  end
  return nil
end

local function add_xp_boost(d, hours)
  local base = math.max(tonumber(d.xp.boost) or 0, now_ms())
  d.xp.boost = base + hours * 3600000
end

-- Entrega un premio del pase / calendario (con los mismos reemplazos de siempre si ya lo tenias).
local function give_reward(d, r)
  local note = {}
  if r.gold then d.gold = d.gold + r.gold end
  if r.diamonds then d.diamonds = d.diamonds + r.diamonds end
  if r.token then
    if tok_owned(d, r.token) then d.gold = d.gold + 15000; note.dup = true else d.own.tokens[r.token] = true end
  end
  if r.avatar then
    if av_owned(d, r.avatar) then d.gold = d.gold + 5000; note.dup = true else d.own.avatars[r.avatar] = true end
  end
  if r.dice then
    if dice_owned(d, r.dice) then d.gold = d.gold + 15000; note.dup = true else d.own.dice[r.dice] = true end
  end
  if r.xp then add_xp_boost(d, r.xp) end
  if r.board then d.own.boards[r.board] = true end
  if r.chest then
    if not add_chest(d, r.chest) then d.gold = d.gold + 20000; note.nospace = true end
  end
  return note
end

-- ---- Tiempo de las anforas ----
local function rpc_chest_start(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local i = tonumber(decode(payload).slot)
  if not i or i < 1 or i > 4 then return eco_fail("pedido_invalido") end
  local ok, res, doc = eco_update(uid, function(d)
    local s = d.chest[i]
    if not s then return false, "no_hay_anfora" end
    if s.state ~= "idle" then return false, "ya_iniciada" end
    for k = 1, 4 do if d.chest[k] and d.chest[k].state == "unlocking" then return false, "ya_hay_una" end end
    s.state = "unlocking"; s.endsAt = now_ms() + CAT.chests[s.type].hours * 3600000
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

local function rpc_chest_gems(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local i = tonumber(decode(payload).slot)
  if not i or i < 1 or i > 4 then return eco_fail("pedido_invalido") end
  local ok, res, doc = eco_update(uid, function(d)
    local s = d.chest[i]
    if not s then return false, "no_hay_anfora" end
    if s.state == "ready" then return true end
    local cost = CHEST_GEM_COST[s.type]
    if d.diamonds < cost then return false, "sin_saldo" end
    d.diamonds = d.diamonds - cost
    s.state = "ready"; s.endsAt = 0
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

-- ---- Cartas de colecciones: cara de dado / color de ficha / pieza de avatar ----
local function roll_dice_face(d, ctype)
  if math.random() >= (DICE_FACE_CHANCE[ctype] or 0.06) then return nil end
  local dr = drops(d)
  local cand = {}
  for _, id in ipairs(list_keys(CAT.dice)) do
    local c = CAT.dice[id]
    if not c.exotic and not c.pass and not dice_owned(d, id) then cand[#cand + 1] = id end
  end
  if #cand == 0 then return nil end
  local function prog(id) return #(dr.dice[id] or {}) end
  local easy = {}
  for _, id in ipairs(cand) do if CAT.dice[id].easy then easy[#easy + 1] = id end end
  local pool = (#easy > 0 and math.random() < 0.6) and easy or cand
  local best = -1
  for _, id in ipairs(pool) do if prog(id) > best then best = prog(id) end end
  local top = {}
  for _, id in ipairs(pool) do if prog(id) == best then top[#top + 1] = id end end
  local id = pick(top)
  dr.dice[id] = dr.dice[id] or {}
  local have = dr.dice[id]
  local missing = {}
  for n = 1, 6 do
    local f = false
    for _, h in ipairs(have) do if h == n then f = true end end
    if not f then missing[#missing + 1] = n end
  end
  local face = pick(missing)
  have[#have + 1] = face
  local completed = false
  if #have >= 6 then completed = true; d.own.dice[id] = true end
  return { id = id, face = face, completed = completed }
end

local function roll_token_color(d, ctype)
  if math.random() >= (TOKEN_COLOR_CHANCE[ctype] or 0.05) then return nil end
  local dr = drops(d)
  local retired = {}
  for _, r in ipairs(CAT.retired) do retired[r] = true end
  local cand = {}
  for _, id in ipairs(list_keys(CAT.tokens)) do
    local c = CAT.tokens[id]
    if id ~= "clasico" and not tok_owned(d, id) and not c.pass and not retired[id] then cand[#cand + 1] = id end
  end
  if #cand == 0 then return nil end
  local function prog(id) return #(dr.tok[id] or {}) end
  local best = -1
  for _, id in ipairs(cand) do if prog(id) > best then best = prog(id) end end
  local top = {}
  for _, id in ipairs(cand) do if prog(id) == best then top[#top + 1] = id end end
  local id = pick(top)
  dr.tok[id] = dr.tok[id] or {}
  local have = dr.tok[id]
  local missing = {}
  for _, c in ipairs(COLORS4) do
    local f = false
    for _, h in ipairs(have) do if h == c then f = true end end
    if not f then missing[#missing + 1] = c end
  end
  local color = pick(missing)
  have[#have + 1] = color
  local completed = false
  if #have >= #COLORS4 then completed = true; d.own.tokens[id] = true end
  return { id = id, color = color, completed = completed }
end

local function roll_avatar_piece(d, ctype)
  if math.random() >= (AV_PIECE_CHANCE[ctype] or 0.03) then return nil end
  local dr = drops(d)
  local cand = {}
  for _, id in ipairs(list_keys(CAT.avatars)) do
    local c = CAT.avatars[id]
    if c.pieces and not av_owned(d, id) then cand[#cand + 1] = id end
  end
  if #cand == 0 then return nil end
  local function prog(id) return #(dr.av[id] or {}) end
  local best = -1
  for _, id in ipairs(cand) do if prog(id) > best then best = prog(id) end end
  local top = {}
  for _, id in ipairs(cand) do if prog(id) == best then top[#top + 1] = id end end
  local id = pick(top)
  dr.av[id] = dr.av[id] or {}
  local have = dr.av[id]
  local missing = {}
  for n = 1, 4 do
    local f = false
    for _, h in ipairs(have) do if h == n then f = true end end
    if not f then missing[#missing + 1] = n end
  end
  local piece = pick(missing)
  have[#have + 1] = piece
  local completed = false
  if #have >= 4 then completed = true; d.own.avatars[id] = true end
  return { id = id, piece = piece, completed = completed }
end

-- Abre una anfora lista: el SERVIDOR sortea el contenido.
local function rpc_chest_open(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local i = tonumber(decode(payload).slot)
  if not i or i < 1 or i > 4 then return eco_fail("pedido_invalido") end
  local ok, res, doc = eco_update(uid, function(d)
    local s = d.chest[i]
    if not s then return false, "no_hay_anfora" end
    local ready = s.state == "ready" or (s.state == "unlocking" and (tonumber(s.endsAt) or 0) <= now_ms())
    if not ready then return false, "no_esta_lista" end
    local info = CAT.chests[s.type]
    local gold = info.gold[1] + math.floor(math.random() * (info.gold[2] - info.gold[1]))
    local dia = info.diamonds[1] + math.floor(math.random() * (info.diamonds[2] - info.diamonds[1] + 1))
    local ctype = s.type
    d.gold = d.gold + gold; d.diamonds = d.diamonds + dia
    d.chest[i] = nil
    local rw = { gold = gold, diamonds = dia, type = ctype }
    rw.face = roll_dice_face(d, ctype)
    rw.color = roll_token_color(d, ctype)
    rw.piece = roll_avatar_piece(d, ctype)
    -- desafio "rompe una anfora"
    local ch = ensure_challenges(d)
    ch.prog.chestsToday = (ch.prog.chestsToday or 0) + 1
    return true, rw
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { rewards = res, drops = doc.drops })
end


-- ---- Premio diario ----
local function rpc_daily_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local today = eco_day()
    if d.daily.last == today then return false, "ya_reclamado" end
    local yesterday = eco_day(os.time() - 86400)
    local streak = (d.daily.last == yesterday) and (d.daily.streak + 1) or 1
    local dayc = ((streak - 1) % 7) + 1
    local entry = CAT.daily[dayc]
    d.daily.last = today; d.daily.streak = streak
    local out = { day = dayc, streak = streak }
    if entry == "chest" then
      if add_chest(d, "oro") then out.chest = "oro" else d.gold = d.gold + 5000; out.gold = 5000; out.nospace = true end
    else
      d.gold = d.gold + entry; out.gold = entry
    end
    return true, out
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { reward = res })
end

-- ---- Videos con recompensa (el servidor lleva el paso de la escalera, el tope y el ritmo) ----
local function rpc_ad_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local today = eco_day()
    if d.ads.day ~= today then d.ads.day = today; d.ads.n = 0 end
    local t = os.time()
    if (t - (tonumber(d.ads.last) or 0)) < AD_MIN_GAP then return false, "muy_rapido" end
    if d.ads.n >= AD_DAILY_MAX then return false, "tope_diario" end
    local step = AD_LADDER[(d.ads.step % #AD_LADDER) + 1]
    local over = d.ads.n >= AD_DAILY_DIAMOND_LIMIT
    local out = {}
    if step[1] == "diamond" and not over then d.diamonds = d.diamonds + step[2]; out.diamonds = step[2]
    elseif step[1] == "diamond" then d.gold = d.gold + 100; out.gold = 100
    else d.gold = d.gold + step[2]; out.gold = step[2] end
    d.ads.n = d.ads.n + 1
    d.ads.step = (d.ads.step + 1) % #AD_LADDER
    d.ads.last = t
    return true, out
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { reward = res })
end

-- ---- Cambiar el nombre (el primero gratis; luego 25, 50, 75, 100 gemas) ----
local function rpc_name_change(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local ok, res, doc = eco_update(uid, function(d)
    local n = tonumber(d.nameChanges) or 0
    local cost = n < 1 and 0 or math.min(100, n * 25)
    if d.diamonds < cost then return false, "sin_saldo" end
    d.diamonds = d.diamonds - cost
    d.nameChanges = n + 1
    return true, cost
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { cost = res })
end

-- ---- Pase: reclamar premio de un escalon (gratis o premium) ----
local function rpc_pass_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local d0 = decode(payload)
  local tier = tonumber(d0.tier)
  local track = d0.track
  if not tier or (track ~= "free" and track ~= "premium") then return eco_fail("pedido_invalido") end
  local entry
  for _, t in ipairs(CAT.pass) do if t.tier == tier then entry = t end end
  if not entry then return eco_fail("no_existe") end
  local ok, res, doc = eco_update(uid, function(d)
    if (tonumber(d.pass.pts) or 0) < entry.points then return false, "faltan_puntos" end
    local claimed = (track == "free") and d.pass.cf or d.pass.cp
    local key = tostring(tier)
    if claimed[key] then return false, "ya_reclamado" end
    if track == "premium" and not d.pass.premium then return false, "sin_premium" end
    claimed[key] = true
    local r = (track == "free") and entry.free or entry.premium
    local note = give_reward(d, r)
    return true, { reward = r, note = note }
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { claim = res })
end

-- ---- Desafios: reclamar ----
local function rpc_challenge_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local id = decode(payload).id
  if type(id) ~= "string" then return eco_fail("pedido_invalido") end
  local def
  for _, c in ipairs(CAT.challenge_pool) do if c.id == id then def = c end end
  if not def then return eco_fail("no_existe") end
  local ok, res, doc = eco_update(uid, function(d)
    local ch = ensure_challenges(d)
    local active = false
    for _, a in ipairs(ch.ids) do if a == id then active = true end end
    if not active then return false, "no_es_de_hoy" end
    if ch.claimed[id] then return false, "ya_reclamado" end
    if (ch.prog[def.track] or 0) < def.target then return false, "sin_completar" end
    ch.claimed[id] = true
    if def.reward.gold then d.gold = d.gold + def.reward.gold end
    if def.reward.diamonds then d.diamonds = d.diamonds + def.reward.diamonds end
    return true, def.reward
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { reward = res })
end

-- ---- Video para acelerar un anfora: quita 1 hora (mismo ritmo y tope que los videos de recompensa) ----
local CHEST_AD_DAILY_MAX = 12
local function rpc_chest_ad(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local i = tonumber(decode(payload).slot)
  if not i or i < 1 or i > 4 then return eco_fail("pedido_invalido") end
  local ok, res, doc = eco_update(uid, function(d)
    local s = d.chest[i]
    if not s or s.state ~= "unlocking" then return false, "no_esta_abriendo" end
    local today = eco_day()
    d.ads = d.ads or {}
    if d.ads.cday ~= today then d.ads.cday = today; d.ads.cn = 0 end
    local t = os.time()
    if (t - (tonumber(d.ads.clast) or 0)) < AD_MIN_GAP then return false, "muy_rapido" end
    if d.ads.cn >= CHEST_AD_DAILY_MAX then return false, "tope_diario" end
    d.ads.cn = d.ads.cn + 1; d.ads.clast = t
    s.endsAt = (tonumber(s.endsAt) or 0) - 3600000
    if s.endsAt <= now_ms() then s.state = "ready"; s.endsAt = 0 end
    return true
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc)
end

nk.register_rpc(rpc_chest_ad, "eco_chest_ad")
nk.register_rpc(rpc_chest_start, "eco_chest_start")
nk.register_rpc(rpc_chest_gems, "eco_chest_gems")
nk.register_rpc(rpc_chest_open, "eco_chest_open")
nk.register_rpc(rpc_daily_claim, "eco_daily_claim")
nk.register_rpc(rpc_ad_claim, "eco_ad_claim")
nk.register_rpc(rpc_name_change, "eco_name_change")
nk.register_rpc(rpc_pass_claim, "eco_pass_claim")
nk.register_rpc(rpc_challenge_claim, "eco_challenge_claim")


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
          out.betPayout = bet.amount * 2
          d.stats.bstreak = (d.stats.bstreak or 0) + 1
          d.stats.bpProfit = (d.stats.bpProfit or 0) + bet.amount
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
nk.register_rpc(rpc_progress, "eco_progress")
nk.register_rpc(rpc_dice_change, "eco_dice_change")
nk.register_rpc(rpc_game_ad, "eco_game_ad")


-- ============================================================================
-- ECONOMIA (parte D): Calendario de Adviento y regalos de amigos
-- ============================================================================
DICE_FACE_CHANCE.xmas = 1

-- Dia del calendario (UTC): diciembre = su dia (maximo 24), enero = 24, el resto del ano 0
local function xmas_day()
  local m, dd = tonumber(os.date("!%m")), tonumber(os.date("!%d"))
  if m == 12 then return math.min(dd, 24) end
  if m == 1 then return 24 end
  return 0
end
local function xmas_key()
  local y, m = tonumber(os.date("!%Y")), tonumber(os.date("!%m"))
  if m == 1 then y = y - 1 end
  return "adviento" .. tostring(y)
end
local function xmas_reward(day)
  if day == 24 then return { kind = "gran", coins = 10000 } end
  if day == 6 then return { kind = "chest", type = "plata" } end
  if day == 12 or day == 18 then return { kind = "chest", type = "oro" } end
  if day == 4 or day == 10 or day == 16 or day == 22 then return { kind = "face" } end
  return { kind = "coins", coins = 300 + day * 100 }
end

local function rpc_xmas_open(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local day = tonumber(decode(payload).day)
  if not day or day < 1 or day > 24 or day ~= math.floor(day) then return eco_fail("pedido_invalido") end
  if day > xmas_day() then return eco_fail("todavia_no") end
  local ok, res, doc = eco_update(uid, function(d)
    local key = xmas_key()
    d.xmas = d.xmas or {}
    if d.xmas.key ~= key then d.xmas = { key = key, opened = {} } end
    for _, o in ipairs(d.xmas.opened) do if o == day then return false, "ya_abierta" end end
    d.xmas.opened[#d.xmas.opened + 1] = day
    local r = xmas_reward(day)
    local out = { kind = r.kind }
    if r.kind == "coins" then
      d.gold = d.gold + r.coins; out.gold = r.coins
    elseif r.kind == "chest" then
      if add_chest(d, r.type) then out.chest = r.type else d.gold = d.gold + 3000; out.gold = 3000; out.nospace = true end
    elseif r.kind == "face" then
      local got = roll_dice_face(d, "xmas")
      if got then out.face = got else d.gold = d.gold + 2000; out.gold = 2000; out.alldice = true end
    else
      d.gold = d.gold + r.coins; out.gold = r.coins
      d.own.boards.navidad2 = true
      d.own.dice.dep_santa = true
      if add_chest(d, "oro") then out.chest = "oro" end
    end
    return true, out
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { reward = res })
end

-- Regalo de un amigo: 100 de oro, maximo 5 al dia y uno por amigo al dia
local GIFT_GOLD, GIFT_DAY_MAX = 100, 5
local function rpc_gift_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local fid = decode(payload).id
  if type(fid) ~= "string" or #fid == 0 or #fid > 64 or fid == uid then return eco_fail("pedido_invalido") end
  local okf, us = pcall(nk.users_get_id, { fid })
  if not okf or type(us) ~= "table" or #us ~= 1 then return eco_fail("no_existe") end
  local ok, res, doc = eco_update(uid, function(d)
    local today = eco_day()
    d.gifts = d.gifts or {}
    if d.gifts.day ~= today then d.gifts = { day = today, n = 0, ids = {} } end
    if d.gifts.ids[fid] then return false, "ya_reclamado" end
    if d.gifts.n >= GIFT_DAY_MAX then return false, "tope_diario" end
    d.gifts.ids[fid] = true; d.gifts.n = d.gifts.n + 1
    d.gold = d.gold + GIFT_GOLD
    return true, GIFT_GOLD
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { gold = res })
end

nk.register_rpc(rpc_xmas_open, "eco_xmas_open")
nk.register_rpc(rpc_gift_claim, "eco_gift_claim")


-- ---- El perfil que sube el telefono ya no puede cambiar el oro ni las gemas ----
ECO_PROFILE = function(uid, obj, v)
  local doc = eco_read(uid)
  if not doc then return false end            -- jugador antiguo todavia sin migrar: sigue la guardia vieja
  local out = obj.value
  if v.gold ~= nil then out = out:gsub('("gold"%s*:%s*)-?[%d%.eE%+%-]+', '%1' .. string.format("%.0f", doc.gold), 1) end
  if v.diamonds ~= nil then out = out:gsub('("diamonds"%s*:%s*)-?[%d%.eE%+%-]+', '%1' .. string.format("%.0f", doc.diamonds), 1) end
  obj.value = out
  return true
end

-- (La coleccion eco se guarda con permission_write=0: el telefono no puede escribirla ni borrarla.)
