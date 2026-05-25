# Pattern Adoption: NXP i.MX RT106A Crossover - Core Dedication by Role

## Overview
Dedicate cixmini cores by role rather than treating all 12 as fungible on the Sky1 platform, which features:
- 4× A720-big cores
- 4× A720-medium cores
- 4× A520-small cores
- 1× Zhouyi V3 NPU (3×4 cores)

## Core Role Mapping

| Core Type | Count | Role | cpuset |
|----------|-------|------|--------|
| A520 small | ×4 | Always-on wake-on-drift classifier, heartbeat, hive polling, E0 ingest queue | 8-11 |
| A720 medium | ×4 | Burst classification, NPU dispatch coordination, lib runtime bookkeeping | 4-7 |
| A720 big | ×4 | NPU job submission, heavy CPU fallback paths, multi-tenant orchestration | 0-3 |
| NPU (Zhouyi V3) | 1×3×4 | All tensor primitives | — |

## Implementation
- Use `systemd CPUSet=` per service unit.
- Always-on watchers pinned to A520 (cpuset 8-11).
- Burst services pinned to A720-medium (cpuset 4-7).
- NPU dispatch coordination pinned to A720-big (cpuset 0-3).
- NPU jobs dispatched from A720-medium cores.

## Acceptance Criteria

### Steady-State Load (idle wake-word + occasional bursts)
- A520 cores active <30%
- A720-big cores active <5%
- Power draw <10W (current: ~15–20W)

### Burst Load
- A720-big cores spike to 80%+ momentarily
- A520 cores remain <40%

## Notes
- cpufreq scaling and devfreq are currently disabled due to BIOS v1.0 missing performance power domain support.
- BIOS v1.2 required for devfreq — per hive job 019e55da-9faf.
- Until devfreq is available, cpuset partitioning is the only available optimization knob.
- OS scheduler maintains cores at fixed frequency.
