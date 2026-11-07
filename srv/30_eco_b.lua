
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
