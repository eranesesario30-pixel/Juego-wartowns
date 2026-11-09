
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


-- Invita y gana: quien entra con el enlace de un amigo lo anota; cuando juega su primera partida de verdad,
-- el que lo invito recibe 100 diamantes (tope: 10 por dia y 100 en total, una sola vez por invitado)
local REF_GEMS, REF_DAY_MAX, REF_TOTAL_MAX = 100, 10, 100
local function rpc_ref_set(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local from = decode(payload).from
  if type(from) ~= "string" or #from == 0 or #from > 64 or from == uid then return eco_fail("pedido_invalido") end
  local okf, us = pcall(nk.users_get_id, { from })
  if not okf or type(us) ~= "table" or #us ~= 1 then return eco_fail("no_existe") end
  local ok, res, doc = eco_update(uid, function(d)
    if d.refBy then return true, "ya" end
    if (tonumber(d.stats.games) or 0) > 0 then return true, "no_nuevo" end   -- solo cuentas que aun no han jugado
    d.refBy = from
    return true, "ok"
  end)
  if not ok then return eco_fail(res) end
  return eco_ok(doc, { ref = res })
end

local function rpc_ref_claim(context, payload)
  local uid = context.user_id
  if not uid then return eco_fail("sin_sesion") end
  local inviter
  local ok, res, doc = eco_update(uid, function(d)
    if not d.refBy or d.refPaid then return true, "nada" end
    if (tonumber(d.stats.games) or 0) < 1 then return true, "aun_no" end
    d.refPaid = true; inviter = d.refBy
    return true, "pagar"
  end)
  if not ok then return eco_fail(res) end
  local paid = 0
  if res == "pagar" and inviter then
    local ok2, got = eco_update(inviter, function(d)
      local today = eco_day()
      d.refs = d.refs or { n = 0, day = "", dn = 0 }
      if d.refs.day ~= today then d.refs.day = today; d.refs.dn = 0 end
      if d.refs.dn >= REF_DAY_MAX or d.refs.n >= REF_TOTAL_MAX then return true, 0 end
      d.refs.dn = d.refs.dn + 1; d.refs.n = d.refs.n + 1
      d.diamonds = d.diamonds + REF_GEMS
      return true, REF_GEMS
    end)
    if ok2 then paid = got end
  end
  return eco_ok(doc, { invited = res, paid = paid })
end

nk.register_rpc(rpc_xmas_open, "eco_xmas_open")
nk.register_rpc(rpc_gift_claim, "eco_gift_claim")
nk.register_rpc(rpc_ref_set, "eco_ref_set")
nk.register_rpc(rpc_ref_claim, "eco_ref_claim")
