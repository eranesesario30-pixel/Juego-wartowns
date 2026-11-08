
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
