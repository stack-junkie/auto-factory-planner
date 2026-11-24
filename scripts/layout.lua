local U=require("scripts.util")
local C=require("scripts.catalogue")
local G=require("scripts.geometry")
local R=require("scripts.router")
local P=require("scripts.parallel")
local Progress=require("scripts.progress")
local A=require("scripts.arrangement")
local Rows=require("scripts.rows")
local Hierarchy=require("scripts.hierarchy")
local Compact=require("scripts.compact")
local I=require('scripts.inserters')
local Mall=require('scripts.mall')
local Paving=require('scripts.paving')
local MallLayout=require('scripts.mall_layout')
local Power=require('scripts.power')
local Inputs=require('scripts.inputs')
local LocalSupplies=require('scripts.local_supplies')
local InputDisplays=require('scripts.input_displays')
local Roboports=require('scripts.roboports')
local Pipes=require('scripts.pipes')
local FluidBoxes=require('scripts.fluid_boxes')
local FlowPlan=require('scripts.flow_plan')
local FlowLayout=require('scripts.flow_layout')
local RatePlan=require('scripts.rate_plan')
local LocalLayout=require('scripts.local_layout')
local Outputs=require('scripts.output_ports')
local Belts=require('scripts.belt_sizing')
local ManualPorts=require('scripts.manual_ports')
local Grid=require('scripts.grid')
local Frame=require('scripts.production_frame')
local CityBlocks=require('scripts.city_blocks')
local Compression=require('scripts.compression')
local CompressionSearch=require('scripts.compression_search')
local Central=require('scripts.central_spine')
local L={}
function L.prepare(c,s,plan)
  plan.compression_search=s.snap_grid==true
  -- Saved projects can still carry the old global equipment selectors.
  if s.infrastructure and not Belts.legacy(s)then s.infrastructure.belt=nil;s.infrastructure.underground=nil;s.infrastructure.splitter=nil end
  plan.factory_signature=U.factory_signature(s)
  if RatePlan.accepts(plan,s)then
    RatePlan.prepare(c,s,plan)
    local recipes={};for _,node in ipairs(plan.nodes)do recipes[node.recipe]=true end
    plan.single_recipe=#U.sorted(recipes)==1
    plan.perpendicular_rows=not plan.single_recipe and #plan.targets==1
    s._single_recipe=plan.perpendicular_rows
    return plan
  end
  s._single_recipe=nil
  if FlowPlan.accepts(plan,s)then return FlowPlan.prepare(c,s,plan)end
  return P.prepare(c,s,plan)
end
local function ends(p,cx,cy,d)
  local a={}
  for _,fb in pairs(p.fluidbox_prototypes) do
    for _,conn in ipairs(fb.pipe_connections) do if conn.connection_type=="normal" then
      local pos=conn.positions[d/4+1];local face=((conn.direction or 0)+d)%16/4
      a[#a+1]={x=math.floor(cx+pos.x+G.dx[face+1]),y=math.floor(cy+pos.y+G.dy[face+1]),
        face=face,box=fb.index,mode=conn.flow_direction or fb.production_type,filter=fb.filter and fb.filter.name}
    end end
  end;return a
end
local inserter_capacity=I.capacity
local adjacent_inserter=I.supported
L.inserter_supported=adjacent_inserter
local function latch(g,c,at,key,low,high,sensor,sensorconnector,gate)
  local proto=C.pick(c,"decider-combinator")
  local e=g:add(proto.name,at.x+0.5,at.y+1,0,{control_behavior={decider_conditions={
    conditions={{first_signal=U.signal(key),comparator="<",constant=low},
      {first_signal={type="virtual",name="signal-S"},comparator=">",constant=0,compare_type="or"},
      {first_signal=U.signal(key),comparator="<",constant=high,compare_type="and"}},
    outputs={{signal={type="virtual",name="signal-S"},copy_count_from_input=false,constant=1}}}}})
  g:wire(sensor,sensorconnector,e,defines.wire_connector_id.combinator_input_green)
  g:wire(e,defines.wire_connector_id.combinator_output_red,e,defines.wire_connector_id.combinator_input_red)
  g:wire(e,defines.wire_connector_id.combinator_output_green,gate,defines.wire_connector_id.circuit_green)
  return e
end
local function begin(c,s,plan,holder)
  if s.roboports or s.snap_grid then s._roboport_span=Grid.size(c,s)end
  local paving=Paving.validate(c,s);plan.paving_material=paving and paving.name;Paving.limit(s)
  if plan.rate_search then
    s._mall_compact_axes=true
    s._single_recipe=plan.perpendicular_rows
    local turns,mirror=A.orientation(s);plan.orientation={turns=turns,mirror=mirror};plan.width_axis=Paving.axis(s);plan.mall_compact_axes=true
    local overrides=s.infrastructure or{}
    local belt=C.pick(c,'transport-belt',plan.belt or overrides.belt)
    local function sufficient(p)return p.belt_speed>=belt.belt_speed end
    local function speed(p)return p.belt_speed end
    local equipment={belt=belt,underground=C.pick(c,'underground-belt',overrides.underground,sufficient,speed),splitter=C.pick(c,'splitter',overrides.splitter,sufficient,speed)}
    for key in pairs(plan.flows)do if U.split(key)=='fluid'then equipment.pipe=C.pick(c,'pipe',overrides.pipe);equipment.pipeug=C.pick(c,'pipe-to-ground',overrides.pipeug);break end end
    return LocalLayout.begin(c,s,plan,equipment,turns,mirror)
  end
  local g=G.new();local events={};local overrides=s.infrastructure or {};local maxrate=0;local hasitems=false
  s._mall_compact_axes=MallLayout.accepts(plan,s) and not s._legacy_orientation
  if MallLayout.accepts(plan,s)then MallLayout.prepare(c,s,plan);if not plan.rate_search then LocalSupplies.prepare(plan,s)end end
  local turns,mirror=A.orientation(s)
  plan.orientation={turns=turns,mirror=mirror};plan.width_axis=Paving.axis(s);plan.mall_compact_axes=s._mall_compact_axes and true or false
  Frame.prepare(s,plan,turns,mirror)
  if holder then holder.work={g=g,events=events,plan=plan,turns=turns,mirror=mirror} end
  if plan.flow_compact then return FlowLayout.begin(g,events,c,s,plan,turns,mirror)end
  for k,f in pairs(plan.flows) do if U.split(k)=="item" then hasitems=true;maxrate=math.max(maxrate,f.demand+f.fuel,f.supply) end end
  local belt,underground,splitter
  if hasitems or plan.rate_search then
    belt=C.pick(c,"transport-belt",plan.belt or overrides.belt,function(p) return p.belt_speed*28800>=maxrate-1e-6 end,function(p)return p.belt_speed end)
    underground=C.pick(c,"underground-belt",overrides.underground,function(p)return p.belt_speed>=belt.belt_speed end,function(p)return p.belt_speed end)
    splitter=C.pick(c,"splitter",overrides.splitter,function(p)return p.belt_speed>=belt.belt_speed end,function(p)return p.belt_speed end)
  end
  if MallLayout.accepts(plan,s) then
    local pipe,pipeug
    for key in pairs(plan.flows)do if U.split(key)=='fluid'then pipe=C.pick(c,'pipe',overrides.pipe);pipeug=C.pick(c,'pipe-to-ground',overrides.pipeug);break end end
    local work=MallLayout.begin(g,events,c,s,plan,{belt=belt,underground=underground,splitter=splitter,pipe=pipe,pipeug=pipeug},turns,mirror)
    if not work then U.fail('layout-ports')end
    return work
  end
  local ins=C.options(c,"inserter",function(p)return p.get_inserter_rotation_speed("normal") end)
  local usable={};for _,p in ipairs(ins) do if adjacent_inserter(p) and (not overrides.inserter or overrides.inserter==p.name) then usable[#usable+1]=p end end
  if hasitems and #usable==0 then U.fail("missing-infrastructure","inserter") end
  local ordinary_items=hasitems
  for key,flow in pairs(plan.flows) do if U.split(key)~='item' or flow.bootstrap or flow.controlled then ordinary_items=false end end
  local pipe,pipeug
  for k in pairs(plan.flows) do if U.split(k)=="fluid" then
    pipe=C.pick(c,"pipe",overrides.pipe);pipeug=C.pick(c,"pipe-to-ground",overrides.pipeug);break
  end end
  -- The recipe bus is perpendicular to the existing external main bus.
  A.order(plan)
  local projected={}
  local flowkeys=U.sorted(plan.flows)
  local connections={};local buses=A.rows(plan)
  local rowroutes={};plan.production_rows={}
  local machine_top=0;for _,b in pairs(buses) do machine_top=math.max(machine_top,b.y+b.below) end
  local function connect(k,port,produce,rate,x)
    local b=buses[k];local tap={x=x,port=port,produce=produce,key=k,rate=rate,bus='recipe',line=tonumber(port.id:match('^row/(%d+)/'))}
    b.taps[#b.taps+1]=tap;connections[#connections+1]=tap
  end
  local specs={}
  for _,node in ipairs(plan.nodes) do
    local p=c.machines[node.machine];local w,h=p.tile_width,p.tile_height
    local requirements={}
    for k,a in pairs(node.input) do if U.split(k)=="item" then requirements[#requirements+1]={key=k,amount=a,input=true} end end
    for k,a in pairs(node.output) do if U.split(k)=="item" then requirements[#requirements+1]={key=k,amount=a,input=false} end end
    local recipe=c.recipes[node.recipe];local ingredients,products=recipe.ingredients,recipe.products
    local fluidboxes=FluidBoxes.assign(p,ingredients,products)
    local function fluid_requirement(v,input)
      local box=fluidboxes and fluidboxes[v]
      if not box then U.fail("fluid-ports",p.localised_name) end
      local amount=v.amount
      if not input then local a,prob=U.expected(v);amount=a+math.max(0,a-(v.ignored_by_productivity or 0)*prob)*node.productivity end
      requirements[#requirements+1]={key=U.stream(U.key("fluid",v.name),node.section),amount=amount,input=input,box=box}
    end
    for _,v in ipairs(ingredients) do if v.type=="fluid" then fluid_requirement(v,true) end end
    for _,v in ipairs(products) do if v.type=="fluid" then fluid_requirement(v,false) end end
    if node.fuel then requirements[#requirements+1]={key=U.stream(U.key("item",node.fuel),node.section),amount=node.fuel_per_craft,input=true,fuel=true} end
    table.sort(requirements,function(a,b)return a.key==b.key and a.input and not b.input or a.key<b.key end)
    local chosen={}
    for _,req in ipairs(requirements) do if U.split(req.key)=="item" then
      local selected
      for _,v in ipairs(usable) do if inserter_capacity(v,c,req.key)>=req.amount*node.crafts/node.count-1e-6 then selected=v;break end end
      selected=selected or usable[#usable]
      node.count=math.max(node.count,math.ceil(req.amount*node.crafts/inserter_capacity(selected,c,req.key)-1e-8))
      chosen[req]=selected
    end end
    if node.count>300 then U.fail("too-large") end
    for _,req in ipairs(requirements) do if U.split(req.key)=="item" then
      for _,v in ipairs(usable) do if inserter_capacity(v,c,req.key)>=req.amount*node.crafts/node.count-1e-6 then chosen[req]=v;break end end
    end end
    local parallel
    if ordinary_items and not overrides.inserter then
      local short,long={},{}
      for _,v in ipairs(usable) do
        local pick=math.floor(-v.inserter_pickup_position[2]+0.5);local put=math.floor(v.inserter_drop_position[2]+0.5)
        if pick==1 and put==1 then short[#short+1]=v elseif pick==2 and put==2 then long[#long+1]=v end
      end
      local function select_arm(pool,group)
        local amount=0;for _,req in ipairs(group) do amount=amount+req.amount end
        local selected,capacity
        for _,v in ipairs(pool) do
          local rate=math.huge;for _,req in ipairs(group) do rate=math.min(rate,inserter_capacity(v,c,req.key)) end
          if not capacity or rate>capacity then selected,capacity=v,rate end
          if rate>=amount*node.crafts/node.count-1e-6 then selected,capacity=v,rate;break end
        end
        if selected then
          node.count=math.max(node.count,math.ceil(amount*node.crafts/capacity-1e-8))
          for _,req in ipairs(group) do chosen[req]=selected end
        end
        return selected
      end
      local inputs,outputs={},{}
      for _,req in ipairs(requirements) do local list=req.input and inputs or outputs;list[#list+1]=req end
      if #outputs==1 and #short>0 then
        -- Reach is a geometry requirement. Use a faster short arm on the
        -- adjacent return belt instead of adding an unnecessary long arm.
        if #inputs>=3 and #inputs<=4 and h>=3 and w>=2 and #long>0 then
          table.sort(inputs,function(a,b)return a.amount==b.amount and a.key<b.key or a.amount>b.amount end)
          local far={};for i=3,#inputs do far[#far+1]=inputs[i] end
          select_arm(long,far)
          parallel={near={inputs[1],inputs[2]},far=far}
        end
        for _,req in ipairs(requirements) do
          local distant=false;if parallel then for _,v in ipairs(parallel.far) do if req==v then distant=true end end end
          if not distant then select_arm(short,{req}) end
        end
        -- Re-evaluate at the final machine count; shared far feeds can need
        -- more machines, which also reduces the near/output arm requirement.
        for _,req in ipairs(requirements) do
          local distant=false;if parallel then for _,v in ipairs(parallel.far) do if req==v then distant=true end end end
          if not distant then select_arm(short,{req}) end
        end
      end
    end
    if node.count>300 then U.fail('too-large') end
    if node.mall_final and node.count>1 then U.fail('mall-final',c.recipes[node.recipe].localised_name) end
    local shared={}
    local function combine(group)
      if #group<2 then return end
      local amount=0;for _,req in ipairs(group) do amount=amount+req.amount end
      local selected
      for _,req in ipairs(group) do
        local candidate=chosen[req];local rate=math.huge;local compatible=true
        for _,member in ipairs(group) do
          local arm=chosen[member]
          if math.abs(candidate.inserter_pickup_position[2]-arm.inserter_pickup_position[2])>0.1
            or math.abs(candidate.inserter_drop_position[2]-arm.inserter_drop_position[2])>0.1 then compatible=false end
          rate=math.min(rate,inserter_capacity(candidate,c,member.key))
        end
        if compatible and rate>=amount*node.crafts/node.count-1e-6 and
          (not selected or candidate.get_inserter_rotation_speed('normal')<selected.get_inserter_rotation_speed('normal')) then selected=candidate end
      end
      if selected then
        local feed={requirements=group,inserter=selected}
        for _,req in ipairs(group) do shared[req]=feed end
      end
    end
    local item_inputs={}
    for _,req in ipairs(requirements) do if req.input and U.split(req.key)=='item' then item_inputs[#item_inputs+1]=req end end
    if parallel then combine(parallel.near)
    elseif #item_inputs>=2 and #item_inputs<=4 then
      combine({item_inputs[1],item_inputs[2]})
      if #item_inputs==4 then combine({item_inputs[3],item_inputs[4]}) end
    end
    local reach=2
    for _,v in pairs(chosen) do reach=math.max(reach,math.floor(-v.inserter_pickup_position[2]+0.5)+math.floor(v.inserter_drop_position[2]+0.5)) end
    specs[#specs+1]={node=node,prototype=p,requirements=requirements,chosen=chosen,shared=shared,parallel=parallel,reach=reach,recipe=c.recipes[node.recipe].localised_name}
  end
  if Compact.accepts(plan,specs,belt,underground) then
    return Compact.begin(g,events,c,s,plan,specs,{belt=belt,underground=underground,splitter=splitter},turns,mirror)
  end
  local cellx=4
  for _,spec in ipairs(specs) do
    local row_limit
    if Paving.axis(s)=='y'and Paving.limit(s)then
      local highest=0;for _,b in pairs(buses)do highest=math.min(highest,b.y-b.above)end
      local pitch=spec.prototype.tile_height+2*spec.reach+2*#spec.requirements+6
      row_limit=math.max(1,math.floor((Paving.limit(s)-(machine_top-highest)-24)/pitch))
    end
    cellx=Rows.build({g=g,x=cellx,y=machine_top+5,reach=spec.reach,belt=belt,splitter=splitter,pipe=pipe,pipeug=pipeug,shared=spec.shared,
      fluid_compact=pipe and not(s._legacy_layout or s._legacy_rate),
      row_limit=row_limit,
      ends=ends,connect=connect,events=events,local_routes=rowroutes,plan=plan,recipe=spec.recipe},spec.node,spec.prototype,spec.requirements,spec.chosen)
  end
  local port_x={}
  for k,b in pairs(buses) do
    local first,last=math.huge,-math.huge
    for _,tap in ipairs(b.taps) do first=math.min(first,tap.x);last=math.max(last,tap.x) end
    if first==math.huge then first,last=4,8 end
    b.import_x=first-4;b.export_x=last+4
    b.minx=first;b.maxx=last
    for _,port in ipairs(plan.ports) do if port.key==k then
      local x=port.kind=="in" and b.import_x or b.export_x;port_x[#port_x+1]=x
      b.minx=math.min(b.minx,x);b.maxx=math.max(b.maxx,x)
    end end
    if b.closed then b.minx=b.minx-2;b.maxx=b.maxx+2 end
  end
  table.sort(port_x)
  A.ports(plan,s,buses,port_x[math.ceil(#port_x/2)] or 4)
  Inputs.assign(s,plan);Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan)
  Mall.add(g,c,s,plan)
  for _,port in ipairs(plan.ports) do local p=port.staging_position or port.local_position
    local direction
    if port.kind=='in' then
      if port.staging_position then direction=0
      elseif U.split(port.key)=='item' then direction=port.pinned_direction or 1
      elseif not (s._project and s._project.offset) then direction=1 end
    elseif U.split(port.key)=='item' then direction=port.staging_position and 2 or 3 end
    projected[port.id]={x=p.x,y=p.y,plain=true,d=direction}
  end
  local length=cellx+2
  for _,p in pairs(projected) do length=math.max(length,p.x+3) end
  if pipe and length>300 then
    for _,k in ipairs(flowkeys) do if U.split(k)=="fluid" then U.fail("fluid-extent",U.name(k)) end end
  end

  for k,f in pairs(plan.flows) do
    local threshold=s.thresholds and (s.thresholds[k] or s.thresholds[U.base_key(k)])
    if threshold then
      f.low,f.high=threshold.low,threshold.high
      if not f.low or not f.high or f.low<0 or f.high<=f.low or f.low%1~=0 or f.high%1~=0 or f.high>2147483647 then U.fail("threshold",U.name(k)) end
      if U.split(k)=="item" and f.controlled then
        local b=buses[k]
        local required=math.ceil(f.high/(4*0.6)+#b.taps-1)
        b.maxx=math.max(b.maxx,b.minx+required)
      end
    else
      local seed=0;for _,n in ipairs(plan.nodes) do seed=seed+(n.input[k] or 0)*n.count end
      f.low=math.max(1,math.ceil(seed+f.demand/6));f.high=math.max(f.low+1,math.ceil(f.low+f.demand/6))
      if U.split(k)=="item" and buses[k].closed then
        -- Cover batches travelling through the shared production rows. Size
        -- real feedback storage for that reserve; ordinary buses stay straight.
        local b=buses[k]
        local travel_seconds=(2*g.maxy+16)/(belt.belt_speed*60)
        f.high=math.ceil(f.low+2*seed+math.min(f.internal,f.supply)*travel_seconds/60)
        b.maxx=math.max(b.maxx,b.minx+math.ceil(f.high/(4*0.6)+#b.taps-1))
      elseif U.split(k)=="item" and f.controlled then
        -- Straight streams can fill only part of a sensing lane before the
        -- export gate blocks it. Keep the automatic reserve below that fill.
        local b=buses[k];local capacity=math.max(3,math.floor((b.maxx-b.minx+1-#b.taps)*2*0.6))
        f.high=math.max(2,math.min(f.high,capacity));f.low=math.min(f.low,math.max(1,math.floor(f.high/2)))
      end
    end
  end
  local special={}
  -- Fluid reservoir branches are built before routing, so their footprints are obstacles.
  local function reservoir(k,port,export)
    local b=buses[k];local f=plan.flows[k];local x=export and -5 or 8;local y=b.y
    local tank=C.pick(c,"storage-tank",overrides.tank)
    local pump=C.pick(c,"pump",overrides.pump,function(p) return p.get_pumping_speed("normal")*3600>=port.rate end,function(p)return p.get_pumping_speed("normal") end)
    if tank.tile_height>5 then U.fail("fluid-ports",tank.localised_name) end
    local te=g:add(tank.name,x+tank.tile_width/2,y+3+tank.tile_height/2,0,nil,k)
    local a,z
    for _,q in ipairs(ends(tank,te.position.x,te.position.y,0)) do if q.face==0 then a=a or q elseif q.face==2 then z=z or q end end
    if not a or not z then U.fail("fluid-ports",tank.localised_name) end
    local dir=export and 8 or 0;local pp
    for _,q in ipairs(ends(pump,0,0,dir)) do if q.mode==(export and "input" or "output") then pp=q;break end end
    if not pp then U.fail("fluid-ports",pump.localised_name) end
    -- ends() rounds to tile indices; reconstruct the centre from the required pipe tile.
    local px,py=z.x-pp.x,z.y-pp.y
    if pump.tile_width%2==1 then px=px+0.5 end
    if (dir%8==4 and pump.tile_width or pump.tile_height)%2==1 then py=py+0.5 end
    local pe=g:add(pump.name,px,py,dir,{control_behavior={circuit_enabled=true,circuit_condition={first_signal=U.signal(k),comparator=export and ">" or "<",constant=export and f.high or f.low}}},k)
    local qoutside
    for _,q in ipairs(ends(pump,px,py,dir)) do if q.mode==(export and "output" or "input") then qoutside=q;break end end
    local id="reservoir/"..k..(export and "/out" or "/in")
    for _,q in ipairs({a,z,qoutside}) do g:reserve(q.x,q.y,id) end
    g:reserve(qoutside.x,qoutside.y,id,port.network)
    for n=1,4 do for side=-1,1 do
      local dx,dy=G.dx[qoutside.face+1],G.dy[qoutside.face+1]
      g:reserve(qoutside.x+dx*n-dy*side,qoutside.y+dy*n+dx*side,port.id,port.network)
    end end
    local volume=tank.fluidbox_prototypes[1].get_volume("normal")
    if f.high>=volume then U.fail("tank-threshold",U.name(k),volume) end
    if export then
      g:wire(te,defines.wire_connector_id.circuit_green,pe,defines.wire_connector_id.circuit_green)
    else
      pe.control_behavior={circuit_enabled=true,circuit_condition={first_signal={type="virtual",name="signal-S"},comparator=">",constant=0}}
      latch(g,c,{x=x+tank.tile_width+3,y=y+4},k,f.low,f.high,te,defines.wire_connector_id.circuit_green,pe)
    end
    special[#special+1]={key=k,from={x=math.max(0,a.x),y=y+1},to=a,id=id,bus_x=math.max(0,a.x)}
    special[#special+1]={key=k,from=z,to=z,id=id}
    special[#special+1]={key=k,from=export and qoutside or port,to=export and port or qoutside,id=port.id,network=port.network,bridge=pe.entity_number}
  end
  local portfirst=#g.entities+1
  for _,p in ipairs(plan.ports) do
    local point=projected[p.id];point.rate=p.rate;local b=buses[p.key];local kind=U.split(p.key)
    local reservoir_port=kind=="fluid" and (p.kind=="in" and plan.flows[p.key].recycle or p.kind=="out" and plan.flows[p.key].demand>0 and U.base_key(p.key)~=plan.target)
    point.network=reservoir_port and U.stream(p.key,1000000+p.index) or p.key
    local id="user/"..p.id;g:reserve(point.x,point.y,id,kind=="fluid" and point.network or nil);point.id=id
    -- Stagger the fan-out before the recipe bus. Two-tile external spacing
    -- alone leaves no turning room between adjacent fluid connections.
    for n=1,2 do g:reserve(point.x+(p.staging_position and 0 or n),point.y-(p.staging_position and n or 0),id,kind=="fluid" and point.network or nil) end
    if p.staging_position then for x=p.local_position.x,point.x do
      if kind=='fluid' then g:tile(pipe.name,x,p.local_position.y,0,nil,point.network)
      else g:tile(belt.name,x,p.local_position.y,p.kind=='in' and (x==point.x and 0 or 4) or 12,nil,p.key) end
    end end
    if kind=="item" then
      local x=p.kind=="in" and b.import_x or b.export_x
      local t={x=x,port=point,produce=p.kind=="in",key=p.key,external=p.kind=="in",export=p.kind=="out",rate=p.rate}
      b.taps[#b.taps+1]=t;connections[#connections+1]=t
    elseif reservoir_port then
      reservoir(p.key,point,p.kind=="out")
    else
      local x=0 -- Both ends of a pressure network can connect at its entrance.
      for n=1,2 do g:reserve(x,b.y+1+n,id,p.key) end
      special[#special+1]={key=p.key,from=p.kind=="in" and point or {x=x,y=b.y+1},to=p.kind=="in" and {x=x,y=b.y+1} or point,id=id,bus_x=x}
    end
  end
  events[#events+1]={stage="ports",first=portfirst,last=#g.entities}
  if not s._legacy_clearance then InputDisplays.reserve(c,s,g,plan)end
  for _,k in ipairs(flowkeys) do
    local first=#g.entities+1
    local b=buses[k];local kind=U.split(k);local y=b.y
    if kind=="item" then
      local skip={};for _,tap in ipairs(b.taps) do
        skip[tap.x]=true
        tap.splitter=g:add(splitter.name,tap.x+0.5,y+1,4,{
          input_priority=tap.produce and (tap.external and "left" or "right") or nil,
          output_priority=tap.produce and "left" or "right"},k)
      end
      for x=b.minx,b.maxx do
        if not skip[x] then b.sensors[#b.sensors+1]=g:tile(belt.name,x,y,b.closed and x==b.maxx and 0 or 4,nil,k) end
      end
      if b.closed then
        for yy=y-1,y-2,-1 do b.sensors[#b.sensors+1]=g:tile(belt.name,b.maxx,yy,0,nil,k) end
        for x=b.maxx,b.minx,-1 do b.sensors[#b.sensors+1]=g:tile(belt.name,x,y-3,x==b.minx and 8 or 12,nil,k) end
        for yy=y-2,y-1 do b.sensors[#b.sensors+1]=g:tile(belt.name,b.minx,yy,8,nil,k) end
      end
      local read=plan.flows[k].controlled
      if read then
        for i,e in ipairs(b.sensors) do
          e.control_behavior={circuit_read_hand_contents=true,circuit_contents_read_mode=defines.control_behavior.transport_belt.content_read_mode.hold}
          if i>1 then g:wire(b.sensors[i-1],defines.wire_connector_id.circuit_green,e,defines.wire_connector_id.circuit_green) end
        end
      end
    else
      local keep={};for _,tap in ipairs(b.taps)do keep[G.cell(tap.x,y)]=true end
      local lo,hi=b.minx,b.maxx
      for _,connection in ipairs(special)do if connection.key==k and connection.bus_x then
        local x=connection.bus_x;lo=math.min(lo,x);hi=math.max(hi,x);keep[G.cell(x,y)]=true
      end end
      if s._legacy_layout or s._legacy_rate then for x=0,length do g:tile(pipe.name,x,y,0,nil,k)end
      else Pipes.line(g,pipe,pipeug,lo,y,hi,y,k,keep)end
    end
    events[#events+1]={stage="recipe-bus",first=first,last=#g.entities,detail={"",U.icon(k)," ",U.name(k)}}
  end
  -- Route the closest terminals first; all future terminals remain reserved.
  for _,t in ipairs(connections) do if t.external and plan.flows[t.key].recycle then
    for y=buses[t.key].y+4,buses[t.key].y+5 do g:reserve(t.x-4,y,"logic/"..t.key) end
  end end
  for _,t in ipairs(connections) do
    local b=buses[t.key];local item=U.split(t.key)=="item"
    local stub={x=t.x+(item and (t.produce and -1 or 1) or 0),y=b.y+1,d=item and (t.produce and 1 or 2) or nil}
    g:reserve(stub.x,stub.y,t.port.id,not item and t.key or nil)
    if item then g:reserve(t.x+(t.produce and 1 or -1),b.y+1,"unused-splitter/"..t.key.."/"..t.x) end
    local from=t.produce and t.port or stub
    if item and from.d then for n=1,2 do
      g:reserve(from.x+G.dx[from.d+1]*n,from.y+G.dy[from.d+1]*n,t.port.id)
    end end
  end
  for _,t in ipairs(special) do
    for _,p in ipairs({t.from,t.to}) do
      if not g.reserved[G.cell(p.x,p.y)] then g:reserve(p.x,p.y,t.id,t.network or t.key) end
    end
  end
  Hierarchy.describe(plan,buses,length,s)
  for _,a in ipairs(connections) do
    a.crowding=0
    if U.split(a.key)=="fluid" then for _,b in ipairs(connections) do if a~=b and U.split(b.key)=="fluid" then
      local distance=math.abs(a.port.x-b.port.x)+math.abs(a.port.y-b.port.y)
      if distance>0 and distance<=4 then a.crowding=a.crowding+1/distance end
    end end end
  end
  table.sort(connections,function(a,b)
    local af,bf=U.split(a.key)=="fluid",U.split(b.key)=="fluid"
    if af~=bf then return af end
    if a.crowding~=b.crowding then return a.crowding>b.crowding end
    return a.x<b.x
  end)
  local main_bus_taps=#connections
  local allroutes={}
  -- Complete all fluid paths before item belts can enclose their corridors.
  for _,list in ipairs({rowroutes,connections}) do for _,t in ipairs(list) do if U.split(t.key)=='fluid' then allroutes[#allroutes+1]=t end end end
  for _,t in ipairs(special) do t.direct_route=true;allroutes[#allroutes+1]=t end
  for _,list in ipairs({rowroutes,connections}) do for _,t in ipairs(list) do if U.split(t.key)=='item' then allroutes[#allroutes+1]=t end end end
  special={}
  connections=allroutes
  plan.layout_revision=32;plan.layout_stats={closed_buses=0,straight_buses=0,production_rows=#plan.production_rows,
    recipe_bus_taps=main_bus_taps,main_bus_taps=0,external_interfaces=#plan.ports,hierarchy_levels=3,generated_main_bus_entities=0}
  for k,b in pairs(buses) do if U.split(k)=="item" then
    local key=b.closed and "closed_buses" or "straight_buses";plan.layout_stats[key]=plan.layout_stats[key]+1
  end end
  return {g=g,plan=plan,events=events,connections=connections,special=special,buses=buses,turns=turns,mirror=mirror,
    equipment={belt=belt and belt.name,underground=underground and underground.name,splitter=splitter and splitter.name,pipe=pipe and pipe.name,pipeug=pipeug and pipeug.name},
    connection_index=1,special_index=1,stage="routes"}
end
function L.begin(c,s,plan,holder)
  return begin(c,s,plan,holder)
end
local function complete_route(c,w,t,made)
  local g,b=w.g,w.buses[t.key];local plan=w.plan
    if t.external and plan.flows[t.key].recycle then
      local gate=made[#made];local f=plan.flows[t.key]
      gate.control_behavior={circuit_enabled=true,circuit_condition={first_signal={type="virtual",name="signal-S"},comparator=">",constant=0}}
      local sensor
      for _,e in ipairs(b.sensors) do if math.abs(e.position.x-t.x)<3 and e.position.y>b.y-1 then sensor=e;break end end
      latch(g,c,{x=t.x-4,y=b.y+4},t.key,f.low,f.high,sensor,defines.wire_connector_id.circuit_green,gate)
    elseif t.export and plan.flows[t.key].controlled then
      local gate=made[1];local f=plan.flows[t.key];local sensor
      for _,e in ipairs(b.sensors) do if math.abs(e.position.x-t.x)<3 and e.position.y>b.y-1 then sensor=e;break end end
      gate.control_behavior={circuit_enabled=true,circuit_condition={first_signal=U.signal(t.key),comparator=">",constant=f.high}}
      g:wire(sensor,defines.wire_connector_id.circuit_green,gate,defines.wire_connector_id.circuit_green)
    end
end
local function finish(c,s,w)
  local g,plan,overrides,turns,mirror=w.g,w.plan,s.infrastructure or {},w.turns,w.mirror
  -- Final connections can turn an already displayed socket, and belt sizing
  -- can replace its prototype. Redraw any earlier geometry that changed.
  local displayed={}
  for i,e in ipairs(g.entities)do displayed[i]={e.name,e.position.x,e.position.y,e.direction or 0,e.type,e.mirror}end
  if plan.rate_search and not g:item_edges_valid()then U.fail('layout-ports')end
  local belt=w.equipment.belt and prototypes.entity[w.equipment.belt]
  local underground=w.equipment.underground and prototypes.entity[w.equipment.underground]
  local splitter=w.equipment.splitter and prototypes.entity[w.equipment.splitter]
  local pipe=w.equipment.pipe and prototypes.entity[w.equipment.pipe]
  local projected={};for _,port in ipairs(plan.ports) do projected[port.id]=port.local_position end
  local first=#g.entities+1
  Mall.add(g,c,s,plan)
  InputDisplays.add(c,s,g,plan)
  local limit=Paving.limit(s)
  if limit and Paving.span(s,g)>limit then
    if g.debug_layout then helpers.write_file('width-failure.json',helpers.table_to_json{entities=g.entities,axis=Paving.axis(s),bounds={g.minx,g.miny,g.maxx,g.maxy},header=plan.intake_header_offset,inputs=plan.ports,context=s._project},false)end
    U.fail('width',Paving.span(s,g)+Paving.margin(s)*2,Paving.maximum(s))
  end
  Frame.align(c,s,g,plan,turns,mirror)
  local pole=w.power and prototypes.entity[w.power] or Power.add(c,s,g,plan)
  if pipe then
    local bounds={}
    for _,e in ipairs(g.entities) do local marker=g.occupied[G.cell(math.floor(e.position.x),math.floor(e.position.y))]
      if marker and marker.fluid then local k=marker.fluid;local b=bounds[k] or {e.position.x,e.position.y,e.position.x,e.position.y};bounds[k]=b
        b[1]=math.min(b[1],e.position.x);b[2]=math.min(b[2],e.position.y);b[3]=math.max(b[3],e.position.x);b[4]=math.max(b[4],e.position.y)
      end
    end
    for k,b in pairs(bounds) do if b[3]-b[1]>300 or b[4]-b[2]>300 then U.fail("fluid-extent",U.name(k)) end end
  end
  for _,port in ipairs(plan.ports) do
    local p=projected[port.id];local marker=g.occupied[G.cell(p.x,p.y)]
    if not marker then U.fail("port",U.name(port.key))end
    marker.entity.tags=marker.entity.tags or {};marker.entity.tags.afp_port={id=port.id,key=U.base_key(port.key),kind=port.kind,rate=port.rate,section=port.section or 1,index=port.index}
  end
  plan.local_bounds={x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy}
  if limit and Paving.span(s,g)>limit then U.fail('width',Paving.span(s,g)+Paving.margin(s)*2,Paving.maximum(s)) end
  CityBlocks.prepare(c,s,g,plan,turns,mirror)
  g.plot_front_body=nil
  Paving.add(g,s,plan,turns,mirror)
  Outputs.extend(g,plan,belt,turns,mirror)
  if plan.rate_search and not g:item_edges_valid()then U.fail('layout-ports')end
  Inputs.finish(g,s,plan)
  if plan.layout_stats.folded_items or s.snap_grid then
    -- Score intrinsic transport before attaching selected world sockets.
    -- Underground spans cost their full length, including hidden belt cells.
    local objects=#g.entities
    for _,t in ipairs(g.tunnels)do if t.kind=='item'then objects=objects+t.hi-t.lo-1 end end
    plan.layout_stats.intrinsic_objects=objects
  end
  local electric_before_manual=#g.electric
  if Outputs.reverse_collectors(s,g,plan)then w.restarted=true end
  Outputs.gateways(s,g,plan,turns,mirror)
  local manual=ManualPorts.apply(c,s,g,plan,w.equipment,w)
  if not s.roboports and #g.electric>electric_before_manual then Power.add(c,s,g,plan,true)end
  if s.roboports and Grid.available(c,s)then
    g.plot_front=nil
    -- Coverage belongs to the production plot and its selected connections,
    -- never to the growing bounding box of service buildings and relay poles.
    plan.roboport_bounds=plan.city_blocks and U.copy(plan.city_blocks.bounds)or{x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy}
    plan.project_offset=plan.project_offset or (s._project and
      Inputs.offset(s._project.origin,s,plan.local_bounds,plan.orientation))
    if Paving.grid_roads(s)and not plan.grid_front then
      local axis=Paving.axis(s)=='x'and'y'or'x';local step=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
      local line=phase[axis]+math.floor((plan.production_bounds[axis..'0']-Paving.road_width/2-phase[axis])/step)*step
      plan.grid_front={axis=axis,line=line,value=line+Paving.road_width/2}
    end
    Roboports.release(g)
    Roboports.add(c,s,g,plan,turns,mirror)
    Progress.event(w,'roboports',first);first=#g.entities+1
    Power.add(c,s,g,plan,true)
    Paving.add_grid_roads(c,g,s,plan,turns,mirror)
    if not Roboports.covered(g,plan)then U.fail('roboport-space',prototypes.entity[plan.roboport_prototype].localised_name)end
  elseif s.snap_grid then
    g.plot_front=nil
    Roboports.release(g)
    plan.roboports={}
    Roboports.plan_grid(c,s,g,plan,turns,mirror)
    Paving.add_grid_roads(c,g,s,plan,turns,mirror)
  end
  if manual or s.roboports or s.snap_grid then
    plan.local_bounds={x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy}
    if not s.roboports and not s.snap_grid and limit and Paving.span(s,g)>limit then U.fail('width',Paving.span(s,g),Paving.maximum(s))end
  end
  -- Historical geometry is reconstructed verbatim to recover placed projects.
  -- Equipment changes belong to the new plan, after that positional recovery.
  if not Belts.legacy(s)then Belts.apply(c,g,plan);plan.layout_revision=plan.rate_search and 86 or 62 end
  if plan.rate_search then
    plan.transport_pairs={}
    for _,t in ipairs(g.tunnels)do
      local a=g.occupied[G.cell(t.horizontal and t.lo or t.x,t.horizontal and t.y or t.lo)]
      local b=g.occupied[G.cell(t.horizontal and t.hi or t.x,t.horizontal and t.y or t.hi)]
      if a and b then plan.transport_pairs[#plan.transport_pairs+1]={a=a.entity.entity_number,b=b.entity.entity_number,kind=t.kind}end
    end
  end
  Progress.event(w,"power",first)
  for i,old in ipairs(displayed)do local e=g.entities[i]
    if old[1]~=e.name or old[2]~=e.position.x or old[3]~=e.position.y or old[4]~=(e.direction or 0)or old[5]~=e.type or old[6]~=e.mirror then w.restarted=true;break end
  end
  g:transform(turns,mirror);w.transformed=true
  local counts={};for _,e in ipairs(g.entities) do U.add(counts,e.name,1) end
  plan.entities=g.entities;plan.counts=counts;plan.bounds={width=g.maxx-g.minx,height=g.maxy-g.miny}
  if turns%2==1 then plan.bounds.width,plan.bounds.height=plan.bounds.height,plan.bounds.width end
  plan.infrastructure={belt=belt and belt.name,underground=underground and underground.name,splitter=splitter and splitter.name,pole=pole.name,roboport=plan.roboport_prototype}
  plan.layout_signature=U.layout_signature(s)
  plan.layout_strategy=plan.flow_compact and'flow'or plan.layout_stats.rate_local and'shared'or'generic'
  w.stage="compression"
  w.route_base=nil;w.route_priorities=nil
  return plan
end
function L.advance(c,s,w,budget)
  if w.stage=="done" then return true end
  if w.stage=="power" then finish(c,s,w);return false end
  if w.stage=='compression'then
    local m=Compression.evaluate(w.plan,s)
    local detail=m and{'afp.compression-result',m.units,m.columns,m.rows,U.fmt(m.perimeter),U.fmt(m.area),m.objects,U.fmt(m.cost),U.fmt(m.unit_cost)}or nil
    Progress.event(w,'compression',#w.g.entities+1,detail)
    w.stage='done';return false
  end
  local t=w.connections[w.connection_index];local special=false
  if not t then t=w.special[w.special_index];special=true end
  if not t then w.stage="power";return false end
  if not w.search then
    local kind=U.split(t.key);local from,to
    if special or t.local_route or t.direct_route then from,to=t.from,t.to
    else
      local b=w.buses[t.key]
      local stub=kind=="item" and {x=t.x+(t.produce and -1 or 1),y=b.y+1,d=t.produce and 1 or 2,plain=w.plan.flows[t.key].controlled} or {x=t.x,y=b.y+1}
      local outward=t.produce or kind=="fluid";from=outward and t.port or stub;to=outward and stub or t.port
    end
    w.search=R.begin(from,to,kind,t.key,prototypes.entity[kind=="item" and w.equipment.belt or w.equipment.pipe],
      prototypes.entity[kind=="item" and(w.plan.balanced_underground and w.plan.balanced_underground[t.key]or w.equipment.underground)or w.equipment.pipeug],(special or t.local_route or t.direct_route) and t.id or t.port.id,t.local_route and kind=="fluid",(special or t.direct_route) and t.network,(special or t.direct_route) and t.bridge)
    if kind=='item'and w.plan.manual_keys and w.plan.manual_keys[t.key]then R.manual(w.search,w.plan.manual_corridor)end
    if w.plan.rate_search then w.search.limit=w.plan.layout_stats.local_network and 40000 or s._shape_rows=='double'and 12000 or 40000 end
    if t.bounds then
      w.search.minx=t.bounds.x0;w.search.maxx=t.bounds.x1;w.search.miny=t.bounds.y0;w.search.maxy=t.bounds.y1
    end
    if w.route_bounds and not t.local_route then
      if w.plan.layout_stats.local_network then
        -- Short underground belts cannot cross a whole dense production row.
        -- Let them go around its ends, even when both terminals are near its centre.
        w.search.minx=w.route_bounds.x0;w.search.maxx=w.route_bounds.x1
        w.search.miny=w.route_bounds.y0;w.search.maxy=w.route_bounds.y1
      else
        w.search.minx=math.max(w.search.minx,w.route_bounds.x0);w.search.maxx=math.min(w.search.maxx,w.route_bounds.x1)
        w.search.miny=math.max(w.search.miny,w.route_bounds.y0);w.search.maxy=math.min(w.search.maxy,w.route_bounds.y1)
      end
    elseif not t.local_route and(not s._project or not s._project.offset)then w.search.miny=math.max(w.search.miny,w.plan.bus_hierarchy.recipe.bounds.y0-9) end
    if kind=='item'and w.plan.manual_keys and w.plan.manual_keys[t.key]then
      w.search.minx=math.min(w.search.minx,from.x-4,to.x-4);w.search.maxx=math.max(w.search.maxx,from.x+4,to.x+4)
      w.search.miny=math.min(w.search.miny,from.y-4,to.y-4);w.search.maxy=math.max(w.search.maxy,from.y+4,to.y+4)
    end
    if t.straight_route then
      assert(from.y==to.y,'Straight branch endpoints are not aligned')
      w.search.miny=from.y;w.search.maxy=from.y
    end
    if t.vertical_route then w.search.minx=from.x;w.search.maxx=from.x end
    w.route_first=#w.g.entities+1
  end
  local ok,advanced=pcall(R.advance,w.g,w.search,budget or 128)
  if not ok then
    if type(advanced)=='table'and advanced[1]=='afp-error.route'and LocalLayout.retry(w)then return false end
    error(advanced,0)
  end
  if not advanced then return false end
  local search=w.search;local made=R.build(w.g,search)
  if not special and not t.local_route and not t.direct_route then complete_route(c,w,t,made) end
  Progress.event(w,t.stage or "routes",w.route_first,{"",U.icon(t.key)," ",U.name(t.key)},search.from,search.to)
  w.search=nil
  if special then w.special_index=w.special_index+1 else w.connection_index=w.connection_index+1 end
  return false
end
local function generate(c,s,plan)
  local w=L.begin(c,s,plan)
  while not L.advance(c,s,w,4096) do end
  return w.plan
end
function L.compression_begin(base,settings,plan)
  return CompressionSearch.begin(base,settings,plan)
end
function L.compression_advance(c,state,budget)
  if state.done then return true end
  if not state.trial then
    local settings=CompressionSearch.next(state)
    if not settings then return true end
    state.trial_settings=settings
    local ok,work=pcall(L.begin,c,settings,U.copy(state.base))
    if not ok then
      if type(work)~='table'then error(work,0)end
      CompressionSearch.observe(state,nil,work);return false
    end
    state.trial=work;return false
  end
  local ok,done=pcall(L.advance,c,state.trial_settings,state.trial,budget or 128)
  if not ok then
    if type(done)~='table'then error(done,0)end
    CompressionSearch.observe(state,nil,done)
  elseif done then CompressionSearch.observe(state,state.trial.plan)end
  return false
end
function L.compression_finish(state)return CompressionSearch.finish(state)end

function L.candidate_settings(s,candidate)
  local settings=U.copy(s);settings.infrastructure=U.copy(s.infrastructure or{})
  if type(candidate)=='table'then
    if candidate.underground then settings.infrastructure.underground=candidate.underground end
    if candidate.pole then
      settings._automatic_pole=not(s.infrastructure and s.infrastructure.pole)
      settings.infrastructure.pole=candidate.pole
    end
    settings._shape_rows=candidate.rows
    settings._intermediate_bank=candidate.intermediate_bank
    settings._central_spine=candidate.central_spine
    settings._central_transverse=candidate.central_transverse
    settings._spine_swap=candidate.spine_swap
  elseif candidate then settings.infrastructure.underground=candidate end
  return settings
end
function L.score(plan)
  if plan.city_blocks and plan.compression then return Compression.score(plan)end
  if plan.fixed_production_bounds then
    -- External routes must not choose a different production arrangement.
    local b=plan.fixed_production_bounds
    local ports=0
    if plan.roboport_prototype and plan.grid_front then
      local prototype=prototypes.entity[plan.roboport_prototype]
      local rows=math.max(2,math.ceil((b.y1-plan.grid_front.line-prototype.construction_radius)/(prototype.logistic_radius*2))+1)
      ports=2*rows
    end
    local shape=(b.x1-b.x0)*(b.y1-b.y0)
    -- Area alone favours a narrow strip with every dependency stacked in
    -- one column, undoing the shorter arrangement selected inside each part.
    if plan.layout_stats.folded_items then shape=shape+20*(b.y1-b.y0)end
    if plan.layout_stats.folded_items then return{ports,shape,plan.layout_stats.intrinsic_objects or 0,#plan.production_rows}end
    return{ports,shape,#plan.production_rows}
  end
  return {#(plan.roboports or{}),plan.bounds.width*plan.bounds.height,#plan.entities}
end
function L.current(plan)return plan.layout_revision==(plan.rate_search and 86 or 62)end
function L.better(a,b)
  if not b then return true end
  local x,y=L.score(a),L.score(b)
  for i=1,#x do if x[i]~=y[i]then return x[i]<y[i]end end
  return false
end

function L.generate(c,s,plan)
  L.prepare(c,s,plan)
  local candidates=L.candidates(c,s,plan)
  local last,best,best_settings,attempts=nil,nil,nil,0
  for _,name in ipairs(candidates) do
    local settings=L.candidate_settings(s,name)
    local attempt=U.copy(plan)
    local ok,result=pcall(generate,c,settings,attempt)
    if ok then
      result.layout_signature=U.layout_signature(s)
      attempts=attempts+1
      if not plan.rate_search and not plan.compression_search then for k in pairs(plan) do plan[k]=nil end;for k,v in pairs(result) do plan[k]=v end;return plan end
      if L.better(result,best)then best=result;best_settings=settings end
    end
    if not ok and s._debug_layout then log('AFP CANDIDATE FAILED '..serpent.line{name=name,error=result})end
    last=result
    if not ok and(type(result)~='table'or not plan.rate_search and not plan.compression_search and(result[1]~="afp-error.route" and result[1]~="afp-error.layout-overlap" and result[1]~="afp-error.infrastructure"and result[1]~='afp-error.belt-flow'and result[1]~='afp-error.power'))then break end
  end
  if best then
    if not s._skip_compression then
      local state=L.compression_begin(plan,best_settings,best)
      while not L.compression_advance(c,state,4096)do end
      best=L.compression_finish(state)
    end
    best.layout_stats.search_attempts=#candidates;best.layout_stats.valid_candidates=attempts
    for k in pairs(plan)do plan[k]=nil end;for k,v in pairs(best)do plan[k]=v end;return plan
  end
  error(last,0)
end
function L.candidates(c,s,plan)
  local hasitems=false;for k in pairs(plan.flows) do if U.split(k)=="item" then hasitems=true end end
  local result={false}
  if hasitems and not(s.infrastructure and s.infrastructure.underground)then
    result={};for _,p in ipairs(C.options(c,"underground-belt",function(v)return v.belt_speed end)) do result[#result+1]=p.name end
  end
  if #result==0 then U.fail("missing-infrastructure","underground-belt") end
  if plan.rate_search then
    if not(s.infrastructure and s.infrastructure.underground)and plan.belt then
      local matching={};local speed=prototypes.entity[plan.belt].belt_speed
      for _,name in ipairs(result)do if name and prototypes.entity[name].belt_speed>=speed then matching[#matching+1]=name end end
      if #matching>0 then result=matching end
    end
    local pole
    if not(s.infrastructure and s.infrastructure.pole)then
      for _,p in ipairs(C.options(c,'electric-pole',function(v)return v.get_supply_area_distance('normal')end))do
        if p.tile_width==1 and p.tile_height==1 then pole=p.name end
      end
    end
    local finals={};for _,target in ipairs(plan.targets)do finals[target.key]=true end
    local split_intermediates=false
    for _,node in ipairs(plan.nodes)do if node.count>14 then
      local final=false;for key in pairs(node.output)do if finals[key]then final=true end end
      if not final then split_intermediates=true end
    end end
    for key in pairs(plan.flows)do if U.split(key)=='fluid'then split_intermediates=false;break end end
    local shapes={};for _,underground in ipairs(result)do
      local profiles={'single','auto','double'}
      local selected=underground or s.infrastructure and s.infrastructure.underground
      if selected and prototypes.entity[selected].max_underground_distance<=5 and not plan.single_recipe then table.insert(profiles,1,'spaced')end
      for _,rows in ipairs(profiles)do shapes[#shapes+1]={underground=underground or nil,rows=rows,pole=pole}end
      if s.snap_grid and s.growth_direction and s.input_rows~='single'and #plan.targets==1 then
        local belt=prototypes.entity[plan.belt or'transport-belt'];local eligible=false
        for _,n in ipairs(plan.nodes)do if n.output[plan.targets[1].key]and Central.spec(c,s,n,belt)then eligible=true end end
        if eligible then for _,transverse in ipairs({false,true,'corner'})do for _,swap in ipairs({false,true})do
          shapes[#shapes+1]={underground=underground or nil,rows='single',pole=pole,central_spine=true,central_transverse=transverse,spine_swap=swap}
        end end end
      end
      if split_intermediates and s.snap_grid and s.growth_direction then
        for _,rows in ipairs({'single','auto'})do shapes[#shapes+1]={underground=underground or nil,rows=rows,pole=pole,intermediate_bank=14}end
      end
    end
    return shapes
  end
  return result
end
return L
