-- Parche — aviso de actualización de la app.
-- Los números salen de app_version.json (repo Juego-wartowns, rama main), que se actualiza desde GitHub
-- sin tocar el servidor. El servidor lo lee cada 5 minutos. Si no puede leerlo, usa los valores de abajo.
-- minVersion: las apps con versión menor quedan bloqueadas hasta actualizar.
-- latestVersion: las apps con versión menor (pero >= minVersion) ven un aviso con "Más tarde".
-- (Va dentro de do...end para no gastar variables locales.)
do
  local nk = require("nakama")
  local APP_MIN_VERSION = 0
  local APP_LATEST_VERSION = 1250
  local URL = "https://raw.githubusercontent.com/eranesesario30-pixel/Juego-wartowns/main/app_version.json"
  local cache, cacheT = nil, 0
  local function load_versions()
    local now = os.time()
    if cache and now - cacheT < 300 then return cache end
    local out = { minVersion = APP_MIN_VERSION, latestVersion = APP_LATEST_VERSION }
    local ok, code, _, body = pcall(nk.http_request, URL, "GET", { ["Accept"] = "application/json" }, "", 4000)
    if ok and code == 200 and body then
      local ok2, j = pcall(nk.json_decode, body)
      if ok2 and type(j) == "table" then
        local mn, lt = tonumber(j.minVersion), tonumber(j.latestVersion)
        if mn then out.minVersion = mn end
        if lt then out.latestVersion = lt end
      end
    end
    cache, cacheT = out, now
    return out
  end
  local function rpc_app_version(context, payload)
    local v = load_versions()
    return nk.json_encode({ minVersion = v.minVersion, latestVersion = v.latestVersion })
  end
  nk.register_rpc(rpc_app_version, "app_version")
end
