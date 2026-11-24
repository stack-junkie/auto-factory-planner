local U=require('scripts.util')
local C=require('scripts.catalogue')
local M=require('scripts.model')
local L=require('scripts.layout')
local Mall=require('scripts.mall')
local Paving=require('scripts.paving')
local Projects=require('scripts.projects')
local R=require('scripts.recommendations')
local ManualPorts=require('scripts.manual_ports')
local Chain=require('scripts.chain_ui')
local Grid=require('scripts.grid')
local Arrangement=require('scripts.arrangement')
local Compression=require('scripts.compression')
local V={tabs={'chain','layout','update'}}
local function T(key,...)return {'afp.'..key,...}end
local function tags(action,extra)local t={afp=true,action=action};for k,v in pairs(extra or {})do t[k]=v end;return t end
function V.button(parent,caption,action,extra)
  return parent.add{type='button',caption=caption,tags=tags(action,extra)}
end
local function label(parent,caption,width)
  local el=parent.add{type='label',caption=caption}
  if width then el.style.single_line=false;el.style.maximal_width=width end
  return el
end
local function field(parent,value,action,extra,width)
  local el=parent.add{type='textfield',text=value==nil and '' or tostring(value),numeric=true,allow_decimal=action=='rate'or action=='rate-value'or action=='compression-weight',allow_negative=false,tags=tags(action,extra)}
  el.style.width=width or 100;return el
end
local function dropdown(parent,items,index,action,extra)
  local el=parent.add{type='drop-down',items=items,selected_index=index,tags=tags(action,extra)}
  el.style.maximal_width=360;return el
end
local function gap(parent)
  local el=parent.add{type='empty-widget'};el.style.horizontally_stretchable=true;return el
end
local function title(parent,caption)label(parent,caption).style.font='heading-2'end
local function index_of(items,value)local index=1;for i,item in ipairs(items)do if item==value then index=i end end;return index end
local function status_caption(c,status)
  local caption={'',T(status.reason)}
  if #status.technologies>0 then caption[#caption+1]={'',' ',T('unlock-technologies'),' '}
    for i,name in ipairs(status.technologies)do if i>1 then caption[#caption+1]=', 'end;caption[#caption+1]=c.force.technologies[name].localised_name end
  end
  return caption
end
function V.body(frame,s)return frame and frame.valid and frame.afp_tabs and frame.afp_tabs['afp_'..(s.ui_tab or 'chain')]end
function V.targets(s)
  local map={};for i,target in ipairs(s.targets or {})do if target.key then map[target.key]={index=i,target=target}end end;return map
end
function V.filter(p,s,sort)
  local body=V.body(p.gui.screen.afp,s);local list=body and body.product_list
  if not list then return end
  local targets=V.targets(s)
  if sort then
    local children=list.children;local wanted={};for _,row in ipairs(children)do wanted[#wanted+1]=row end
    table.sort(wanted,function(a,b)
      local x,y=a.tags.item,b.tags.item;local nx,ny=s.ui_names[x] or x,s.ui_names[y] or y
      return nx==ny and x<y or nx<ny
    end)
    local positions={};for i,row in ipairs(children)do positions[row.index]=i end
    for i,row in ipairs(wanted)do local at=positions[row.index]
      if at~=i then local other=list.children[i];list.swap_children(i,at);positions[other.index]=at;positions[row.index]=i end
    end
  end
  local visible=0
  for _,row in ipairs(list.children)do
    local name=row.tags.item;row.visible=(not s.ui_only_selected or targets[U.key('item',name)]~=nil)and R.matches(name,s.ui_names[name],s.ui_query)
    if row.visible then visible=visible+1 end
  end
  body.product_count.caption=T('products-shown',visible,#list.children)
  body.product_empty.visible=visible==0
  body.product_empty.caption=T(s.ui_only_selected and 'products-empty-selected' or 'products-empty')
end
function V.sync_products(p,s)
  local body=V.body(p.gui.screen.afp,s);if not body or not body.product_list then return end
  local targets=V.targets(s)
  body.products_head.children[1].caption=T('products-title',#(s.targets or {}))
  for _,row in ipairs(body.product_list.children) do
    local name=row.tags.item;local key=U.key('item',name);local entry=targets[key]
    if not entry and not row.tags.recommended then row.destroy()
    else
      local stacks=entry and entry.target.stacks or s.ui_stocks[key] or 1
      row.children[1].state=entry~=nil;row.children[1].enabled=entry~=nil or row.tags.available
      local count=row.children[2];count.text=stacks and tostring(stacks)or'';count.enabled=entry~=nil and row.tags.available
      count.tooltip=T('mall-stack-hint',prototypes.item[name].stack_size,(stacks or 0)*prototypes.item[name].stack_size)
      local t=count.tags;t.index=entry and entry.index;count.tags=t
      row.children[3].caption=T('products-item-count',(stacks or 0)*prototypes.item[name].stack_size)
    end
  end
end
function V.chests(parent,c,s)
  local row=parent.add{type='flow'};label(row,T('mall-chest'))
  local names={T('automatic')};s.chest_options={false};local selected=1
  for _,chest in ipairs(Mall.chests(c))do
    names[#names+1]=T('chest-option',chest.localised_name,chest.get_inventory_size(defines.inventory.chest,'normal'))
    s.chest_options[#names]=chest.name;if chest.name==s.infrastructure.chest then selected=#names end
  end
  if s.infrastructure.chest and selected==1 then names[#names+1]=T('paving-locked',s.infrastructure.chest);s.chest_options[#names]=s.infrastructure.chest;selected=#names end
  dropdown(row,names,selected,'mall-chest').tooltip=T('mall-chest-hint')
end
function V.products(parent,p,c,s,width,unavailable)
  local top=parent.add{type='flow',name='products_head'};title(top,s.mode=='mall'and T('products-title',#(s.targets or {}))or T('target'));gap(top)
  if s.project_id then
    local rate=V.button(top,T('mode-rate'),'mode-rate');rate.toggled=s.mode~='mall'
    local mall=V.button(top,T('mode-mall'),'mode-mall');mall.toggled=s.mode=='mall'
  end
  if s.mode~='mall' then
    local row=parent.add{type='flow'};label(row,T('target'))
    row.add{type='choose-elem-button',elem_type='signal',signal=s.signal,tags=tags('target')}
    field(row,s.rate,'rate');label(row,T('per-minute'))
    if M.has_rate_targets(s)then
      for i=2,#s.targets do local target=s.targets[i];local extra=parent.add{type='flow'};label(extra,T('target'))
        extra.add{type='choose-elem-button',elem_type='signal',signal=target.key and U.signal(target.key),tags=tags('rate-target',{index=i})}
        field(extra,target.rate,'rate-value',{index=i});label(extra,T('per-minute'));V.button(extra,T('remove-target'),'rate-remove',{index=i})
      end
    end
    V.button(parent,T('add-target'),'rate-add')
    return
  end
  if #unavailable>0 then
    local warning=label(parent,T('mall-remove-unavailable-hint',#unavailable),width-60);warning.style.font_color={1,0.65,0.25}
    V.button(parent,T('mall-remove-unavailable',#unavailable),'remove-unavailable')
  end
  local options=parent.add{type='flow'};label(options,T('products-recommended'));gap(options);V.button(options,T('products-add-custom'),'add-target')
  label(parent,T('products-hint'),width-60)
  if s.ui_picker then
    local picker=parent.add{type='flow'};label(picker,T('products-add-custom'))
    picker.add{type='choose-elem-button',elem_type='item',tags=tags('mall-item')}
  end
  V.chests(parent,c,s)
  local filters=parent.add{type='flow'}
  local search_group=filters.add{type='flow',direction='vertical'};label(search_group,T('products-search'))
  local search=search_group.add{type='textfield',name='search',text=s.ui_query or '',tags=tags('product-search')}
  search.style.width=math.max(150,width-300);search.tooltip=T('products-search')
  filters.add{type='checkbox',caption=T('products-selected-only'),state=s.ui_only_selected or false,tags=tags('products-selected-only')}
  parent.add{type='label',name='product_count',caption=''}
  local headings=parent.add{type='flow'};local first=label(headings,T('products-item'));first.style.width=width-300
  local stock=label(headings,T('products-stacks'));stock.style.width=90;label(headings,T('products-quantity'))
  local list=parent.add{type='flow',name='product_list',direction='vertical'}
  local targets=V.targets(s);local statuses={};for _,entry in ipairs(unavailable)do statuses[entry.key]=entry end
  s.ui_names=s.ui_names or {};s.ui_translation_pending=s.ui_translation_pending or {};s.ui_translation_names=s.ui_translation_names or {}
  for _,name in ipairs(R.items(s))do
    local item=prototypes.item[name];local key=U.key('item',name);local entry=targets[key]
    local available=#C.recipes(c,key,s.show_recycling)>0
    local row=list.add{type='flow',name='item_'..name,tags={item=name,available=available,recommended=R.recommended(item)}}
    local toggle=row.add{type='checkbox',caption={'',U.icon(key),' ',item.localised_name},state=entry~=nil,tags=tags('mall-toggle',{key=key})}
    toggle.style.width=width-300;toggle.enabled=entry~=nil or available
    toggle.tooltip=item.localised_name
    if not available then toggle.tooltip={'',item.localised_name,'\n',statuses[key]and status_caption(c,statuses[key])or T('products-unavailable')}end
    local stacks=entry and entry.target.stacks or s.ui_stocks[key]or 1
    local count=field(row,stacks,'mall-stock',{key=key,index=entry and entry.index},90);count.enabled=entry~=nil and available
    count.tooltip=T('mall-stack-hint',item.stack_size,(stacks or 0)*item.stack_size)
    local amount=label(row,T('products-item-count',(stacks or 0)*item.stack_size));amount.style.width=105
    if not available then toggle.style.font_color={0.65,0.65,0.65}end
    if not s.ui_names[name]and not s.ui_translation_names[name]then
      local id=p.request_translation(item.localised_name);s.ui_translation_pending[id]=name;s.ui_translation_names[name]=true
    end
  end
  parent.add{type='label',name='product_empty',caption='',visible=false}.style.single_line=false
end
function V.resources(c,s)return Chain.resources(c,s)end
function V.chain(parent,p,c,s,width)return Chain.render(parent,p,c,s,width)end
function V.layout(parent,p,c,s,width)
  title(parent,T('layout-title'))
  if s.project_id then
    local row=parent.add{type='flow'};label(row,T(s.mode=='mall' and 'mall-width-label' or 'width-label'));field(row,s.roboports and math.min(s.max_width or math.huge,Grid.width(s)or math.huge)or s.max_width or 0,'width')
    local reference,port=Projects.default_width(s.infrastructure and s.infrastructure.roboport or s.grid_anchor and s.grid_anchor.name)
    if reference then V.button(parent,T('roboport-width',reference),'roboport-width').tooltip=T('roboport-width-hint',port.localised_name,U.fmt(port.logistic_radius*2))end
  end
  local dir=parent.add{type='flow'};label(dir,T('growth-direction'))
  local context=s.project_id and Projects.context(s.project_id)
  dropdown(dir,{T('north'),T('east'),T('south'),T('west')},Arrangement.growth_direction(s,s.plan,context),'growth-direction').tooltip=T('growth-direction-hint')
  do
    local row=parent.add{type='flow'};label(row,T('input-rows'))
    dropdown(row,{T('input-rows-auto'),T('input-rows-single'),T('input-rows-double')},index_of({'auto','single','double'},s.input_rows or 'auto'),'input-rows').tooltip=T('input-rows-hint')
  end
  local ports=C.options(c,'roboport');local available=#ports>0
  if s.mode~='mall'then
    parent.add{type='checkbox',caption=T('layout-search-label'),state=s.layout_search==true,tags=tags('layout-search'),tooltip=T('layout-search-hint')}
  end
  local robot=parent.add{type='checkbox',caption=T('roboports-label'),state=s.roboports==true,tags=tags('roboports')}
  robot.enabled=available or s.roboports==true;robot.tooltip=T('roboports-hint')
  local snap=parent.add{type='checkbox',caption=T('snap-grid-label'),state=s.snap_grid==true,tags=tags('snap-grid')}
  snap.enabled=true
  local port=Grid.prototype(c,s)
  if port then label(parent,T('snap-grid-hint',math.floor(port.logistic_radius*2)),width-60)
  else label(parent,T('roboports-locked'),width-60)end
  V.button(parent,T('controller-grid'),'controller-grid').enabled=true
  V.button(parent,T('grid-anchor-tool'),'grid-anchor-tool').enabled=true
  if s.grid_anchor then
    label(parent,T('grid-anchor-current',s.grid_anchor.position.x,s.grid_anchor.position.y),width-60)
    V.button(parent,T('grid-anchor-clear'),'grid-anchor-clear')
  end
  if s.snap_grid and port then label(parent,T('grid-width-limit',math.floor(port.logistic_radius*2)),width-60)end
  if not available then label(parent,T('grid-before-robotics'),width-60)end
  if s.snap_grid then
    title(parent,T('compression-weights'));label(parent,T('compression-weights-hint'),width-60)
    local weights=Compression.weights(s)
    local fields=parent.add{type='table',column_count=2}
    for _,key in ipairs(Compression.keys)do label(fields,T('compression-'..key));field(fields,weights[key],'compression-weight',{key=key})end
  end
  if s.plan and s.plan.compression and s.plan.city_blocks then local m=s.plan.compression
    label(parent,T('compression-result',m.units,m.columns,m.rows,U.fmt(m.perimeter),U.fmt(m.area),m.objects,U.fmt(m.cost),U.fmt(m.unit_cost or Compression.unit_cost(s.plan.entities))),width-60)
  end
  if s.plan and s.plan.roboports then label(parent,T('roboports-count',#s.plan.roboports),width-60)end
  local grid_roads=Paving.grid_roads(s)
  local paving=parent.add{type='checkbox',caption=T(grid_roads and 'grid-roads-label'or'paving-label'),state=grid_roads or s.paving~=nil,tags=tags('paving-enabled')}
  paving.enabled=not grid_roads
  if grid_roads then paving.tooltip=T('grid-roads-hint')end
  s.paving_options={};local materials={};local selected=1
  local chosen=s.paving
  if grid_roads and not chosen then chosen=Paving.material(c,s).name end
  for _,item in ipairs(Paving.options(c))do materials[#materials+1]=item.localised_name;s.paving_options[#materials]=item.name;if item.name==chosen then selected=#materials end end
  if chosen then
    if not prototypes.item[chosen]or not c.available[U.key('item',chosen)]then materials[#materials+1]=T('paving-locked',chosen);s.paving_options[#materials]=chosen;selected=#materials end
    dropdown(parent,materials,selected,'paving').tooltip=T(grid_roads and 'grid-roads-hint'or'paving-hint')
  end
  label(parent,T('hierarchy-external'),width-60)
  local plan=s.plan
  local pins=plan and plan.project_inputs or s.project_id and storage.afp_projects[s.project_id]and storage.afp_projects[s.project_id].inputs
  local known={}
  if pins and #pins>0 then
    title(parent,T('inputs-title'))
    for _,pin in ipairs(pins)do
      known[pin.id]=true
      label(parent,{'','#',pin.index,' · ',U.icon(pin.key),' ',U.name(pin.key),' · ',T(pin.active and'inputs-fixed'or'inputs-reserved')},width-60)
    end
    label(parent,T('inputs-append'),width-60)
  end
  if plan then
    if not pins or #pins==0 then title(parent,T('inputs-title'))end
    for _,port in ipairs(plan.ports)do
      local id=U.base_key(port.key)..'/'..(port.section or 1)
      if port.kind=='out'or not known[id]then
        label(parent,{'',T(port.kind=='out'and'out'or'inputs-new'),' · ',U.icon(port.key),' ',U.name(port.key),' · ',U.fmt(port.rate),' ',T('per-minute')},width-60)
      end
    end
  end
  V.button(parent,T(s.ui_equipment and'equipment-collapse'or'equipment-manual'),'equipment')
  local connections=plan or s.ui_model
  if not connections then local ok,value=pcall(M.calculate,c,s);if ok then connections=value end end
  if connections then
    title(parent,T('manual-ports-title'));label(parent,T('manual-ports-hint'),width-60)
    if s.mode=='mall'then label(parent,T('manual-ports-mall'),width-60)end
    for _,port in ipairs(connections.ports)do if s.mode~='mall'or port.kind=='in'then
      local id=ManualPorts.id(port);local pin=s.manual_ports and s.manual_ports[id]
      local row=parent.add{type='flow',direction=width<900 and'vertical'or'horizontal'}
      label(row,{'',T(port.kind=='in'and'in'or'out'),' ',U.icon(port.key),' ',U.name(port.key)})
      local extra={id=id,key=U.base_key(port.key),kind=port.kind,section=port.section or 1}
      V.button(row,T(pin and'manual-port-move'or'manual-port-place'),'port-place',extra)
      if pin then
        label(row,{'',pin.position.x,', ',pin.position.y,' ',T('manual-direction-'..pin.direction)})
        V.button(row,T('manual-port-turn'),'port-turn',extra);V.button(row,T('automatic'),'port-auto',extra)
      end
    end end
  end
  label(parent,T('belts-automatic'),width-60)
  if s.ui_equipment then
    local infra=parent.add{type='table',column_count=2};s.infra_options={}
    for _,spec in ipairs({{'inserter','inserter'},{'pole','electric-pole'},{'pipe','pipe'},{'pipeug','pipe-to-ground'},{'tank','storage-tank'},{'pump','pump'},{'roboport','roboport'}})do
      local key,kind=spec[1],spec[2];local names={T('automatic')};local values={false};local selected=1
      for _,prototype in ipairs(C.options(c,kind))do if kind~='inserter'or L.inserter_supported(prototype)then
        names[#names+1]=prototype.localised_name;values[#values+1]=prototype.name;if s.infrastructure[key]==prototype.name then selected=#values end
      end end
      if s.infrastructure[key]and selected==1 then names[#names+1]=T('paving-locked',s.infrastructure[key]);values[#values+1]=s.infrastructure[key];selected=#values end
      s.infra_options[key]=values;label(infra,T(key));dropdown(infra,names,selected,'infrastructure',{key=key})
    end
  else label(parent,T('equipment-auto-hint'),width-60)end
  if plan then
    label(parent,T('sections',plan.sections or 1))
    local thresholds=parent.add{type='table',column_count=4};label(thresholds,T('stock'));label(thresholds,T('low'));label(thresholds,T('high'));label(thresholds,'')
    for _,key in ipairs(U.sorted(plan.flows))do local flow=plan.flows[key];if flow.controlled then
      label(thresholds,{'',U.icon(key),' ',U.name(key)});field(thresholds,s.thresholds[key]and s.thresholds[key].low or flow.low,'low',{key=key,low=flow.low,high=flow.high})
      field(thresholds,s.thresholds[key]and s.thresholds[key].high or flow.high,'high',{key=key,low=flow.low,high=flow.high});V.button(thresholds,T('automatic'),'auto-threshold',{key=key})
    end end
  end
end
return V
