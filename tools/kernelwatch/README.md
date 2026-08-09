# lore.kernel.org scanning

## The access rule

lore is behind Anubis. Measured 2026-08-09:

| path | works? |
|---|---|
| `https://lore.kernel.org/<list>/new.atom` | **yes**, with `curl -A "<browser UA>"` |
| `https://lore.kernel.org/all/new.atom` | **yes** (firehose) |
| WebFetch on any lore URL | no — the tool's fetcher is challenged |
| `/raw`, `/t.mbox.gz`, `/T/` | no |
| `?q=<query>&x=A` search feeds | no — challenged even via curl+UA |
| public-inbox git `/info/refs` | no — HTTP 403 |

**The atom `<content>` element carries the entire message, diff included.** So
the feed is full retrieval, not just discovery — a whole patch series can be
reconstructed from it without ever touching `/raw`.

## The coverage limit

Each feed holds only the **25 most recent** messages, and search is blocked.
There is no historical query path from here: you cannot ask lore "what landed
in the last 60 days". Coverage comes only from polling often enough and
storing what you see. That is the argument for kernelwatch storing the
`<content>`, not just the subject line — as of 2026-08-09 it stores subject and
link only, which meant a human had to screenshot a thread to a PDF to get a
cover letter that was sitting in the feed all along.

## Tools

`lore-feedscan.py` — pulls the lists we care about and flags any patch that
either touches a file our 170-patch series also touches, or mentions a
subsystem we carry downstream (panthor, mali, linlondp, cix, sky1, amvx,
zhouyi, cdns3). File-overlap on `Kconfig`/`Makefile` is noise: every SoC patch
touches those.

`lore-extract-series.py <feed.atom> <outdir>` — reconstructs a numbered patch
series from a feed into `git am`-able files, and says which parts of the series
have already rolled out of the window rather than silently emitting a short
series.
