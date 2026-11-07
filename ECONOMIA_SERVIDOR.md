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
