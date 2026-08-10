#!/usr/bin/env python3
"""Analyse a WAYLAND_DEBUG trace for the layer-surface stale-buffer crash pattern.

DANGEROUS SEQUENCE (what actually kills the shell):
    zwlr_layer_surface_v1#N.destroy          on wl_surface#S
    wl_surface#S.attach(wl_buffer#B)         <-- stray frame lands after unmap
    ...
    get_layer_surface(new #M, wl_surface#S)  <-- SAME surface, still dirty
    wl_surface#S.commit()                    --> "never been configured"

A surface being reused is NOT sufficient. A stray attach is NOT sufficient.
Only reuse WITH an un-cleared buffer between destroy and re-create is fatal.
"""
import re, sys, collections

path = sys.argv[1]
get_ls   = re.compile(r'get_layer_surface\(new id (zwlr_layer_surface_v1#\d+), (wl_surface#\d+)')
destroy  = re.compile(r'(zwlr_layer_surface_v1#\d+)\.destroy')
attach   = re.compile(r'(wl_surface#\d+)\.attach\((\w+#?\d*|nil)')
commit   = re.compile(r'(wl_surface#\d+)\.commit\(\)')
err      = re.compile(r'wl_display#1\.error\((zwlr_layer_surface_v1#\d+), (\d+), "([^"]*)"')

ls_of_surface = {}          # layer_surface -> wl_surface
state = collections.defaultdict(lambda: {"live_ls": None, "dirty": False, "cycles": 0})
danger, errors = [], []

for ln, line in enumerate(open(path, errors="ignore"), 1):
    m = get_ls.search(line)
    if m:
        ls, surf = m.group(1), m.group(2)
        st = state[surf]
        st["cycles"] += 1
        if st["dirty"]:
            danger.append((ln, surf, ls, st["cycles"]))
        st["live_ls"] = ls
        st["dirty"] = False          # new role; buffer state re-evaluated at commit
        ls_of_surface[ls] = surf
        continue
    m = destroy.search(line)
    if m:
        surf = ls_of_surface.get(m.group(1))
        if surf:
            state[surf]["live_ls"] = None
            state[surf]["dirty"] = False   # unmapped clean until proven otherwise
        continue
    m = attach.search(line)
    if m:
        surf, buf = m.group(1), m.group(2)
        st = state[surf]
        if st["live_ls"] is None:          # roleless: no layer surface right now
            st["dirty"] = (buf != "nil")   # a real buffer attached while roleless
        continue
    m = err.search(line)
    if m:
        errors.append((ln, m.group(1), m.group(2), m.group(3)))

surfaces = {s: v for s, v in state.items() if v["cycles"] > 0}
reused = {s: v for s, v in surfaces.items() if v["cycles"] > 1}

print(f"  layer surfaces created : {sum(v['cycles'] for v in surfaces.values())}")
print(f"  distinct wl_surfaces   : {len(surfaces)}")
print(f"  reused wl_surfaces     : {len(reused)}  {'(reuse alone is NOT fatal)' if reused else ''}")
print(f"  DANGEROUS re-creations : {len(danger)}   <-- reuse WITH a stale buffer")
for ln, surf, ls, cyc in danger[:10]:
    print(f"      line {ln}: {surf} re-roled as {ls} while dirty (cycle {cyc})")
print(f"  protocol errors        : {len(errors)}")
for ln, ls, code, msg in errors[:5]:
    print(f"      line {ln}: {ls} code={code} {msg}")
print()
print("  VERDICT: " + ("STILL VULNERABLE - dangerous re-creations present"
                       if danger else
                       "SAFE - no surface was re-roled while carrying a buffer"))
