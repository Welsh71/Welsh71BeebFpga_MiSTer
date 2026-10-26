# sim-only: give every scalar/vector reg an initial value of 0 (FPGA power-up)
import re,sys
s=open(sys.argv[1]).read()
out=[]; mods=[]
for m in re.finditer(r'\bmodule\s+(\w+)',s): mods.append(m.start())
def proc(seg):
    names=[]; blk=None
    for line in seg.split('\n'):
        bm=re.search(r'begin\s*:\s*(\w+)',line)
        if bm: blk=bm.group(1)
        code=re.sub(r'//.*|/\*.*?\*/','',line)
        m=re.match(r'\s*(?:output\s+)?reg\b\s*(\[[^\]]*\])?\s*([^;=]+);\s*$',code)
        if m:
            for n in m.group(2).split(','):
                n=n.strip()
                if not n or '[' in n: continue
                indent=len(line)-len(line.lstrip())
                names.append((blk if indent>0 else None)+'.'+n if indent>0 and blk else n)
        m2=re.match(r'\s*output\s+reg\s*(\[[^\]]*\])?\s*(\w+)\s*,?\s*$',code)
        if m2: names.append(m2.group(2))
    return names
res=s
for i,st in enumerate(mods):
    en=s.index('endmodule',st)
    names=proc(s[st:en])
    init='initial begin\n'+''.join('  %s = 0;\n'%n for n in names)+'end\n'
    res=res.replace(s[st:en], s[st:en]+init,1)
open(sys.argv[1],'w').write(res)
