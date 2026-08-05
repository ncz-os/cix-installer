# Upstream patches pending submission

## libdrm-xf86drm-acpi-platform-identity.patch

Fixes libdrm's `drmParseOFBusInfo()` MODALIAS fallback for ACPI-enumerated
platform DRM devices: an ACPI modalias ends with ':', so the parsed bus name
is empty and identical for every device, and `drmGetDevices2()` folds all
ACPI DRM devices into one. On Sky1 (3× linlondp + panthor) only one device
survived enumeration, which broke Mesa device selection, panvk GPU discovery,
and wlroots' DRM device lookup. Verified on O6N: stock enumerates 1 device
with an empty name; patched enumerates all, correctly paired, uniquely named
(sysfs device basename, e.g. "CIXH5010:00").

Submission target: https://gitlab.freedesktop.org/mesa/drm (merge request;
the anongit and GitHub mirrors are read-only). Author identity:
Jason Perlow <jperlow@gmail.com>. Needs a gitlab.freedesktop.org account to
fork + push — the patch applies with `git am` on current main (the touched
fallback path is unchanged since 2.4.134).
