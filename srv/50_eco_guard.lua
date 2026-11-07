
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
