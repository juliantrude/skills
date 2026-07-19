function esc(x){return String(x).replace(/[&<>"']/g,
 c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function md(x){return esc(x).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<b>$1</b>');}
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
