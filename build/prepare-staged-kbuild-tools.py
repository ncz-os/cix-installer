#!/usr/bin/env python3
"""Build native Kbuild host tools without regenerating staged kernel headers."""
import hashlib
from pathlib import Path
import subprocess
import sys


def snapshot(root):
    return {
        str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in root.rglob('*')
        if p.is_file() and (p.suffix == '.h' or p.name in {
            '.config', 'Module.symvers', 'kernel.release', 'auto.conf', 'rustc_cfg'
        })
    }


def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: prepare-staged-kbuild-tools.py STAGED_HEADERS_DIR')
    root = Path(sys.argv[1]).resolve(strict=True)
    for name in ['.config', 'Module.symvers', 'include/generated/compile.h',
                 'include/generated/autoconf.h', 'include/generated/utsrelease.h',
                 'scripts/mod/elfconfig.h', 'scripts/mod/devicetable-offsets.h']:
        if not (root / name).is_file():
            raise SystemExit(f'missing exact-build input: {root / name}')
    before = snapshot(root)
    command = ['make', '-C', str(root), '-f', 'scripts/Makefile.build',
               'srctree=.', 'srcroot=.', 'objtree=.', 'HOSTCC=gcc',
               'KBUILD_HOSTCFLAGS=-O2 -I ./scripts/include']
    try:
        subprocess.run(command + ['obj=scripts/basic', 'scripts/basic/fixdep'], check=True)
        # These two headers describe the target kernel, not the build host.
        # Use the staged originals; only the host executable is rebuilt.
        subprocess.run(command + ['obj=scripts/mod',
                                  '-o', 'scripts/mod/elfconfig.h',
                                  '-o', 'scripts/mod/devicetable-offsets.h',
                                  'scripts/mod/modpost'], check=True)
        # genksyms needs the same targeted rebuild as fixdep/modpost -- it is
        # stripped from the shipped tree for the identical reason (uninative
        # loader) but was missing from this list. Any DKMS module compiled
        # with CONFIG_MODVERSIONS=y and EXPORT_SYMBOL invokes genksyms during
        # its own build; without it present, that module's build fails with
        # "scripts/genksyms/genksyms: not found" (Error 127) -- confirmed on
        # real O6 hardware 2026-09-08 (aipu, cix-gpu-kmd both hit this; the
        # DKMS packages whose object order never triggered a genksyms
        # invocation built fine and made the failure look module-specific).
        # parse.tab.c/parse.tab.h/lex.lex.c are yacc/lex-generated sources
        # shipped pre-staged in the tarball. Without `-o` make reruns
        # yacc/lex and regenerates them -- cosmetically different from the
        # staged copies (confirmed 2026-09-08: real content, e.g. line
        # ordering, differs release-to-release of yacc/flex), which the
        # snapshot guard below correctly treats as an identity change and
        # aborts on. Same fix as scripts/mod's two headers above: tell make
        # the staged copies are already up to date so it links genksyms
        # directly from them instead of regenerating.
        subprocess.run(command + ['obj=scripts/genksyms',
                                  '-o', 'scripts/genksyms/parse.tab.c',
                                  '-o', 'scripts/genksyms/parse.tab.h',
                                  '-o', 'scripts/genksyms/lex.lex.c',
                                  'scripts/genksyms/genksyms'], check=True)
    finally:
        after = snapshot(root)
        changed = sorted(k for k in before.keys() | after.keys()
                         if before.get(k) != after.get(k))
        if changed:
            raise SystemExit('FAIL: staged headers/config/identity changed: ' + ', '.join(changed))
    print(f'Native fixdep/modpost built; {len(before)} header/config/symbol hashes unchanged.')


if __name__ == '__main__':
    main()
