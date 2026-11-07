
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
  return {
    v = 1, gold = gold, diamonds = dia, chest = chest, imported = false, created = eco_now(),
    own = { tokens = { clasico = true }, dice = { classic = true }, boards = { classic = true }, avatars = {}, frames = {} },
    pass = { pts = 0, premium = false, cf = {}, cp = {} },
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
local function eco_update(uid, fn)
  for _ = 1, 6 do
    local doc, ver = eco_read(uid)
    local isnew = false
    if not doc then doc = eco_new_doc(uid); isnew = true; ver = "*" end
    local ok, res, extra = fn(doc)
    if not ok then return false, res end
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
  return { gold = d.gold, diamonds = d.diamonds, chest = d.chest, own = d.own, pass = d.pass, daily = d.daily,
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
  local ok, res, doc = eco_update(uid, function(d) ensure_challenges(d); return true end)
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
        if c and (allowPass or not c.pass) and not c.anfora then set[id] = true end
      end
    end
    take(d0.tokens, d.own.tokens, CAT.tokens, false)
    take(d0.dice, d.own.dice, CAT.dice, false)
    take(d0.boards, d.own.boards, CAT.boards, false)
    take(d0.avatars, d.own.avatars, CAT.avatars, false)
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
