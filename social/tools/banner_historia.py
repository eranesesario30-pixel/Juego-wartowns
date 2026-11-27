from PIL import Image, ImageDraw, ImageFont, ImageFilter
import sys
W,H=1080,1920
# fondo azul noche con degradado suave
bg=Image.new('RGB',(W,H),'#0b1233')
d=ImageDraw.Draw(bg)
for y in range(H):
    t=y/H; c=(int(11+14*(1-t)),int(18+22*(1-t)),int(51+40*(1-t)));d.line([(0,y),(W,y)],fill=c)
bg.save('bg.png')
# banner (png con alfa) del link
def font(sz):
    for p in ['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf','/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf']:
        try: return ImageFont.truetype(p,sz)
        except: pass
    return ImageFont.load_default()
bw,bh=900,150
b=Image.new('RGBA',(W,H),(0,0,0,0)); d=ImageDraw.Draw(b)
x0=(W-bw)//2; y0=1650
d.rounded_rectangle([x0,y0,x0+bw,y0+bh],radius=40,fill=(8,14,44,235),outline=(255,200,60,255),width=5)
f1=font(46); f2=font(35)
t1='Disponible en la App Store'; t2='apps.apple.com/app/id6837540118'
for t,f,yy,col in [(t1,f1,y0+22,(255,255,255,255)),(t2,f2,y0+88,(255,205,70,255))]:
    w=d.textlength(t,font=f); d.text(((W-w)/2,yy),t,font=f,fill=col)
b.save('banner.png')
