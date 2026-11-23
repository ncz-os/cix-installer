#!/usr/bin/env python3
"""Write the Iride source for the Cygnus NCZ Chromium icon.

usage: gen-chromium-iride-src.py OUT_DIR [cygnus|chrome|vivaldi] [FLAT.svg]

The geometry and palette are those of render-chromium-icon.py (same 512 viewBox scaled to a
128 canvas): rim disc, three gradient ring segments, soft shade, field disc, cyan accretion ring
and the black hole. Motion (about 880 ms, ends on the still icon): the segments turn in with a
stagger, the ring ignites, the hole springs open. Compile with the iride compiler:
    iride build OUT_DIR chromium-ncz-sky1.iride && iride check chromium-ncz-sky1.iride
"""
import re,os,json,sys
S=0.25
def sc(path):
    toks=re.findall(r'[MLAZmlaz]|-?\d+\.?\d*',path)
    out=[];i=0;cmd=None
    while i<len(toks):
        t=toks[i]
        if re.match(r'[A-Za-z]',t): cmd=t; out.append(t); i+=1; continue
        if cmd in 'ML': out.append(f'{float(toks[i])*S:.3f},{float(toks[i+1])*S:.3f}'); i+=2
        elif cmd=='A':
            rx,ry,rot,la,sw,x,y=toks[i:i+7]
            out.append(f'{float(rx)*S:.3f},{float(ry)*S:.3f} {rot} {la} {sw} {float(x)*S:.3f},{float(y)*S:.3f}'); i+=7
        else: i+=1
    return ' '.join(out)
ARCS=["M244.029 80.408 A176.000 176.000 0 0 0 97.947 333.429","M109.918 354.163 A176.000 176.000 0 0 0 402.082 354.163","M414.053 333.429 A176.000 176.000 0 0 0 267.971 80.408"]
SEG_DEF='<defs><linearGradient id="seg" gradientUnits="userSpaceOnUse" x1="30" y1="27.5" x2="100" y2="100"><stop offset="0.05" stop-color="#EE3FB8"/><stop offset="0.38" stop-color="#8F55F7"/><stop offset="0.80" stop-color="#2ED8F0"/></linearGradient></defs>'
SHADE_DEF='<defs><radialGradient id="shade" cx="0.38" cy="0.32" r="0.75"><stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/><stop offset="0.6" stop-color="#ffffff" stop-opacity="0"/><stop offset="1" stop-color="#000000" stop-opacity="0.22"/></radialGradient></defs>'
def svg(body,defs=''): return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">{defs}{body}</svg>\n'
OUT=sys.argv[1] if len(sys.argv)>1 else '.'
# (segment start, middle, end, accretion ring, field, hole)
PALETTES={"cygnus":("#EE3FB8","#8F55F7","#2ED8F0","#2ED8F0","#120A22","#05030A"),
          "vivaldi":("#FF6A6A","#EF3939","#A3122B","#EF3939","#1C0A0D","#070204"),
          "chrome":("#34A853","#FBBC04","#EA4335","#4285F4","#14181D","#06080A")}
# letter mark in the hole: palette -> (path, colour)
MARKS={"cygnus":("M54,76 L54,52 L74,76 L74,52","#8FF0FF"),          # N
       "chrome":("M72.4,56.3 A11,12 0 1 0 75,64 L65,64","#FFFFFF"),   # G
       "vivaldi":("M54,52 L64,76 L74,52","#FFFFFF")}                  # V
# palettes whose three ring segments are flat colours instead of one gradient
FLAT_SEGMENTS={"chrome"}
PALETTE=sys.argv[2] if len(sys.argv)>2 else "cygnus"
C0,C1,C2,RING,FIELD,HOLE=PALETTES[PALETTE]
def recolor(t, layer=None):
    # the artwork is written in the cygnus colours; swap them for the chosen palette
    # (the accretion ring, layer 006, is the only user of the ring colour)
    if layer == "008":
        return t
    if layer == "006":
        return t.replace("#2ED8F0", RING)
    if PALETTE in FLAT_SEGMENTS and layer in ("001", "002", "003"):
        # left, bottom and upper-right segments take one colour each
        t = re.sub(r"<defs>.*?</defs>", "", t, flags=re.S)
        return t.replace("url(#seg)", {"001": C0, "002": C1, "003": C2}[layer])
    for old, new in (("#EE3FB8", C0), ("#8F55F7", C1), ("#2ED8F0", C2), ("#120A22", FIELD), ("#05030A", HOLE)):
        t = t.replace(old, new)
    return t
os.makedirs(OUT+'/layers',exist_ok=True)
_mp,_mc=MARKS[PALETTE]
L={}
L['000']=svg('<circle cx="64" cy="64" r="61.25" fill="#120A22"/>')
for n,a in zip(('001','002','003'),ARCS):
    L[n]=svg(f'<path d="{sc(a)}" fill="none" stroke="url(#seg)" stroke-width="28"/>',SEG_DEF)
L['004']=svg('<circle cx="64" cy="64" r="58" fill="url(#shade)" opacity="0.9"/>',SHADE_DEF)
L['005']=svg('<circle cx="64" cy="64" r="30" fill="#120A22"/>')
L['006']=svg('<circle cx="64" cy="64" r="28.25" fill="none" stroke="#2ED8F0" stroke-width="2.5"/>')
L['007']=svg('<circle cx="64" cy="64" r="27" fill="#05030A"/>')
L['008']=svg(f'<path d="{_mp}" fill="none" stroke="{_mc}" stroke-width="4.4" stroke-linecap="round" stroke-linejoin="round"/>')
for k,v in L.items(): open(f'{OUT}/layers/{k}.svg','w').write(recolor(v,k))
if len(sys.argv)>3:
    # static SVG of the finished icon (the SVG SIT pairs the .iride with, and the fallback elsewhere)
    parts=[re.sub(r'^<svg[^>]*>|</svg>\s*$','',recolor(v,k).strip()) for k,v in sorted(L.items())]
    seen=set(); body=''
    for t in parts:
        for d in re.findall(r'<defs>.*?</defs>',t): 
            if d in seen: t=t.replace(d,'')
            seen.add(d)
        body+=t
    open(sys.argv[3],'w').write('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="512" height="512">'+body+'</svg>\n')
rim="M2.75,64A61.25,61.25 0 1 0 125.25,64A61.25,61.25 0 1 0 2.75,64Z"
man={"format":1,"canvas":[128,128],"box":[0,0,128,128],
 "stack":[
  {"shadow":{"dx":0,"dy":2.8,"blur":3.2,"color":"#05030A","opacity":0.45,"region":[-12,-12,152,152]},
   "stack":[{"layer":"layers/000.svg","piece":"disc"},
            {"layer":"layers/001.svg","piece":"seg-a"},
            {"layer":"layers/002.svg","piece":"seg-b"},
            {"layer":"layers/003.svg","piece":"seg-c"},
            {"layer":"layers/004.svg","piece":"shade"},
            {"layer":"layers/005.svg","piece":"field"}]},
  {"layer":"layers/006.svg","piece":"ring"},
  {"layer":"layers/007.svg","piece":"core"},
  {"layer":"layers/008.svg","piece":"mark"}],
 "motion":[
  # Infall, about 980 ms: a singularity dot, the accretion disc spirals in from far out while
  # tilting face-on, the ring falls in and flares, then the hole opens with an overshoot.
  # A track holds its "from" until it starts, so a swing is two tracks (-A, then +A).
  {"piece":"disc","origin":[64,64],"tracks":[{"kind":"scale","from":[1.12,1.12],"at":0,"duration":620,"ease":"out"},{"kind":"opacity","from":[0],"at":0,"duration":200,"ease":"linear"}]},
  {"piece":"seg-a","origin":[64,64],"tracks":[{"kind":"rotate","from":[-260],"at":0,"duration":760,"ease":"out"},{"kind":"scale","from":[1.3,1.3],"at":0,"duration":760,"ease":"out"},{"kind":"tilt","from":[55],"at":0,"duration":700,"ease":"out"},{"kind":"opacity","from":[0],"at":0,"duration":240,"ease":"linear"}]},
  {"piece":"seg-b","origin":[64,64],"tracks":[{"kind":"rotate","from":[-260],"at":60,"duration":760,"ease":"out"},{"kind":"scale","from":[1.3,1.3],"at":60,"duration":760,"ease":"out"},{"kind":"tilt","from":[55],"at":60,"duration":700,"ease":"out"},{"kind":"opacity","from":[0],"at":60,"duration":240,"ease":"linear"}]},
  {"piece":"seg-c","origin":[64,64],"tracks":[{"kind":"rotate","from":[-260],"at":120,"duration":760,"ease":"out"},{"kind":"scale","from":[1.3,1.3],"at":120,"duration":760,"ease":"out"},{"kind":"tilt","from":[55],"at":120,"duration":700,"ease":"out"},{"kind":"opacity","from":[0],"at":120,"duration":240,"ease":"linear"}]},
  {"piece":"shade","origin":[64,64],"tracks":[{"kind":"opacity","from":[0],"at":300,"duration":300,"ease":"linear"}]},
  {"piece":"field","origin":[64,64],"tracks":[{"kind":"scale","from":[1.12,1.12],"at":0,"duration":620,"ease":"out"},{"kind":"opacity","from":[0],"at":0,"duration":200,"ease":"linear"}]},
  {"piece":"ring","origin":[64,64],"tracks":[{"kind":"opacity","from":[0],"at":0,"duration":300,"ease":"linear"},{"kind":"scale","from":[1.9,1.9],"at":0,"duration":650,"ease":"out"},{"kind":"scale","from":[0.9,0.9],"at":680,"duration":120,"ease":"out"},{"kind":"scale","from":[1.1,1.1],"at":800,"duration":180,"ease":"spring"}]},
  {"piece":"core","origin":[64,64],"tracks":[{"kind":"scale","from":[0.2,0.2],"at":380,"duration":520,"ease":"spring"}]},
  {"piece":"mark","origin":[64,64],"tracks":[{"kind":"opacity","from":[0],"at":520,"duration":200,"ease":"linear"},{"kind":"scale","from":[0.4,0.4],"at":520,"duration":380,"ease":"spring"}]}]}
open(OUT+'/iride.json','w').write(recolor(json.dumps(man,indent=1)))
print('wrote',OUT)
