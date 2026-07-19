#!/usr/bin/env python3
"""Tiny stdlib-only monitoring dashboard for the advance-goal loop.

Portable: no systemd dependency — "running" comes from the run.pid file,
"next fire" from hustle-scheduler.sh (which speaks systemd on Linux and launchd
on macOS). Zero tokens at runtime: everything is local file parsing.

Layout (HUSTLE_HOME = <project>/.hustle):
  config       KEY=VALUE settings (HUSTLE_PROJECT, HUSTLE_PORT, HUSTLE_BIND, ...)
  bin/         this script + hustle-scheduler.sh + hustle-session.sh
  status.json  written by hustle-session.sh after each run
  run.log      chain log
  run.pid      pid of the active run (if any)
"""
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HUSTLE_HOME = Path(os.environ.get("HUSTLE_HOME", Path(__file__).absolute().parents[1]))


def read_config() -> dict:
    cfg = {}
    try:
        for ln in (HUSTLE_HOME / "config").read_text().splitlines():
            ln = ln.strip()
            if ln and not ln.startswith("#") and "=" in ln:
                k, v = ln.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"')
    except Exception:
        pass
    return cfg


CFG = read_config()
PROJECT = Path(CFG.get("HUSTLE_PROJECT", HUSTLE_HOME.parent))
PORT = int(os.environ.get("HUSTLE_PORT", CFG.get("HUSTLE_PORT", "8787")))
BIND = os.environ.get("HUSTLE_BIND", CFG.get("HUSTLE_BIND", "0.0.0.0"))
LOGLINES = int(CFG.get("HUSTLE_LOGLINES", "60"))

STATUS_JSON = HUSTLE_HOME / "status.json"
LOG_FILE = HUSTLE_HOME / "run.log"
GOAL_FILE = PROJECT / "GOAL.md"

CHECKBOX = re.compile(r"^\s*-\s*\[( |x|X)\]\s+(.*)$")


def run_active() -> bool:
    try:
        pid = int((HUSTLE_HOME / "run.pid").read_text().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def armed_next() -> str:
    try:
        out = subprocess.run(
            ["bash", str(HUSTLE_HOME / "bin" / "hustle-scheduler.sh"), "next"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        return out
    except Exception:
        return ""


def read_status_json() -> dict:
    try:
        return json.loads(STATUS_JSON.read_text())
    except Exception:
        return {}


def tail(path: Path, n: int) -> str:
    try:
        lines = path.read_text(errors="replace").splitlines()
        return "\n".join(lines[-n:])
    except Exception:
        return "(no log yet)"


def parse_goal() -> dict:
    """Parse GOAL.md into DoD, plan sections, status fields and the goal log."""
    try:
        lines = GOAL_FILE.read_text().splitlines()
    except Exception:
        return {}

    section = ""
    dod, plan, goal_log = [], [], []
    status_flag, next_action, blockers = "", "", ""
    cur = None        # current plan subsection
    last_item = None  # for wrapped checkbox continuation lines

    for ln in lines:
        if ln.startswith("## "):
            section = ln[3:].strip().lower()
            cur = last_item = None
            continue
        if ln.startswith("### ") and section.startswith("plan"):
            cur = {"name": ln[4:].strip(), "items": []}
            plan.append(cur)
            last_item = None
            continue

        m = CHECKBOX.match(ln)
        if m:
            item = {"done": m.group(1).lower() == "x", "text": m.group(2).strip()}
            if section.startswith("definition"):
                dod.append(item)
                last_item = item
            elif section.startswith("plan"):
                if cur is None:
                    cur = {"name": "Plan", "items": []}
                    plan.append(cur)
                cur["items"].append(item)
                last_item = item
            continue

        # Wrapped continuation of the previous checkbox (indented plain line).
        if (last_item is not None and ln[:1].isspace() and ln.strip()
                and not ln.strip().startswith(("<!--", "#"))):
            last_item["text"] += " " + ln.strip()
            continue
        last_item = None

        s = ln.strip()
        if section == "status":
            if s.startswith("STATUS:"):
                status_flag = s.split(":", 1)[1].strip()
            elif s.lower().startswith("**next action:**"):
                next_action = s[len("**Next action:**"):].strip()
            elif s.lower().startswith("**blockers:**"):
                blockers = s[len("**Blockers:**"):].strip()
            elif next_action and not blockers and s and not s.startswith(("<!--", "**")):
                next_action += " " + s  # wrapped continuation line
        elif section == "log":
            if s.startswith("- ") and not s.startswith("- <!--"):
                goal_log.append(s[2:])

    next_up = []
    for sec in plan:
        for it in sec["items"]:
            if not it["done"] and len(next_up) < 3:
                next_up.append({"section": sec["name"], "text": it["text"]})

    for sec in plan:
        sec["done"] = sum(1 for i in sec["items"] if i["done"])
        sec["total"] = len(sec["items"])

    plan_done = sum(s["done"] for s in plan)
    plan_total = sum(s["total"] for s in plan)
    return {
        "status_flag": status_flag,
        "next_action": next_action,
        "blockers": blockers,
        "dod": dod,
        "dod_done": sum(1 for i in dod if i["done"]),
        "dod_total": len(dod),
        "plan": plan,
        "plan_done": plan_done,
        "plan_total": plan_total,
        "next_up": next_up,
        "goal_log": goal_log[-10:],
    }


def compute_state() -> dict:
    running = run_active()
    st = read_status_json()
    armed = armed_next()
    phase = st.get("phase", "unknown")

    if running:
        headline, tone = "Working", "run"
    elif phase == "complete":
        headline, tone = "Goal reached", "done"
    elif phase == "on_hold":
        headline, tone = "Paused – session limit", "hold"
    elif phase == "blocked":
        headline, tone = "Blocked (last increment)", "warn"
    elif phase == "not_ready":
        headline, tone = "GOAL.md not filled in yet", "warn"
    elif armed:
        headline, tone = "Waiting for next run", "wait"
    elif phase == "unknown":
        headline, tone = "No runs yet", "idle"
    else:
        headline, tone = "No chain scheduled (stopped?)", "warn"

    return {
        "headline": headline,
        "tone": tone,
        "running": running,
        "phase": phase,
        "session_pct": st.get("session_pct", ""),
        "week_pct": st.get("week_pct", ""),
        "reset": st.get("reset", ""),
        "note": st.get("note", ""),
        "last_exit": st.get("last_exit", ""),
        "updated": st.get("updated", ""),
        "next_run": armed,
        "server_time": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    }


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>hustle monitor</title>
<style>
 :root{color-scheme:dark}
 body{font:15px/1.5 system-ui,sans-serif;margin:0;background:#0f1115;color:#e6e6e6}
 .wrap{max-width:1080px;margin:0 auto;padding:24px}
 h1{font-size:15px;font-weight:600;color:#8a94a6;letter-spacing:.04em;text-transform:uppercase;margin:0 0 16px}
 h2{font-size:12px;font-weight:600;color:#8a94a6;letter-spacing:.04em;text-transform:uppercase;margin:26px 0 10px}
 .badge{display:inline-block;padding:10px 16px;border-radius:10px;font-size:20px;font-weight:600;margin:0 8px 18px 0}
 .run{background:#12351f;color:#5ee08a} .hold{background:#3a2a10;color:#f0b74d}
 .done{background:#10263a;color:#5ab0f0} .wait{background:#1c2230;color:#9fb0c8}
 .warn{background:#3a1414;color:#f07a7a} .idle{background:#1c2230;color:#8a94a6}
 .pill{display:inline-block;padding:4px 10px;border-radius:20px;font-size:12px;background:#1c2230;color:#9fb0c8;vertical-align:middle}
 .next-action{background:#141b2b;border:1px solid #24304a;border-left:4px solid #5ab0f0;
   border-radius:10px;padding:12px 16px;margin-bottom:20px}
 .next-action .k{font-size:11px;color:#5ab0f0;text-transform:uppercase;letter-spacing:.05em;margin-bottom:2px}
 .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:6px}
 .card{background:#171a21;border:1px solid #232833;border-radius:10px;padding:14px}
 .card .k{font-size:12px;color:#8a94a6;margin-bottom:4px}
 .card .v{font-size:17px;font-weight:600;overflow-wrap:anywhere}
 .bar{height:8px;background:#232833;border-radius:4px;overflow:hidden;margin-top:8px}
 .bar>i{display:block;height:100%;background:#5ab0f0}
 .bar.hot>i{background:#f0b74d} .bar.ok>i{background:#5ee08a}
 .cols{display:grid;grid-template-columns:280px 1fr;gap:16px;align-items:start}
 @media(max-width:760px){.cols{grid-template-columns:1fr}}
 .donutwrap{background:#171a21;border:1px solid #232833;border-radius:10px;padding:18px;text-align:center}
 .donut{width:130px;height:130px;border-radius:50%;margin:6px auto 10px;display:grid;place-items:center}
 .donut>div{width:96px;height:96px;border-radius:50%;background:#171a21;display:grid;place-items:center;
   font-size:24px;font-weight:700}
 ul.check{list-style:none;margin:8px 0 0;padding:0;text-align:left;font-size:13px}
 ul.check li{padding:3px 0;color:#c8d0dc;display:flex;gap:8px}
 ul.check li.on{color:#5ee08a}
 details{background:#171a21;border:1px solid #232833;border-radius:10px;padding:0;margin-bottom:10px}
 summary{cursor:pointer;padding:12px 14px;display:flex;align-items:center;gap:12px;list-style:none}
 summary::-webkit-details-marker{display:none}
 summary .name{font-weight:600;flex:0 0 auto}
 summary .cnt{color:#8a94a6;font-size:12px;flex:0 0 auto}
 summary .bar{flex:1;margin:0}
 .items{padding:2px 14px 12px 14px;border-top:1px solid #232833}
 .items div{padding:4px 0;font-size:13.5px;color:#9fb0c8;display:flex;gap:9px}
 .items div.on{color:#57b06b;text-decoration:line-through;text-decoration-color:#2f5c3a}
 .items div.nxt{color:#f0d24d;font-weight:600}
 pre{background:#0b0d11;border:1px solid #232833;border-radius:10px;padding:14px;
     overflow:auto;max-height:300px;font-size:12.5px;color:#c8d0dc;white-space:pre-wrap}
 .muted{color:#6b7688;font-size:12px}
 .goal-log div{font-size:13px;color:#9fb0c8;padding:3px 0;border-bottom:1px dashed #1e2430}
</style></head><body><div class="wrap">
 <h1>hustle monitor</h1>
 <div><span id="badge" class="badge idle">…</span><span id="stflag" class="pill"></span></div>
 <div class="next-action" id="na" style="display:none">
   <div class="k">Up next</div><div id="naText"></div>
 </div>
 <div class="grid" id="grid"></div>

 <div class="cols">
  <div>
   <h2>Definition of Done</h2>
   <div class="donutwrap">
     <div class="donut" id="donut"><div id="donutPct">–</div></div>
     <ul class="check" id="dodList"></ul>
   </div>
  </div>
  <div>
   <h2>Plan <span class="muted" id="planTotal"></span></h2>
   <div id="plan"></div>
  </div>
 </div>

 <h2>Iteration history (GOAL.md)</h2>
 <div class="goal-log" id="goalLog"></div>
 <h2>Log</h2>
 <pre id="log">…</pre>
 <div class="muted" id="foot"></div>
</div><script>
function esc(x){return String(x).replace(/[&<>"']/g,
 c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function md(x){return esc(x).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>');}
function bar(p,cls){p=parseInt(p);if(isNaN(p))return'';
 return `<div class="bar ${cls||(p>=85?'hot':'')}"><i style="width:${Math.min(p,100)}%"></i></div>`;}
async function refresh(){
 try{
  const [s,g]=await Promise.all([
    (await fetch('api/status')).json(), (await fetch('api/goal')).json()]);
  const b=document.getElementById('badge');
  b.className='badge '+s.tone; b.textContent=s.headline;
  document.getElementById('stflag').textContent=g.status_flag?('STATUS: '+g.status_flag):'';

  const na=document.getElementById('na');
  if(g.next_action){na.style.display='';document.getElementById('naText').innerHTML=md(g.next_action);}
  else na.style.display='none';

  const planPct=g.plan_total?Math.round(100*g.plan_done/g.plan_total):0;
  const cards=[
   ['Plan progress', g.plan_done+' / '+g.plan_total+bar(planPct,'ok')],
   ['Session budget', (s.session_pct!==''?esc(s.session_pct)+'%':'–')+bar(s.session_pct)],
   ['Weekly budget', (s.week_pct!==''?esc(s.week_pct)+'%':'–')+bar(s.week_pct)],
   ['Next run', esc(s.next_run||'– none scheduled –')],
   ['Blockers', md(g.blockers||'–')],
   ['Last note', esc(s.note||'–')],
  ];
  document.getElementById('grid').innerHTML=cards.map(
   ([k,v])=>`<div class="card"><div class="k">${k}</div><div class="v">${v}</div></div>`).join('');

  const dp=g.dod_total?Math.round(100*g.dod_done/g.dod_total):0;
  document.getElementById('donut').style.background=
   `conic-gradient(#5ee08a ${dp*3.6}deg, #232833 0deg)`;
  document.getElementById('donutPct').textContent=dp+'%';
  document.getElementById('dodList').innerHTML=(g.dod||[]).map(
   i=>`<li class="${i.done?'on':''}"><span>${i.done?'✔':'○'}</span><span>${md(i.text)}</span></li>`).join('');

  document.getElementById('planTotal').textContent='· '+planPct+'%';
  let nextFound=false;
  document.getElementById('plan').innerHTML=(g.plan||[]).map(sec=>{
   const pct=sec.total?Math.round(100*sec.done/sec.total):0;
   const hasNext=!nextFound&&sec.items.some(i=>!i.done);
   const items=sec.items.map(i=>{
     let cls=i.done?'on':'';
     if(!i.done&&!nextFound){cls='nxt';nextFound=true;}
     return `<div class="${cls}"><span>${i.done?'✔':(cls==='nxt'?'➤':'○')}</span><span>${md(i.text)}</span></div>`;
   }).join('');
   return `<details ${hasNext?'open':''}><summary><span class="name">${esc(sec.name)}</span>
     <span class="cnt">${sec.done}/${sec.total}</span>${bar(pct,'ok')}</summary>
     <div class="items">${items}</div></details>`;
  }).join('');

  document.getElementById('goalLog').innerHTML=(g.goal_log||[]).slice().reverse().map(
   l=>`<div>${md(l)}</div>`).join('')||'<div class="muted">no iterations yet</div>';
  document.getElementById('log').textContent=await (await fetch('api/log')).text();
  document.getElementById('foot').textContent=
   'Status updated: '+(s.updated||'never')+' · Server: '+s.server_time;
 }catch(e){document.getElementById('badge').textContent='Monitor unreachable';}
}
refresh(); setInterval(refresh, 5000);
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if path in ("", "/"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/api/status":
            self._send(200, json.dumps(compute_state()), "application/json")
        elif path == "/api/goal":
            self._send(200, json.dumps(parse_goal()), "application/json")
        elif path == "/api/log":
            self._send(200, tail(LOG_FILE, LOGLINES), "text/plain; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"hustle monitor on http://{BIND}:{PORT}  (project: {PROJECT})", flush=True)
    srv.serve_forever()
