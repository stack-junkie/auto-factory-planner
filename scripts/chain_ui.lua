local U=require('scripts.util')
local C=require('scripts.catalogue')
local M=require('scripts.model')
local R=require('scripts.recommendations')
local Mall=require('scripts.mall')
local K={}
local function T(k,...)return {'afp.'..k,...}end
local function tags(action,key)return {afp=true,action=action,key=key}end
local function label(parent,caption,width,name)
  local e=parent.add{type='label',caption=caption,name=name}
  if width then e.style.width=width;e.style.single_line=false end
  return e
end
local function contains(list,value)for _,v in ipairs(list)do if v==value then return true end end end
function K.choice(c,key,recipe,machine,fuel)
  local recipes=C.recipes(c,key,true)
  if not contains(recipes,recipe)then return end
  local machines=C.machines(c,c.recipes[recipe]);machine=contains(machines,machine)and machine or machines[1]
  if not machine then return end
  local fuels=C.fuels(c,c.machines[machine]);fuel=contains(fuels,fuel)and fuel or fuels[1]
  if c.machines[machine].burner_prototype and not fuel then return end
  return {mode='craft',recipe=recipe,machine=machine,fuel=fuel}
end
function K.resources(c,s,root)
  local seen,keys,queue={}, {}, {}
  if root then queue[1]=root else for _,t in ipairs(M.targets(s))do if t.key then queue[#queue+1]=t.key end end end
  for _,route in ipairs(s.conversions or{})do local recipe=c.recipes[route.recipe];if recipe then
    for _,v in ipairs(recipe.ingredients)do queue[#queue+1]=U.key(v.type,v.name)end
  end end
  local pending
  local i=1
  while i<=#queue do local key=queue[i];i=i+1
    if not seen[key]then
      seen[key]=true;keys[#keys+1]=key;local d=s.decisions[key]
      local choice=d and d.mode=='craft'and K.choice(c,key,d.recipe,d.machine,d.fuel)
      if not d or d.mode=='craft'and(not choice or choice.machine~=d.machine or d.fuel and choice.fuel~=d.fuel)then pending=pending or key end
      local recipe=d and d.mode=='craft'and c.recipes[d.recipe]
      if recipe then for _,v in ipairs(recipe.ingredients)do queue[#queue+1]=U.key(v.type,v.name)end end
    end
  end
  return keys,pending,seen
end
function K.choose_unique(c,s,targets_only)
  local changed=0;local seen={};local queue={}
  for _,t in ipairs(M.targets(s))do if t.key then queue[#queue+1]=t.key end end
  local i=1
  while i<=#queue do local key=queue[i];i=i+1
    if not seen[key]then seen[key]=true;local d=s.decisions[key]
      if not d then local recipes=C.recipes(c,key,s.show_recycling)
        if #recipes==1 then d=K.choice(c,key,recipes[1]);if d then s.decisions[key]=d;changed=changed+1 end end
      end
      if not targets_only and d and d.mode=='craft'and c.recipes[d.recipe]then
        for _,v in ipairs(c.recipes[d.recipe].ingredients)do queue[#queue+1]=U.key(v.type,v.name)end
      end
    end
  end
  return changed
end
-- Missing ingredients start as external inputs. Choosing a recipe replaces
-- that decision; no automatic recursive recipe selection is involved.
function K.prepare(c,s)
  s.decisions=s.decisions or{};s.conversions=s.conversions or{};s.byproduct_exports=s.byproduct_exports or{}
  local _,_,seen=K.resources(c,s)
  for key in pairs(seen)do if not s.decisions[key]and not M.is_target(s,key)then s.decisions[key]={mode='external'}end end
end
local function button(parent,caption,action,extra)
  local t={afp=true,action=action};for k,v in pairs(extra or{})do t[k]=v end
  return parent.add{type='button',name=extra and extra.name,caption=caption,tags=t}
end
local function icon(parent,key,action,amount,extra)
  local kind,name=U.split(key);local t=tags(action,key);for k,v in pairs(extra or{})do t[k]=v end
  local b=parent.add{type='sprite-button',sprite=kind..'/'..name,style='slot_button',number=amount,tags=t}
  b.style.width=40;b.style.height=40;b.tooltip=U.name(key);return b
end
local function recipe_icon(parent,name,action,key)
  local b=parent.add{type='sprite-button',sprite='recipe/'..name,style='slot_button',tags={afp=true,action=action,key=key,recipe=name}}
  b.style.width=40;b.style.height=40;b.tooltip=prototypes.recipe[name].localised_name;return b
end
local function field(parent,value,action,extra)
  local t={afp=true,action=action};for k,v in pairs(extra or{})do t[k]=v end
  local b=parent.add{type='textfield',text=value and tostring(value)or'',numeric=true,allow_decimal=true,allow_negative=false,tags=t}
  b.style.width=100;return b
end
local function target_list(s)
  local result={};for _,v in ipairs(M.targets(s))do if v.key then result[#result+1]=U.copy(v)end end;return result
end
local function sync_targets(s,list)
  s.targets=list;s.target=list[1]and list[1].key;s.signal=s.target and U.signal(s.target)or nil
  s.rate=s.mode=='mall'and 0 or list[1]and list[1].rate or 60
end
local function entry(s,key)
  for i,v in ipairs(M.targets(s))do if v.key==key then return v,i end end
end
local function pick_recipe(c,s,key,route)
  local recipes=route and K.consumers(c,key,s)or C.recipes(c,key,s.show_recycling)
  s.ui_selector={kind=route and'conversion-recipe'or'recipe',key=key,rate=60}
  if #recipes==1 then s.ui_selector.recipe=recipes[1];s.ui_selector.kind='machine' end
end
function K.consumers(c,key,s)
  local result={}
  for name,r in pairs(c.recipes)do if (s.show_recycling or not C.is_recycling(r))and #C.machines(c,r)>0 then
    for _,v in ipairs(r.ingredients)do if U.key(v.type,v.name)==key then result[#result+1]=name;break end end
  end end
  table.sort(result);return result
end
function K.action(c,s,t)
  local a=t.action;local picker=s.ui_selector;local dirty=false
  if a=='production-add'then s.ui_selector={kind='product'}
  elseif a=='production-product'then s.ui_selector={kind='target',key=t.key}
  elseif a=='production-select-product'then
    if not entry(s,t.key)then
      local list=target_list(s);list[#list+1]=s.mode=='mall'and{key=t.key,stacks=1}or{key=t.key,rate=60};sync_targets(s,list);dirty=true
    end
    if s.decisions[t.key]and s.decisions[t.key].mode=='craft'then s.ui_selector={kind='target',key=t.key}
    else pick_recipe(c,s,t.key)end
  elseif a=='production-recipe'or a=='production-ingredient'then pick_recipe(c,s,t.key)
  elseif a=='production-machine'then
    local d=t.conversion and s.conversions[t.conversion]or s.decisions[t.key]
    if d and d.recipe then s.ui_selector={kind='machine',key=t.key,recipe=d.recipe,conversion=t.conversion,source=d.source,rate=d.rate or 60}
    else pick_recipe(c,s,t.key)end
  elseif a=='production-byproduct'then s.ui_selector={kind='byproduct',key=t.key}
  elseif a=='production-use'then
    pick_recipe(c,s,t.key,true);s.ui_selector.source=t.key
  elseif a=='production-export'then s.byproduct_exports[t.key]=true;s.ui_selector=nil;dirty=true
  elseif a=='production-unexport'then s.byproduct_exports[t.key]=nil;s.ui_selector=nil;dirty=true
  elseif a=='production-remove-target'then
    local list=target_list(s);for i=#list,1,-1 do if list[i].key==t.key then table.remove(list,i)end end
    sync_targets(s,list);s.ui_selector=nil;dirty=true
  elseif a=='production-remove-conversion'then table.remove(s.conversions,t.conversion);s.ui_selector={kind='byproduct',key=t.key};dirty=true
  elseif a=='production-external'then
    if M.is_target(s,t.key)then U.fail('target-external')end
    s.decisions[t.key]={mode='external'};s.ui_selector=nil;dirty=true
  elseif a=='production-select-recipe'then
    picker.recipe=t.recipe;picker.kind='machine';picker.query=nil
  elseif a=='production-select-machine'then
    if not picker or not picker.recipe then return false end
    local machines=C.machines(c,c.recipes[picker.recipe]);if not contains(machines,t.machine)then U.fail('machine',t.machine)end
    local current=picker.conversion and s.conversions[picker.conversion]or s.decisions[picker.key]
    local fuels=C.fuels(c,c.machines[t.machine]);local fuel=current and contains(fuels,current.fuel)and current.fuel or fuels[1]
    local d={mode='craft',recipe=picker.recipe,machine=t.machine,fuel=fuel}
    if picker.source then
      if not picker.rate or picker.rate<=0 or picker.rate>1000000 then U.fail('conversion-rate')end
      d.source=picker.source;d.rate=picker.rate
      local at=picker.conversion
      if not at then for i,r in ipairs(s.conversions)do if r.recipe==d.recipe and r.source==d.source then at=i;break end end end
      s.conversions[at or #s.conversions+1]=d
    else s.decisions[picker.key]=d end
    s.ui_selector=nil;dirty=true;K.prepare(c,s)
  elseif a=='production-cancel'then s.ui_selector=nil
  else return false end
  s.ui_tab='chain';s.phase='chain';return true,dirty
end
function K.changed(c,s,el)
  local a=el.tags.action
  if a=='production-picker-search'then
    if s.ui_selector then s.ui_selector.query=el.text end
    return true,false
  elseif a=='production-conversion-rate'then
    if s.ui_selector then s.ui_selector.rate=tonumber(el.text)end
    return true,false
  elseif a=='production-target-rate'then
    local target=entry(s,el.tags.key)
    if target then
      if s.mode=='mall'then target.stacks=tonumber(el.text)else target.rate=tonumber(el.text)end
      if target.key==s.target and s.mode~='mall'then s.rate=target.rate end
    end
    return true,true
  elseif a=='production-route-rate'then
    local route=s.conversions[el.tags.conversion];if route then route.rate=tonumber(el.text)end
    return true,true
  elseif a=='production-fuel'then
    local d=el.tags.conversion and s.conversions[el.tags.conversion]or s.decisions[el.tags.key]
    local fuels=d and C.fuels(c,c.machines[d.machine]);if fuels then d.fuel=fuels[el.selected_index]end
    return true,true
  end
end
local function process(model,d)
  local result
  if model and d and d.recipe then for _,node in ipairs(model.nodes)do if node.recipe==d.recipe and node.machine==d.machine then
    result=result or{count=0,input={},output={}}
    result.count=result.count+node.count
    for k,v in pairs(node.input)do U.add(result.input,U.base_key(k),v*node.crafts)end
    for k,v in pairs(node.output)do U.add(result.output,U.base_key(k),v*node.crafts)end
    if node.fuel then U.add(result.input,U.key('item',node.fuel),node.fuel_per_craft*node.crafts)end
  end end end
  return result
end
local function amounts(c,d)
  local inputs,outputs={},{};local r=d and c.recipes[d.recipe]
  if r then
    for _,v in ipairs(r.ingredients)do U.add(inputs,U.key(v.type,v.name),v.amount)end
    for _,v in ipairs(r.products)do U.add(outputs,U.key(v.type,v.name),U.expected(v))end
  end
  return inputs,outputs
end
local function rate_icons(parent,rates,action,calculated,extra)
  parent.clear()
  for _,key in ipairs(U.sorted(rates))do
    local b=icon(parent,key,action,calculated and rates[key]or nil,extra)
    b.tooltip={'',U.name(key),' · ',U.fmt(rates[key]),' ',T(calculated and'per-minute'or'chain-per-craft')}
  end
end
function K.filter(parent,c,s)
  if not parent or not parent.chain_list then return end
  local visible,total=0,0
  for _,wrapper in ipairs(parent.chain_list.children)do
    total=total+1;wrapper.visible=R.matches(select(2,U.split(wrapper.tags.key)),(s.ui_chain_names or{})[wrapper.tags.key],s.ui_chain_query or'')
    if wrapper.visible then visible=visible+1 end
  end
  parent.chain_count.caption=T('chain-showing',visible,total);parent.chain_empty.visible=visible==0
end
function K.picker_filter(parent,s)
  if not parent or not parent.production_picker or not parent.production_picker.picker_scroll then return end
  local query=s.ui_selector and s.ui_selector.query or''
  for _,b in ipairs(parent.production_picker.picker_scroll.picker_grid.children)do
    local key=b.tags.key;local name=b.tags.recipe or b.tags.machine or key and select(2,U.split(key))or''
    b.visible=R.matches(name,key and(s.ui_chain_names or{})[key],query)
  end
end
function K.statistics(parent,s,c)
  if not parent or not parent.chain_list then return end
  c=c or C.build(game.get_player(parent.player_index).force)
  local model=s.plan or s.ui_model;local inputs,byproducts={},{};local targetkeys={}
  for _,v in ipairs(M.targets(s))do if v.key then targetkeys[v.key]=true end end
  for _,wrapper in ipairs(parent.chain_list.children)do
    local key=wrapper.tags.key;local d=wrapper.tags.conversion and s.conversions[wrapper.tags.conversion]or s.decisions[key]
    local node=process(model,d);local req,out=amounts(c,d);if node then req=node.input;out=node.output end
    local main,side={},{}
    for k,v in pairs(out)do if k==key then main[k]=v else side[k]=v;if not targetkeys[k]then byproducts[k]=true end end end
    local row=wrapper.row
    row.machine.number=node and node.count or nil
    rate_icons(row.products,main,'production-ingredient',node~=nil)
    rate_icons(row.byproducts,side,'production-byproduct',node~=nil)
    rate_icons(row.ingredients,req,'production-ingredient',node~=nil)
    for k in pairs(req)do if not s.decisions[k]or s.decisions[k].mode=='external'then inputs[k]=true end end
  end
  local summary=parent.chain_summary
  local products=summary.products.chain_products;local sides=summary.byproducts.chain_byproducts;local feed=summary.inputs.chain_inputs
  products.clear();sides.clear();feed.clear()
  for _,target in ipairs(M.targets(s))do if target.key then
    local value=s.mode=='mall'and target.stacks or target.rate
    local b=icon(products,target.key,'production-product',value);b.tooltip={'',U.name(target.key),' · ',T(s.mode=='mall'and'products-stacks'or'per-minute')}
  end end
  for key in pairs(s.byproduct_exports)do if byproducts[key]then
    local f=model and model.flows[key];icon(products,key,'production-byproduct',f and f.surplus or nil)
  end end
  local add=button(products,'+','production-add');add.style.width=40;add.style.height=40;add.tooltip=T('add-target')
  local external={}
  if model then for _,port in ipairs(model.ports)do if port.kind=='in'then U.add(external,U.base_key(port.key),port.rate)end end
  else for key in pairs(inputs)do external[key]=0 end end
  for _,key in ipairs(U.sorted(external))do
    local b=icon(feed,key,'production-ingredient',model and external[key]or nil)
    b.tooltip={'',U.name(key),model and {'',' · ',U.fmt(external[key]),' ',T('per-minute')}or {'',' · ',T('production-rate-pending')}}
  end
  for _,key in ipairs(U.sorted(byproducts))do if not s.byproduct_exports[key]then
    local f=model and model.flows[key];local b=icon(sides,key,'production-byproduct',f and f.surplus or nil)
    b.tooltip={'',U.name(key),' · ',T('production-byproduct-hint')}
  end end
  parent.chain_model_error.caption=s.ui_model_error or'';parent.chain_model_error.visible=s.ui_model_error~=nil
end
local function picker(parent,c,s,width)
  local pick=s.ui_selector;if not pick then return end
  local panel=parent.add{type='frame',name='production_picker',index=3,direction='vertical',style='inside_shallow_frame'};panel.style.width=width-80
  local head=panel.add{type='flow'};label(head,T('production-pick-'..pick.kind)).style.font='heading-2'
  if pick.key then label(head,{'',U.icon(pick.key),' ',U.name(pick.key)})end
  button(head,'×','production-cancel')
  if pick.kind=='target'then
    local target=entry(s,pick.key);if target then
      local row=panel.add{type='flow'};label(row,T(s.mode=='mall'and'products-stacks'or'production-rate'))
      field(row,s.mode=='mall'and target.stacks or target.rate,'production-target-rate',{key=pick.key})
      button(row,T('production-change-recipe'),'production-recipe',{key=pick.key})
      button(row,T('remove-target'),'production-remove-target',{key=pick.key})
    end
    return
  elseif pick.kind=='byproduct'then
    label(panel,T('production-byproduct-hint'),width-110)
    local controls=panel.add{type='flow',direction=width<850 and'vertical'or'horizontal'}
    button(controls,T(s.byproduct_exports[pick.key]and'production-unexport'or'production-export'),s.byproduct_exports[pick.key]and'production-unexport'or'production-export',{key=pick.key})
    button(controls,T('production-use'),'production-use',{key=pick.key})
    for i,route in ipairs(s.conversions)do if route.source==pick.key then
      local row=panel.add{type='flow'};recipe_icon(row,route.recipe,'production-use',pick.key)
      label(row,T('production-source-rate'));field(row,route.rate,'production-route-rate',{conversion=i})
      button(row,T('remove-target'),'production-remove-conversion',{key=pick.key,conversion=i})
    end end
    return
  end
  if pick.source then
    local row=panel.add{type='flow'};label(row,T('production-source-rate'));field(row,pick.rate,'production-conversion-rate')
  end
  if (pick.kind=='recipe'or pick.kind=='machine')and not pick.source and not M.is_target(s,pick.key)then button(panel,T('external'),'production-external',{key=pick.key})end
  local search=panel.add{type='textfield',text=pick.query or'',tags={afp=true,action='production-picker-search'}};search.style.width=220;search.tooltip=T('chain-search')
  local scroll=panel.add{type='scroll-pane',name='picker_scroll',direction='vertical',horizontal_scroll_policy='never'}
  scroll.style.maximal_height=220;scroll.style.width=width-110
  local grid=scroll.add{type='table',name='picker_grid',column_count=math.max(1,math.floor((width-140)/44))}
  if pick.kind=='product'then
    for _,key in ipairs(U.sorted(c.by_product))do if (s.mode~='mall'or U.split(key)=='item')and #C.recipes(c,key,s.show_recycling)>0 then
      icon(grid,key,'production-select-product')
      if not(s.ui_chain_names or{})[key]and not(s.ui_chain_translation_names or{})[key]then
        s.ui_chain_names=s.ui_chain_names or{};s.ui_chain_translation_names=s.ui_chain_translation_names or{};s.ui_chain_translation_pending=s.ui_chain_translation_pending or{}
        local request=game.get_player(parent.player_index).request_translation(U.name(key));s.ui_chain_translation_pending[request]=key;s.ui_chain_translation_names[key]=true
      end
    end end
  elseif pick.kind=='recipe'or pick.kind=='conversion-recipe'then
    local recipes=pick.source and K.consumers(c,pick.key,s)or C.recipes(c,pick.key,s.show_recycling)
    for _,name in ipairs(recipes)do recipe_icon(grid,name,'production-select-recipe',pick.key)end
    if #recipes==0 then label(panel,T('production-no-recipes'),width-110)end
  elseif pick.kind=='machine'then
    for _,name in ipairs(C.machines(c,c.recipes[pick.recipe]))do
      local b=grid.add{type='sprite-button',sprite='entity/'..name,style='slot_button',tags={afp=true,action='production-select-machine',machine=name}}
      b.tooltip=c.machines[name].localised_name;b.style.width=40;b.style.height=40
    end
    local d=pick.conversion and s.conversions[pick.conversion]or s.decisions[pick.key]
    if d and d.machine then local fuels=C.fuels(c,c.machines[d.machine]);if #fuels>0 then
      local row=panel.add{type='flow'};label(row,T('fuel'));local items={};local selected=1
      for i,name in ipairs(fuels)do items[i]=prototypes.item[name].localised_name;if name==d.fuel then selected=i end end
      row.add{type='drop-down',items=items,selected_index=selected,tags={afp=true,action='production-fuel',key=pick.key,conversion=pick.conversion}}
    end end
  end
  K.picker_filter(parent,s)
end
function K.render(parent,p,c,s,width)
  K.prepare(c,s)
  if not parent.chain_summary then
    local modes=parent.add{type='flow',name='production_modes'}
    if s.project_id then
      local rate=button(modes,T('mode-rate'),'mode-rate',{name='rate'});rate.toggled=s.mode~='mall'
      local mall=button(modes,T('mode-mall'),'mode-mall',{name='mall'});mall.toggled=s.mode=='mall'
    end
    local summary=parent.add{type='flow',name='chain_summary',direction=width>=700 and'horizontal'or'vertical'}
    local weights={products=.34,byproducts=.28,inputs=.38};local headings={products='tab-products',byproducts='production-byproducts',inputs='chain-global-inputs'}
    for _,name in ipairs({'products','byproducts','inputs'})do
      local w=width>=700 and math.floor((width-96)*weights[name])or width-80
      local frame=summary.add{type='frame',name=name,direction='vertical',style='inside_shallow_frame'};frame.style.width=w;frame.style.padding=4
      label(frame,T(headings[name]),w-12).style.font='heading-2'
      frame.add{type='table',name='chain_'..name,column_count=math.max(1,math.floor((w-12)/44))}
    end
    local tools=parent.add{type='flow',name='chain_tools',direction=width<700 and'vertical'or'horizontal'}
    label(tools,T('chain-production')).style.font='heading-2'
    local search=tools.add{type='textfield',name='search',text=s.ui_chain_query or'',tags=tags('chain-search')};search.style.width=180;search.tooltip=T('chain-search')
    parent.add{type='checkbox',name='show_recycling',caption=T('chain-show-recycling'),state=s.show_recycling==true,tags=tags('show-recycling'),tooltip=T('chain-show-recycling-hint')}
    label(parent,'',width-70,'chain_count');label(parent,'',width-70,'chain_notice')
    local error=label(parent,'',width-70,'chain_model_error');error.style.font_color={1,.45,.3}
    parent.add{type='flow',name='chain_head'};parent.add{type='flow',name='chain_list',direction='vertical'}
    label(parent,T('production-empty'),width-70,'chain_empty')
    label(parent,T('production-hint'),width-70)
  end
  if parent.production_modes.rate then parent.production_modes.rate.toggled=s.mode~='mall';parent.production_modes.mall.toggled=s.mode=='mall'end
  parent.show_recycling.state=s.show_recycling==true
  if parent.production_picker then parent.production_picker.destroy()end
  -- Put the active chooser immediately below the summary, not inside a recipe row.
  picker(parent,c,s,width)
  parent.chain_head.clear();parent.chain_list.clear()
  local available=width-88;local rw,mw=52,56;local pw=math.max(44,math.floor((available-rw-mw-24)*.24));local sw=pw
  local iw=available-rw-mw-pw-sw-24
  for _,v in ipairs({{'recipe',rw},{'chain-machines',mw},{'tab-products',pw},{'production-byproducts',sw},{'ingredients',iw}})do label(parent.chain_head,T(v[1]),v[2]).style.font='default-bold'end
  local used={}
  local function row(key,d,conversion)
    if not d or d.mode~='craft'or not c.recipes[d.recipe]or not c.machines[d.machine]then return end
    local id=d.recipe..'/'..d.machine;if used[id]then return end;used[id]=true
    local wrap=parent.chain_list.add{type='frame',name=conversion and'conversion_'..conversion or key,direction='vertical',style='afp_chain_row',tags={key=key,conversion=conversion}};wrap.style.width=width-80
    local flow=wrap.add{type='flow',name='row'};flow.style.vertical_align='center';flow.style.horizontal_spacing=4
    local recipe=flow.add{type='flow'};recipe.style.width=rw
    local b=recipe_icon(recipe,d.recipe,'production-recipe',key);if conversion then b.tags={afp=true,action='production-byproduct',key=d.source}end
    local m=flow.add{type='sprite-button',name='machine',sprite='entity/'..d.machine,style='slot_button',tags={afp=true,action='production-machine',key=key,conversion=conversion}};m.style.width=mw;m.style.height=40;m.tooltip=c.machines[d.machine].localised_name
    for _,spec in ipairs({{'products',pw},{'byproducts',sw},{'ingredients',iw}})do
      local cell=flow.add{type='table',name=spec[1],column_count=math.max(1,math.floor(spec[2]/44))};cell.style.width=spec[2]
    end
    if conversion then
      local r=wrap.add{type='flow'};label(r,{'',U.icon(d.source),' ',T('production-source-rate')});field(r,d.rate,'production-route-rate',{conversion=conversion})
    end
  end
  for _,key in ipairs(K.resources(c,s))do row(key,s.decisions[key])end
  for i,d in ipairs(s.conversions)do local recipe=c.recipes[d.recipe];local product=recipe and recipe.products[1];if product then row(U.key(product.type,product.name),d,i)end end
  if s.mode=='mall'then
    -- Mall stock and chest selection share the same production screen.
    local chests=parent.mall_chests or parent.add{type='flow',name='mall_chests'};chests.clear()
    local items={T('automatic')};s.chest_options={false};local at=1
    for _,v in ipairs(Mall.chests(c))do items[#items+1]=v.localised_name;s.chest_options[#items]=v.name;if v.name==s.infrastructure.chest then at=#items end end
    label(chests,T('mall-chest'));chests.add{type='drop-down',items=items,selected_index=at,tags=tags('mall-chest')}
  elseif parent.mall_chests then parent.mall_chests.destroy()end
  if parent.production_unavailable then parent.production_unavailable.destroy()end
  local unavailable=M.unavailable(c,s)
  if #unavailable>0 then
    local warning=parent.add{type='flow',name='production_unavailable',direction='vertical',index=3}
    label(warning,T('mall-remove-unavailable-hint',#unavailable),width-100)
    button(warning,T('mall-remove-unavailable',#unavailable),'remove-unavailable')
  end
  parent.chain_notice.caption=s.ui_notice or'';parent.chain_notice.visible=s.ui_notice~=nil
  K.filter(parent,c,s);K.statistics(parent,s,c)
end
return K
