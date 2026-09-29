# Singularity PR commits: AI attribution evidence (2026-09-29)

Purpose: the `Assisted-by:` trailer on open singularityos-lab PRs must name the tool and
model that actually wrote the change. This records how each value was established.

Method: commit timestamps on the PR branches were matched to the orchestrating Claude Code
session transcript (session 85a60706, model claude-opus-5 / claude-sonnet-5), which logged the
exact `codex exec ... -m <model>` dispatch commands, and to the pre-existing commits the work
was rebased from. Code identity was checked by diffing the earlier downstream patch against
the PR diff.

## Findings

1. The trailer `Claude Code:gpt-5.6-sol` was wrong. It came from a brief template used on
   2026-09-27 (Claude Code wrote the brief); the work itself was run with the Codex CLI:
   `codex exec ... -m gpt-5.6-sol` (dispatch 2026-09-27 14:20 UTC to CERBERUS for plugins,
   14:21 UTC to ACHILLES for shell/desktop, 15:33 UTC for website). Commits landed 14:24-15:39 UTC.
2. Commits 3a4eb724 (shell#30) and c369e7a2 (desktop#262) were written 2026-09-18 by
   Claude Code (claude-sonnet-5). Their diffs are identical to the downstream patches committed
   2026-09-20 with `Assisted-by: Claude Code:claude-sonnet-5`. The 2026-09-27 Codex run only
   reworded/re-committed them, so the original label is restored.
3. The Phase 1-3 commits (shell#32/#33/#34, desktop#264-#266) were created 2026-09-25 16:00-16:08 UTC
   by `codex exec --sandbox workspace-write --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol`
   (dispatched 15:57 UTC from the Claude Code session). The old `Codex:gpt-5` was the tool's
   self-report, not the model flag. The brief also told the agent to append Co-Authored-By and
   Claude-Session trailers; both are removed as the maintainer forbids them.
4. Phase code lineage: Phase 1 was first implemented 2026-09-13 by Codex (`Codex:gpt-5`, commit
   62d6905); Phase 2 (f52f031) and Phase 3 (de80e23) were implemented the same day by Claude Code
   (claude-sonnet-5). The 2026-09-25 commits are rebases/integrations of those, so they list both.

## Values used

| PR | Commit (old) | Assisted-by now |
|---|---|---|
| shell#30 | 3a4eb724 | Claude Code:claude-sonnet-5 |
| shell#30 | 46fcb426 | Codex:gpt-5.6-sol |
| shell#32 | 24b4f5b9 | Codex:gpt-5 and Codex:gpt-5.6-sol |
| shell#33 | 24b4f5b9, faa01fe8 | phase 1 as above; phase 2: Claude Code:claude-sonnet-5 and Codex:gpt-5.6-sol |
| shell#34 | + 015b9c99 | phase 3: Claude Code:claude-sonnet-5 and Codex:gpt-5.6-sol |
| desktop#262 | c369e7a2 | Claude Code:claude-sonnet-5 |
| desktop#264/#265/#266 | 820e1af2, fba09f33, d40c2fa8 | Codex:gpt-5.6-sol |
| plugins#2 | 93a5bd56 (ebed25ce unchanged) | Codex:gpt-5.6-sol |
| plugins#3 | 0900713a (e3955330 unchanged) | Codex:gpt-5.6-sol |
| website#10 | ef318413 | Codex:gpt-5.6-sol |

Unestablished: the website#10 commit has a 2026-09-06 author date, so an earlier draft may have
come from another tool; the 2026-09-27 rewrite that produced the current content is Codex.
