# Genera 10_catalog.lua a partir de catalogs.json (volcado desde el juego con Playwright)
import json
r=json.load(open('catalogs.json'))
def lua(v):
    if v is None: return 'nil'
    if v is True: return 'true'
    if v is False: return 'false'
    if isinstance(v,(int,float)): return repr(v) if isinstance(v,float) and not v.is_integer() else str(int(v))
    if isinstance(v,str): return json.dumps(v,ensure_ascii=False)
    if isinstance(v,list): return '{'+','.join(lua(x) for x in v)+'}'
    if isinstance(v,dict): return '{'+','.join('['+json.dumps(k,ensure_ascii=False)+']='+lua(x) for k,x in v.items())+'}'
o=['-- GENERADO por gen_catalog.py: no editar a mano','local CAT = {}']
# precios por id (nil = no se vende con gemas)
dice={}
for e in r['DICE_CATALOG']:
    if e['id']=='classic': continue
    dice[e['id']]={'price': (e.get('price') or r['PRICE_DICE']) if not (e.get('passOnly') or e.get('anfora')) else None,
                   'pass':bool(e.get('passOnly')),'anfora':bool(e.get('anfora')),'easy':bool(e.get('easy')),'exotic':bool(e.get('exotic'))}
av={}
for e in r['AVATAR_CATALOG']:
    av[e['id']]={'price':None if (e.get('passOnly') or e.get('tier')=='basic') else e.get('price'),'pass':bool(e.get('passOnly')),'pieces':e.get('pieces'),'basic':e.get('tier')=='basic'}
bd={}
for e in r['BOARD_CATALOG']:
    if e['id']=='classic': continue
    bd[e['id']]={'price':None if e.get('passOnly') else e.get('price'),'pass':bool(e.get('passOnly'))}
# Objetos de Navidad (se agregan a la tienda solo en temporada; el servidor los conoce siempre)
for xid in ['xd_reno','xd_muneco','xd_baston','xd_gorro','xd_campana','xd_estrella','xd_galleta','xd_regalo']:
    dice[xid]={'price':r['PRICE_DICE'],'pass':False,'anfora':False,'easy':False,'exotic':False,'xmas':True}
for xid in ['xtaller','xpueblo']:
    bd[xid]={'price':1000,'pass':False,'xmas':True}
tokens={}
for a in r['ANIMALS']:
    pass_only=a in r['PASS_ONLY_TOKENS']
    tokens[a]={'price':None if pass_only else r['PRICE_TOKEN'],'pass':pass_only,'free':a in r['TOKEN_FREE_TEST']}
o.append('CAT.dice='+lua(dice)); o.append('CAT.avatars='+lua(av)); o.append('CAT.boards='+lua(bd)); o.append('CAT.tokens='+lua(tokens))
o.append('CAT.retired='+lua(r['RETIRED_TOKENS']))
o.append('CAT.chests='+lua(r['CHEST_TYPES']))
o.append('CAT.pass='+lua(r['PASS_TIERS']))
o.append('CAT.daily='+lua(r['DAILY_REWARDS']))
o.append('CAT.challenges='+lua(r['CHALLENGES']))
o.append('CAT.challenge_pool='+lua(r['CHALLENGE_POOL']))
o.append('CAT.frames='+lua({e['id']:e['levelReq'] for e in r['FRAME_CATALOG']}))
open('10_catalog.lua','w').write('\n'.join(o)+'\n')
print({k:len(v) for k,v in [('dice',dice),('avatars',av),('boards',bd),('tokens',tokens)]})
