import sys, os, json, time
from playwright.sync_api import sync_playwright
L='/tmp/promo/lib/three/'
INIT="""
(()=>{
 let vnow=0; const start0=Date.now(); const D=Date;
 let timers=[]; let tid=1; let rafs=[]; let rid=1;
 performance.now=()=>vnow;
 window.Date=class extends D{constructor(...a){ if(a.length===0) super(start0+vnow); else super(...a);} static now(){return start0+vnow;}};
 window.setTimeout=(f,ms=0,...a)=>{ if(typeof f!=='function') return 0; const id=tid++; timers.push({id,t:vnow+Math.max(0,+ms||0),f,a,iv:null}); return id; };
 window.setInterval=(f,ms=0,...a)=>{ if(typeof f!=='function') return 0; const id=tid++; ms=Math.max(1,+ms||0); timers.push({id,t:vnow+ms,f,a,iv:ms}); return id; };
 window.clearTimeout=window.clearInterval=(id)=>{ timers=timers.filter(x=>x.id!==id); };
 window.requestAnimationFrame=(f)=>{ const id=rid++; rafs.push({id,f}); return id; };
 window.cancelAnimationFrame=(id)=>{ rafs=rafs.filter(x=>x.id!==id); };
 window.__advance=(dt)=>{
   const target=vnow+dt; let guard=0;
   while(guard++<5000){
     let bi=-1,bt=Infinity; for(let i=0;i<timers.length;i++){ if(timers[i].t<bt){bt=timers[i].t;bi=i;} }
     if(bi<0||bt>target) break;
     const tm=timers[bi]; vnow=Math.max(vnow,tm.t);
     if(tm.iv){ tm.t+=tm.iv; } else timers.splice(bi,1);
     try{ tm.f(...tm.a); }catch(e){}
   }
   vnow=target;
   const cbs=rafs; rafs=[]; cbs.forEach(c=>{ try{ c.f(vnow); }catch(e){} });
   try{ document.getAnimations().forEach(a=>{ try{ if(a.__v===undefined) a.__v=0; a.pause(); a.__v+=dt; a.currentTime=a.__v; }catch(e){} }); }catch(e){}
 };
})();
"""
def route(r):
    u=r.request.url
    if 'three.min.js' in u: r.fulfill(path=L+'build/three.min.js',content_type='application/javascript')
    elif 'GLTFLoader.js' in u: r.fulfill(path=L+'examples/js/loaders/GLTFLoader.js',content_type='application/javascript')
    elif u.startswith('file://') or u.startswith('data:') or u.startswith('blob:'): r.continue_()
    else: r.abort()
def session(p,w=430,h=764,dsf=3.2):
    b=p.chromium.launch(args=['--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist'])
    pg=b.new_page(viewport={'width':w,'height':h},device_scale_factor=dsf)
    pg.route('**/*',route); pg.add_init_script(INIT)
    pg.goto('file:///home/claude/juego-wartowns/index.html?dev=1')
    return b,pg
def run(setup_js,outdir,seconds,fps=30,warm=3.0,step_mult=1.0,hook=None):
    os.makedirs(outdir,exist_ok=True)
    with sync_playwright() as p:
        b,pg=session(p)
        for _ in range(int(warm*30)): pg.evaluate("__advance(33.333)")
        pg.evaluate(setup_js)
        n=int(seconds*fps)
        for i in range(n):
            pg.evaluate("__advance(%f)"%(1000/fps*step_mult))
            if hook: hook(pg,i)
            pg.screenshot(path='%s/f%04d.jpg'%(outdir,i),type='jpeg',quality=90)
        b.close()
def main2():
    import sys
    setup="""()=>{ ['loginScreen','lobbyScreen','betScreen','boardChoiceScreen'].forEach(i=>{const e=document.getElementById(i); if(e) e.style.display='none';}); startGame('ffa'); players.forEach(p=>{p.isBot=true;p.active=true;}); }"""
    run(setup,'/tmp/promo/clipB',float(sys.argv[1]))
if __name__=='__main__' and len(sys.argv)>2 and sys.argv[2]=='B':
    main2(); sys.exit()
if __name__=='__main__':
    setup="""()=>{ ['loginScreen','lobbyScreen','betScreen','boardChoiceScreen'].forEach(i=>{const e=document.getElementById(i); if(e) e.style.display='none';}); startGame('ffa'); players.forEach(p=>{p.isBot=true;p.active=true;}); }"""
    t=time.time(); run(setup,'/tmp/promo/clipA',float(sys.argv[1]) if len(sys.argv)>1 else 2); print(time.time()-t)
