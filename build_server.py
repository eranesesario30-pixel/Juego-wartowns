import sys,glob
parts=sorted(glob.glob('/home/claude/juego-wartowns/srv/[0-9]*.lua'))
out=sys.argv[1] if len(sys.argv)>1 else '/home/claude/juego-wartowns/parche_eco_test.lua'
open(out,'w').write('\n'.join(open(p).read() for p in parts))
print('ok',out,[p.split('/')[-1] for p in parts])
