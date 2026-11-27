import os, math
import cap
from cap import *
from playwright.sync_api import sync_playwright
out='/tmp/promo/sc_tienda_st'; os.makedirs(out,exist_ok=True)
SET="""(()=>{const e=document.getElementById('loginScreen'); if(e) e.style.display='none'; const l=document.getElementById('lobbyScreen'); if(l) l.style.display='flex'; lobbyDiamonds=3200; openStore();
 const mk=(id,css,html)=>{const o=document.createElement('div'); o.id=id; o.style.cssText=css; o.innerHTML=html; document.body.appendChild(o); return o;};
 mk('pSub','position:fixed;left:16px;right:16px;bottom:108px;z-index:99999;text-align:center;font:900 27px system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.68);border:2px solid #ffd45a;border-radius:18px;padding:11px 10px;pointer-events:none;transition:opacity .5s','Diamantes, oro y elixires ✨');
 mk('pEnd','position:fixed;left:16px;right:16px;bottom:108px;z-index:99999;text-align:center;font:900 29px system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.68);border:2px solid #ffd45a;border-radius:18px;padding:11px 10px;opacity:0;pointer-events:none;transition:opacity .5s','¿Qué comprarías primero?');
})()"""
fps=30; secs=10
with sync_playwright() as p:
    b,pg=session(p,430,645,2.5116)
    for _ in range(90): pg.evaluate("__advance(33.333)")
    pg.evaluate(SET)
    for _ in range(30): pg.evaluate("__advance(33.333)")
    mx=pg.evaluate("(()=>{const o=document.getElementById('storeOverlay'); return o.scrollHeight-o.clientHeight})()")
    print('max',mx)
    for i in range(fps*secs):
        t=i/fps
        k=min(1,max(0,(t-1.0)/6.5)); e=k*k*(3-2*k)
        pg.evaluate("(y)=>{document.getElementById('storeOverlay').scrollTop=y}",mx*e)
        if t>=7.0: pg.evaluate("document.getElementById('pEnd').style.opacity=1;document.getElementById('pSub').style.opacity=0")
        pg.evaluate("__advance(33.333)")
        pg.screenshot(path='%s/f%04d.jpg'%(out,i),type='jpeg',quality=92)
    b.close()
