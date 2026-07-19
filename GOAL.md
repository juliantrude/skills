# GOAL

<!--
  Single source of truth for the /advance-goal loop (driven headless via the
  one-shot systemd chain, or interactively via `/loop /advance-goal`).
  The loop reads and rewrites this file every iteration.
-->

## North star

Turn the hustlebot web monitor from a single scrolling page into a small
multi-page dashboard whose home screen is readable at a glance from across the
room. The home screen shows only the KPIs — current status, current task, next
task, overall progress, and session/week budget — plus an animated avatar that
expresses the chain's state. Plan detail moves to its own page; the run log,
which currently drowns everything else, moves to a third. The avatar artwork is
**already finished and must not be redesigned**: six SVG scenes in
`plugins/hustlebot/assets/`, approved by the user over nine review rounds. This
goal is about the dashboard around them, not about the art.

## Definition of Done

- [ ] `http://localhost:<HUSTLE_PORT>/` serves a home screen showing all five KPIs (status, current task, next task, plan progress, session + week budget) and the state-appropriate avatar, with **no run-log text anywhere on it**
- [ ] `/plan` serves Definition of Done, the plan sections with per-section progress, and the GOAL.md iteration history
- [ ] `/logs` serves the full run log
- [ ] All three pages are reachable from a persistent nav, survive a page reload (deep links work), and poll without a full-page refresh
- [ ] Each of the six avatar states renders for its corresponding `compute_state()` tone, verified by driving the monitor against fixture data — not by reading code
- [ ] `hustle-setup.sh --dev <project>` symlinks `.hustle/bin/*` at the repo sources instead of copying, and a plain `hustle-setup.sh <project>` still copies exactly as before (verified by running both against a scratch directory)
- [ ] `python3 plugins/hustlebot/scripts/hustle-monitor.py` still runs on the Python standard library alone — no new dependencies, no build step
- [ ] Fully blocked externally does **not** count as done; a blocked increment is documented in `## Log` and the loop moves to the next one

## Working Agreements (read every iteration — these override convenience)

**Priority order per iteration:**
1. If the previous iteration left a broken monitor (does not start, or a page 500s), fixing that comes before anything else.
2. Then take the next unchecked increment from `## Plan`.

**Git workflow:**
- Work on the branch `feat/dashboard-morepager`, branched from `main`. Create it if missing; never commit to `main`.
- **Never push.** No `git push`, no PR, no remote operation of any kind. The user reviews locally and merges by hand. This is a public repository and the loop runs unattended.
- One commit per completed increment. Message: what changed and why, not a restatement of the diff.
- Do not commit until the increment is verified per the bar below.

**Verification bar (this is where the last effort went wrong — do not skip):**
- A structural check is not a verification. Starting the monitor and reading its source proves nothing about what a user sees.
- Before checking off any increment that touches a page, **start the monitor and fetch the affected route**, then assert on the returned markup — that the KPI is present, that the log is absent from the home screen, that the nav links resolve.
- For anything visual, render it and look at it. `plugins/hustlebot/assets/*.svg` can be rasterised with `convert in.svg out.png` and read back as an image. Note that ImageMagick silently drops elements carrying `<animate>` children and does not support `clipPath`, `<use>` or CSS animation — strip SMIL and hardcode the pose before rendering, or you will diagnose tool artefacts as bugs.
- If an increment cannot be verified, say so in `## Log` and leave the box unchecked rather than claiming it.

**Out-of-scope systems — never modify:**
- `plugins/hustlebot/assets/*.svg` — the avatar artwork is signed off. If a state genuinely cannot be wired up without an art change, document it in `## Log` and leave the increment blocked; do not redraw it.
- `hustle-session.sh`, `hustle-scheduler.sh` — the scheduling chain is working and orthogonal to this goal. `hustle-setup.sh` may be touched **only** for the `--dev` flag.
- The runtime namespace: `.hustle/`, the `HUSTLE_*` config keys, and the `hustle-<slug>` service names stay exactly as they are. Renaming them breaks every existing installation.
- Anything under `.hustle/` in this repo is local runtime state, not source. Never commit it.

**Etiquette:**
- Comments explain why, never what. No comment that restates the line below it.
- Dashboard copy is English (the UI is already English); `GOAL.md` log lines are English too.
- Never claim a state you did not observe. "Rendered and checked" and "should work" are different sentences.

**References:**
- `plugins/hustlebot/scripts/hustle-monitor.py` — current single-page monitor; `compute_state()` is the authority on which states exist.
- `plugins/hustlebot/assets/` — the six approved avatar scenes: `working`, `idle`, `waiting`, `sleeping`, `searching`, `done`.
- `GOAL.md` parsing lives in `parse_goal()`; the format contract is in `plugins/hustlebot/skills/grill-goal/SKILL.md`.

## Plan

### Foundation
- [x] Add `--dev` to `hustle-setup.sh`: symlink `.hustle/bin/*` at the repo sources instead of copying, so edits to the monitor are visible on the running dashboard. Verify both modes against a scratch directory; confirm the default path is byte-identical to today's behaviour.
- [x] Re-run `hustle-setup.sh --dev` against this repo so the rest of the work is visible live on `:8787`, and confirm the monitor restarts cleanly.
- [x] Arbitrate the monitor port instead of blindly binding `HUSTLE_PORT`. On startup, if the port is already held, read the holder's `status.json`: if that chain is still working, **do not steal the port** — fall back to the next free port, log which one was chosen, and keep running; if the holder's `phase` is `complete`, claim the port and retire the stale monitor. Also make `hustle-setup.sh` pick a free port at install time rather than always writing 8787. Verify by starting two projects against the same port in both states — a working holder and a completed one — and asserting which process ends up bound. Today a second project silently dies in a systemd restart loop with `EADDRINUSE` while the user looks at the wrong project's dashboard.
- [ ] Split the monitor's embedded HTML into `plugins/hustlebot/assets/app.html`, `app.css`, `app.js`; add a small static-file handler to `hustle-monitor.py` and extend `hustle-setup.sh` to copy (or symlink) the whole `assets/` directory. Verify the existing single page still renders unchanged before moving on.

### Routing and pages
- [ ] Add hash-based routing (`#/`, `#/plan`, `#/logs`) with a persistent nav, so a reload lands on the same page. No server-side route changes; the existing `/api/*` endpoints stay as they are.
- [ ] Build the **home** screen: status headline, current task, next task, overall plan progress, session and week budget. No log output on this page at all.
- [ ] Build the **plan** page: DoD donut, plan sections with per-section progress, iteration history from `## Log`.
- [ ] Build the **logs** page: the full run log, with the newest lines visible without scrolling.

### Avatar
- [ ] Map `compute_state()`'s tones onto the six scenes (`run`→working, `wait`→waiting, `hold`→sleeping, `done`→done, `idle`→idle, unreachable→searching), and decide what `warn`/`blocked`/`not_ready` show — reuse an existing scene rather than commissioning new art.
- [ ] Embed the avatar on the home screen so the scene follows the live status, including the browser-side "monitor unreachable" case which no server response can report.
- [ ] Drive the monitor against fixture `status.json` files covering every state, and confirm by rendering that each one shows its intended scene.

### Closeout
- [ ] Final sweep: everything at spec or documented-blocked; DoD checkboxes above updated; no stray files from the abandoned pixel-art approach remain.

## Status

STATUS: READY
**Next action:** Split the monitor's embedded HTML into `plugins/hustlebot/assets/app.html`, `app.css`, `app.js` (Foundation, 4th/last increment) — add a static-file handler to `hustle-monitor.py`, extend `hustle-setup.sh` to copy/symlink `assets/`, and verify the existing single page still renders unchanged before moving on to routing.
**Blockers:** none

## Budget

- session pause threshold: 85%
- weekly pause threshold: 90%

## Log

- 2026-07-19 — GOAL.md created via /hustle. Avatar artwork settled beforehand over nine review rounds: pixel art was tried and abandoned (unreadable at 48x32; the outline tone collided with the background), replaced by animated SVG. Plugin renamed hustle → hustlebot (0.3.0); runtime namespace deliberately unchanged.
- 2026-07-19 — Added `--dev` to `hustle-setup.sh`: symlinks `.hustle/bin/*` at the plugin sources instead of copying. Verified against two scratch dirs: default mode produces regular files byte-identical to the plugin source (`diff` clean on all three scripts); `--dev` mode produces symlinks resolving to the repo sources; re-running either mode on top of the other cleanly swaps symlinks↔copies. Committed as f4742dc on `feat/dashboard-morepager`.
- 2026-07-19 — Re-ran `hustle-setup.sh --dev .` against this repo. Found the monitor crash-looping under systemd (`EADDRINUSE`, restart counter 40+) — this violated the "fix a broken monitor first" priority rule, so fixed before anything else: `hustle-monitor.py` computed `HUSTLE_HOME` via `Path(__file__).resolve()`, which follows the `.hustle/bin/hustle-monitor.py` symlink back to its source in `plugins/hustlebot/scripts/`, so the config file was never found and the monitor silently fell back to the default port 8787 — already held by another project's monitor. Changed `.resolve()` to `.absolute()` so the symlink path itself (inside `.hustle/`) is used. Verified: `systemctl --user restart hustle-monitor-skills.service` now stays `active (running)`, binds `0.0.0.0:8789` (the configured port), and `curl localhost:8789/` returns HTTP 200 with the expected `<title>hustle monitor</title>` markup. Committed as f075e3e. This is a preview of the port-collision bug the next increment (port arbitration) is meant to fix properly — today it's silent, not just non-graceful.
- 2026-07-19 — Also found (before starting this increment) that the previous iteration's `--dev` chmod had leaked into git status: `chmod +x` on `.hustle/bin/hustle-{scheduler,session}.sh` follows the symlink and flips the mode bit on the tracked source in `plugins/hustlebot/scripts/` (Linux has no `lchmod`; `hustle-monitor.py` was already 100755 so it didn't show). Reverted the mode-only diff (`git checkout --`) per the "never modify hustle-session.sh/hustle-scheduler.sh" rule and left it alone — worth a permanent fix (commit those two scripts as 100755 once so dev-mode's chmod becomes a no-op) but that's a deliberate call for a human, not something to sneak into an unrelated increment. Also committed the prior iteration's GOAL.md bookkeeping (checkbox + log line for f075e3e) that never made it into a commit.
- 2026-07-19 — Implemented port arbitration. `hustle-monitor.py`: added `resolve_port()` — tries the configured `HUSTLE_PORT` first; on `EADDRINUSE`, HTTP-probes the holder's own `/api/status` (added a `pid` field to `compute_state()` for this) instead of adding a new registry file; if the holder reports `phase: complete` it SIGTERMs that pid and reclaims the port (retry loop, 3s budget), otherwise it treats the holder as alive and binds the next free port instead, logging the choice either way. `hustle-setup.sh`: replaced the hardcoded `HUSTLE_PORT="8787"` with a python3 scan for the first free port from 8787, and fixed the `Watch:` hint at the end to read the port back out of the written config instead of printing a stale literal 8787. Verified end to end, not just structurally: ran two real `hustle-setup.sh` installs into scratch dirs — both picked port 8788 (expected: install-time picking only checks what's bound *right now*, and neither monitor was running yet, so this exact race is the real-world version of the bug) — then started both via `systemctl --user start hustle-monitor-<slug>.service` and watched B's journal log `"port 8788 is held by another chain (phase=unknown) — falling back to 8790"` and stay `active`, while A stayed `active` on 8788; also drove the two-phase scenario directly against `hustle-monitor.py` (no systemd) with fixture `status.json` files — a `phase: active` holder made the second monitor fall back to the next port, a `phase: complete` holder got SIGTERMed and its port reclaimed by the pid that killed it. All scratch systemd units and `/tmp` dirs removed after. Note: mid-cleanup a stray `pkill -f hustle-monitor.py` briefly killed this repo's own live monitor unit too (Restart=on-failure doesn't cover a clean SIGTERM exit) — caught it via `curl` returning connection-refused, restarted with `systemctl --user start hustle-monitor-skills.service`, confirmed 200 again. `hustle-scheduler.sh`/`hustle-session.sh` untouched.
