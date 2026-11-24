local U=require('scripts.util')
local C=require('scripts.catalogue')
local G=require('scripts.geometry')
local I=require('scripts.inserters')
local Flow=require('scripts.flow_plan')
local Cells=require('scripts.flow_cells')
local Bus=require('scripts.bus')
local Intake=require('scripts.intake')
local Inputs=require('scripts.inputs')
local Displays=require('scripts.input_displays')
local Paving=require('scripts.paving')
local Pipes=require('scripts.pipes')
local Layout={}
local eps=1e-6
local function translate(p,dx,dy)p.x=p.x+dx;p.y=p.y+dy end
function Layout.begin(g,events,c,s,plan,turns,mirror)
  local overrides=s.infrastructure or{}
  local belt=C.pick(c,'transport-belt',plan.belt,nil,function(p)return p.belt_speed end)
  local underground=C.pick(c,'underground-belt',overrides.underground,function(p)return p.belt_speed>=belt.belt_speed end,function(p)return p.belt_speed end)
  local splitter=C.pick(c,'splitter',overrides.splitter,function(p)return p.belt_speed>=belt.belt_speed end,function(p)return p.belt_speed end)
  local pipe=C.pick(c,'pipe',overrides.pipe);local pipeug=C.pick(c,'pipe-to-ground',overrides.pipeug)
  local equipment={belt=belt,underground=underground,splitter=splitter,pipe=pipe,pipeug=pipeug}
  equipment.input_capacity={}
  for key,f in pairs(plan.flows)do equipment.input_capacity[key]=f.supply>eps and belt.belt_speed*14400*.8 or belt.belt_speed*28800 end
  local pool={}
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+.5)==1 and math.floor(p.inserter_drop_position[2]+.5)==1
      and(not overrides.inserter or overrides.inserter==p.name)then pool[#pool+1]=p end
  end
  if #pool==0 then U.fail('missing-infrastructure','inserter')end
  local order=Intake.order(s,plan);local rank={};for i,key in ipairs(order)do rank[key]=i end
  local socket_rank=U.copy(rank)
  local groups=Flow.groups(c,s,plan,pool)
  local physical={};for key in pairs(plan.flows)do if U.split(key)=='item'and not plan.local_items[key]then physical[#physical+1]=key end end
  local initial=Bus.pack(plan,physical,order)
  for key,p in pairs(initial)do rank[key]=p.position end
  for _,group in ipairs(groups)do for j,key in ipairs(U.sorted(group.local_keys))do rank[key]=100000+j end end
  local limit=Paving.limit(s);local maximum=math.max(1,math.min(16,math.floor(((limit or 216)-76)/6)))
  local connections,terminals={},{}
  plan.production_rows={};plan.production_groups={};plan.mall_buffers={};plan.mall_links={};plan.cell_links={};plan.lane_balancers={}
  plan.feed_branches={};plan.feed_corridors={};plan.transport_lanes={};plan.recipe_bus_order=U.copy(order)
  local cursor,underpasses,side_fluids=12,0,0
  local local_rows={};local miny=0;local local_depth=0
  for _,group in ipairs(groups)do
    local direct={};for _,spec in ipairs(group.direct)do direct[spec.key]=true end
    local y=4
    for _,key in ipairs(U.sorted(group.local_keys))do if not direct[key]then
      local f=plan.flows[key];local lanes=math.max(1,math.ceil(f.supply/(belt.belt_speed*14400*.8)-1e-8))
      local_rows[key]={y=y};local_depth=math.max(local_depth,y+2*(lanes-1));y=y+2*lanes+2
    end end
  end
  local body_top=math.max(18,local_depth+8)
  for gi,group in ipairs(groups)do
    local parts,used,units,producer={},{},{},{}
    for _,spec in ipairs(group.direct)do
      units[#units+1]={nodes={spec.source,spec.target},direct=spec}
      used[spec.source.id]=true;used[spec.target.id]=true
    end
    for _,node in ipairs(group.nodes)do if not used[node.id]then units[#units+1]={nodes={node}}end end
    for i,unit in ipairs(units)do for _,n in ipairs(unit.nodes)do for key in pairs(n.output)do producer[key]=i end end end
    local done={}
    local function build(i)
      if done[i]then return end;done[i]=true
      local unit=units[i]
      for _,n in ipairs(unit.nodes)do for key in pairs(n.input)do local source=producer[key];if source and source~=i then build(source)end end end
      if unit.direct then for _,part in ipairs(Cells.direct(c,s,unit.direct,pool,equipment,order))do parts[#parts+1]=part end
      else parts[#parts+1]=Cells.build(c,s,unit.nodes[1],pool,equipment,maximum,rank)end
    end
    for i in ipairs(units)do build(i)end
    local firstrow=#plan.production_rows+1
    for pi,part in ipairs(parts)do
      local dx,dy=cursor-part.g.minx,body_top-part.g.miny;local offset=#g.entities;local first=offset+1
      local prefix='cell/'..gi..'/'..pi..'/'
      for _,e in ipairs(part.g.entities)do local extra=U.copy(e);extra.entity_number=nil;extra.position=nil
        g:add(e.name,e.position.x+dx,e.position.y+dy,e.direction,extra)
      end
      for cell,id in pairs(part.g.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$');g:reserve(tonumber(x)+dx,tonumber(y)+dy,prefix..id,part.g.fluid_ports[cell])end
      for _,t in ipairs(part.g.tunnels)do
        if t.horizontal then g:tunnel(t.kind,t.lo+dx,t.y+dy,t.hi+dx,t.y+dy)
        else g:tunnel(t.kind,t.x+dx,t.lo+dy,t.x+dx,t.hi+dy)end
      end
      for _,row in ipairs(part.rows)do
        row.id=#plan.production_rows+1;row.bus='recipe'
        for _,list in ipairs({row.machines,row.input_inserters,row.output_inserters})do for j,id in ipairs(list)do list[j]=id+offset end end
        row.bounds.x0=row.bounds.x0+dx;row.bounds.x1=row.bounds.x1+dx;row.bounds.y0=row.bounds.y0+dy;row.bounds.y1=row.bounds.y1+dy
        plan.production_rows[#plan.production_rows+1]=row
      end
      for _,link in ipairs(part.links)do
        for _,field in ipairs({'source','target','inserter'})do link[field]=link[field]+offset end
        plan.mall_links[#plan.mall_links+1]=link
      end
      for _,t in ipairs(part.terminals)do
        if t.mixed then U.fail('item-ports',belt.localised_name)end
        translate(t.port,dx,dy);t.port.id=prefix..t.port.id
        if part.direct_key and t.produce then t.tapx=dx+part.g.maxx+3 end
        terminals[#terminals+1]=t
      end
      for _,t in ipairs(part.local_routes)do
        translate(t.from,dx,dy);translate(t.to,dx,dy);t.id=prefix..t.id
        if t.bounds then t.bounds.x0=t.bounds.x0+dx;t.bounds.x1=t.bounds.x1+dx;t.bounds.y0=t.bounds.y0+dy;t.bounds.y1=t.bounds.y1+dy end
        connections[#connections+1]=t
      end
      underpasses=underpasses+(part.underpasses or 0);side_fluids=side_fluids+(part.side_fluids or 0)
      events[#events+1]={stage='machines',first=first,last=#g.entities}
      cursor=dx+part.g.maxx+(part.direct_key and 7 or 5)
    end
    local keys=U.sorted(group.local_keys)
    local recipes={};for _,n in ipairs(group.nodes)do recipes[n.recipe]=true end
    plan.production_groups[#plan.production_groups+1]={recipes=U.sorted(recipes),local_items=keys,rows={first=firstrow,last=#plan.production_rows}}
  end
  local bykey={}
  for _,t in ipairs(terminals)do bykey[t.key]=bykey[t.key]or{};bykey[t.key][#bykey[t.key]+1]=t end
  local buses,keys,itemkeys,fluidkeys={},{},{},{}
  local lane_capacity=belt.belt_speed*14400*.8
  for _,key in ipairs(U.sorted(bykey))do
    local f=plan.flows[key];local fluid=U.split(key)=='fluid'
    local count=fluid and 1 or math.max(1,math.ceil(math.max(f.external/(belt.belt_speed*28800),f.supply/lane_capacity)-1e-8))
    for i=1,count do
      local id=count==1 and key or U.stream(key,200000000+i)
      local b={key=key,id=id,index=i,fluid=fluid,taps={},above=0,below=1,closed=false,direction=(f.internal or 0)<eps and f.external<eps and 12 or 4}
      buses[id]=b;keys[#keys+1]=id
      if id~=key then local copy=U.copy(f);copy.key=id;copy.supply=f.supply/count;copy.demand=f.demand/count;copy.internal=f.internal/count;copy.external=f.external/count;plan.flows[id]=copy end
      if not local_rows[key]then local list=fluid and fluidkeys or itemkeys;list[#list+1]=id end
      plan.transport_lanes[#plan.transport_lanes+1]={id=id,key=key,index=i,count=count,local_item=local_rows[key]~=nil}
    end
    local loads={};for i=1,count do loads[i]={input=0,output=0}end
    table.sort(bykey[key],function(a,b)return a.port.x==b.port.x and a.port.y<b.port.y or a.port.x<b.port.x end)
    for _,t in ipairs(bykey[key])do
      local side=t.produce and'output'or'input';local chosen
      local capacity=fluid and math.huge or(t.produce or f.supply>eps)and lane_capacity or belt.belt_speed*28800
      for i=1,count do if loads[i][side]+t.rate<=capacity+eps then chosen=i;break end end
      if not chosen then U.fail('item-ports',belt.localised_name)end
      loads[chosen][side]=loads[chosen][side]+t.rate
      local id=count==1 and key or U.stream(key,200000000+chosen);t.bus=id;buses[id].taps[#buses[id].taps+1]=t
    end
  end
  local transport_order,seen={},{}
  for _,key in ipairs(order)do for _,id in ipairs(itemkeys)do if buses[id].key==key and not seen[id]then transport_order[#transport_order+1]=id;seen[id]=true end end end
  local packed,ordered,span=Bus.pack(plan,itemkeys,transport_order)
  local stored={};for _,key in ipairs(plan.recipe_bus_order)do stored[key]=true end
  for _,id in ipairs(ordered)do local key=buses[id].key;if not stored[key]then plan.recipe_bus_order[#plan.recipe_bus_order+1]=key;stored[key]=true end end
  for _,id in ipairs(ordered)do local b,p=buses[id],packed[id];b.y=p.position-span;b.group=p.group;b.lane=p.lane;b.role=p.role;miny=math.min(miny,b.y)end
  for i,id in ipairs(fluidkeys)do buses[id].y=-span-4*i;miny=math.min(miny,buses[id].y)end
  for _,id in ipairs(keys)do local b=buses[id];local loc=local_rows[b.key]
    if loc then b.y=loc.y+2*(b.index-1);b.local_item=true end
    b.minx=math.huge;b.maxx=-math.huge
    for _,t in ipairs(b.taps)do
      local x=t.tapx or(t.fluid and t.port.x or t.produce and(t.port.x+(b.direction==12 and-1 or 1))or t.port.x-1)
      t.x=x;b.minx=math.min(b.minx,x-2);b.maxx=math.max(b.maxx,x+2)
    end
  end
  local ports={}
  for _,port in ipairs(plan.ports)do
    local f=plan.flows[port.key];local count=U.split(port.key)=='item'and math.max(1,math.ceil(port.rate/(belt.belt_speed*28800)-1e-8))or 1
    if port.kind=='out'then local lanes=0;for _,id in ipairs(keys)do if buses[id].key==port.key then lanes=lanes+1 end end;count=math.max(count,lanes)end
    for i=1,count do local copy=U.copy(port);copy.section=(port.section or 1)+i-1;copy.id=port.id..(count>1 and'/'..i or'');copy.rate=port.rate/count;ports[#ports+1]=copy end
  end
  plan.ports=ports
  table.sort(ports,function(a,b)if a.kind~=b.kind then return a.kind<b.kind end;local ar,br=socket_rank[a.key]or 100000,socket_rank[b.key]or 100000;return ar==br and a.id<b.id or ar<br end)
  for i,p in ipairs(ports)do
    p.index=i;p.local_position={x=-12,y=miny-4+2*(i-1)};p.staging_position=nil
    local x,y=U.rotate(p.local_position.x+.5,(mirror and-1 or 1)*(p.local_position.y+.5),turns);p.position={x=x,y=y}
  end
  Inputs.assign(s,plan);Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan);Displays.reserve(c,s,g,plan)
  for _,p in ipairs(ports)do
    local list={};for _,id in ipairs(keys)do if buses[id].key==p.key then list[#list+1]=buses[id]end end
    local b=list[math.min(p.section or 1,#list)];if not b then U.fail('port',U.name(p.key))end
    b.minx=math.min(b.minx,1)
    local id='user/'..p.id;local from,to
    if b.fluid then from={x=p.local_position.x,y=p.local_position.y};to={x=0,y=b.y}
    elseif p.kind=='in'then from={x=p.local_position.x,y=p.local_position.y,d=p.pinned_direction or 1,plain=true};to={x=0,y=b.y,d=1,plain=true}
    else from={x=0,y=b.y,d=b.fluid and nil or 3,plain=true};to={x=p.local_position.x,y=p.local_position.y,d=b.fluid and nil or 3,plain=true}end
    g:reserve(from.x,from.y,id,b.fluid and b.key or nil);g:reserve(to.x,to.y,id,b.fluid and b.key or nil)
    if not b.fluid then
      for step=1,2 do
        g:reserve(from.x+G.dx[from.d+1]*step,from.y+G.dy[from.d+1]*step,id)
        g:reserve(to.x-G.dx[to.d+1]*step,to.y-G.dy[to.d+1]*step,id)
      end
    end
    connections[#connections+1]={key=p.key,from=from,to=to,id=id,direct_route=true,local_route=b.fluid,fluid_header=b.fluid,external=true,stage='ports'}
    b.external=true
  end
  for _,id in ipairs(keys)do local b=buses[id]
    for ti,t in ipairs(b.taps)do
      local port=t.port;local stub
      if b.fluid then stub={x=t.x,y=b.y,id=port.id}
      else stub={x=t.x+(t.produce and(b.direction==12 and 1 or-1)or 1),y=b.y+1,d=t.produce and(b.direction==12 and 3 or 1)or 2,plain=true,id=port.id}end
      g:reserve(stub.x,stub.y,port.id,b.fluid and b.key or nil)
      if not b.fluid then
        local lo,hi=math.min(stub.y,port.y),math.max(stub.y,port.y)
        -- These straight columns belong to the production bank. Dense bus
        -- lanes pass beneath them rather than bending the ingredient feeds.
        if stub.x==port.x then for y=lo,hi do if not g.occupied[G.cell(stub.x,y)]then
          local old=g.reserved[G.cell(stub.x,y)];if not old or old==port.id then g:reserve(stub.x,y,port.id)end
        end end end
        plan.feed_branches[#plan.feed_branches+1]={key=t.key,x0=stub.x,x1=port.x,y=port.y}
      end
      connections[#connections+1]={key=t.key,from=(b.fluid or t.produce)and port or stub,to=(b.fluid or t.produce)and stub or port,id=port.id,
        direct_route=true,local_route=b.fluid,fluid_header=b.fluid,vertical_route=not b.fluid and stub.x==port.x}
    end
  end
  local first=#g.entities+1
  -- Splitters occupy the two surface lanes of their tap. Reserve every tap
  -- before tunnelling any neighbouring bus line below the branch corridors.
  for _,id in ipairs(keys)do local b=buses[id];if not b.fluid then for _,t in ipairs(b.taps)do
    g:add(splitter.name,t.x+.5,b.y+1,b.direction,{output_priority=t.produce and(b.direction==12 and'right'or'left')or nil,input_priority=t.produce and'right'or nil},b.key)
  end end end
  local function blocked(x,y,key)
    local marker=g.occupied[G.cell(x,y)];if marker then return true end
    return g.reserved[G.cell(x,y)]~=nil
  end
  for _,id in ipairs(keys)do local b=buses[id]
    if b.fluid then
      local keep={};for _,t in ipairs(b.taps)do keep[G.cell(t.x,b.y)]=true end
      if b.external then keep[G.cell(0,b.y)]=true;b.minx=0 end
      Pipes.line(g,pipe,pipeug,b.minx,b.y,b.maxx,b.y,b.key,keep)
    else
      local taps={};for _,t in ipairs(b.taps)do taps[t.x]=true end
      while blocked(b.minx,b.y,b.key)do b.minx=b.minx-1 end
      while blocked(b.maxx,b.y,b.key)do b.maxx=b.maxx+1 end
      local x=b.minx
      while x<=b.maxx do
        if taps[x]then x=x+1
        elseif blocked(x,b.y,b.key)then U.fail('layout-overlap',belt.name,x,b.y)
        else
          local nextx=x+1
          if nextx<=b.maxx and not taps[nextx]and blocked(nextx,b.y,b.key)then
            repeat
              if taps[nextx]then U.fail('layout-ports')end
              nextx=nextx+1
            until nextx>b.maxx or not blocked(nextx,b.y,b.key)
            while nextx<b.maxx and not taps[nextx+1]and blocked(nextx+1,b.y,b.key)do
              nextx=nextx+2;while nextx<=b.maxx and blocked(nextx,b.y,b.key)do nextx=nextx+1 end
            end
            if nextx>b.maxx or nextx-x>underground.max_underground_distance then U.fail('infrastructure',underground.name)end
            if not g:tunnel_free('item',x,b.y,nextx,b.y)then U.fail('layout-ports')end
            g:tile(underground.name,x,b.y,b.direction,{type=b.direction==4 and'input'or'output'},b.key)
            g:tile(underground.name,nextx,b.y,b.direction,{type=b.direction==4 and'output'or'input'},b.key)
            g:tunnel('item',x,b.y,nextx,b.y);x=nextx+1
          else g:tile(belt.name,x,b.y,b.direction,nil,b.key);x=x+1 end
        end
      end
    end
  end
  events[#events+1]={stage='recipe-bus',first=first,last=#g.entities}
  table.sort(connections,function(a,b)
    local af,bf=U.split(a.key)=='fluid',U.split(b.key)=='fluid';if af~=bf then return af end
    if af and(a.fluid_header or false)~=(b.fluid_header or false)then return a.fluid_header or false end
    if af and (a.external or false)~=(b.external or false)then return a.external or false end
    local ad=math.abs(a.from.x-a.to.x)+math.abs(a.from.y-a.to.y);local bd=math.abs(b.from.x-b.to.x)+math.abs(b.from.y-b.to.y)
    return ad==bd and a.id<b.id or ad<bd
  end)
  local direction=((s.direction or 2)-1)*4
  plan.bus_hierarchy={levels=3,generated_levels=2,main={id='main',external=true,built=false,entities={},lanes={},direction=direction,
    interface={from=U.copy(ports[1].local_position),to=U.copy(ports[#ports].local_position)}},
    recipe={id='recipe',target=plan.target,direction=(direction+(s.side==2 and-4 or 4))%16,group_size=4,group_gap=2,
      bounds={x0=0,y0=miny,x1=cursor,y1=0},lanes={}},lines=plan.production_rows,interfaces={}}
  for _,id in ipairs(ordered)do local b=buses[id]
    plan.bus_hierarchy.recipe.lanes[#plan.bus_hierarchy.recipe.lanes+1]={key=b.key,y=b.y,x0=b.minx,x1=b.maxx,position=packed[id].position,group=b.group,lane=b.lane,role=b.role}
  end
  for _,p in ipairs(ports)do plan.bus_hierarchy.interfaces[#plan.bus_hierarchy.interfaces+1]={key=p.key,kind=p.kind,port=p.id,position=U.copy(p.local_position),from=p.kind=='in'and'main'or'recipe',to=p.kind=='in'and'recipe'or'main'}end
  plan.layout_revision=32
  plan.layout_stats={compact=true,flow_compact=true,underpasses=underpasses,side_fluid_ports=side_fluids,direct_links=#plan.mall_links,
    production_rows=#plan.production_rows,closed_buses=0,straight_buses=#keys,recipe_bus_taps=#terminals,
    main_bus_taps=0,external_interfaces=#ports,hierarchy_levels=3,generated_main_bus_entities=0}
  local bounds={x0=g.minx-8,y0=g.miny-8,x1=g.maxx+8,y1=g.maxy+8}
  for _,p in ipairs(ports)do bounds.x0=math.min(bounds.x0,p.local_position.x-8);bounds.x1=math.max(bounds.x1,p.local_position.x+8)
    bounds.y0=math.min(bounds.y0,p.local_position.y-8);bounds.y1=math.max(bounds.y1,p.local_position.y+8)end
  return {g=g,events=events,plan=plan,connections=connections,special={},buses={},turns=turns,mirror=mirror,
    equipment={belt=belt.name,underground=underground.name,splitter=splitter.name,pipe=pipe.name,pipeug=pipeug.name},
    connection_index=1,special_index=1,stage='routes',route_bounds=bounds}
end
return Layout
