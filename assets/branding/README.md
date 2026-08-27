# NCZ-OS branding assets

Login wallpapers, icon theme, logo, and greeter/QOTD assets are dropped here
and consumed by `post-install/50-brand.sh`, `55-greeter.sh`, `56-icon-theme.sh`,
`57-qotd.sh`, `45-wallpaper-rotator.sh`, and `30-agents.sh`.

**Plymouth is gone.** As of NCZ-OS 26.7 the boot splash is the native
`singularity-boot-splash` (KMS-direct, no toolkit), installed and branded by
`post-install/60-boot-splash.sh` — see the top-level `README.md` and
`docs/SINGULARITY_ISO_PLAN.md`. The `gdm/` subdirectory here is a legacy
holdover from an early desktop-stack evaluation; the shipping greeter is
`singularity-greeter` (native Wayland, Mali-rendered), not GDM.
