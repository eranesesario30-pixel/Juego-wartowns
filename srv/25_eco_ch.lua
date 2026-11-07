
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
