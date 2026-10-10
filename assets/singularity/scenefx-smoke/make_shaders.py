#!/usr/bin/env python3
"""make_shaders.py — reproduce SceneFX 0.5's exact *compiled* shader strings.

SceneFX embeds each .frag/.vert as a raw C string (embed.sh) and builds the
final source at runtime with snprintf() format substitution:

  quad            : quad.frag(%d=EFFECTS) + "\n" [+ corner_alpha.frag if clip]
  quad_grad       : quad_grad.frag(%d=LEN) + "\n" + gradient.frag
  quad_round      : quad_round.frag + "\n" + corner_alpha.frag
  quad_grad_round : quad_grad_round.frag(%d=LEN) + "\n" + gradient.frag + "\n" + corner_alpha.frag
  tex             : tex.frag(%d=SOURCE,%d=EFFECTS) + "\n" [+ corner_alpha.frag if effects]
  box_shadow      : box_shadow.frag + "\n" + corner_alpha.frag
  blur1/blur2/blur_effects : verbatim

Vertex for every program: common.vert

Usage: make_shaders.py <scenefx-src-root> <outdir>
Writes one .frag per program plus common.vert, and a manifest TSV
(label<TAB>vert<TAB>frag) suitable for shader_probe.
"""
import os, sys, re

def rd(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

def fmt(src, *vals):
    # emulate C snprintf: replace the first len(vals) %d occurrences, left to
    # right.  FAIL CLOSED twice over (r203 integration: union of both branches):
    # (1) an upstream shader gaining/losing a format specifier is refused up
    # front, and (2) any leftover/unused value after substitution is refused
    # too.  Either would silently produce a wrong (but "successful") runtime
    # string and a false pass.
    n = src.count("%d")
    if n != len(vals):
        raise SystemExit(
            "make_shaders: %d format specifier(s) in source but %d value(s) "
            "supplied -- upstream SceneFX shader layout changed" % (n, len(vals)))
    out, vals = [], list(vals)
    i = 0
    while i < len(src):
        if src[i] == '%' and i + 1 < len(src) and src[i + 1] == 'd' and vals:
            out.append(str(vals.pop(0)))
            i += 2
        else:
            out.append(src[i])
            i += 1
    result = "".join(out)
    if vals:
        raise SystemExit("make_shaders: %d format value(s) unused after substitution "
                         "(upstream shader changed)" % len(vals))
    if '%d' in result:
        raise SystemExit("make_shaders: an unmatched %d remains after substitution "
                         "(upstream shader changed)")
    return result

def main():
    root, outdir = sys.argv[1], sys.argv[2]
    if os.path.isfile(os.path.join(root, "common.vert")):
        sd = root
    else:
        sd = os.path.join(root, "render", "fx_renderer", "shaders")
    os.makedirs(outdir, exist_ok=True)
    common = rd(os.path.join(sd, "common.vert"))
    corner = rd(os.path.join(sd, "corner_alpha.frag"))
    gradient = rd(os.path.join(sd, "gradient.frag"))
    quad = rd(os.path.join(sd, "quad.frag"))
    quad_grad = rd(os.path.join(sd, "quad_grad.frag"))
    quad_round = rd(os.path.join(sd, "quad_round.frag"))
    quad_grad_round = rd(os.path.join(sd, "quad_grad_round.frag"))
    tex = rd(os.path.join(sd, "tex.frag"))
    box_shadow = rd(os.path.join(sd, "box_shadow.frag"))
    blur1 = rd(os.path.join(sd, "blur1.frag"))
    blur2 = rd(os.path.join(sd, "blur2.frag"))
    blur_effects = rd(os.path.join(sd, "blur_effects.frag"))

    vert = os.path.join(outdir, "common.vert")
    with open(vert, "w") as f:
        f.write(common)

    programs = {}
    programs["quad"] = fmt(quad, 0) + "\n"
    programs["quad_clip"] = fmt(quad, 1) + "\n" + corner
    programs["quad_grad"] = fmt(quad_grad, 16) + "\n" + gradient
    programs["quad_round"] = quad_round + "\n" + corner
    programs["quad_grad_round"] = fmt(quad_grad_round, 16) + "\n" + gradient + "\n" + corner
    for src_name, s in (("rgba", 1), ("rgbx", 2), ("ext", 3)):
        programs["tex_%s" % src_name] = fmt(tex, s, 0) + "\n"
        programs["tex_effects_%s" % src_name] = fmt(tex, s, 1) + "\n" + corner
    programs["box_shadow"] = box_shadow + "\n" + corner
    programs["blur1"] = blur1
    programs["blur2"] = blur2
    programs["blur_effects"] = blur_effects

    manifest = []
    for label, frag in programs.items():
        p = os.path.join(outdir, label + ".frag")
        with open(p, "w") as f:
            f.write(frag)
        # Relative to outdir so the manifest is portable across hosts (the probe
        # is run from the shaders dir by run_probe.sh).
        manifest.append("%s\t%s\t%s" % (label, "common.vert", label + ".frag"))

    with open(os.path.join(outdir, "manifest.tsv"), "w") as f:
        # The probe asserts this count so a truncated/empty manifest fails closed.
        f.write("# expected_programs=%d\n" % len(programs))
        f.write("\n".join(manifest) + "\n")
    print("wrote %d programs to %s" % (len(programs), outdir))

if __name__ == "__main__":
    main()
