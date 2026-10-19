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
  start_gold        = 1000,      -- perfil nuevo
  start_diamonds    = 200,
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

nk.register_req_before(before_write, "WriteStorageObjects")
nk.register_req_before(before_delete, "DeleteStorageObjects")
nk.logger_info("Parche: guardia de economía activa")
