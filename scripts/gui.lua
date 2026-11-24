local U=require("scripts.util")
local C=require("scripts.catalogue")
local M=require("scripts.model")
local L=require("scripts.layout")
local J=require("scripts.generation")
local Projects=require('scripts.projects')
local Paving=require('scripts.paving')
local Mall=require('scripts.mall')
local View=require('scripts.gui_view')
local Reconcile=require('scripts.reconcile')
local Chain=require('scripts.chain_ui')
local Preferences=require('scripts.preferences')
local Grid=require('scripts.grid')
local UI={}
local ui_sessions={}
local function T(k,...) return {"afp."..k,...} end
local function button(parent,caption,action,extra)
  local tags={afp=true,action=action};for k,v in pairs(extra or {}) do tags[k]=v end
  return parent.add{type="button",caption=caption,tags=tags}
end
local function label(parent,caption) return parent.add{type="label",caption=caption} end
local function fresh(p,controller)
  local defaults=Preferences.get(p.index,storage.afp and storage.afp[p.index])
  local robots=true
  local anchor=storage.afp_grid_anchors and storage.afp_grid_anchors[p.index]
  if anchor and anchor.surface~=p.surface.index then anchor=nil end
  return {phase='goal',mode='rate',decisions={},thresholds={},infrastructure=anchor and {roboport=anchor.name}or{},rate=60,growth_direction=defaults.growth_direction,
    max_width=Projects.default_width(anchor and anchor.name),roboports=robots,snap_grid=true,grid_anchor=U.copy(anchor),layout_search=true}
end
local function state(p)
  storage.afp=storage.afp or {};storage.afp[p.index]=storage.afp[p.index] or fresh(p)
  return storage.afp[p.index]
end
function UI.close(p)
  local frame=p.gui.screen.afp
  if frame then local s=storage.afp and storage.afp[p.index];if s then s.ui_location=U.copy(frame.location)end;frame.destroy()end
end
local function clear_marks(s)
  for _,r in pairs(s.markers or {}) do if r.valid then r.destroy() end end;s.markers={}
end
local function generation_panel(parent,p,s,width,height)
  local j=s.job
  if not j or not j.surface or not j.surface.valid then s.phase="ports";return end
  local camera_height=math.max(180,math.min(340,height-350))
  j.viewport={width=(width-70)*p.display_scale,height=camera_height*p.display_scale,render_scale=p.display_scale}
  if j.view.fit then J.preview.fit(j) end
  local panel=parent.add{type="flow",name="generation",direction="vertical"}
  panel.add{type="label",name="status",caption=J.status(j)}
  local detail=panel.add{type="label",name="detail",caption=J.detail(j)};detail.style.single_line=false;detail.style.maximal_width=width-70
  local bar=panel.add{type="progressbar",name="progress",value=0};bar.style.width=width-70
  panel.add{type="label",name="count",caption=""}
  local controls=panel.add{type="flow",name="controls"}
  for _,spec in ipairs({{"play","auto-play","job-play"},{"next","next-step","job-next"},{"cancel","cancel-generation","job-cancel"},{"replay","replay","job-replay"},{"settings","back-settings","job-settings"}}) do
    controls.add{type="button",name=spec[1],caption=T(spec[2]),tags={afp=true,action=spec[3]}}
  end
  local camera=panel.add{type="camera",name="camera",position=j.view.position,surface_index=j.surface.index,zoom=j.view.zoom}
  camera.style.width=width-70;camera.style.height=camera_height
  local view=panel.add{type="flow"}
  for _,spec in ipairs({{"fit","fit-view"},{"focus","follow-step"},{"zoom-in","zoom-in"},{"zoom-out","zoom-out"},{"left","pan-left"},{"up","pan-up"},{"down","pan-down"},{"right","pan-right"}}) do
    local b=view.add{type="button",caption=T(spec[2]),tags={afp=true,action="job-"..spec[1]}}
    b.style.minimal_width=32;if spec[1]~="fit" and spec[1]~="focus" then b.style.width=40 end
  end
  local diagnostic=panel.add{type="label",name="diagnostic",caption=J.diagnostics(j)};diagnostic.style.single_line=false;diagnostic.style.maximal_width=width-70
  local changes=panel.add{type='label',name='changes',caption=''};changes.style.single_line=false;changes.style.maximal_width=width-70
  local hint=panel.add{type='label',name='change_hint',caption=''};hint.style.single_line=false;hint.style.maximal_width=width-70
  local history=panel.add{type="label",name="history",caption=""};history.style.single_line=false;history.style.maximal_width=width-70
  local actions=panel.add{type="flow"};local export=button(actions,T("blueprint"),"blueprint");export.enabled=j.status=="done" and s.mode~='mall'
  if s.project_id then local apply=button(actions,T("apply-project"),"project-apply");apply.enabled=j.status=='done' end
  panel.add{type="label",name="ready",caption=""}
end
local function update_difference(s)
  if s.ui_changes or s.ui_diff_error or not s.plan or not s.plan.entities then return end
  if not s.project_id then s.ui_changes={keep=0,add=#s.plan.entities,remove=0};return end
  local ok,result=pcall(function()
    local project=storage.afp_projects[s.project_id]
    local entities=Projects.preview(s.project_id,s,s.plan)
    local keep,retire=Reconcile.partition(project,entities,Grid.reference(s));local kept=0
    for _ in pairs(keep) do kept=kept+1 end
    return {keep=kept,add=#entities-kept,remove=#retire}
  end)
  if ok then s.ui_changes=result else s.ui_diff_error=result end
end
function UI.update(p)
  local s=state(p);local j=s.job;local frame=p.gui.screen.afp
  if frame and frame.valid and frame.meta and frame.meta.project_status and s.project_id then
    local project=storage.afp_projects and storage.afp_projects[s.project_id]
    frame.meta.project_status.caption=project and {"",T('project-number',project.id),' · ',T('project-'..project.status)} or T('project-missing')
  end
  if frame and frame.meta then
    frame.meta.draft.caption=T(s.ui_dirty==false and 'draft-saved' or 'draft-dirty')
    if frame.meta.calculation then frame.meta.calculation.caption=T(j and j.status=='done'and 'state-plan-ready'or j and(j.status=='running'or j.status=='retry')and'state-generating'or'state-needs-plan')end
  end
  if frame and frame.footer and frame.footer.demolish then
    frame.footer.demolish.enabled=Projects.can_demolish(storage.afp_projects and storage.afp_projects[s.project_id])
  end
  local body=View.body(frame,s)
  if not j or not body or not body.generation then return end
  local panel=body.generation
  panel.status.caption=J.status(j);panel.detail.caption=J.detail(j);panel.diagnostic.caption=J.diagnostics(j)
  panel.progress.value=j.status=="done" and 1 or math.min(0.99,(j.view_event or 0)/math.max(1,j.total or 1))
  panel.count.caption=T("generation-count",j.view_event,j.total or 0,j.drawn)
  panel.camera.position=j.view.position;panel.camera.zoom=j.view.zoom
  local active=j.status=="running" or j.status=="retry";local remaining=j.work and j.view_event<#j.work.events
  panel.controls.play.caption=T(j.playing and "pause" or "auto-play")
  panel.controls.play.enabled=active or remaining or false;panel.controls.next.enabled=(active and not j.request or remaining) and true or false
  panel.controls.cancel.enabled=active;panel.controls.replay.enabled=j.drawn>0
  local recent={""};local events=j.work and j.work.events or {}
  for i=math.max(1,j.view_event-3),j.view_event do local event=events[i];if event then
    recent[#recent+1]={"","✓ ",T("stage-"..event.stage),event.detail and {""," · ",event.detail} or "","\n"}
  end end
  panel.history.caption=recent
  if j.status=='done' then update_difference(s) end
  local changes=s.ui_changes
  panel.changes.caption=changes and T('review-changes',changes.keep,changes.add,changes.remove) or s.ui_diff_error and T('review-diff-error') or ''
  panel.change_hint.caption=changes and s.project_id and T('review-preserved') or ''
  local actions=panel.children[#panel.children-1]
  for _,el in ipairs(actions.children) do
    if el.tags.action=="blueprint" then el.enabled=j.status=="done" and s.mode~='mall'
    elseif el.tags.action=='project-apply' then el.enabled=j.status=='done' and not s.ui_diff_error and s.ui_dirty~=false end
  end
  panel.ready.caption=j.status=="done" and T("summary",#s.plan.entities,s.plan.bounds.width,s.plan.bounds.height) or ""
end
local function initialise_ui(p,s)
  if s.mode~='mall'and s.layout_search==nil then s.layout_search=true end
  s.ui_tab=s.ui_tab or (s.phase=='goal' and 'products' or s.phase=='chain' and 'chain' or s.phase=='generation' and 'update' or 'layout')
  if s.ui_tab=='products'then s.ui_tab='chain'end
  s.decisions=s.decisions or {};s.thresholds=s.thresholds or {};s.infrastructure=s.infrastructure or {}
  s.infrastructure.belt=nil;s.infrastructure.underground=nil;s.infrastructure.splitter=nil
  s.ui_stocks=s.ui_stocks or {};s.ui_query=s.ui_query or ''
  if not s.signal and s.target then s.signal=U.signal(s.target) end
  if s.mode=='mall' then for i=#(s.targets or {}),1,-1 do if not s.targets[i].key then table.remove(s.targets,i) end end end
  if s.ui_locale~=p.locale then
    s.ui_names={};s.ui_translation_pending={};s.ui_translation_names={};s.ui_locale=p.locale
    s.ui_chain_names={};s.ui_chain_translation_pending={};s.ui_chain_translation_names={}
  end
end
local function goals_valid(c,s)
  for _,route in ipairs(s.conversions or{})do if not route.rate or route.rate<=0 or route.rate>1000000 then return false,{'afp-error.conversion-rate'}end end
  if s.mode=='mall' then
    if not s.project_id or not s.targets or #s.targets==0 then return false end
    if #s.targets>50 then return false,{'afp-error.mall-targets'} end
    local seen={}
    for _,target in ipairs(s.targets) do
      if not target.key or U.split(target.key)~='item' then return false,{'afp-error.target'} end
      if not target.stacks or target.stacks<1 or target.stacks%1~=0 then return false,{'afp-error.mall-stock'} end
      if seen[target.key] then return false,{'afp-error.duplicate-target',U.name(target.key)} end;seen[target.key]=true
      local ok,err=pcall(Mall.chest,c,s,target.stacks);if not ok then return false,err end
    end
    if #M.unavailable(c,s)>0 then return false end
    return true
  end
  if not(s.signal and s.signal.type~='virtual'and s.signal.name and(not s.signal.quality or s.signal.quality=='normal'))then return false end
  local seen={}
  for _,target in ipairs(M.targets(s))do
    if not target.key then return false end
    if not target.rate or target.rate<=0 or target.rate>1000000 then return false,{'afp-error.rate'}end
    if seen[target.key]then return false,{'afp-error.duplicate-target',U.name(target.key)}end;seen[target.key]=true
  end
  return true
end
local function invalidate(s)
  J.remove(s);s.plan=nil;s.ui_changes=nil;s.ui_diff_error=nil;s.ui_dirty=true;s.ui_notice=nil
  s.ui_model=nil;s.ui_model_error=nil;s.ui_model_due=game.tick+15
  if s.phase=='generation' or s.phase=='preview' then s.phase='ports' end
end
local function refresh_products(p,s)
  local frame=p.gui.screen.afp;local body=View.body(frame,s)
  if not body then return end
  local c=C.build(p.force);local valid,err=goals_valid(c,s)
  if body.product_validation then body.product_validation.caption=err or '';body.product_validation.visible=err~=nil end
  if frame.footer and frame.footer.primary and s.ui_tab=='products' then frame.footer.primary.enabled=valid and true or false end
  if frame.meta then frame.meta.draft.caption=T(s.ui_dirty==false and 'draft-saved' or 'draft-dirty') end
  View.filter(p,s)
end
function UI.open(p)
  local s=state(p);Mall.migrate(s);initialise_ui(p,s);clear_marks(s)
  if not ui_sessions[p.index] then
    s.ui_translation_pending={};s.ui_translation_names={};ui_sessions[p.index]=true
  end
  if s.pending_port=='blueprint-created'then
    s.pending_port=nil
  elseif s.pending_port then
    s.pending_port=nil
    if p.cursor_stack and p.cursor_stack.valid_for_read and p.cursor_stack.name=='afp-port' then p.clear_cursor() end
  end
  local c=C.build(p.force);Chain.prepare(c,s);local unavailable=M.unavailable(c,s)
  if #unavailable>0 then
    J.remove(s);s.plan=nil;s.phase='goal'
    if s.ui_tab=='chain' or s.ui_tab=='update' then s.ui_tab='chain' end
  end
  if s.job and s.job.schema~=J.schema then J.remove(s);s.plan=nil;s.phase='ports' end
  local height=math.max(300,math.floor(p.display_resolution.height/p.display_scale)-80)
  local width=math.min(1180,math.max(420,math.floor(p.display_resolution.width/p.display_scale)-60))
  s.display={width=p.display_resolution.width,height=p.display_resolution.height,scale=p.display_scale}
  local frame=p.gui.screen.afp
  local reuse=frame and frame.valid and frame.tags.chain_cards==2 and s.ui_tab=='chain'and frame.tags.tab=='chain'and frame.tags.project==(s.project_id or 0)and frame.tags.width==width and frame.tags.height==height
  if not reuse then
  UI.close(p);frame=p.gui.screen.add{type='frame',name='afp',direction='vertical',tags={tab=s.ui_tab,project=s.project_id or 0,width=width,height=height,chain_cards=2}}
  if s.ui_location then frame.location=s.ui_location else frame.auto_center=true end
  frame.style.maximal_height=height;frame.style.width=width
  local head=frame.add{type='flow'}
  local heading=label(head,T('title'));heading.style.font='heading-1'
  local drag=head.add{type='empty-widget',style='draggable_space_header'};drag.style.horizontally_stretchable=true;drag.style.height=24;drag.drag_target=frame
  head.add{type='sprite-button',sprite='utility/close',style='frame_action_button',tags={afp=true,action='close'}}
  local meta=frame.add{type='flow',name='meta',direction=width>=1000 and'horizontal'or'vertical'}
  if s.project_id then meta.add{type='label',name='project_status',caption=''} end
  local spacer=meta.add{type='empty-widget'};spacer.style.horizontally_stretchable=true
  meta.add{type='label',name='draft',caption=T(s.ui_dirty==false and 'draft-saved' or 'draft-dirty')}
  meta.add{type='label',name='calculation',caption=''}
  local pane=frame.add{type='tabbed-pane',name='afp_tabs',tags={afp=true,action='tab'}}
  pane.style.width=width-24
  for i,name in ipairs(View.tabs) do
    local tab=pane.add{type='tab',caption=T('tab-'..name)}
    local body=pane.add{type='scroll-pane',name='afp_'..name,direction='vertical',horizontal_scroll_policy='never'}
    body.style.width=width-40;body.style.maximal_height=height-190
    pane.add_tab(tab,body)
    if name==s.ui_tab then
      pane.selected_tab_index=i
      local err=body.add{type='label',name='ui_error',caption=s.error or'',visible=s.error~=nil};err.style.font_color={1,0.35,0.25};err.style.single_line=false;err.style.maximal_width=width-70
      if name=='products' then
        View.products(body,p,c,s,width,unavailable)
        local valid,err=goals_valid(c,s)
        local warning=body.add{type='label',name='product_validation',caption=err or '',visible=err~=nil}
        warning.style.single_line=false;warning.style.maximal_width=width-70;warning.style.font_color={1,0.65,0.25}
      elseif name=='chain' then View.chain(body,p,c,s,width)
      elseif name=='layout' then View.layout(body,p,c,s,width)
      elseif s.job and s.job.surface and s.job.surface.valid then generation_panel(body,p,s,width,height)
      else label(body,T('review-empty')).style.single_line=false end
    end
  end
  else
    local body=View.body(frame,s);body.ui_error.caption=s.error or'';body.ui_error.visible=s.error~=nil
    View.chain(body,p,c,s,width)
  end
  if s.ui_tab=='chain'and not s.plan and not s.ui_model and not s.ui_model_error then s.ui_model_due=s.ui_model_due or game.tick+15 end
  local footer=frame.footer or frame.add{type='flow',name='footer',direction=width<700 and'vertical'or'horizontal'};footer.clear();button(footer,T('new'),'new')
  if s.project_id then footer.add{type='button',name='demolish',caption=T('demolish-project'),tooltip=T('demolish-project-hint'),style='red_button',tags={afp=true,action='project-demolish'}}end
  local space=footer.add{type='empty-widget'};space.style.horizontally_stretchable=true
  local _,pending=View.resources(c,s);local valid=goals_valid(c,s)
  if s.ui_tab=='chain'then button(footer,T('tab-layout'),'calculate').enabled=valid and not pending end
  if s.ui_tab~='update' or not s.job then
    local action=s.ui_tab=='products' and 'start' or s.ui_tab=='chain'and'preview'or pending and 'start' or 'preview'
    local caption=action=='start' and T('chain-next') or action=='calculate' and T('calculate') or T('compute-plan')
    local primary=footer.add{type='button',name='primary',caption=caption,style='confirm_button',tags={afp=true,action=action}}
    primary.enabled=valid and not(s.ui_tab=='chain'and pending) and (action~='calculate' or not pending) and true or false
  end
  p.opened=frame;View.filter(p,s);UI.update(p)
end
local function calculate(p,s)
  local c=C.build(p.force);s.phase="ports";s.plan=M.calculate(c,s);L.prepare(c,s,s.plan);s.ui_tab='layout';return c
end
function UI.open_project(p,project)
  local previous=state(p)
  if previous.project_id~=project.id or previous.project_revision~=project.revision
    or(previous.project_settings_revision or 0)~=(project.settings_revision or 0)then
    J.remove(previous)
    local s=U.copy(project.copied_settings or project.config or fresh(p,true))
    s.project_id=project.id;s.project_revision=project.revision;s.phase=s.target and 'chain' or 'goal';s.ui_tab='products';s.ui_dirty=false
    s.project_settings_revision=project.settings_revision or 0;s.ui_dirty=project.copied_settings~=nil or project.status=='demolished'or project.demolishing or false
    s.decisions=s.decisions or {};s.thresholds=s.thresholds or {};s.infrastructure=s.infrastructure or {}
    if s.target then s.signal=U.signal(s.target) end
    storage.afp[p.index]=s
    local c=C.build(p.force)
    if s.target and #M.unavailable(c,s)==0 and not select(2,Chain.resources(c,s))then
      local ok,err=pcall(calculate,p,s)
      if not ok then s.plan=nil;s.phase='chain';s.error=type(err)=='table'and err or {'afp-error.unexpected',tostring(err)}end
    end
    s.ui_tab='chain'
  end
  UI.open(p)
end
function UI.paste_settings(event)
  local source,destination=event.source,event.destination
  if not source or not source.valid or not destination or not destination.valid or source==destination
    or source.name~='afp-controller'or destination.name~='afp-controller'then return end
  local p=game.get_player(event.player_index);if not p then return end
  local ok,project=pcall(Projects.copy_settings,source,destination,p.index)
  if not ok then p.print(type(project)=='table'and project or {'afp-error.unexpected',tostring(project)});return end
  if not project then p.print(T('settings-empty'));return end
  Preferences.remember(p.index,project.copied_settings)
  UI.open_project(p,project);p.print(T('settings-copied'))
end
local function next_chain_resource(c,s,key)
  local _,pending=Chain.resources(c,s)
  s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil
  s.ui_resource=pending or key;s.ui_chain_expanded=true;s.phase='chain';s.ui_tab='chain'
  s.ui_notice=not pending and T('chain-ready')or nil
  if pending then s.ui_chain_query='';s.ui_chain_scope=nil;s.ui_chain_focus=true end
end
local function run(p,fn)
  local s=state(p);s.error=nil
  local ok,err=pcall(fn,s)
  if not ok then
    s.error=type(err)=="table" and err or {"afp-error.unexpected",tostring(err)}
    log("AFP: "..(type(err)=="table" and serpent.line(err) or tostring(err)))
  end
  if not s.pending_port then UI.open(p) end
end
function UI.click(e)
  local el=e.element;if not el or not el.valid or not el.tags.afp then return end
  -- Native pickers, drop-downs and text fields also emit on_gui_click.
  -- Rebuilding the window here dismisses their native editing interface.
  if el.type~="button" and el.type~='sprite-button' then return end
  local p=game.get_player(e.player_index);local t=el.tags
  if t.action=="close" then UI.close(p);return end
  run(p,function(s)
    local a=t.action
    if a and a:match('^production%-')then
      local handled,dirty=Chain.action(C.build(p.force),s,t)
      if handled and dirty then invalidate(s)end
      return
    elseif a=="new" then
      local id,revision,settings_revision,width,paving,mode=s.project_id,s.project_revision,s.project_settings_revision,s.max_width,s.paving,s.mode
      Preferences.remember(p.index,s)
      UI.close(p);J.remove(s);clear_marks(s);storage.afp[p.index]=nil
      local fresh=state(p);fresh.paving=paving;fresh.mode=mode;fresh.ui_tab='products';fresh.ui_dirty=true
      if id then fresh.project_id=id;fresh.project_revision=revision;fresh.project_settings_revision=settings_revision;fresh.max_width=width end
      return
    elseif a=='mode-rate' or a=='mode-mall' then
      local mode=a=='mode-mall' and 'mall' or 'rate'
      if s.mode~=mode then
        invalidate(s);s.ui_selector=nil
        s[(s.mode or'rate')..'_conversions']=s.conversions
        s.conversions=s[mode..'_conversions']or{}
        s[(s.mode or'rate')..'_exports']=s.byproduct_exports
        s.byproduct_exports=s[mode..'_exports']or{}
        if s.mode=='mall'then s.mall_targets=s.targets;s.targets=s.rate_targets
        else s.rate_targets=s.targets;s.rate_value=s.rate;s.targets=s.mall_targets end
        s.mode=mode;s.phase='goal';s.ui_tab='products';s.targets=s.targets or {};s.rate=s.rate or 60
        if mode=='rate'then
          if M.has_rate_targets(s)then s.target=s.targets[1].key;s.rate=s.targets[1].rate;s.signal=s.target and U.signal(s.target)
          else s.rate=s.rate_value or 60;s.target=s.signal and U.key(s.signal.type,s.signal.name)end
        end
      end
    elseif a=='rate-add'then
      invalidate(s)
      if not M.has_rate_targets(s)then s.targets={{key=s.target,rate=s.rate}}end
      s.targets[#s.targets+1]={rate=s.rate or 60};s.phase='goal'
    elseif a=='rate-remove'then
      invalidate(s);table.remove(s.targets,t.index);s.phase='goal'
    elseif a=='add-target' then s.ui_picker=not s.ui_picker
    elseif a=='equipment' then s.ui_equipment=not s.ui_equipment
    elseif a=='port-place'then
      if not p.clear_cursor()then U.fail('cursor')end
      local pin=s.manual_ports and s.manual_ports[t.id]
      s.port_origin=s.port_origin or{x=math.floor(p.position.x)+.5,y=math.floor(p.position.y)+.5}
      s.pending_port={id=t.id,key=t.key,kind=t.kind,section=t.section,direction=pin and pin.direction or 0,surface=p.surface.index}
      p.cursor_stack.set_stack{name='afp-port'};UI.close(p)
      for _,v in pairs(s.manual_ports or{})do if v.surface==p.surface.index then
        s.markers[#s.markers+1]=rendering.draw_circle{surface=p.surface,target=v.position,radius=.45,color={0,1,1},width=3,players={p.index}}
        s.markers[#s.markers+1]=rendering.draw_text{surface=p.surface,target={v.position.x,v.position.y-1},text=T('manual-direction-'..v.direction),color={0,1,1},players={p.index},alignment='center'}
      end end
      p.print(T('manual-port-pick',U.icon(t.key),T('manual-direction-'..s.pending_port.direction)))
    elseif a=='port-auto'then
      invalidate(s);if s.manual_ports then s.manual_ports[t.id]=nil end
    elseif a=='port-turn'then
      local pin=s.manual_ports and s.manual_ports[t.id]
      if pin then
        -- Turning an endpoint requires its approach to be recalculated too.
        invalidate(s);pin.direction=(pin.direction+4)%16
      end
    elseif a=='grid-anchor-tool'then
      if not p.clear_cursor()then U.fail('cursor')end
      s.pending_grid_anchor=true;p.cursor_stack.set_stack{name='afp-grid-anchor'};UI.close(p);p.print(T('grid-anchor-pick'))
    elseif a=='grid-anchor-clear'then
      invalidate(s);s.grid_anchor=nil;storage.afp_grid_anchors=storage.afp_grid_anchors or{};storage.afp_grid_anchors[p.index]=nil
    elseif a=='controller-grid'then
      Grid.controller(p,C.build(p.force),s);UI.close(p);s.pending_port='blueprint-created'
    elseif a=='resource' or a=='chain-link' then
      s.ui_chain_expanded=a=='chain-link'or s.ui_resource~=t.key or not s.ui_chain_expanded
      s.ui_resource=t.key;s.ui_tab='chain';s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil
      if a=='chain-link'then s.ui_chain_query='';s.ui_chain_scope=nil;s.ui_chain_focus=true end
    elseif a=='chain-unique' then
      local c=C.build(p.force);local count=Chain.choose_unique(c,s)
      if count>0 then invalidate(s)end
      s.ui_notice=T('chain-unique-applied',count);s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil
    elseif a=='chain-bulk-machine' then
      local c=C.build(p.force);local source=s.decisions[t.key];local changes={};local count=0
      for _,key in ipairs(Chain.resources(c,s))do local d=s.decisions[key]
        if source and d and d.mode=='craft'then
          local candidate=Chain.choice(c,key,d.recipe,source.machine,d.fuel)
          if candidate and candidate.machine==source.machine and U.fingerprint(candidate)~=U.fingerprint(d)then changes[key]=candidate;count=count+1 end
        end
      end
      if count>0 then invalidate(s);for key,d in pairs(changes)do s.decisions[key]=d end end
      s.ui_notice=T('chain-bulk-applied',count)
    elseif a=='remove-unavailable' then
      local unavailable=M.unavailable(C.build(p.force),s)
      for i=#unavailable,1,-1 do
        local target=s.targets[unavailable[i].index];s.ui_stocks[target.key]=target.stacks;table.remove(s.targets,unavailable[i].index)
      end
      invalidate(s);s.target=s.targets[1] and s.targets[1].key or nil;s.phase='goal';s.ui_tab='products';s.pending_recipe=nil;s.pending_machine=nil
    elseif a=='roboport-width' then
      local width=Projects.default_width(s.infrastructure and s.infrastructure.roboport);if not width then U.fail('missing-infrastructure','roboport') end
      invalidate(s);s.max_width=width
      if s.phase~='goal' and s.phase~='chain' then s.phase='ports' end
    elseif a=="goal" then s.phase="goal";s.ui_tab='products'
    elseif a=="start" then
      if s.mode=='mall' then
        if not s.project_id then U.fail('mall-controller') end
        local seen={}
        if not s.targets or #s.targets==0 or #s.targets>50 then U.fail('mall-targets') end
        for _,target in ipairs(s.targets) do
          if not target.key or U.split(target.key)~='item' then U.fail('target') end
          if not target.stacks or target.stacks<1 or target.stacks%1~=0 then U.fail('mall-stock') end
          if seen[target.key] then U.fail('duplicate-target',U.name(target.key)) end;seen[target.key]=true
        end
        local unavailable=M.unavailable(C.build(p.force),s)
        if #unavailable>0 then U.fail('mall-unavailable',#unavailable) end
        s.target=s.targets[1].key;s.rate=0;s.phase='chain'
      else
      if not s.signal or s.signal.type=="virtual" or not s.signal.name or s.signal.quality and s.signal.quality~="normal" then U.fail("target") end
      local valid,err=goals_valid(C.build(p.force),s);if not valid then error(err or {'afp-error.target'},0)end
      local target=U.key(s.signal.type,s.signal.name)
      if target~=s.target then s.decisions={} end
      s.target=target;s.phase="chain"
      end
      s.ui_tab='chain';s.ui_resource=nil;s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil
      local c=C.build(p.force)
      for _,target in ipairs(M.targets(s))do if s.decisions[target.key]and s.decisions[target.key].mode=='external'then s.decisions[target.key]=nil end end
      if Chain.choose_unique(c,s,true)>0 then invalidate(s)end
    elseif a=="external" then
      if M.is_target(s,t.key)then U.fail('target-external')end
      invalidate(s);s.decisions[t.key]={mode='external'};next_chain_resource(C.build(p.force),s,t.key)
    elseif a=="craft" then
      local choice=Chain.choice(C.build(p.force),t.key,s.pending_recipe,s.pending_machine,s.pending_fuel)
      if not choice then U.fail('recipe',s.pending_recipe or t.key)end
      invalidate(s);s.decisions[t.key]=choice
      next_chain_resource(C.build(p.force),s,t.key)
    elseif a=="edit" then invalidate(s);s.decisions[t.key]=nil;s.phase="chain";s.ui_tab='chain';s.ui_resource=t.key
    elseif a=="chain" then s.phase="chain";s.ui_tab='chain'
    elseif a=="calculate" then calculate(p,s)
    elseif a=="auto-threshold" then invalidate(s);s.thresholds[t.key]=nil;calculate(p,s)
    elseif a=='project-demolish'then
      local project=Projects.demolish(s.project_id,p.index,s.project_revision)
      invalidate(s);s.project_revision=project.revision;s.phase=s.target and'ports'or'goal'
    elseif a=='project-apply' then
      local current=storage.afp_projects and storage.afp_projects[s.project_id]
      if not current or not current.anchor.valid then U.fail('project-missing')end
      if(s.project_settings_revision or 0)~=(current.settings_revision or 0)then U.fail('project-revision')end
      Paving.validate(C.build(p.force),s)
      local plan=s.plan
      if not s.job or s.job.schema~=J.schema or s.job.status~='done' or not plan or not L.current(plan) or plan.model_signature~=M.calculate(C.build(p.force),s).model_signature
        or plan.layout_signature~=U.layout_signature(s) then U.fail('stale-plan') end
      local project=Projects.apply(s.project_id,s,plan,p.index,s.project_revision)
      Preferences.remember(p.index,s)
      s.project_revision=project.revision;s.phase='ports';s.ui_dirty=false;s.ui_changes=nil
    elseif a=="preview" then
      UI.close(p);s.ui_changes=nil;s.ui_diff_error=nil;J.start(p,s,true);s.ui_tab='update'
    elseif a=="job-play" then J.toggle(s.job)
    elseif a=="job-next" then J.next(s.job)
    elseif a=="job-cancel" then J.cancel(s.job)
    elseif a=="job-replay" then J.replay(s.job)
    elseif a=="job-settings" then
      if s.job.status=="running" or s.job.status=="retry" then J.cancel(s.job) end
      s.phase="ports";s.ui_tab='layout'
    elseif a=="job-fit" then J.preview.fit(s.job)
    elseif a=="job-focus" then s.job.view.follow=true;s.job.view.fit=false;J.preview.focus(s.job)
    elseif a=="job-zoom-in" or a=="job-zoom-out" then
      s.job.view.follow=false;s.job.view.fit=false;s.job.view.zoom=math.max(0.01,math.min(4,s.job.view.zoom*(a=="job-zoom-in" and 1.5 or 1/1.5)))
    elseif a=="job-left" or a=="job-right" or a=="job-up" or a=="job-down" then
      local view=s.job.view;view.follow=false;view.fit=false;local step=4/view.zoom
      view.position.x=view.position.x+(a=="job-left" and -step or a=="job-right" and step or 0)
      view.position.y=view.position.y+(a=="job-up" and -step or a=="job-down" and step or 0)
    elseif a=="blueprint" then
      if s.mode=='mall' then U.fail('mall-controller') end
      local c=C.build(p.force);local plan=s.plan
      Paving.validate(c,s)
      if not plan or not plan.entities or not L.current(plan) or plan.model_signature~=M.calculate(c,s).model_signature or plan.layout_signature~=U.layout_signature(s) then U.fail("stale-plan") end
      for name in pairs(plan.counts) do local proto=prototypes.entity[name];if not (c.infra[proto.type] and c.infra[proto.type][name]) then U.fail("infrastructure",name) end end
      if not p.clear_cursor() then U.fail("cursor") end
      local inventory=game.create_inventory(1)
      local ok,err=pcall(function()
        local stack=inventory[1];stack.set_stack{name="blueprint"};stack.set_blueprint_entities(plan.entities)
        if plan.tiles then stack.set_blueprint_tiles(plan.tiles) end
        Grid.apply(stack,c,s)
        if stack.get_blueprint_entity_count()~=#plan.entities then U.fail("blueprint") end
        stack.label="AFP · "..select(2,U.split(s.target))..(#plan.targets>1 and' + '..(#plan.targets-1)or' · '..U.fmt(s.rate)..'/min')
        local description={'Auto Factory Planner '..script.active_mods['auto-factory-planner']}
        for _,target in ipairs(plan.targets)do description[#description+1]=select(2,U.split(target.key))..': '..U.fmt(target.rate)..' /min'end
        description[#description+1]=#plan.entities..' entities';stack.blueprint_description=table.concat(description,'\n')
        stack.set_blueprint_entity_tag(1,"afp",{target=s.target,rate=s.rate,targets=U.copy(s.targets),input_order=U.copy(s.input_order),layout_search=s.layout_search,compression_weights=U.copy(s.compression_weights),decisions=U.copy(s.decisions),direction=s.direction,side=s.side,growth_direction=s.growth_direction,infrastructure=U.copy(s.infrastructure),thresholds=U.copy(s.thresholds),show_recycling=s.show_recycling,conversions=U.copy(s.conversions),byproduct_exports=U.copy(s.byproduct_exports)})
        p.cursor_stack.swap_stack(stack)
      end)
      inventory.destroy();if not ok then error(err,0) end
      Preferences.remember(p.index,s);clear_marks(s);p.print(T("created"));UI.close(p);s.pending_port="blueprint-created"
    end
  end)
  if state(p).pending_port=="blueprint-created" then state(p).pending_port=nil end
end
function UI.changed(e)
  local el=e.element;if not el or not el.valid or not el.tags.afp or not el.enabled then return end
  local p=game.get_player(e.player_index);local s=state(p);initialise_ui(p,s)
  local t=el.tags;local a=t.action
  if a and a:match('^production%-')then
    local handled,dirty=Chain.changed(C.build(p.force),s,el)
    if dirty then
      invalidate(s)
      local c=C.build(p.force);local valid,err=goals_valid(c,s);local frame=p.gui.screen.afp
      s.ui_model_error=err
      if frame and frame.footer and s.ui_tab=='chain'then
        for _,b in ipairs(frame.footer.children)do if b.tags.action=='preview'or b.tags.action=='calculate'then b.enabled=valid and not select(2,Chain.resources(c,s))or false end end
      end
      Chain.statistics(View.body(frame,s),s,c)
    end
    if a=='production-picker-search'then Chain.picker_filter(View.body(p.gui.screen.afp,s),s)end
    return
  end
  if a=='product-search' then s.ui_query=el.text;View.filter(p,s);return
  elseif a=='show-recycling'then
    s.show_recycling=el.state;s.ui_dirty=true;s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil;UI.open(p);return
  elseif a=='products-selected-only' then s.ui_only_selected=el.state;View.filter(p,s);return
  elseif a=='chain-search'then s.ui_chain_query=el.text;Chain.filter(View.body(p.gui.screen.afp,s),C.build(p.force),s);return
  elseif a=='chain-scope'then s.ui_chain_scope=s.ui_chain_scope_options[el.selected_index]or nil;Chain.filter(View.body(p.gui.screen.afp,s),C.build(p.force),s);return end
  if a=='source-mode'or a=='recipe'or a=='machine'or a=='fuel'then
    run(p,function(s)
      local c=C.build(p.force);local key=t.key or s.ui_resource;local d=s.decisions[key]
      s.ui_resource=key;s.ui_chain_expanded=true;s.ui_tab='chain';s.phase='chain';s.ui_notice=nil
      if a=='source-mode'then
        if el.selected_index==2 then
          if M.is_target(s,key)then U.fail('target-external')end
          invalidate(s);s.decisions[key]={mode='external'}
        else
          local recipes=C.recipes(c,key,s.show_recycling);local recipe=d and d.mode=='craft'and d.recipe or #recipes==1 and recipes[1]
          invalidate(s);s.decisions[key]=el.selected_index==1 and recipe and Chain.choice(c,key,recipe,d and d.machine,d and d.fuel)or nil
        end
      else
        local recipe=a=='recipe'and s.recipe_options[el.selected_index]or s.pending_recipe or d and d.recipe
        if not recipe then return end
        local machine=a=='machine'and s.machine_options[el.selected_index]or s.pending_machine or d and d.machine
        local fuel=a=='fuel'and s.fuel_options[el.selected_index]or s.pending_fuel or d and d.fuel
        local choice=Chain.choice(c,key,recipe,machine,fuel);if not choice then U.fail('recipe',recipe)end
        invalidate(s);s.decisions[key]=choice
      end
      s.pending_recipe=nil;s.pending_machine=nil;s.pending_fuel=nil
    end)
    return
  end
  s.error=nil
  if a=='target' then
    local signal=el.elem_value;local key=signal and signal.type~='virtual' and U.key(signal.type,signal.name)
    if key~=s.target then s.decisions={} end
    invalidate(s);s.signal=signal;s.target=key
    if M.has_rate_targets(s)then s.targets[1].key=key end
    refresh_products(p,s)
  elseif a=='rate-target'then
    local signal=el.elem_value;local target=s.targets[t.index]
    invalidate(s);target.key=signal and signal.type~='virtual'and(not signal.quality or signal.quality=='normal')and U.key(signal.type,signal.name)or nil
    refresh_products(p,s)
  elseif a=='rate-value'then
    invalidate(s);s.targets[t.index].rate=tonumber(el.text);refresh_products(p,s)
  elseif a=='mall-item' then
    local name=el.elem_value;if not name then return end
    local key=U.key('item',name);local targets=View.targets(s)
    if not targets[key] then
      invalidate(s);s.targets=s.targets or {};s.targets[#s.targets+1]={key=key,stacks=s.ui_stocks[key] or 1}
      s.target=s.targets[1].key
    end
    s.ui_picker=false;s.ui_query='';UI.open(p)
  elseif a=='mall-toggle' then
    local key=t.key;local entry=View.targets(s)[key]
    if el.state and not entry then
      invalidate(s);s.targets=s.targets or {};s.targets[#s.targets+1]={key=key,stacks=s.ui_stocks[key] or 1}
    elseif not el.state and entry then
      s.ui_stocks[key]=entry.target.stacks;invalidate(s);table.remove(s.targets,entry.index)
    end
    s.target=s.targets[1] and s.targets[1].key or nil;s.phase='goal'
    if not el.parent.tags.available then UI.open(p) else View.sync_products(p,s);refresh_products(p,s) end
  elseif a=='mall-stock' then
    local entry=View.targets(s)[t.key]
    if entry then
      invalidate(s);entry.target.stacks=tonumber(el.text);s.ui_stocks[t.key]=entry.target.stacks
      local _,name=U.split(t.key);local amount=el.parent.children[3]
      amount.caption=T('products-item-count',(entry.target.stacks or 0)*prototypes.item[name].stack_size)
      el.tooltip=T('mall-stack-hint',prototypes.item[name].stack_size,(entry.target.stacks or 0)*prototypes.item[name].stack_size)
      refresh_products(p,s)
    end
  elseif a=='mall-chest' then
    invalidate(s);s.infrastructure.chest=s.chest_options[el.selected_index] or nil;UI.open(p)
  elseif a=='width' then
    invalidate(s);local value=tonumber(el.text);s.max_width=value and value>0 and value or nil
    if s.roboports and s.max_width then s.max_width=math.min(s.max_width,Grid.width(s)or s.max_width);el.text=tostring(s.max_width)end
  elseif a=='paving-enabled' then
    if Paving.grid_roads(s)then el.state=true;return end
    invalidate(s)
    if el.state then
      local c=C.build(p.force);local options=Paving.options(c)
      s.paving=s.ui_paving_last and c.available[U.key('item',s.ui_paving_last)] and s.ui_paving_last or options[1] and options[1].name
    else s.ui_paving_last=s.paving;s.paving=nil end
    UI.open(p)
  elseif a=='paving' then
    invalidate(s);s.paving=s.paving_options[el.selected_index];s.ui_paving_last=s.paving
  elseif a=='rate' then
    invalidate(s);s.rate=tonumber(el.text)
    if M.has_rate_targets(s)then s.targets[1].rate=s.rate end
    refresh_products(p,s)
  elseif a=='input-rows' then invalidate(s);s.input_rows=({'auto','single','double'})[el.selected_index];s.phase='ports'
  elseif a=='compression-weight'then
    invalidate(s);s.compression_weights=s.compression_weights or{};s.compression_weights[t.key]=tonumber(el.text);s.phase='ports'
  elseif a=='layout-search'then invalidate(s);s.layout_search=el.state;s.phase='ports'
  elseif a=='roboports'or a=='snap-grid'then invalidate(s);s[a=='roboports'and'roboports'or'snap_grid']=el.state;s.phase='ports'
  elseif a=='direction' or a=='side' then invalidate(s);s[a]=el.selected_index;Preferences.remember(p.index,s);s.phase='ports'
  elseif a=='growth-direction'then invalidate(s);s.growth_direction=el.selected_index;Preferences.remember(p.index,s);s.phase='ports'
  elseif a=='infrastructure' then invalidate(s);s.infrastructure[t.key]=s.infra_options[t.key][el.selected_index] or nil;s.phase='ports'
  elseif a=='low' or a=='high' then
    local f=s.plan and s.plan.flows[t.key]
    s.thresholds[t.key]=s.thresholds[t.key] or {low=f and f.low or t.low,high=f and f.high or t.high}
    invalidate(s);s.thresholds[t.key][a]=tonumber(el.text);s.phase='ports'
  end
  local frame=p.gui.screen.afp
  if frame and frame.meta then frame.meta.draft.caption=T(s.ui_dirty==false and 'draft-saved' or 'draft-dirty') end
end
function UI.tab_changed(e)
  local el=e.element;if not el or not el.valid or not el.tags.afp or el.tags.action~='tab' then return end
  local p=game.get_player(e.player_index);local s=state(p);s.ui_tab=View.tabs[el.selected_tab_index] or 'chain';UI.open(p)
end
function UI.translated(e)
  local s=storage.afp and storage.afp[e.player_index]
  local key=s and s.ui_chain_translation_pending and s.ui_chain_translation_pending[e.id]
  if key then s.ui_chain_names[key]=e.translated and e.result or select(2,U.split(key));s.ui_chain_translation_pending[e.id]=nil;s.ui_chain_translation_names[key]=nil;s.ui_chain_translation_dirty=true;return end
  local name=s and s.ui_translation_pending and s.ui_translation_pending[e.id]
  if not name then return end
  s.ui_names[name]=e.translated and e.result or name;s.ui_translation_pending[e.id]=nil;s.ui_translation_names[name]=nil;s.ui_translation_dirty=true
end
function UI.locale_changed(e)
  local p=game.get_player(e.player_index);local s=storage.afp and storage.afp[e.player_index]
  if s then s.ui_locale=nil;if p.gui.screen.afp then UI.open(p) end end
end
function UI.remove(index)
  local s=storage.afp and storage.afp[index];if s then J.remove(s);clear_marks(s);storage.afp[index]=nil end
  Preferences.remove(index);ui_sessions[index]=nil
  if storage.afp_grid_anchors then storage.afp_grid_anchors[index]=nil end
end
function UI.research_changed(event)
  for _,player in pairs(event.research.force.players) do
    local s=storage.afp and storage.afp[player.index];if s then invalidate(s) end
    if player.gui.screen.afp then UI.open(player) end
  end
end
function UI.tick(e)
  local active={}
  for _,index in ipairs(U.sorted(storage.afp or {})) do
    local s=storage.afp[index]
    local p=game.get_player(index)
    if p and p.gui.screen.afp and not ui_sessions[index] then UI.open(p) end
    if p and s.ui_translation_dirty and e.tick%6==0 then s.ui_translation_dirty=nil;View.filter(p,s,true) end
    if p and s.ui_chain_translation_dirty and e.tick%6==0 then s.ui_chain_translation_dirty=nil;Chain.filter(View.body(p.gui.screen.afp,s),C.build(p.force),s);Chain.picker_filter(View.body(p.gui.screen.afp,s),s)end
    if p and s.ui_model_due and e.tick>=s.ui_model_due then
      s.ui_model_due=nil;local c=C.build(p.force);local _,pending=View.resources(c,s)
      if not pending and goals_valid(c,s)then
        local ok,result=pcall(function()local config=Projects.configuration(s);local model=M.calculate(c,config);L.prepare(c,config,model);return model end)
        if ok then s.ui_model=result else s.ui_model_error=type(result)=='table'and result or {'afp-error.unexpected',tostring(result)}end
        Chain.statistics(View.body(p.gui.screen.afp,s),s,c)
      end
    end
    if s.job and s.job.schema~=J.schema then
      local visible=p and p.gui.screen.afp
      if p then UI.close(p) end
      J.remove(s);s.plan=nil;s.phase="ports"
      if visible and p then UI.open(p) end
    end
    if p and p.gui.screen.afp and (not s.display or s.display.width~=p.display_resolution.width or s.display.height~=p.display_resolution.height or s.display.scale~=p.display_scale) then UI.open(p) end
    if s.job then
      if s.job.status=="running" or s.job.status=="retry" or s.job.playing or s.job.request or s.job.status=="failed" and s.job.work and s.job.drawn<#s.job.work.g.entities then active[#active+1]=index end
    end
    if(s.job or s.project_id)and p and p.gui.screen.afp and e.tick%6==0 then UI.update(p)end
  end
  if #active>0 then
    local index=active[e.tick%#active+1];local p=game.get_player(index)
    if p then J.tick(p,storage.afp[index],e.tick) end
  end
end
local render=UI.open
function UI.open(p)
  local ok,err=pcall(render,p)
  if not ok then
    UI.close(p)
    local s=state(p);s.phase="goal";s.error=type(err)=="table" and err or {"afp-error.unexpected",tostring(err)}
    log("AFP GUI: "..(type(err)=="table" and serpent.line(err) or tostring(err)))
    render(p)
  end
end
function UI.port_rotate(event)
  local p=game.get_player(event.player_index);local s=state(p);local pending=s.pending_port
  if type(pending)=='table'and p.cursor_stack.valid_for_read and p.cursor_stack.name=='afp-port'then
    pending.direction=(pending.direction+4)%16;p.print(T('manual-port-pick',U.icon(pending.key),T('manual-direction-'..pending.direction)))
  end
end
function UI.port_selected(event)
  if event.item=='afp-grid-anchor'then
    local p=game.get_player(event.player_index);local s=state(p);local chosen
    for _,e in ipairs(event.entities or{})do if e.valid and e.type=='roboport'and e.force==p.force then
      if chosen then p.print(T('grid-anchor-pick'));return end;chosen=e
    end end
    if not chosen then p.print(T('grid-anchor-pick'));return end
    local project=s.project_id and storage.afp_projects[s.project_id]
    if project and chosen.surface.index~=project.anchor.surface.index then p.print({'afp-error.grid-anchor-surface'});return end
    invalidate(s);Grid.bind(s,chosen);s.pending_grid_anchor=nil
    storage.afp_grid_anchors=storage.afp_grid_anchors or{};storage.afp_grid_anchors[p.index]=U.copy(s.grid_anchor)
    s.ui_tab='layout';p.clear_cursor();p.print(T('grid-anchor-set',chosen.position.x,chosen.position.y));UI.open(p);return
  end
  if event.item~='afp-port'then return end
  local p=game.get_player(event.player_index);local s=state(p);local pending=s.pending_port
  if type(pending)~='table'then return end
  local project=s.project_id and storage.afp_projects[s.project_id]
  if project and project.anchor.surface.index~=p.surface.index then p.print({'afp-error.manual-port-surface'});return end
  local area=event.area;local position={x=math.floor((area.left_top.x+area.right_bottom.x)/2)+.5,y=math.floor((area.left_top.y+area.right_bottom.y)/2)+.5}
  s.manual_ports=s.manual_ports or{};s.manual_ports[pending.id]={position=position,direction=pending.direction,surface=p.surface.index}
  s.pending_port=nil;invalidate(s);s.ui_tab='layout';p.clear_cursor();UI.open(p)
end
function UI.port_cursor_changed(event)
  local p=game.get_player(event.player_index);local s=state(p)
  if s.pending_grid_anchor and(not p.cursor_stack.valid_for_read or p.cursor_stack.name~='afp-grid-anchor')then s.pending_grid_anchor=nil;UI.open(p)end
  if type(s.pending_port)=='table'and(not p.cursor_stack.valid_for_read or p.cursor_stack.name~='afp-port')then s.pending_port=nil;UI.open(p)end
end
return UI
