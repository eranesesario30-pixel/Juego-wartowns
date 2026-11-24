import sys, os, json
from playwright.sync_api import sync_playwright
import cap
from cap import *
scn=sys.argv[1]; secs=float(sys.argv[2]); mult=float(sys.argv[3]); mode=sys.argv[4] if len(sys.argv)>4 else 'rd'
out=f'/tmp/promo/sc_{scn}'+(sys.argv[5] if len(sys.argv)>5 else ''); os.makedirs(out,exist_ok=True)
SC={
 'baja':dict(kind='baja',head='TRAMPA: BAJA',sub='Si caes aquí, retrocedes a un número más bajo',end='¿Cuál es la trampa que más odias?'),
 'sube':dict(kind='sube',head='VENTAJA: SUBE',sub='Si caes aquí, subes a un número más alto',end='¿Cuál es tu ventaja favorita?'),
}[scn]
SET="""(async()=>{
 ['loginScreen','lobbyScreen','betScreen','boardChoiceScreen'].forEach(i=>{const e=document.getElementById(i); if(e) e.style.display='none';});
 profileStats.equippedBoard='%(mode)s'; window.boardOwned=()=>true;
 const T=['parche2d','mapachito2d','zorrito2d','conejito2d']; ['red','blue','yellow','green'].forEach((c,i)=>{tokenSkins[c]=T[i];});
 startGame('ffa'); players.forEach(p=>{p.isBot=false;p.active=true;});
 const N=[['Carlos','spx4',3200],['María','spx1',1850],['José','spy13',2400],['Ana','spy5',990]];
 players.forEach((p,i)=>{ botProfiles[p.color]={n:N[i][0],a:N[i][1]}; p._d=N[i][2]; });
 lobbyDiamonds=3200; window.ensureDisplayName=()=>'Carlos'; window.myAvatarUrl=()=>avatarURL('av3');
 try{updateGameHudDiamonds();renderPlayerCards();}catch(e){}
 const k='%(kind)s'; let bi=-1; for(let i=14;i<path.length-12;i++){ if(path[i].type===k){bi=i;break;} }
 window.__bi=bi; window.__target=path[bi]&&path[bi].target;
 current=0; players[0].position=bi-5; updateTokenPosition(players[0]); updateActiveCellGlow();
 dice=[null,null]; usedDie=[false,false]; render();
 const mk=(id,css,html)=>{const o=document.createElement('div'); o.id=id; o.style.cssText=css; o.innerHTML=html; document.body.appendChild(o); return o;};
 mk('pHead','position:fixed;left:10px;right:10px;top:136px;z-index:99999;text-align:center;font:900 27px system-ui,sans-serif;color:#fff;text-shadow:0 3px 8px #000,0 0 14px #000;pointer-events:none;transition:opacity .4s','%(head)s');
 mk('pSub','position:fixed;left:14px;right:14px;bottom:12px;z-index:99999;text-align:center;font:800 21px system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.65);border:2px solid #ffd45a;border-radius:16px;padding:12px 10px;pointer-events:none;transition:opacity .4s','%(sub)s');
 mk('pEnd','position:fixed;left:12px;right:12px;bottom:10px;z-index:99999;text-align:center;font:900 24px system-ui,sans-serif;color:#fff;background:rgba(0,0,0,.65);border:2px solid #ffd45a;border-radius:18px;padding:12px 8px;opacity:0;transition:opacity .4s;pointer-events:none','%(end)s<br><span style="font-size:18px;font-weight:700">Cuéntanos en comentarios</span>');
})()"""%dict(mode=mode,kind=SC['kind'],head=SC['head'],sub=SC['sub'],end=SC['end'])
AUD="""
(()=>{ const AC=window.AudioContext||window.webkitAudioContext;
 window.AudioContext=window.webkitAudioContext=function(){ const oc=new OfflineAudioContext(2,44100*60,44100);
   Object.defineProperty(oc,'currentTime',{get:()=>performance.now()/1000});
   Object.defineProperty(oc,'state',{get:()=>'running'}); oc.resume=()=>Promise.resolve(); window.__oc=oc; return oc; };
 window.__renderAudio=async(t0,t1)=>{ const buf=await window.__oc.startRendering(); const sr=buf.sampleRate; const a=Math.floor(t0*sr), b=Math.floor(t1*sr);
   const L=buf.getChannelData(0), R=buf.getChannelData(1); const n=b-a; const out=new Int16Array(n*2);
   for(let i=0;i<n;i++){ out[2*i]=Math.max(-1,Math.min(1,L[a+i]))*32767; out[2*i+1]=Math.max(-1,Math.min(1,R[a+i]))*32767; }
   let s=''; const u=new Uint8Array(out.buffer); for(let i=0;i<u.length;i+=8192) s+=String.fromCharCode.apply(null,u.subarray(i,i+8192)); return btoa(s); };
})();
"""
fps=30
with sync_playwright() as p:
    b=p.chromium.launch(args=['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist'])
    pg=b.new_page(viewport={'width':430,'height':764},device_scale_factor=2.5116)
    pg.route('**/*',route); pg.add_init_script(AUD); pg.add_init_script(INIT); pg.goto('file:///home/claude/juego-wartowns/index.html?dev=1')
    for _ in range(90): pg.evaluate("__advance(33.333)")
    pg.evaluate(SET)
    for _ in range(20): pg.evaluate("__advance(33.333)")
    T0=pg.evaluate('performance.now()/1000')
    print('bi',pg.evaluate("[window.__bi,window.__target]"))
    n=int(secs*fps); moved=False
    for i in range(n):
        t=i/fps
        if t>=1.6 and not moved:
            moved=True; pg.evaluate("dice=[5,1]; usedDie=[false,true]; rolling=false; render(); executeMove(0); 0")
        if t>=secs-3.0: pg.evaluate("document.getElementById('pEnd').style.opacity=1;document.getElementById('pHead').style.opacity=0;document.getElementById('pSub').style.opacity=0")
        pg.evaluate("__advance(%f)"%(1000/fps*mult))
        pg.screenshot(path='%s/f%04d.jpg'%(out,i),type='jpeg',quality=92)
    T1=pg.evaluate('performance.now()/1000')
    import base64
    data=pg.evaluate('([t0,t1])=>__renderAudio(t0,t1)',[T0,T1])
    open(out+'.pcm','wb').write(base64.b64decode(data))
    b.close()
