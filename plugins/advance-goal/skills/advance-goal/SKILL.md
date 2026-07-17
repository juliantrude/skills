---
name: advance-goal
description: Advance one increment of a long-running, multi-session goal defined in GOAL.md, then self-check the subscription budget via /usage and schedule the next run. Designed to be driven by the headless one-shot chain (ag-session.sh) or by `/loop /advance-goal` so it keeps working across session-limit resets.
---

# advance-goal — one iteration of a cross-session goal loop

You are one iteration of a self-paced loop working toward a long-term goal.
The single source of truth is **`GOAL.md`** in the project root. Everything you
need to resume — the north-star goal, the increment plan, what's done, and the
explicit next action — lives there. Trust it over your memory of earlier turns.

## Protocol (do these in order, every iteration)

### 1. Load state
- Read `GOAL.md`. If it does not exist, STOP and tell the user to create it
  (via `/grill-goal`) — do not invent a goal.
- **Readiness guard:** if `GOAL.md` still contains unfilled template placeholders
  (`_TODO:` markers) or `STATUS: NOT_STARTED` with no real plan, the goal is not
  ready. STOP, say so, and do NOT invent work or treat placeholder lines as
  increments. (In a headless run this simply means "nothing to do yet" — exit
  cleanly.)
- Follow any priority rules in GOAL.md's Working Agreements (e.g. process
  assigned review work before plan increments).
- Find the **next unchecked increment** (`- [ ]`) under `## Plan`, or use the
  explicit `**Next action:**` pointer under `## Status` if set.
- If every increment is checked and the goal's Definition of Done is met →
  write `STATUS: COMPLETE` at the top of `## Status`, tell the user the goal is
  done, and do **not** schedule anything. The loop ends here.

### 2. Do the work
- Execute exactly **one** increment — the smallest shippable step. Resist doing
  more; small idempotent steps survive interruption.
- Follow the project's own conventions (CLAUDE.md, Working Agreements in GOAL.md).

### 3. Verify
- Verify the increment the way the project expects (tests, boot checks, …).
  Prefer running the actual verification over assuming.
- If verification fails and you cannot fix it this iteration, do NOT check the
  box. Record the blocker in `## Status` and leave the increment for next time.

### 4. Persist progress (this is what makes the loop resumable)
Update `GOAL.md`:
- Check off (`- [x]`) the increment only if it's done AND verified.
- Append a dated line under `## Log` (e.g. `- 2026-07-15 14:20 — <what changed / result>`).
- Rewrite `**Next action:**` under `## Status` to the concrete next step, so a
  cold next iteration can start instantly.
- Record any blocker/decision that a future iteration must know.

### 5. Budget check — schedule the next run
Run the subscription usage report as a subprocess and parse it (ANSI-stripping
via python3 — portable across Linux/macOS):

```bash
claude -p "/usage" 2>&1 | python3 -c "import sys,re;print(re.sub(r'\x1b\[[0-9;]*[a-zA-Z]|\x1b[()][AB0]','',sys.stdin.read()))" | grep -Ei 'session|week'
```

Output looks like:
```
Current session: 34% used · resets Jul 15, 10pm (Europe/Berlin)
Current week (all models): 61% used · resets Jul 18, 11pm (Europe/Berlin)
Current week (Sonnet): 3% used · resets Jul 18, 11pm (Europe/Berlin)
```

**Two carrier modes — detect which one you're in:**

- **Headless one-shot chain** (invoked via `claude -p "/advance-goal"` from
  `.advance-goal/bin/ag-session.sh`): each run is independent and short-lived,
  and **you are responsible for arming the next run before you exit**. There is
  no persistent process and `ScheduleWakeup` does nothing here. Arm via the
  scheduler (path relative to the project root, which is your cwd):

  ```bash
  .advance-goal/bin/ag-scheduler.sh arm --in 120                    # budget healthy → continue soon
  .advance-goal/bin/ag-scheduler.sh arm --at "2026-07-15 22:02:00"  # exhausted → restart just after reset
  ```

  Convert the `/usage` "resets …" time to a `YYYY-MM-DD HH:MM:SS` timestamp and
  add ~2 minutes of buffer so you're safely past the reset. If the goal is
  COMPLETE, do **not** arm anything — write `STATUS: COMPLETE` in GOAL.md and
  the chain stops. (A safety net in ag-session.sh re-arms a fallback if you
  ever forget, but arm it explicitly.)

  The scheduler **fails loudly** (non-zero exit) if the timer couldn't be armed
  or the target time already lies in the past. If `--at` fails, fall back to a
  relative `--in` (e.g. seconds until the reset + 120) and note it in the log.

- **Self-paced `/loop`** (driven by `/loop /advance-goal`): the process
  persists; instead of arming a timer you recommend a `ScheduleWakeup` delay.
  Use the hop logic below (a single wakeup is capped at 1 hour).

Decision table (thresholds are defaults — GOAL.md may override under `## Budget`).
The "arm" column is the headless one-shot action; the "hop" column is the
`/loop` fallback.

| Condition | Headless: arm next run | `/loop`: recommend wakeup |
|---|---|---|
| Goal COMPLETE | arm **nothing** (write `STATUS: COMPLETE`) | no wakeup — end loop |
| `week (all models)` ≥ **90%** | `arm --at "<weekly reset + 2min>"` — real work paused until the weekly reset | ~3000s hop, keep re-checking |
| `session` ≥ **85%** | `arm --at "<session reset + 2min>"` — restart at the next session window | ~3000s hop, keep re-checking |
| otherwise | `arm --in 120` — continue promptly | ~120–270s wakeup |

Notes:
- The weekly cap is the real ceiling; if `week` is exhausted, arming for the
  *session* reset is pointless — arm for the weekly reset instead.
- `/loop` only: `ScheduleWakeup` is clamped to ≤3600s, so you cannot sleep
  straight to a reset hours away — hop under an hour and let the next iteration
  re-check. (Headless has no such cap: `--at` schedules the exact reset time.)

### 6. Report
End your turn with a short human status line, e.g.:
`Increment 3/12 done ✓ · session 34% / week 61% · armed next run +2min`
or
`Session 88% used — no work this run, armed restart for 22:02 (reset).`

Then, as the **very last line**, emit one machine-readable status line that the
launcher parses for the monitoring dashboard. Pipe-delimited, `key=value`, no
spaces around `|`, exactly this shape:

```
STATUS|phase=<active|on_hold|complete|not_ready|blocked>|session=<int>|week=<int>|reset=<YYYY-MM-DD HH:MM or ->|note=<short text>
```

- `phase`: `active` = did an increment, budget healthy, next run armed soon;
  `on_hold` = budget exhausted, next run armed at the reset; `complete` = goal
  done, nothing armed; `not_ready` = GOAL.md still a template; `blocked` =
  increment couldn't be completed/verified this run.
- `session`/`week`: integer percent from `/usage` (omit the `%`).
- `reset`: the reset time you armed for when `on_hold`, else `-`.
- `note`: one short phrase, no `|` characters.

Example: `STATUS|phase=on_hold|session=88|week=61|reset=2026-07-15 22:00|note=session limit reached, restart armed`

## Notes
- Keep each iteration cheap and focused; the loop's value is consistency, not
  heroics per turn.
- If `claude -p "/usage"` errors or returns nothing, assume budget is fine and
  arm a short next run (fail open, don't stall the goal).
- Never fabricate progress in `GOAL.md`. A checked box must correspond to
  verified work.
