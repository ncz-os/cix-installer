# PR draft — fix: session launcher must find helpers in libexecdir, not bindir

> **Branch:** `fix/session-libexec-path`
> **Base:** `main`
> **Commit subject (conventional):** `fix: launch polkit agent from libexecdir, not bindir`
> **No attribution/co-author trailers** (per CONTRIBUTING.md and the CLA).
> This is the highest-value, clearly-correct PR — file it first among the PRs.

---

## Summary

**What:** The session launcher scripts start `singularity-polkit-agent` from the same
directory as the launcher itself (`$BIN`, i.e. `bindir`), but the agent — along with
`singularity-polkit-auth-helper` and `xdg-desktop-portal-singularity` — is installed to
**`libexecdir`** by meson. On any prefix where `libexecdir != bindir` (the normal case for
`--prefix=/usr`, where `bindir=/usr/bin` and `libexecdir=/usr/libexec`), a plain
`meson install` produces a session that **silently starts with no polkit agent**: privilege
prompts never appear, and `~/.local/state/singularity/polkit.log` shows the launch failing
(no such file → exit 127).

**Why it isn't caught today:** `scripts/deploy-to-host.sh` sidesteps the problem by manually
copying the libexec helpers into the bin directory, flattening the layout. So the
developer-deploy path works, but the *shipped session scripts* + a clean `meson install`
(what a packager/distro does) are broken.

**Scope boundary:** touches only the session launcher's helper-resolution. No behaviour
change on the flattened `deploy-to-host.sh` layout (the fix falls back to `$BIN`). No meson
install-dir changes.

**Blast radius:** the session startup path only.

## Reproduce

```bash
meson setup build --prefix=/usr
meson install -C build --destdir /tmp/stage
# polkit agent lands in libexec, session script looks in bin:
ls /tmp/stage/usr/libexec/singularity-polkit-agent      # present
ls /tmp/stage/usr/bin/singularity-polkit-agent          # MISSING
grep 'singularity-polkit-agent' /tmp/stage/usr/bin/singularity-desktop-session
#   nohup "$BIN/singularity-polkit-agent" ...   <-- resolves to /usr/bin, wrong dir
```

Same for a custom prefix — e.g. NCZ-OS installs to `/opt/singularity`, and
`/opt/singularity/bin/singularity-desktop-session` looks for the agent in
`/opt/singularity/bin` while meson put it in `/opt/singularity/libexec`.

## Root cause

- `subprojects/singularity-polkit-agent/meson.build` installs both `singularity-polkit-agent`
  and `singularity-polkit-auth-helper` with `install_dir: get_option('libexecdir')`.
- `subprojects/xdg-desktop-portal-singularity/meson.build` installs
  `xdg-desktop-portal-singularity` with `install_dir: get_option('libexecdir')`.
- `subprojects/singularity-session/src/singularity-desktop-session` computes
  `BIN="$(dirname "$SELF")"` / `PREFIX="$(dirname "$BIN")"` and then runs
  `nohup "$BIN/singularity-polkit-agent" ...` — `bindir`, not `libexecdir`.
- The generated launcher inside `subprojects/singularity-session/scripts/install-session.sh`
  has the identical `"$BIN/singularity-polkit-agent"` assumption.

The session scripts are shipped verbatim via `install_data` (not `configure_file`), so they
have no compile-time knowledge of the configured `libexecdir`. The robust, self-contained
fix is to resolve the helper at runtime relative to the prefix the script already derives,
preferring `libexec/` and falling back to `bin/` (so the flattened `deploy-to-host.sh`
layout keeps working).

## Proposed fix

Add a tiny resolver to `singularity-desktop-session`. The script already has `PREFIX`, so:

```diff
--- a/subprojects/singularity-session/src/singularity-desktop-session
+++ b/subprojects/singularity-session/src/singularity-desktop-session
@@
 SELF="$(readlink -f "$0")"
 BIN="$(dirname "$SELF")"
 PREFIX="$(dirname "$BIN")"
 LIB="$PREFIX/lib"
 SHARE="$PREFIX/share"
+LIBEXEC="$PREFIX/libexec"
+
+# Resolve an installed helper: meson installs helpers to libexecdir, but the
+# deploy-to-host.sh developer layout flattens them into bindir. Prefer libexec,
+# fall back to bin, then to $PATH.
+singularity_helper() {
+    if [ -x "$LIBEXEC/$1" ]; then
+        printf '%s\n' "$LIBEXEC/$1"
+    elif [ -x "$BIN/$1" ]; then
+        printf '%s\n' "$BIN/$1"
+    else
+        command -v "$1" 2>/dev/null || printf '%s\n' "$LIBEXEC/$1"
+    fi
+}
@@
-nohup "$BIN/singularity-polkit-agent" >> "$_STATE/polkit.log" 2>&1 &
+nohup "$(singularity_helper singularity-polkit-agent)" >> "$_STATE/polkit.log" 2>&1 &
```

Apply the same `singularity_helper` pattern to the generated launcher in
`subprojects/singularity-session/scripts/install-session.sh` (it emits its own
`"$BIN/singularity-polkit-agent"` line for the per-user `~/.local/singularity` install).

For the `/opt/local` branch of `install-session.sh`, define `LIBEXEC="/opt/local/libexec"`
and resolve the agent the same way.

### Note on the portal binary

`xdg-desktop-portal-singularity` is also in `libexecdir`, but it's launched by
`xdg-desktop-portal` via the `.portal` / portals.conf `DBusActivatable` mechanism rather
than directly by the session script, so it's not part of the exit-127 path here. This PR
deliberately scopes to the **polkit agent**, which the session script execs directly and
which is the observable failure. Worth a follow-up to double-check the shipped `.service` /
portals config points at `libexecdir` too, but that's out of scope for this fix.

## Alternative considered

Convert the session scripts to `configure_file` templates and substitute `@libexecdir@` at
build time. That works, but it's a larger change (touches the meson graph and turns two
scripts into `.in` templates) for no extra robustness — the runtime resolver above already
handles both the meson-install and deploy-to-host layouts. Happy to go the `configure_file`
route instead if the maintainers prefer build-time substitution.

## Validation evidence

```
# clean meson install to a non-/usr prefix, run session, agent starts:
$ ls /opt/singularity/libexec/singularity-polkit-agent
/opt/singularity/libexec/singularity-polkit-agent
$ pgrep -a singularity-polkit-agent
<pid> /opt/singularity/libexec/singularity-polkit-agent      # was empty before the fix
$ tail ~/.local/state/singularity/polkit.log
# no "No such file or directory" / exit 127; a privilege prompt now appears
```

(Validated on NCZ-OS 26.7 on Radxa Orion O6N, CIX Sky1, `/opt/singularity` prefix.)

## Compatibility

- `deploy-to-host.sh` (flattened bin layout): unchanged — resolver falls back to `$BIN`.
- `--prefix=/usr` packaged installs: now finds the agent in `/usr/libexec`.
- Custom prefixes: works via prefix-relative resolution.

## Rollback

Revert the single commit; no data or schema migration involved.
