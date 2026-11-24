local U=require("scripts.util")
local C=require("scripts.catalogue")
local M=require("scripts.model")
local L=require("scripts.layout")
local V=require("scripts.preview")
local Projects=require('scripts.projects')
local J={schema=85}
local function T(k,...) return {"afp."..k,...} end
function J.remove(s) if s.job then V.remove(s.job);s.job=nil end end
function J.start(p,s,playing)
  J.remove(s)
  if s.project_id then s._project=Projects.context(s.project_id) end
  if s.snap_grid==nil then s.snap_grid=true end
  local c=C.build(p.force);local plan=M.calculate(c,s);L.prepare(c,s,plan)
  -- Later stages receive this saved catalogue instead of the force catalogue.
  -- Keep every available kind, including optional entities such as input displays.
  local support={};for kind,entities in pairs(c.infra) do support[kind]=U.sorted(entities) end
  local input={};for _,key in ipairs({"target","rate","decisions","direction","side","growth_direction","infrastructure","thresholds","mode","targets","max_width","input_rows","input_order","layout_search","paving","roboports","snap_grid","compression_weights","grid_anchor","_project","_single_recipe","manual_ports","port_origin","conversions","byproduct_exports"}) do input[key]=U.copy(s[key]) end
  input.infrastructure=input.infrastructure or {}
  local j={schema=J.schema,status="running",playing=playing~=false,input=input,base=U.copy(plan),support=support,candidates=L.candidates(c,input,plan),attempt=1,next_tick=0}
  V.create(p,j);s.job=j;s.plan=plan;s.phase="generation";s.error=nil
  return j
end
function J.toggle(j) j.playing=not j.playing;j.request=false end
function J.next(j) j.playing=false;j.request=true end
function J.cancel(j) j.status="cancelled";j.playing=false;j.request=false;if j.work then j.work.search=nil end end
function J.replay(j) V.clear(j);j.playing=false;j.request=false;j.current=nil end
local function retryable(err)
  return type(err)=="table" and (err[1]=="afp-error.route" or err[1]=="afp-error.layout-overlap" or err[1]=="afp-error.infrastructure"or err[1]=='afp-error.belt-flow'or err[1]=='afp-error.power')
end
function J.tick(p,s,tick)
  local j=s.job;if not j or not j.surface or not j.surface.valid then return end
  local stopped=j.status=="failed" or j.status=="cancelled" or j.status=="done"
  if not j.playing and not j.request and not (j.status=="failed" and j.work and j.drawn<#j.work.g.entities) then return end
  if tick<j.next_tick and not j.request then return end
  local stepping=j.request
  local ok,err=pcall(function()
    if j.status=="retry" then
      j.attempt=j.attempt+1;j.work=nil;j.current=nil;j.failure=nil;j.error=nil;j.status="running";V.clear(j)
    end
    if j.compaction then
      local state=j.compaction;local before=#state.history
      local c
      if not state.trial then c=C.build(p.force)else
        c={infra={}};for kind,names in pairs(j.support)do c.infra[kind]={};for _,name in ipairs(names)do c.infra[kind][name]=prototypes.entity[name]end end
      end
      if L.compression_advance(c,state,128)then
        local result=L.compression_finish(state);j.compaction_summary=result.compression.refinement;j.compacted=true;j.compaction=nil
        if state.accepted>0 then
          j.final_settings=U.copy(state.settings);j.final_settings._compression_positions=U.copy(state.positions)
          j.work=nil;j.current=nil;V.clear(j)
        else j.work.plan.compression.refinement=U.copy(j.compaction_summary)end
      end
      if #state.history>before or state.done then j.request=false end
      return
    end
    if not j.work then
      local settings=j.final_settings or L.candidate_settings(j.input,j.candidates[j.attempt])
      j.settings=settings
      j.work=L.begin(C.build(p.force),settings,U.copy(j.base),j)
      j.total=#j.work.events+#j.work.connections+#j.work.special+2
      return
    end
    local w=j.work;local event=w.events[j.view_event+1]
    if event then
      if j.current~=event and event.from then V.route_marks(p,j,false,event) end
      j.current=event
      if V.draw(p,j,event.last,100) then
        j.view_event=j.view_event+1;j.request=false;j.next_tick=tick+(j.playing and 6 or 0)
        if j.view.follow and event.stage~="routes" then V.focus(j,event) end
      end
      return
    end
    if stopped then j.request=false;j.playing=false;return end
    if w.stage=="done" then
      j.total=#w.events
      if(w.plan.rate_search or w.plan.compression_search)and not j.best_replay then
        if L.better(w.plan,j.best_plan)then j.best_plan=U.copy(w.plan);j.best_attempt=j.attempt end
        if j.attempt<#j.candidates then j.attempt=j.attempt+1;j.work=nil;j.current=nil;V.clear(j);return end
        if j.best_attempt~=j.attempt then j.attempt=j.best_attempt;j.best_replay=true;j.work=nil;j.current=nil;V.clear(j);return end
        w.plan.layout_stats.search_attempts=#j.candidates
      end
      if not j.compacted then
        j.best_replay=true;j.best_plan=nil
        j.compaction=L.compression_begin(j.base,j.settings,w.plan)
        return
      end
      if j.compaction_summary then w.plan.compression.refinement=U.copy(j.compaction_summary)end
      j.status="done";j.playing=false;j.request=false;s.plan=w.plan
      if w.plan.rate_search or w.plan.compression_search then w.plan.layout_stats.search_attempts=#j.candidates end
      j.best_plan=nil
      s.plan.layout_signature=U.layout_signature(j.input)
      if j.search_mark and j.search_mark.valid then j.search_mark.destroy() end
      for _,mark in ipairs(j.marks) do if mark.valid then mark.destroy() end end;j.marks={}
      V.fit(j)
      w.g.occupied={};w.g.reserved={};w.g.fluid_ports={};w.g.tunnels={};w.g.electric={};w.connections={};w.special={};w.buses={}
      return
    end
    local previous=w.search
    local c={infra={}}
    for kind,names in pairs(j.support) do c.infra[kind]={};for _,name in ipairs(names) do c.infra[kind][name]=prototypes.entity[name] end end
    L.advance(c,j.settings,w,128)
    if w.restarted then V.clear(j);j.current=nil;w.restarted=nil;return end
    if w.search and not previous then V.route_marks(p,j,false) end
    V.search_cursor(p,j)
  end)
  if not ok then
    j.error=type(err)=="table" and err or {"afp-error.unexpected",tostring(err)}
    j.failure=j.work and j.work.search and j.work.search.failure
    if j.work then
      local events=j.work.events;local last=events[#events] and events[#events].last or 0
      if #j.work.g.entities>last then events[#events+1]={stage="incomplete",first=last+1,last=#j.work.g.entities} end
      j.total=j.total or #events
    end
    if j.failure then V.route_marks(p,j,true) end
    j.status=(retryable(err)or(j.base.rate_search or j.base.compression_search)and type(err)=='table')and j.attempt<#j.candidates and "retry" or "failed"
    if j.status=='failed'and j.best_attempt and not j.best_replay then j.attempt=j.best_attempt-1;j.best_replay=true;j.status='retry'end
    j.next_tick=tick+90;j.request=j.status=='retry'and stepping and not j.playing or false
    if j.status=="failed" then j.playing=false end
    log("AFP GENERATION: "..serpent.line(j.error).." attempt="..j.attempt)
  end
end
function J.status(j)
  if j.status=="failed" or j.status=="cancelled" or j.status=="done" or j.status=="retry" then return T("generation-"..j.status) end
  if not j.playing and not j.request then return T("generation-paused") end
  return T("generation-running")
end
function J.detail(j)
  if j.error then return j.error end
  if j.compaction then local state=j.compaction
    return T('compression-running',state.attempts,state.accepted,U.fmt(state.best.compression.unit_cost))
  end
  local w=j.work
  if not w then return T("stage-prepare") end
  if w.search then return {"",T("stage-routes")," · ",U.icon(w.search.key)," ",U.name(w.search.key)," · ",T("search-count",w.search.expanded,w.search.limit)} end
  local event=j.current
  return event and {"",T("stage-"..event.stage),event.detail and {""," · ",event.detail} or ""} or T("stage-prepare")
end
function J.diagnostics(j)
  local f=j.failure
  if not f then
    local name=j.settings and j.settings.infrastructure.underground;local proto=name and prototypes.entity[name]
    return T("generation-attempt",j.attempt,#j.candidates,proto and proto.localised_name or "—")
  end
  return T("route-diagnostic",T("reason-"..f.reason),f.expanded,f.range,f.from.x,f.from.y,f.to.x,f.to.y)
end
J.preview=V
return J
