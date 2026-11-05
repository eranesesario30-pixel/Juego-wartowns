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
  start_diamonds    = 500,
}
local GUARD = "econ_guard"
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
}

local function safe_key(store, tid)
  local k = (tostring(store) .. "_" .. tostring(tid)):gsub("[^%w%._%-]", "_")
  return k
end

local function reply(t) return nk.json_encode(t) end

-- Suma el premio a lo que la guardia considera "saldo aceptado", para que el
-- siguiente guardado del teléfono (saldo + compra) no se recorte como trampa.
local function credit_guard(uid, gold, diamonds)
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
          local writes = {{ collection = IAP, key = key, user_id = uid, permission_read = 0, permission_write = 0,
            value = { product_id = vp.product_id, transaction_id = vp.transaction_id, store = vp.store,
                      gold = prod.gold or 0, diamonds = prod.diamonds or 0, xp_hours = prod.xp_hours or 0,
                      status = "pending", credited = false, created = os.time() } }}
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
        v.credited = true
        nk.storage_write({{ collection = IAP, key = o.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
      end
      out[#out + 1] = { transaction_id = v.transaction_id, key = o.key, product_id = v.product_id,
                        gold = v.gold or 0, diamonds = v.diamonds or 0, xp_hours = v.xp_hours or 0 }
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
nk.register_rpc(rpc_iap_ack, "iap_ack")


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
local LIGA_MIN_GAP = 60
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

local function rpc_global_report(context, payload)
  local uid = context.user_id
  if not uid then return reply({ ok = false, error = "sin_sesion" }) end
  local okd, d = pcall(nk.json_decode, payload or "{}")
  if not okd or type(d) ~= "table" then return reply({ ok = false, error = "pedido_invalido" }) end
  local now = os.time()
  local rl = nk.storage_read({{ collection = LIGA_RL, key = "main", user_id = uid }})
  if rl and #rl > 0 and type(rl[1].value) == "table" and (now - (tonumber(rl[1].value.t) or 0)) < LIGA_MIN_GAP then
    return reply({ ok = false, error = "muy_rapido" })
  end
  nk.storage_write({{ collection = LIGA_RL, key = "main", user_id = uid, value = { t = now },
                      permission_read = 0, permission_write = 0 }})
  local pts = (d.won == true) and 25 or 8
  local name = clean_text(d.name, 24) or "Jugador"
  local meta = {}
  local av = clean_text(d.avatar, 200)
  if av then meta.av = av end
  local ok, rec = pcall(nk.leaderboard_record_write, GLOBAL_BOARD, uid, name, pts, 0, meta)
  if not ok then
    nk.logger_warn("LIGA no se pudo apuntar user=" .. tostring(uid) .. " err=" .. tostring(rec))
    return reply({ ok = false, error = "no_se_pudo" })
  end
  return reply({ ok = true, points = rec and rec.score or pts })
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
  return reply({ ok = true, rows = rows, me = me, next_reset = info and info.next_reset or nil,
                 prize = GLOBAL_PRIZE })
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
  -- 2) entregar lo pendiente (igual que las compras)
  local objs = nk.storage_list(uid, LIGA_GRANTS, 50, nil)
  local out = {}
  for _, o in ipairs(objs or {}) do
    local v = o.value
    if type(v) == "table" and v.status ~= "granted" then
      if not v.credited then
        credit_guard(uid, v.gold, v.diamonds)
        v.credited = true
        nk.storage_write({{ collection = LIGA_GRANTS, key = o.key, user_id = uid, value = v, permission_read = 0, permission_write = 0 }})
      end
      out[#out + 1] = { key = o.key, kind = v.kind, gold = v.gold or 0, diamonds = v.diamonds or 0 }
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
nk.register_rpc(rpc_liga_claim, "liga_claim")
nk.register_rpc(rpc_liga_ack, "liga_ack")

nk.register_req_before(before_write, "WriteStorageObjects")
nk.register_req_before(before_delete, "DeleteStorageObjects")
nk.logger_info("Parche: guardia de economía activa")
