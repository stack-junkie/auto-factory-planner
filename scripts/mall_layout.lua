local U=require('scripts.util')
local C=require('scripts.catalogue')
local G=require('scripts.geometry')
local A=require('scripts.arrangement')
local I=require('scripts.inserters')
local Mall=require('scripts.mall')
local Paving=require('scripts.paving')
local Power=require('scripts.power')
local Inputs=require('scripts.inputs')
local Bus=require('scripts.bus')
local SharedRows=require('scripts.shared_rows')
local CompactCells=require('scripts.compact_cells')
local StraightCells=require('scripts.straight_cells')
local Intake=require('scripts.intake')
local InputDisplays=require('scripts.input_displays')
local ProductionGroups=require('scripts.production_groups')
local LocalSupplies=require('scripts.local_supplies')
local FluidCells=require('scripts.fluid_cells')
local Pipes=require('scripts.pipes')
local Router=require('scripts.router')
local ML={}
local epsilon=1e-6
-- This path handles ordinary item DAGs. Feedback, fluids and fuel retain the
-- general planner, including its bootstrap and circuit-control machinery.
function ML.accepts(plan,s)
  if s._legacy_layout or s.mode~='mall'and s._legacy_rate or s.mode=='mall'and plan.sections~=1 then return false end
  local override=s.infrastructure and s.infrastructure.inserter
  if override then local p=prototypes.entity[override]
    if not p or not I.supported(p) or math.floor(-p.inserter_pickup_position[2]+0.5)~=1 or math.floor(p.inserter_drop_position[2]+0.5)~=1 then return false end
  end
  for key,f in pairs(plan.flows) do
    if (U.split(key)~='item'and not plan.rate_search) or f.bootstrap or f.controlled or f.surplus>epsilon then return false end
  end
  for _,n in ipairs(plan.nodes) do
    local p=prototypes.entity[n.machine]
    if n.fuel or p.tile_width<2 or p.tile_height<2 or #U.sorted(n.output)~=1 and not plan.rate_search then return false end
  end
  return true
end
local function arms(c,s)
  local result={}
  local override=s.infrastructure and s.infrastructure.inserter
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal') end)) do
    if I.supported(p) and math.floor(-p.inserter_pickup_position[2]+0.5)==1
      and math.floor(p.inserter_drop_position[2]+0.5)==1
      and (not override or override==p.name) then result[#result+1]=p end
  end
  if #result==0 then U.fail('missing-infrastructure','inserter') end
  return result
end
-- A machine row must be able to load its ingredients as well as craft them.
-- Size the parallel row before private direct-feed producers are expanded.
function ML.prepare(c,s,plan)
  if s.mode=='mall'or plan.local_supplies then return end
  local short=arms(c,s);local long={};local direct={}
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+0.5)==2 and math.floor(p.inserter_drop_position[2]+0.5)==2
      and(not(s.infrastructure and s.infrastructure.inserter)or s.infrastructure.inserter==p.name)then long[#long+1]=p end
  end
  for _,n in ipairs(plan.nodes)do if LocalSupplies.eligible(n,plan)then direct[U.sorted(n.output)[1]]=true end end
  for _,n in ipairs(plan.nodes)do
    local rates={};for _,key in ipairs(U.sorted(n.input))do if U.split(key)=='item'and not direct[key]then rates[#rates+1]={key=key,rate=n.input[key]*n.crafts}end end
    local width=c.machines[n.machine].tile_width;local count=n.count
    local function required(copies)
      local slots=0
      for i=1,#rates,2 do
        local pool=i==1 and short or long
        if #pool==0 then return math.huge end
        local rate,capacity=0,math.huge
        for j=i,math.min(i+1,#rates)do rate=rate+rates[j].rate;capacity=math.min(capacity,I.capacity(pool[#pool],c,rates[j].key))end
        slots=slots+math.ceil(rate/(copies*capacity)-1e-8)
      end
      return slots
    end
    if math.ceil(#rates/2)<=width and(#rates<=2 or #long>0)then
      while required(count)>width do count=count+1;if count>300 then U.fail('too-large')end end
      if count>n.count then
        for key,amount in pairs(n.input)do local f=plan.flows[key];f.seed=f.seed+amount*(count-n.count)end
        n.count=count
      end
    end
  end
end
local function pick(pool,c,key,rate,direct)
  local capacity=direct and I.direct_capacity or I.capacity
  for _,p in ipairs(pool) do if capacity(p,c,key)>=rate-epsilon then return p end end
end
local function direction(dx,dy) return dx>0 and 12 or dx<0 and 4 or dy>0 and 0 or 8 end
local function arm(g,p,x,y,dx,dy,key,output)
  local _,name=U.split(key)
  return g:tile(p.name,x,y,direction(dx,dy),output and p.filter_count>0
    and {use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}}} or {use_filters=false},key)
end
local function clusters(plan,s)
  local straight=not(s._legacy_straight or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout)
  local parent,producer,consumers,fed={},{},{},{}
  for i,n in ipairs(plan.nodes) do
    parent[i]=i
    for key in pairs(n.output) do producer[key]=i end
    for key in pairs(n.input) do consumers[key]=consumers[key] or {};consumers[key][#consumers[key]+1]=i end
    for key in pairs(n.input)do if plan.direct_keys and plan.direct_keys[key]then fed[n.id]=true end end
  end
  local function root(i) while parent[i]~=i do i=parent[i] end;return i end
  local sizes={};for i,n in ipairs(plan.nodes)do sizes[i]=n.count end
  local function join(i,j) i,j=root(i),root(j)
    if plan.rate_search and(FluidCells.has_fluid({nodes={plan.nodes[i]}})or FluidCells.has_fluid({nodes={plan.nodes[j]}}))then return end
    -- A shared recipe is not a single adjacent machine. Large consumers
    -- retain their common ingredient feed instead of exhausting a producer's
    -- perimeter with one separate transfer per consumer machine.
    if s.mode~='mall'and not(plan.nodes[i].local_supply or plan.nodes[j].local_supply)and(sizes[i]>1 or sizes[j]>1)then return end
    if i~=j and(s.mode=='mall'or plan.nodes[i].local_supply or plan.nodes[j].local_supply or sizes[i]+sizes[j]<=10)then parent[j]=i;sizes[i]=sizes[i]+sizes[j]end
  end
  for key,list in pairs(consumers) do local source=producer[key]
    if source then
      local n=plan.nodes[source]
      -- Stock dependencies and small local intermediate fan-outs are strong
      -- grouping hints. Widely shared intermediates stay on the common bus.
      if straight and #list~=1 then
        -- Shared intermediates keep their established bus lane.
      elseif n.mall_final or #list<=2 then for _,j in ipairs(list) do if n.local_supply or(not fed[n.id]and not plan.nodes[j].local_supply)then join(source,j)end end
      else
        for _,j in ipairs(list) do local demand=plan.nodes[j].input[key]*plan.nodes[j].crafts
          if demand>=n.output[key]*n.crafts*0.8 and(n.local_supply or(not fed[n.id]and not plan.nodes[j].local_supply))then join(source,j) end
        end
      end
    end
  end
  local groups={};for i,n in ipairs(plan.nodes) do local id=root(i);groups[id]=groups[id] or {nodes={},keys={}}
    local group=groups[id];group.nodes[#group.nodes+1]=n
    group.local_supply=group.local_supply or n.local_supply
    for key in pairs(n.input) do group.keys[key]=true end
  end
  for _,group in pairs(groups)do
    local part={nodes={},keys=U.copy(group.keys),local_supply=group.local_supply}
    for _,n in ipairs(group.nodes)do part.nodes[#part.nodes+1]=n end
    group.parts={part}
  end
  -- Independent groups with at least two common ingredients can share a
  -- compact cell. Never merge through a dependency: that could create a
  -- cycle in the group order even though the recipe graph is acyclic.
  local graph={}
  for key,list in pairs(consumers) do local source=producer[key]
    if source then for _,j in ipairs(list) do local a,b=root(source),root(j)
      if a~=b then graph[a]=graph[a] or {};graph[a][b]=true end
    end end
  end
  local function reaches(a,b,seen)
    if a==b then return true end;seen=seen or {};if seen[a] then return false end;seen[a]=true
    for nextid in pairs(graph[a] or {}) do if reaches(nextid,b,seen) then return true end end;return false
  end
  local ids=U.sorted(groups)
  for ai,a in ipairs(ids) do if groups[a] then for bi=ai+1,#ids do local b=ids[bi]
    if groups[b] and not reaches(a,b) and not reaches(b,a) then
      local shared,count=0,0
      for key in pairs(groups[a].keys) do if groups[b].keys[key] then shared=shared+1 end end
      for _,n in ipairs(groups[a].nodes) do count=count+n.count end
      for _,n in ipairs(groups[b].nodes) do count=count+n.count end
      local raw=U.copy(groups[a].keys)
      for key in pairs(groups[b].keys)do raw[key]=true end
      for _,group in ipairs({groups[a],groups[b]})do for _,n in ipairs(group.nodes)do for key in pairs(n.output)do raw[key]=nil end end end
      if not ProductionGroups.enabled(s)and shared>=2 and count<=8 and(not straight or #U.sorted(raw)<=4)and not groups[a].local_supply and not groups[b].local_supply then
        for _,n in ipairs(groups[b].nodes) do groups[a].nodes[#groups[a].nodes+1]=n end
        for _,part in ipairs(groups[b].parts)do groups[a].parts[#groups[a].parts+1]=part end
        for key in pairs(groups[b].keys) do groups[a].keys[key]=true end
        graph[a]=graph[a] or {};for k in pairs(graph[b] or {}) do graph[a][k]=true end
        for _,edges in pairs(graph) do if edges[b] then edges[a]=true;edges[b]=nil end end
        graph[b]=nil;groups[b]=nil
      end
    end
  end end end
  local ordered,visiting,done={},{},{}
  local function visit(id)
    if done[id] then return end
    if visiting[id] then return false end
    visiting[id]=true
    for _,source in ipairs(U.sorted(groups)) do if (graph[source] or {})[id] then if visit(source)==false then return false end end end
    visiting[id]=nil;done[id]=true;ordered[#ordered+1]=groups[id];return true
  end
  for _,id in ipairs(U.sorted(groups)) do if visit(id)==false then return end end
  return ordered
end
local function in_box(x,y,b) return x>=b.x and x<b.x+b.w and y>=b.y and y<b.y+b.h end
local function boundary(b)
  local slots={}
  for x=b.x,b.x+b.w-1 do slots[#slots+1]={x=x,y=b.y-1,dx=0,dy=-1};slots[#slots+1]={x=x,y=b.y+b.h,dx=0,dy=1} end
  for y=b.y,b.y+b.h-1 do slots[#slots+1]={x=b.x-1,y=y,dx=-1,dy=0};slots[#slots+1]={x=b.x+b.w,y=y,dx=1,dy=0} end
  return slots
end
local function free_box(g,b,padding)
  for x=b.x-padding,b.x+b.w-1+padding do for y=b.y-padding,b.y+b.h-1+padding do
    if not g:free(x,y) then return false end
  end end;return true
end
local function stock_position(g,b)
  -- Prefer the centre of an edge. The other three sides of the chest remain
  -- available for direct stock-to-machine transfers.
  local slots=boundary(b)
  table.sort(slots,function(a,z)
    local function score(v) return (v.dx==1 and 0 or v.dy==-1 and 10 or v.dy==1 and 20 or 30)
      +math.abs(v.x-(b.x+(b.w-1)/2))+math.abs(v.y-(b.y+(b.h-1)/2)) end
    return score(a)<score(z)
  end)
  for _,v in ipairs(slots) do
    if g:free(v.x,v.y) and g:free(v.x+v.dx,v.y+v.dy)
      and not in_box(v.x+v.dx,v.y+v.dy,b) then return v end
  end
end
local function direct_slots(g,source,target)
  local result={}
  for _,v in ipairs(boundary(source)) do
    if in_box(v.x+v.dx,v.y+v.dy,target) and g:free(v.x,v.y) then result[#result+1]=v end
  end
  return result
end
local function cell(c,s,group,pool,targets,belt)
  local g=G.new();local machines={};local pending={};local rows={};local stocks={};local links={};local terminals={}
  local direct_capacity=s._legacy_orientation and I.capacity or I.direct_capacity
  local fan_rows={}
  if not s._legacy_orientation then for _,node in ipairs(group.nodes) do
    local key=U.sorted(node.output)[1];local consumers,recipes=0,0
    for _,other in ipairs(group.nodes) do if other.input[key] then consumers=consumers+other.count;recipes=recipes+1 end end
    -- A dedicated producer bank leaves overlapping edges for a staggered
    -- bank of consumers. Shared intermediates keep the ordinary placement.
    if not node.mall_final and node.count>=2 and node.count<=6 and recipes==1 and consumers>=2 then fan_rows[node.id]={} end
  end end
  for _,n in ipairs(group.nodes) do for i=1,n.count do pending[#pending+1]={node=n,copy=i} end end
  local hub,ordinary
  if group.local_supply and not s._legacy_cells then
    ordinary=0
    for _,n in ipairs(group.nodes)do if not n.local_supply then ordinary=ordinary+1;hub=n end end
    if ordinary~=1 or hub.count~=1 then hub=nil end
    if hub then for _,n in ipairs(group.nodes)do if n.local_supply and n.direct_target~=hub.id then hub=nil;break end end end
  end
  local depths={};local sources={}
  for _,n in ipairs(group.nodes) do for key in pairs(n.output) do sources[key]=n end end
  local function depth(n)
    if depths[n.id] then return depths[n.id] end
    local d=0
    for key in pairs(n.input) do if sources[key] then d=math.max(d,depth(sources[key])+1) end end
    depths[n.id]=d;return d
  end
  table.sort(pending,function(a,b)
    if hub and(a.node==hub or b.node==hub)then return a.node==hub and b.node~=hub end
    if depth(a.node)~=depth(b.node) then return depth(a.node)<depth(b.node) end
    local function score(v)
      local out=0;for _,n in ipairs(group.nodes) do for key in pairs(v.node.output) do if n.input[key] then out=out+1 end end end
      return out
    end
    local aout,bout=score(a),score(b)
    if aout~=bout then return aout>bout end
    return a.node.id==b.node.id and a.copy<b.copy or a.node.id<b.node.id
  end)
  for _,instance in ipairs(pending) do
    local n=instance.node;local p=c.machines[n.machine];local key=U.sorted(n.output)[1];local target=n.mall_final and targets[U.base_key(key)]
    local candidates={{x=0,y=0,w=p.tile_width,h=p.tile_height}}
    local fan=fan_rows[n.id]
    if fan and fan.first then candidates[#candidates+1]={x=fan.first.x+(instance.copy-1)*(p.tile_width+1),y=fan.first.y,w=p.tile_width,h=p.tile_height,fan=true} end
    for _,source in ipairs(machines) do
      local inventory=source.stock or source.box
      if n.input[source.key]or(hub and n.local_supply and source.node==hub and source.node.input[key])then
        if hub and source.node==hub then inventory=source.box end
        for _,v in ipairs(boundary(inventory)) do
          -- The arm is between inventory edges; align every possible edge
          -- tile, allowing multiple direct arms between wide machines.
          for offset=0,(v.dx~=0 and p.tile_height or p.tile_width)-1 do
            local x=v.dx>0 and v.x+1 or v.dx<0 and v.x-p.tile_width or v.x-offset
            local y=v.dy>0 and v.y+1 or v.dy<0 and v.y-p.tile_height or v.y-offset
            candidates[#candidates+1]={x=x,y=y,w=p.tile_width,h=p.tile_height}
          end
        end
      end
      local b=source.box
      for _,pos in ipairs({{b.x+b.w+3,b.y},{b.x,b.y+b.h+3},{b.x-p.tile_width-3,b.y},{b.x,b.y-p.tile_height-3}}) do
        candidates[#candidates+1]={x=pos[1],y=pos[2],w=p.tile_width,h=p.tile_height}
      end
    end
    local best,score
    for _,b in ipairs(candidates) do if free_box(g,b,0) then
      local touches=false
      for _,old in ipairs(machines) do local a=old.box
        local overlapx=b.x<a.x+a.w and b.x+b.w>a.x
        local overlapy=b.y<a.y+a.h and b.y+b.h>a.y
        if overlapx and (b.y==a.y+a.h or b.y+b.h==a.y)
          or overlapy and (b.x==a.x+a.w or b.x+b.w==a.x) then touches=true end
      end
      local st=target and stock_position(g,b)
      if not touches and (not target or st) then
        local area=(math.max(g.maxx,b.x+b.w+2)-math.min(g.minx,b.x-2))*(math.max(g.maxy,b.y+b.h+2)-math.min(g.miny,b.y-2))
        local value=-area
        if b.fan then value=value+10000 end
        for _,source in ipairs(machines) do if n.input[source.key] then
          local available=direct_slots(g,source.stock or source.box,b)
          if #available>0 then
            local alignment=math.huge
            for _,v in ipairs(available) do alignment=math.min(alignment,v.dx~=0 and math.abs(v.y-(b.y+(b.h-1)/2)) or math.abs(v.x-(b.x+(b.w-1)/2))) end
            value=value+1000+math.min(n.input[source.key]*n.crafts/n.count,200)-alignment*100
          end
        end end
        if hub and n.local_supply and hub.input[key]then for _,target in ipairs(machines)do if target.node==hub then
          local available=direct_slots(g,b,target.box)
          if #available>0 then value=value+2000-math.abs((b.x+b.w/2)-(target.box.x+target.box.w/2))*2-math.abs((b.y+b.h/2)-(target.box.y+target.box.h/2))*2 end
        end end end
        -- Avoid very wide cells; free length is much cheaper than reserved width.
        value=value-math.max(0,math.max(g.maxx,b.x+b.w)-math.min(g.minx,b.x)-24)*100
        if not score or value>score then best,score=b,value end
      end
    end end
    if not best then U.fail('item-ports',p.localised_name) end
    if fan and not fan.first then fan.first={x=best.x,y=best.y} end
    local entity=g:add(p.name,best.x+p.tile_width/2,best.y+p.tile_height/2,0,{recipe=n.recipe,recipe_quality='normal'})
    local m={node=n,key=key,box=best,entity=entity,need={},remaining=(n.output[key] or 0)*n.crafts/n.count}
    for k,amount in pairs(n.input) do m.need[k]=amount*n.crafts/n.count end
    machines[#machines+1]=m
    rows[#rows+1]={node=n.id,recipe=n.recipe,count=1,machines={entity.entity_number},input_inserters={},output_inserters={},mall_cell=true,
      bounds={x0=best.x-2,y0=best.y-2,x1=best.x+best.w+1,y1=best.y+best.h+1}}
    m.row=rows[#rows]
    if target then
      local v=stock_position(g,best);local chest=Mall.chest(c,s,target.stacks)
      local selected=pick(pool,c,key,m.remaining)
      if not selected then U.fail('mall-final',p.localised_name) end
      local sink=arm(g,selected,v.x,v.y,v.dx,v.dy,key,true)
      local box=g:tile(chest.name,v.x+v.dx,v.y+v.dy,0,{bar=target.stacks,tags={afp_mall={key=U.base_key(key),stacks=target.stacks}}},key)
      m.stock={x=v.x+v.dx,y=v.y+v.dy,w=1,h=1};m.chest=box
      m.row.output_inserters[#m.row.output_inserters+1]=sink.entity_number
      stocks[#stocks+1]={key=U.base_key(key),stock=target.stock,stacks=target.stacks,chest=box.entity_number,inserter=sink.entity_number}
      -- Only internal demand is exported from a stock chest. Native slot bars
      -- reserve the requested stock without stopping downstream consumers.
      m.remaining=math.max(0,m.remaining-target.rate)
    end
  end
  -- Assign scarce edge slots to the highest-flow local links first.
  local candidates={}
  for _,source in ipairs(machines) do for _,target in ipairs(machines) do
    if source~=target and (target.need[source.key] or 0)>epsilon then
      for _,v in ipairs(direct_slots(g,source.stock or source.box,target.box)) do
        candidates[#candidates+1]={source=source,target=target,v=v,rate=target.need[source.key]}
      end
    end
  end end
  table.sort(candidates,function(a,b)
    if a.rate~=b.rate then return a.rate>b.rate end
    if a.source.entity.entity_number~=b.source.entity.entity_number then return a.source.entity.entity_number<b.source.entity.entity_number end
    return a.v.x==b.v.x and a.v.y<b.v.y or a.v.x<b.v.x
  end)
  for _,edge in ipairs(candidates) do
    local source,target,v=edge.source,edge.target,edge.v;local key=source.key
    local rate=math.min(source.remaining,target.need[key] or 0)
    if rate>epsilon and g:free(v.x,v.y) then
      local selected=pick(pool,c,key,rate,not s._legacy_orientation) or pool[#pool];rate=math.min(rate,direct_capacity(selected,c,key))
      local e=arm(g,selected,v.x,v.y,v.dx,v.dy,key,false)
      source.remaining=source.remaining-rate;target.need[key]=target.need[key]-rate
      target.row.input_inserters[#target.row.input_inserters+1]=e.entity_number
      if not source.stock then source.row.output_inserters[#source.row.output_inserters+1]=e.entity_number end
      links[#links+1]={key=key,source=(source.chest or source.entity).entity_number,target=target.entity.entity_number,
        inserter=e.entity_number,rate=rate,stock=source.stock~=nil}
    end
  end
  local rim={x0=g.minx-2,y0=g.miny-2,x1=g.maxx+1,y1=g.maxy+1}
  local function terminal(m,key,rate,output)
    local inventory=output and (m.stock or m.box) or m.box
    while rate>epsilon do
      local selected=pick(pool,c,key,rate) or pool[#pool];local amount=math.min(rate,I.capacity(selected,c,key))
      local slots=boundary(inventory);local chosen,best
      for _,v in ipairs(slots) do local x,y=v.x+v.dx,v.y+v.dy
        local clear=g:free(v.x,v.y);local length=0
        while clear do
          if not g:free(x,y) then clear=false;break end
          if x<=rim.x0 or x>=rim.x1 or y<=rim.y0 or y>=rim.y1 then break end
          x,y=x+v.dx,y+v.dy;length=length+1
        end
        if clear and g:free(x+v.dx,y+v.dy) and g:free(x+2*v.dx,y+2*v.dy) then
          local score=length*2+x*0.05
          if not best or score<best then chosen,best={x=v.x,y=v.y,dx=v.dx,dy=v.dy,ex=x,ey=y},score end
        end
      end
      if not chosen then
        log('AFP MALL NO TERMINAL '..m.node.recipe..' '..m.node.id..' '..key..' output='..tostring(output))
        U.fail('item-ports',c.machines[m.node.machine].localised_name)
      end
      local v=chosen;local dx,dy=v.dx,v.dy
      local e=arm(g,selected,v.x,v.y,output and dx or -dx,output and dy or -dy,key,output)
      local list=output and m.row.output_inserters or m.row.input_inserters;list[#list+1]=e.entity_number
      local id='mall/'..e.entity_number;local port={x=v.ex,y=v.ey,d=output and (direction(-dx,-dy)/4) or (direction(dx,dy)/4),plain=true,id=id}
      local x,y=v.x+dx,v.y+dy
      while x~=v.ex or y~=v.ey do
        g:tile(belt.name,x,y,port.d*4,nil,key);x,y=x+dx,y+dy
      end
      g:reserve(port.x,port.y,id);g:reserve(port.x+dx,port.y+dy,id);g:reserve(port.x+2*dx,port.y+2*dy,id)
      terminals[#terminals+1]={key=key,port=port,produce=output,rate=amount}
      rate=rate-amount
    end
  end
  for _,m in ipairs(machines) do
    if m.node.local_supply and m.remaining>epsilon then log('AFP incomplete direct output '..m.node.id..' '..m.remaining);U.fail('item-ports',c.machines[m.node.machine].localised_name)end
    for key,amount in pairs(m.need)do if amount>epsilon and key:match('^item@100%d+:')then log('AFP incomplete direct input '..m.node.id..' '..key..' '..amount);U.fail('item-ports',c.machines[m.node.machine].localised_name)end end
    -- Output inventories and high-rate inputs get their edge slots first.
    if m.remaining>epsilon then terminal(m,m.key,m.remaining,true) end
    for _,key in ipairs(U.sorted(m.need)) do if m.need[key]>epsilon then terminal(m,key,m.need[key],false) end end
  end
  return {g=g,rows=rows,stocks=stocks,links=links,terminals=terminals}
end
function ML.begin(g,events,c,s,plan,equipment,turns,mirror)
  g.isolate_items=plan.rate_search==true
  local straight=not(s._legacy_straight or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout)
  local modern=straight and not s._legacy_intake
  local dense=modern and not s._legacy_branches
  local order=modern and Intake.order(s,plan)or(s._project and s._project.recipe_bus_order)
  local groups=clusters(plan,s);if not groups then return end
  local pool=arms(c,s);local targets={};for _,t in ipairs(plan.targets) do targets[t.key]=t end
  local cells={};local keys={};local placed={}
  local single=U.copy(s);single._legacy_dual=true
  local function build_group(group,grouping,cell_width)
    local config=grouping and single or s
    if plan.rate_search and s._shape_rows then config=U.copy(config);config.input_rows=s._shape_rows end
    if cell_width then config=U.copy(config);config._cell_width=cell_width end
    if plan.rate_search then group.touching=true end
    if plan.rate_search and FluidCells.has_fluid(group)then return FluidCells.build(c,config,group,pool,equipment,order)end
    if straight then return SharedRows.build(c,config,group,pool,equipment)or StraightCells.build(c,config,group,pool,targets,equipment,order)end
    return CompactCells.build(c,s,group,pool,targets,equipment.belt)or SharedRows.build(c,s,group,pool,equipment)or cell(c,s,group,pool,targets,equipment.belt)
  end
  local function add(group)
    local ok,part=pcall(build_group,group)
    if not ok then
      if not s._legacy_cells and not s._legacy_rows and not s._legacy_bus and type(part)=='table'and part[1]=='afp-error.item-ports'and group.parts and #group.parts>1 then
        for _,separate in ipairs(group.parts)do add(separate)end;return
      else
        error(part,0)
      end
    end
    placed[#placed+1]=group;cells[#cells+1]=part
    for _,t in ipairs(part.terminals)do for _,key in ipairs(t.keys or{t.key})do keys[key]=true end end
  end
  if ProductionGroups.enabled(s)then
    groups,cells=ProductionGroups.plan(s,plan,groups,build_group)
    for _,part in ipairs(cells)do for _,t in ipairs(part.terminals)do for _,key in ipairs(t.keys or{t.key})do keys[key]=true end end end
  else for _,group in ipairs(groups)do add(group)end;groups=placed end
  local fluid_keys,fluid_buses={},{}
  for key in pairs(keys)do if U.split(key)=='fluid'then fluid_keys[#fluid_keys+1]=key;keys[key]=nil end end
  table.sort(fluid_keys)
  for i,key in ipairs(fluid_keys)do fluid_buses[key]={key=key,x=-4-3*i,first=math.huge,last=-math.huge,taps={}}end
  keys=U.sorted(keys);local buses={};local packed,span
  if not s._legacy_bus and not s._legacy_orientation then packed,keys,span=Bus.pack(plan,keys,straight and order)end
  if straight then
    plan.recipe_bus_order=U.copy(order or{})
    local known={};for _,key in ipairs(plan.recipe_bus_order)do known[key]=true end
    for _,key in ipairs(keys)do if not known[key]then plan.recipe_bus_order[#plan.recipe_bus_order+1]=key;known[key]=true end end
  end
  local preserved=SharedRows.balanceable(c,s,plan);local merging=false
  for key in pairs(preserved)do
    if plan.flows[key].supply<=equipment.belt.belt_speed*14400+epsilon then preserved[key]=nil else merging=true end
  end
  local pitch=packed and(merging and 5 or 4)or 3
  for i,key in ipairs(keys)do local lane=packed and packed[key]
    buses[key]={x=lane and lane.position or 3*(i-1),group=lane and lane.group,lane=lane and lane.lane,role=lane and lane.role,direction=lane and lane.role=='output'and 0 or 8,
      taps={},cuts={},first=math.huge,last=-math.huge}
  end
  local ports,outputs={},{};for _,p in ipairs(plan.ports)do local list=p.kind=='in'and ports or outputs;list[#list+1]=p end
  if s.mode=='mall'then plan.ports=ports;outputs={}end
  local output_x=2*#ports
  for i,p in ipairs(outputs)do
    p.index=#ports+i;p.local_position={x=output_x,y=-4};p.staging_position=nil
    local x,y=U.rotate(output_x+0.5,(mirror and -1 or 1)*-3.5,turns);p.position={x=x,y=y}
    output_x=output_x+2
  end
  local intake_bottom
  if modern then
    Intake.prepare(s,plan,ports,order,turns,mirror)
    if #outputs>0 then plan.ports={};for _,list in ipairs({ports,outputs})do for _,p in ipairs(list)do plan.ports[#plan.ports+1]=p end end end
    Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan)
    InputDisplays.reserve(c,s,g,plan)
    local item_ports={};for _,p in ipairs(ports)do if U.split(p.key)=='item'then item_ports[#item_ports+1]=p else
      for step=0,2 do g:reserve(p.local_position.x,p.local_position.y+step,'user/'..p.id,p.key)end
    end end
    intake_bottom=Intake.build(g,plan,item_ports,buses,equipment.belt)
  end
  local output_top=intake_bottom or 8+#ports*pitch;local right,left={},{}
  for _,p in ipairs(outputs)do output_top=math.max(output_top,p.local_position.y+3)end
  for _,p in ipairs(outputs)do local b=buses[p.key]
    if b then if p.local_position.x>b.x then right[#right+1]=p elseif p.local_position.x<b.x then left[#left+1]=p else p.output_y=output_top+1 end end
  end
  for i,p in ipairs(right)do p.output_y=output_top+i end
  for i,p in ipairs(left)do p.output_y=output_top+#left-i+1 end
  -- Reserve both ends and their mandatory straight approaches before mixed
  -- feeds or earlier output routes can occupy them. This also protects old
  -- factories whose fixed inputs now enter through a different side.
  for _,p in ipairs(outputs)do
    local id='user/'..p.id;local b=buses[p.key]
    if b then for step=0,2 do
      g:reserve(p.local_position.x,p.local_position.y+step,id)
      g:reserve(b.x,p.output_y-step,id)
    end else g:reserve(p.local_position.x,p.local_position.y,id,p.key)end
  end
  local mixers=0
  if straight then for _,part in ipairs(cells)do local count=0;for _,t in ipairs(part.terminals)do if t.mixed then count=count+1 end end;mixers=math.max(mixers,count)end end
  local bodyx=(span or #keys*3)+(dense and 3+mixers*2 or 5+mixers*4)+(plan.rate_search and 8 or 0);local top=intake_bottom and intake_bottom+3 or 8+#ports*pitch
  if #outputs>0 then top=math.max(top,output_top+math.max(1,#left,#right)+2)end
  local connections={};plan.production_rows={};plan.mall_buffers={};plan.mall_links={}
  plan.lane_balancers={};plan.feed_corridors={};plan.feed_branches={};plan.cell_links={};plan.production_groups={}
  local limit=Paving.limit(s)
  if limit then
    local fitted_groups,fitted_cells={},{};local budget=limit-bodyx-2
    local function append(group,part)fitted_groups[#fitted_groups+1]=group;fitted_cells[#fitted_cells+1]=part end
    for i,part in ipairs(cells)do local group=groups[i]
      if part.fluid_cell and part.g.maxx-part.g.minx>budget then
        append(group,build_group(group,false,budget))
      elseif part.shared_row and part.g.maxx-part.g.minx>budget then
        append(group,SharedRows.build(c,s,group,pool,equipment,budget))
      elseif s.mode=='mall'and Paving.axis(s)=='x'and bodyx+part.g.maxx-part.g.minx-g.minx>limit then
        U.fail('width',bodyx+part.g.maxx-part.g.minx-g.minx+Paving.margin(s)*2,s.max_width)
      elseif s.mode~='mall'and part.straight_cell and part.g.maxx-part.g.minx>budget
        and #group.nodes==1 and not group.nodes[1].local_supply then
        -- Continue the same recipe in successive compact sections. A plot
        -- width limit must not switch the entire factory to another layout.
        local n=group.nodes[1];local p=c.machines[n.machine]
        local maximum=math.max(1,math.floor((budget-2)/(p.tile_width+1)))
        local done=0
        while done<n.count do
          local count=math.min(maximum,n.count-done);local node=U.copy(n)
          node.count=count;node.crafts=n.crafts*count/n.count
          local section=U.copy(group);section.nodes={node};section.count=count;section.parts=nil
          append(section,build_group(section));done=done+count
        end
      else append(group,part)end
    end
    groups,cells=fitted_groups,fitted_cells
  end
  local function route(key,from,to,id,straight_route)
    connections[#connections+1]={key=key,from=from,to=to,id=id,direct_route=true,straight_route=straight_route}
  end
  local function translate(point,dx,dy) point.x=point.x+dx;point.y=point.y+dy end
  local function crossings_fit(constraints,candidate)
    -- Pack taps only while every crossed lane can still retain its own
    -- splitter and paired underground endpoints at the selected tier.
    local all={};for _,old in ipairs(constraints)do all[#all+1]=old end;if candidate then all[#all+1]=candidate end
    for key,b in pairs(buses)do
      local cuts={}
      for _,t in ipairs(all)do local source=buses[t.key]
        if source.x<b.x then
          local center=t.y-(t.produce and 0 or 1)
          local lo=center-(t.merge and 2 or 1)
          if not t.produce and b.x>source.x+1 then lo=lo+1 end
          cuts[#cuts+1]={lo=lo,hi=center+(t.merge and 2 or t.produce and 1 or 2)}
        end
      end
      table.sort(cuts,function(a,z)return a.lo<z.lo end)
      local lo,hi
      for _,cut in ipairs(cuts)do
        if not hi or cut.lo>hi then lo,hi=cut.lo,cut.hi else hi=math.max(hi,cut.hi)end
        if hi-lo>equipment.underground.max_underground_distance or(b.import and lo<=b.import.y)then return false end
        for _,t in ipairs(all)do if t.key==key then
          local center=t.y-(t.produce and 0 or 1)
          if center>=lo and center<=hi then return false end
        end end
      end
    end
    return true
  end
  local function constraints_for(part,dy)
    local result={}
    for key,b in pairs(buses)do for _,t in ipairs(b.taps)do result[#result+1]={key=key,y=t.y+(t.produce and 0 or 1),produce=t.produce,merge=t.merge}end end
    if not plan.rate_search then for _,t in ipairs(part.terminals)do if not t.mixed and not t.fluid then result[#result+1]={key=t.key,y=t.port.y+dy,produce=t.produce,merge=t.produce and preserved[t.key]}end end end
    return result
  end
  local previous_bottom=intake_bottom or 0
  local function mixer_x(part,dx,index)
    if plan.rate_search and s._shape_rows=='double'and dx then
      local count=0;for _,t in ipairs(part.terminals)do if t.mixed then count=count+1 end end
      return dx+part.g.minx-2*count-1+(index-1)*2
    end
    return(span or #keys*3)+2+(index-1)*2
  end
  local function prepare_junctions(part,dy,dx)
    local constraints=constraints_for(part,dy);local raw={}
    if not crossings_fit(constraints)then return end
    local minimum=plan.rate_search and s._shape_rows=='double'and(intake_bottom or 0)+1 or previous_bottom-2
    local index=0
    if plan.rate_search then for _,t in ipairs(part.terminals)do if not t.mixed and not t.fluid then
      local value=t.port.y+dy;local chosen
      for delta=0,160 do
        local candidate=value+delta;local clear=true
        for _,old in ipairs(constraints)do if math.abs(candidate-old.y)<2 then clear=false;break end end
        if clear and crossings_fit(constraints,{key=t.key,y=candidate,produce=t.produce,merge=t.produce and preserved[t.key]})then chosen=candidate;break end
      end
      if not chosen then return end
      raw[t]={chosen};constraints[#constraints+1]={key=t.key,y=chosen,produce=t.produce,merge=t.produce and preserved[t.key]}
    end end end
    for _,t in ipairs(part.terminals)do if t.mixed then
      index=index+1;local x=mixer_x(part,dx,index);local y=t.port.y+dy
      raw[t]={}
      if not g:free(x,y)then return end
      for j,key in ipairs(t.keys)do
        local side=j==1 and -1 or 1;local value=y+side;local chosen
        if not g:free(x,y+side)then return end
        for attempt=1,200 do
          if value<minimum then break end
          local clear=g:free(x,value)and g:free(x-1,value)
          if clear then for _,old in ipairs(constraints)do if math.abs(value-old.y)<2 then clear=false;break end end end
          if clear and crossings_fit(constraints,{key=key,y=value})then chosen=value;break end
          value=value+side
        end
        if not chosen then return end
        constraints[#constraints+1]={key=key,y=chosen};raw[t][j]=chosen
      end
    end end
    return raw
  end
  local placed_boxes={};local packing_top=top
  for ci,part in ipairs(cells) do
    local producers,consumers={},{}
    for _,t in ipairs(part.terminals) do local list=t.produce and producers or consumers;list[#list+1]=t end
    local mixcount=0;for _,t in ipairs(part.terminals)do if t.mixed then mixcount=mixcount+1 end end
    local padding=mixcount>0 and(dense and mixcount*2+1 or mixcount*4+2)or 0
    local dx,dy=bodyx-part.g.minx,(straight and top+padding or top+#producers*pitch+2)-part.g.miny
    local prepared
    if plan.rate_search and s._shape_rows=='double'then
      local xs,ys={[bodyx]=true},{[packing_top+padding]=true}
      for _,box in ipairs(placed_boxes)do xs[box.x1+3]=true;ys[box.y1+2+padding]=true;ys[box.y0]=true end
      local choices={};local pw,ph=part.g.maxx-part.g.minx,part.g.maxy-part.g.miny
      for _,x in ipairs(U.sorted(xs))do for _,y in ipairs(U.sorted(ys))do
        if not limit or x+pw<=limit-2 then
          local overlap=false
          for _,box in ipairs(placed_boxes)do if x<box.x1+1 and x+pw>box.x0-1 and y<box.y1+1 and y+ph>box.y0-1 then overlap=true;break end end
          if not overlap then choices[#choices+1]={x=x,y=y,score=math.max(g.maxx,x+pw)*(math.max(g.maxy,y+ph)-g.miny)+x*.1}end
        end
      end end
      table.sort(choices,function(a,b)return a.score==b.score and(a.y==b.y and a.x<b.x or a.y<b.y)or a.score<b.score end)
      for index=1,math.min(40,#choices)do local v=choices[index];local px,py=v.x-part.g.minx,v.y-part.g.miny;local clear=true
        for cell in pairs(part.g.occupied)do local x,y=cell:match('^(-?%d+),(-?%d+)$');if not g:free(tonumber(x)+px,tonumber(y)+py)then clear=false;break end end
        if clear then local junctions=prepare_junctions(part,py,px)
          if junctions then dx,dy,prepared=px,py,junctions;break end
        end
      end
    end
    if dense then
      local tries=0;prepared=prepared or prepare_junctions(part,dy,dx)
      while not prepared do
        dy=dy+1;tries=tries+1;if tries>200 then U.fail('layout-ports')end
        prepared=prepare_junctions(part,dy,dx)
      end
    end
    placed_boxes[#placed_boxes+1]={x0=dx+part.g.minx,y0=dy+part.g.miny,x1=dx+part.g.maxx,y1=dy+part.g.maxy}
    local offset=#g.entities;local first=offset+1
    for _,e in ipairs(part.g.entities) do
      local extra=U.copy(e);extra.entity_number=nil;extra.position=nil
      g:add(e.name,e.position.x+dx,e.position.y+dy,e.direction,extra)
    end
    for k,id in pairs(part.g.reserved) do local x,y=k:match('^(-?%d+),(-?%d+)$');g:reserve(tonumber(x)+dx,tonumber(y)+dy,ci..'/'..id,part.g.fluid_ports[k]) end
    for _,t in ipairs(part.g.tunnels)do
      if t.horizontal then g:tunnel(t.kind,t.lo+dx,t.y+dy,t.hi+dx,t.y+dy)
      else g:tunnel(t.kind,t.x+dx,t.lo+dy,t.x+dx,t.hi+dy)end
    end
    local row_offset=#plan.production_rows
    for _,row in ipairs(part.rows) do
      row.id=#plan.production_rows+1
      row.bus='recipe'
      row.bounds.x0=row.bounds.x0+dx;row.bounds.x1=row.bounds.x1+dx
      row.bounds.y0=row.bounds.y0+dy;row.bounds.y1=row.bounds.y1+dy
      for _,list in ipairs({row.machines,row.input_inserters,row.output_inserters}) do for j,n in ipairs(list) do list[j]=n+offset end end
      plan.production_rows[#plan.production_rows+1]=row
    end
    for _,buffer in ipairs(part.stocks) do buffer.chest=buffer.chest+offset;buffer.inserter=buffer.inserter+offset;plan.mall_buffers[#plan.mall_buffers+1]=buffer end
    for _,link in ipairs(part.links) do for _,field in ipairs({'source','target','inserter'}) do link[field]=link[field]+offset end;plan.mall_links[#plan.mall_links+1]=link end
    for _,link in ipairs(part.cell_links or{})do
      for _,field in ipairs({'source','target','output','inserter','first','last'})do link[field]=link[field]+offset end
      plan.cell_links[#plan.cell_links+1]=link
    end
    local recipes={};for _,n in ipairs(groups[ci].nodes)do recipes[n.recipe]=true end
    plan.production_groups[#plan.production_groups+1]={recipes=U.sorted(recipes),inputs=U.sorted(groups[ci].inputs or{}),local_items=U.sorted(groups[ci].local_keys or{}),rows={first=row_offset+1,last=#plan.production_rows},dual_feed=part.dual_feed or false}
    for _,balance in ipairs(part.balances or{})do balance.entity=balance.entity+offset;balance.row=balance.row+row_offset;plan.lane_balancers[#plan.lane_balancers+1]=balance end
    for _,corridor in ipairs(part.corridors or{})do corridor.x0=corridor.x0+dx;corridor.x1=corridor.x1+dx;corridor.y=corridor.y+dy;plan.feed_corridors[#plan.feed_corridors+1]=corridor end
    events[#events+1]={stage='machines',first=first,last=#g.entities}
    local bottom=dy+part.g.maxy+(modern and 0 or 5)
    local function tap(key,y,produce,port)
      local b=buses[key];local merge=produce and preserved[key]
      b.first=math.min(b.first,y-(merge and 1 or 0));b.last=math.max(b.last,y+((not produce or merge)and 1 or 0))
      b.taps[#b.taps+1]={y=y,produce=produce,merge=merge,port=port}
      local stub={x=b.x+1,y=y+(merge and -1 or produce and 0 or 1),d=merge and 2 or produce and 3 or 1,plain=true,id=port.id}
      g:reserve(stub.x,stub.y,port.id)
      if not produce then g:reserve(stub.x+1,stub.y,port.id) end
      if merge then g:reserve(b.x+1,y+1,'unused-merge/'..port.id)end
      if packed then
        -- The adjacent lane passes under the splitter and its branch.
        -- Farther lanes only need to pass under the branch itself.
        for _,other in ipairs(keys)do local crossed=buses[other]
          if crossed.x>b.x then
            local lo=y-(merge and 2 or 1)
            if dense and not produce and crossed.x>b.x+1 then lo=lo+1 end
            crossed.cuts[#crossed.cuts+1]={lo=lo,hi=y+(merge and 2 or produce and 1 or 2)}
          end
        end
        for x=stub.x,straight and math.min(bodyx-4,port.x)or bodyx-4 do if not g.reserved[G.cell(x,stub.y)]then g:reserve(x,stub.y,port.id)end end
      end
      route(key,produce and port or stub,produce and stub or port,port.id,straight and not produce and stub.y==port.y and not(plan.rate_search and s._shape_rows=='double'))
      if straight and not produce then plan.feed_branches[#plan.feed_branches+1]={key=key,x0=stub.x,x1=port.x,y=stub.y}end
    end
    if straight then
      local mixed=0;local junction_bottom=bottom;local constraints={};local junctions={}
      constraints=constraints_for(part,dy)
      local function nearby(key,y,side)
        local function clear(value)
          for _,old in ipairs(constraints)do
            if math.abs(value-old.y)<(dense and 2 or 4)then return false end
          end
          if dense and not crossings_fit(constraints,{key=key,y=value})then return false end
          return true
        end
        local tries=0
        while not clear(y)do y=y+side;tries=tries+1;if tries>200 then U.fail('layout-ports')end end
        constraints[#constraints+1]={key=key,y=y};return y
      end
      local function leg(x,from,to,key,step)
        if plan.rate_search and s._shape_rows=='double'then
          Router.route(g,{x=x,y=from,d=step>0 and 2 or 0,plain=true},{x=x,y=to,d=step>0 and 2 or 0,plain=true},'item',key,equipment.belt,equipment.underground,'mixed-leg/'..ci..'/'..key,false,12000)
          return
        end
        local d=step>0 and 8 or 0;local y=from
        while (to-y)*step>=0 do
          if not g:free(x,y)then log('AFP MIX OCCUPIED '..ci..' '..key..' '..x..','..y..' '..tostring(g.reserved[G.cell(x,y)]));U.fail('layout-ports')end
          local nexty=y+step
          if (to-nexty)*step>=0 and not g:free(x,nexty)then
            while (to-nexty)*step>=0 and not g:free(x,nexty)do nexty=nexty+step end
            if dense then while (to-nexty-step)*step>=0 and not g:free(x,nexty+step)do
              nexty=nexty+step
              while (to-nexty)*step>=0 and not g:free(x,nexty)do nexty=nexty+step end
            end end
            if (to-nexty)*step<0 or math.abs(nexty-y)>equipment.underground.max_underground_distance then log('AFP MIX LEG BLOCKED '..ci..' '..key..' x='..x..' from='..from..' to='..to..' blocked='..y..'/'..nexty);U.fail('infrastructure',equipment.underground.name)end
            g:tile(equipment.underground.name,x,y,d,{type='input'},key);g:tile(equipment.underground.name,x,nexty,d,{type='output'},key)
            g:tunnel('item',x,y,x,nexty);y=nexty+step
          else g:tile(equipment.belt.name,x,y,d,nil,key);y=y+step end
        end
      end
      local function mixed_line(junction)
        if plan.rate_search and s._shape_rows=='double'then
          local made=Router.route(g,{x=junction.x,y=junction.y,d=1,plain=true},junction.port,'item',junction.keys,equipment.belt,equipment.underground,junction.port.id,false,12000)
          for _,e in ipairs(made)do e.tags=e.tags or{};e.tags.afp_stream=table.concat(junction.keys,'|')end
          return
        end
        local x,y=junction.x,junction.y;local last=junction.port.x
        while x<=last do
          if not g:free(x,y,nil,nil,junction.port.id)then U.fail('layout-ports')end
          local nextx=x+1
          if nextx<=last and not g:free(nextx,y,nil,nil,junction.port.id)then
            while nextx<=last and not g:free(nextx,y,nil,nil,junction.port.id)do nextx=nextx+1 end
            while nextx<last and not g:free(nextx+1,y,nil,nil,junction.port.id)do
              nextx=nextx+1
              while nextx<=last and not g:free(nextx,y,nil,nil,junction.port.id)do nextx=nextx+1 end
            end
            if nextx>last or nextx-x>equipment.underground.max_underground_distance then U.fail('infrastructure',equipment.underground.name)end
            g:tile(equipment.underground.name,x,y,4,{type='input'},junction.keys)
            g:tile(equipment.underground.name,nextx,y,4,{type='output'},junction.keys)
            g:tunnel('item',x,y,nextx,y);x=nextx+1
          else g:tile(equipment.belt.name,x,y,4,nil,junction.keys);x=x+1 end
        end
      end
      for _,t in ipairs(part.terminals)do
        translate(t.port,dx,dy);t.port.id=ci..'/'..t.port.id
        if plan.rate_search and not t.fluid and t.port.d then
          local d=t.produce and t.port.d or(t.port.d+2)%4
          for step=1,2 do g:reserve(t.port.x+G.dx[d+1]*step,t.port.y+G.dy[d+1]*step,t.port.id)end
        end
        if t.fluid then
          local b=fluid_buses[t.key];b.first=math.min(b.first,t.port.y);b.last=math.max(b.last,t.port.y)
          b.taps[#b.taps+1]={port=t.port}
          connections[#connections+1]={key=t.key,from=t.port,to={x=b.x,y=t.port.y},id=t.port.id,direct_route=true,local_route=true,network=t.key}
        elseif t.mixed then
          mixed=mixed+1;local x=plan.rate_search and mixer_x(part,dx,mixed)or(span or #keys*3)+2+(mixed-1)*(dense and 2 or 4);local y=t.port.y
          for j,key in ipairs(t.keys)do
            local side=j==1 and -1 or 1;local rawy=dense and prepared[t][j]or nearby(key,y+side,side)
            junction_bottom=math.max(junction_bottom,rawy+2)
            leg(x,rawy,y+(j==1 and -1 or 1),key,j==1 and 1 or-1)
            local port={x=x-1,y=rawy,d=1,plain=true,id=t.port.id..'/'..j}
            g:reserve(port.x,port.y,port.id);tap(key,rawy-1,false,port)
          end
          if dense then junctions[#junctions+1]={x=x,y=y,keys=t.keys,port=t.port}
          else for px=x,t.port.x do
              if not g:free(px,y,nil,nil,t.port.id)then U.fail('layout-ports')end
              g:tile(equipment.belt.name,px,y,4,nil,t.keys)
          end end
          plan.feed_corridors[#plan.feed_corridors+1]={keys=t.keys,x0=x,x1=t.port.x,y=y}
        else
          local y=plan.rate_search and prepared[t][1]or t.port.y
          junction_bottom=math.max(junction_bottom,y+2)
          tap(t.key,y-(t.produce and 0 or 1),t.produce,t.port)
        end
      end
      for _,junction in ipairs(junctions)do mixed_line(junction)end
      if plan.rate_search then g:protect_item_ends()end
      previous_bottom=math.max(previous_bottom,junction_bottom)
      local next_padding=0
      if dense and cells[ci+1]then
        local count=0;for _,t in ipairs(cells[ci+1].terminals)do if t.mixed then count=count+1 end end
        if count>0 then next_padding=count*2+1 end
      end
      -- Junction clearance can overlap the empty area beside the previous
      -- machines. Keep one gap between occupied cells instead of adding
      -- the next cell's mixing allowance to the inter-row gap as well.
      top=dense and math.max(junction_bottom,g.maxy)+1-next_padding or junction_bottom+2
    else
    for i,t in ipairs(producers) do
      translate(t.port,dx,dy);t.port.id=ci..'/'..t.port.id
      tap(t.key,top+(i-1)*pitch,true,t.port)
    end
    local feeds={}
    for _,t in ipairs(consumers) do
      translate(t.port,dx,dy);t.port.id=ci..'/'..t.port.id
      feeds[t.key]=feeds[t.key] or {};feeds[t.key][#feeds[t.key]+1]=t
    end
    local feedkeys=U.sorted(feeds)
    for i,key in ipairs(feedkeys) do
      local list=feeds[key];local y=bottom+(i-1)*pitch
      table.sort(list,function(a,b)return a.port.x==b.port.x and a.port.y<b.port.y or a.port.x<b.port.x end)
      local columns={};local previous=bodyx-3
      for j,t in ipairs(list) do columns[j]=math.max(previous+3,t.port.x);previous=columns[j] end
      local start={x=bodyx-4,y=y,d=1,plain=true,id='feed/'..ci..'/'..key}
      g:reserve(start.x,start.y,start.id)
      tap(key,y-1,false,start)
      local forks={};for j,col in ipairs(columns) do forks[col]=j end
      for x=start.x+1,columns[#columns] do
        local j=forks[x]
        if j and j<#columns then g:add(equipment.splitter.name,x+0.5,y,4,nil,key)
        else g:tile(equipment.belt.name,x,y,x==columns[#columns] and 0 or 4,nil,key) end
      end
      for j,t in ipairs(list) do
        local from={x=columns[j]+(j<#columns and 1 or 0),y=y-1,d=0,plain=true,id=t.port.id}
        g:reserve(from.x,from.y,t.port.id);g:reserve(from.x,from.y-1,t.port.id)
        route(key,from,t.port,t.port.id)
      end
    end
    top=bottom+#feedkeys*pitch+4
    end
  end
  -- Keep every external interface on the main-bus side, two tiles apart.
  if not modern then for i,p in ipairs(ports) do
    p.index=i;p.local_position=s._mall_compact_axes and {x=2*(i-1),y=-4} or {x=-4,y=2*(i-1)};p.staging_position=nil
    local wx,wy=U.rotate(p.local_position.x+0.5,(mirror and -1 or 1)*(p.local_position.y+0.5),turns);p.position={x=wx,y=wy}
  end
  Inputs.assign(s,plan);Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan)
  end
  local entrance_x,entrance_y=-6,g.miny-2;local entrance_bottom=g.maxy+2;local entrance_right=g.maxx+4
  for _,p in ipairs(outputs)do
    local b=buses[p.key]or fluid_buses[p.key];local id='user/'..p.id
    if fluid_buses[p.key]then
      b.first=math.min(b.first,0);b.last=math.max(b.last,0)
      g:reserve(b.x,0,id,p.key)
      connections[#connections+1]={key=p.key,from={x=p.local_position.x,y=p.local_position.y},to={x=b.x,y=0},id=id,direct_route=true,local_route=true,network=p.key}
    else
    local from={x=b.x,y=p.output_y,d=0,plain=true,id=id}
    local to={x=p.local_position.x,y=p.local_position.y,d=0,plain=true,id=id}
    b.first=math.min(b.first,from.y+1)
    g:reserve(from.x,from.y,id);g:reserve(to.x,to.y,id)
    route(p.key,from,to,id)
    entrance_right=math.max(entrance_right,to.x+6);entrance_y=math.min(entrance_y,to.y-6)
    end
  end
  for i,p in ipairs(ports) do
    local b=buses[p.key]or fluid_buses[p.key];local id='user/'..p.id;local y=pitch*i
    entrance_x=math.min(entrance_x,p.local_position.x-6);entrance_y=math.min(entrance_y,p.local_position.y-6);entrance_bottom=math.max(entrance_bottom,p.local_position.y+6)
    if fluid_buses[p.key]then
      local from={x=p.local_position.x,y=p.local_position.y};local to={x=b.x,y=0}
      b.first=math.min(b.first,to.y);b.last=math.max(b.last,to.y)
      g:reserve(to.x,to.y,id,p.key)
      connections[#connections+1]={key=p.key,from=from,to=to,id=id,direct_route=true,local_route=true,network=p.key}
    elseif not intake_bottom then
      b.first=math.min(b.first,y);b.last=math.max(b.last,y)
      local from={x=p.local_position.x,y=p.local_position.y,d=p.pinned_direction or (s._mall_compact_axes and 2 or 1),plain=true,id=id}
      local to={x=b.x,y=y,d=2,plain=true,id=id}
      g:reserve(from.x,from.y,id);g:reserve(from.x+G.dx[from.d+1],from.y+G.dy[from.d+1],id);g:reserve(to.x,to.y,id)
      route(p.key,from,to,id);b.import=to
    end
  end
  local first=#g.entities+1
  for _,key in ipairs(keys) do local b=buses[key];local taps,merges={},{}
    for _,t in ipairs(b.taps) do if not t.produce then taps[t.y]=t elseif t.merge then merges[t.y]=t end end
    table.sort(b.cuts,function(a,z)return a.lo<z.lo end)
    local cuts={}
    for _,cut in ipairs(b.cuts)do
      local last=cuts[#cuts]
      if last and cut.lo<=last.hi then last.hi=math.max(last.hi,cut.hi)else cuts[#cuts+1]=cut end
    end
    local ci,y=1,b.first
    while y<=b.last do
      local cut=cuts[ci]
      if cut and cut.lo<b.first then ci=ci+1
      elseif cut and y==cut.lo then
        if cut.hi-cut.lo>equipment.underground.max_underground_distance then log('AFP BUS CROSSING TOO LONG '..key..' '..cut.lo..'/'..cut.hi);U.fail('infrastructure',equipment.underground.name)end
        g:tile(equipment.underground.name,b.x,cut.lo,b.direction,{type=b.direction==8 and'input'or'output'},key)
        g:tile(equipment.underground.name,b.x,cut.hi,b.direction,{type=b.direction==8 and'output'or'input'},key)
        g:tunnel('item',b.x,cut.lo,b.x,cut.hi);y=cut.hi+1;ci=ci+1
      else
      if not (b.import and y==b.import.y) then
        if merges[y]then
          g:add(equipment.splitter.name,b.x+1,y+0.5,8,{input_priority='left',output_priority='right'},key)
        elseif taps[y] then
          g:add(equipment.splitter.name,b.x+1,y+0.5,8,nil,key)
        else g:tile(equipment.belt.name,b.x,y,b.direction,nil,key) end
      end
      y=y+1
      end
    end
  end
  for _,key in ipairs(fluid_keys)do local b=fluid_buses[key];local keep={}
    for _,t in ipairs(b.taps)do keep[G.cell(b.x,t.port.y)]=true end
    keep[G.cell(b.x,0)]=true
    Pipes.line(g,equipment.pipe,equipment.pipeug,b.x,b.first,b.x,b.last,key,keep)
    entrance_x=math.min(entrance_x,b.x-5)
  end
  events[#events+1]={stage='recipe-bus',first=first,last=#g.entities}
  events[#events+1]={stage='ports',first=#g.entities+1,last=#g.entities}
  -- Short connections first, but all future ports and the full trunks are
  -- already reserved, so a route cannot strand another machine's terminal.
  table.sort(connections,function(a,b)
    local af,bf=U.split(a.key)=='fluid',U.split(b.key)=='fluid';if af~=bf then return af end
    local function length(t) return math.abs(t.from.x-t.to.x)+math.abs(t.from.y-t.to.y) end
    local al,bl=length(a),length(b);if al~=bl then return al<bl end;return a.id<b.id
  end)
  local limit=Paving.limit(s)
  if limit and Paving.span(s,g)>limit then U.fail('width',Paving.span(s,g)+Paving.margin(s)*2,s.max_width) end
  first=#g.entities+1
  if s.mode=='mall'and not(s.infrastructure and s.infrastructure.pole)then
    local best=C.pick(c,'electric-pole',nil,function(p)return p.get_supply_area_distance('normal')>0 and p.get_max_wire_distance('normal')>0 end,function(p)return p.get_max_wire_distance('normal')end)
    for _,p in ipairs(C.options(c,'electric-pole',function(v)return v.get_max_wire_distance('normal')end))do
      if p.tile_width<=best.tile_width and p.tile_height<=best.tile_height and p.get_supply_area_distance('normal')>=best.get_supply_area_distance('normal')and p.get_max_wire_distance('normal')>=best.get_max_wire_distance('normal')then best=p end
    end
    plan.automatic_pole=best.name
  end
  local pole=(not straight or plan.rate_search)and Power.add(c,s,g,plan)
  events[#events+1]={stage='power',first=first,last=#g.entities}
  local start=ports[1] and ports[1].local_position or {x=g.minx,y=g.miny}
  local stop=ports[#ports] and ports[#ports].local_position or start
  local main_direction=((s.direction or 2)-1)*4
  local bus_bounds={x0=0,y0=math.huge,x1=span or #keys*3,y1=-math.huge}
  for _,b in pairs(buses)do bus_bounds.y0=math.min(bus_bounds.y0,b.first);bus_bounds.y1=math.max(bus_bounds.y1,b.last+1)end
  plan.bus_hierarchy={levels=3,generated_levels=2,main={id='main',external=true,built=false,entities={},lanes={},direction=main_direction,interface={from=U.copy(start),to=U.copy(stop)}},
    recipe={id='recipe',target=plan.target,direction=(main_direction+(s.side==2 and-4 or 4))%16,bounds=bus_bounds,lanes={}},lines=plan.production_rows,interfaces={}}
  for _,p in ipairs(plan.ports)do plan.bus_hierarchy.interfaces[#plan.bus_hierarchy.interfaces+1]={key=p.key,kind=p.kind,port=p.id,position=U.copy(p.local_position),from=p.kind=='in'and'main'or'recipe',to=p.kind=='in'and'recipe'or'main'}end
  if packed then
    plan.bus_hierarchy.recipe.group_size=Bus.size;plan.bus_hierarchy.recipe.group_gap=Bus.gap
    for _,key in ipairs(keys)do local b=buses[key]
      plan.bus_hierarchy.recipe.lanes[#plan.bus_hierarchy.recipe.lanes+1]={key=key,x=b.x,y0=b.first,y1=b.last,group=b.group,lane=b.lane,role=b.role}
    end
  end
  plan.layout_revision=32
  local dual_groups=0;for _,part in ipairs(cells)do if part.dual_feed then dual_groups=dual_groups+1 end end
  plan.layout_stats={dual_groups=dual_groups,compact=true,mall_local=s.mode=='mall',rate_local=s.mode~='mall',mall_groups=#cells,direct_links=#plan.mall_links,
    production_rows=#plan.production_rows,closed_buses=0,straight_buses=#keys,recipe_bus_taps=#connections,
    main_bus_taps=0,external_interfaces=#plan.ports,hierarchy_levels=3,generated_main_bus_entities=0}
  return {g=g,events=events,plan=plan,connections=connections,special={},buses={},turns=turns,mirror=mirror,
    power=pole and pole.name,equipment={belt=equipment.belt.name,underground=equipment.underground.name,splitter=equipment.splitter.name,pipe=equipment.pipe and equipment.pipe.name,pipeug=equipment.pipeug and equipment.pipeug.name},
    connection_index=1,special_index=1,stage='routes',route_bounds={x0=math.min(entrance_x,g.minx-2),y0=entrance_y,x1=entrance_right,y1=entrance_bottom}}
end
return ML
