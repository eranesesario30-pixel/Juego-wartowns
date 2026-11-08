# Economía y progreso en el servidor (proyecto)

Objetivo: que el oro, las gemas, lo desbloqueado y todo premio vivan en el servidor (Nakama) y el teléfono solo muestre y pida.

## Piezas
- `srv/00_base.lua`  : parche.lua actual (guardia, compras, liga, torneos). Se desplegaba tal cual.
- `srv/10_catalog.lua`: catálogos generados desde el juego (precios, premios, ánforas...). Se regenera con `srv/gen_catalog.py`.
- `srv/20_eco.lua`   : cartera + inventario + RPCs `eco_*`.
- `build_server.py`  : une las piezas en `parche.lua` (el archivo que se despliega).

## Documento `eco/main` por jugador (solo el servidor escribe)
gold, diamonds, chest[4], own{tokens,dice,boards,avatars,frames}, pass{...}, daily{...}, ads{...}, xp{...}

## Fases
A cartera + migración | B gastos y premios fijos | C apuestas/partidas | D pruebas y publicación
El juego publicado NO se toca hasta terminar D (copia de trabajo: /home/claude/pachis-economia.html).

## Estado: fase D terminada (pruebas pasadas, nada publicado)
Archivos listos: `parche_economia.lua` (servidor nuevo, NO desplegado), `/home/claude/pachis-economia.html` (cliente BUILD 1246).
`parche.lua` sigue siendo el servidor actual (v1245) = copia de seguridad / vuelta atrás.

## Topes anti-trampa en apuestas (servidor)
- Partida mínima de 20 s desde `eco_match_start`; si se cierra antes, la apuesta se da por perdida.
- Sin `eco_match_start` la apuesta solo se devuelve (sin ganancia).
- 8 victorias seguidas con apuesta: el resto del día solo se devuelve lo apostado.
- Ganancia máxima por apuestas: 60.000.000 al día (después solo se devuelve lo apostado).
- Cierres de partida separados por 45 s como mínimo.
Límite que queda: contra bots (y el resultado en mesas con personas) el servidor no ve las jugadas, solo el resultado que reporta el teléfono.
La solución total sería que el servidor juegue las partidas contra bots (proyecto grande aparte).

## Puesta en marcha (en este orden)
1. Copia de seguridad en el VPS: copiar `C:\nakama\data\modules\parche.lua` a `parche_v1245_respaldo.lua`.
2. Subir las apps nuevas (Android/iOS, BUILD 1246) a las tiendas y esperar a que se aprueben.
3. Con las apps aprobadas: copiar `parche_economia.lua` como `C:\nakama\data\modules\parche.lua`, reiniciar `NakamaService`.
4. Publicar la web nueva (GitHub Pages) y subir `minVersion` a 1246 en el JSON de actualización (fuerza a actualizar las apps viejas).
5. Poner `ADS_LIVE=true` solo cuando se publique la versión de producción.
Vuelta atrás: devolver `parche_v1245_respaldo.lua` a `parche.lua`, reiniciar el servicio y volver a publicar la web v1245.
Importante: el cliente nuevo NO funciona con el servidor viejo (usa RPCs `eco_*`), y los clientes viejos NO muestran bien el oro con el servidor nuevo.


## Regla: si no ganas, no sumas nada
Una derrota no da puntos de liga, ni puntos de nivel, ni puntos del Pase (solo cuenta como partida jugada para los desafíos). La victoria da 30 de nivel/Pase, 25 de liga y 50 de oro.
