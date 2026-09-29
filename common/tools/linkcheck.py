import io,os,re,sys,subprocess
ROOT="."
md=[]
for dp,dn,fn in os.walk(ROOT):
    if any(x in dp for x in (".git","sqfs-work","iso-staging","forky-mirror","tool-cache","node_modules")): continue
    for f in fn:
        if f.endswith(".md"): md.append(os.path.join(dp,f))

def slug(h):
    # Match GitLab/GitHub: lowercase, drop non-alphanumeric (except space and
    # hyphen), then replace EACH space with a hyphen. Runs are NOT collapsed --
    # "GPU - Mali" (em-dash removed) leaves two spaces and therefore "gpu--mali".
    # Collapsing them produced 10 false "broken anchor" reports.
    s=h.strip().lower()
    s=re.sub(r'[^a-z0-9 \-_]','',s)
    return s.replace(' ','-').strip('-')

heads={}
for p in md:
    t=io.open(p,encoding="utf-8",errors="replace").read()
    heads[os.path.normpath(p)]={slug(m.group(2)) for m in re.finditer(r'^(#{1,6})\s+(.+)$',t,re.M)}

link_re=re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
bad_file=[];bad_anchor=[];urls=set()
for p in md:
    t=io.open(p,encoding="utf-8",errors="replace").read()
    base=os.path.dirname(p)
    for i,line in enumerate(t.split("\n"),1):
        for m in link_re.finditer(line):
            tgt=m.group(1)
            if tgt.startswith(("http://","https://")): urls.add(tgt.rstrip(">.,")); continue
            if tgt.startswith(("mailto:","#")):
                if tgt.startswith("#"):
                    a=tgt[1:].lower()
                    if a and a not in heads[os.path.normpath(p)]:
                        bad_anchor.append((p,i,tgt))
                continue
            path,_,anch=tgt.partition("#")
            if not path: continue
            fp=os.path.normpath(os.path.join(base,path))
            if not os.path.exists(fp):
                bad_file.append((p,i,tgt)); continue
            if anch and fp.endswith(".md"):
                k=os.path.normpath(fp)
                if k in heads and anch.lower() not in heads[k]:
                    bad_anchor.append((p,i,tgt))

print("=== BROKEN RELATIVE LINKS (file missing) ===")
for p,i,t in bad_file: print(f"  {p}:{i}  ->  {t}")
print(f"  ({len(bad_file)} total)")
print("=== BROKEN ANCHORS ===")
for p,i,t in bad_anchor: print(f"  {p}:{i}  ->  {t}")
print(f"  ({len(bad_anchor)} total)")
io.open("/tmp/urls.txt","w").write("\n".join(sorted(urls)))
print(f"=== {len(urls)} distinct external URLs written to /tmp/urls.txt ===")
