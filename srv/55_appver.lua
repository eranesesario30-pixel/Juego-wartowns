
-- Parche — aviso de actualización de la app (antes se leía de version.json en la web)
-- minVersion: las apps con versión menor quedan bloqueadas hasta actualizar.
-- latestVersion: las apps con versión menor (pero >= minVersion) ven un aviso con "Más tarde".
-- Se cambian aquí y se vuelve a copiar el archivo al VPS. (Va dentro de do...end para no gastar variables locales.)
do
  local nk = require("nakama")
  local APP_MIN_VERSION = 0
  local APP_LATEST_VERSION = 1250
  local function rpc_app_version(context, payload)
    return nk.json_encode({ minVersion = APP_MIN_VERSION, latestVersion = APP_LATEST_VERSION })
  end
  nk.register_rpc(rpc_app_version, "app_version")
end
