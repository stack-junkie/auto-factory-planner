local U=require('scripts.util')
local Rows=require('scripts.rows')
local A=require('scripts.arrangement')
local G=require('scripts.geometry')
local Hierarchy=require('scripts.hierarchy')
local Mall=require('scripts.mall')
local Paving=require('scripts.paving')
local Inputs=require('scripts.inputs')
local Bus=require('scripts.bus')
local InputDisplays=require('scripts.input_displays')
local Intake=require('scripts.intake')
local C={}
function C.accepts(plan,specs,belt,underground)
  if not belt or not underground or underground.max_underground_distance<5 then return false end
  for key,f in pairs(plan.flows) do if U.split(key)~='item' or f.bootstrap or f.controlled or f.internal_export then return false end end
  for _,spec in ipairs(specs) do
    for _,req in ipairs(spec.requirements) do
      if U.split(req.key)~='item' then return false end
    end
  end
  return true
end
local function compose(g,events,c,s,plan,specs,equipment,turns,mirror,row_limit,gap)
  local keys=U.sorted(plan.flows);local buses={};local taps={};local rows={}
  local packed
  if not s._legacy_bus and not s._legacy_layout then packed,keys=Bus.pack(plan,keys,not s._legacy_rate and Intake.order(s,plan)or nil)end
  if not s._legacy_rate then plan.recipe_bus_order=U.copy(keys)end
  if not s._legacy_rate then plan.intake_revision=1 end
  plan.production_rows={}
  for i,key in ipairs(keys) do local lane=packed and packed[key]
    buses[key]={y=lane and -lane.position or 1-i,group=lane and lane.group,lane=lane and lane.lane,role=lane and lane.role,
      above=0,below=0,closed=false,fluid=false,taps={},sensors={},cuts={},forks={},turns={}}
  end
  local function connect(key,port,produce,rate)
    local tap={key=key,port=port,produce=produce,rate=rate,column=port.x,bus='recipe',line=tonumber(port.id:match('^row/(%d+)/'))}
    taps[#taps+1]=tap;buses[key].taps[#buses[key].taps+1]=tap
  end
  local x=4
  for _,spec in ipairs(specs) do
    x=Rows.build({g=g,x=x,y=0,reach=spec.reach,belt=equipment.belt,underground=equipment.underground,splitter=equipment.splitter,compact=true,row_limit=row_limit,gap=gap,parallel=spec.parallel,shared=spec.shared,
      ends=function()return {} end,
      connect=connect,events=events,local_routes=rows,plan=plan,recipe=spec.recipe},spec.node,spec.prototype,spec.requirements,spec.chosen)
  end
  local length=0
  for _,key in ipairs(keys) do
    local b=buses[key];local producers,consumers={},{}
    for _,tap in ipairs(b.taps) do local a=tap.produce and producers or consumers;a[#a+1]=tap end
    table.sort(consumers,function(a,b)return a.column<b.column end)
    local external=false;for _,port in ipairs(plan.ports) do if port.key==key then external=true end end
    local first,last=math.huge,-math.huge
    for _,tap in ipairs(b.taps) do first=math.min(first,tap.column);last=math.max(last,tap.column) end
    b.direction=#consumers==0 and 12 or 4
    b.minx=external and 0 or first;b.maxx=last
    for i,tap in ipairs(consumers) do
      tap.fork=i<#consumers;tap.station=tap.column-(tap.fork and 1 or 0)
      if tap.fork then b.forks[tap.station]=tap else b.turns[tap.station]=true end
    end
    for _,tap in ipairs(producers) do tap.station=tap.column end
    length=math.max(length,last)
  end
  -- Surface branches cross the packed bus. Only the crossed resource lanes
  -- go underground, rather than spreading every lane four tiles apart.
  for _,tap in ipairs(taps) do
    local b=buses[tap.key]
    for _,key in ipairs(keys) do local lower=buses[key]
      if lower.y>b.y then
        local lo,hi=math.huge,-math.huge
        local function block(col) if col>=lower.minx and col<=lower.maxx then lo=math.min(lo,col);hi=math.max(hi,col) end end
        block(tap.column)
        if tap.fork and lower.y==b.y+1 then block(tap.station) end
        if lo<math.huge then lower.cuts[#lower.cuts+1]={lo=lo-1,hi=hi+1} end
      end
    end
  end
  for _,key in ipairs(keys) do
    local b=buses[key];table.sort(b.cuts,function(a,b)return a.lo<b.lo end)
    local merged={}
    for _,cut in ipairs(b.cuts) do
      local last=merged[#merged]
      if last and cut.lo<=last.hi then last.hi=math.max(last.hi,cut.hi) else merged[#merged+1]={lo=cut.lo,hi=cut.hi} end
    end
    b.cuts=merged
    for _,cut in ipairs(merged) do
      if cut.hi-cut.lo>equipment.underground.max_underground_distance then U.fail('infrastructure',equipment.underground.name) end
    end
  end
  table.sort(plan.ports,function(a,b)return buses[a.key].y<buses[b.key].y end)
  local width=#plan.ports+3;local first=math.huge
  for i,port in ipairs(plan.ports) do first=math.min(first,buses[port.key].y-2*(i-1)-1) end
  local connections={};local low=first-1;local high=first+2*(#plan.ports-1)+1
  local port_first=#g.entities+1
  for i,port in ipairs(plan.ports) do
    port.index=i;port.local_position={x=-width,y=first+2*(i-1)};port.staging_position=nil
    local wx,wy=U.rotate(port.local_position.x+0.5,(mirror and -1 or 1)*(port.local_position.y+0.5),turns);port.position={x=wx,y=wy}
  end
  Inputs.assign(s,plan);Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan)
  local left,right,top,bottom=-width-1,-width+1,low,high
  for i,port in ipairs(plan.ports) do
    local id='user/'..port.id;local input=port.kind=='in';local d=input and 1 or 3
    local source_y=first+2*(i-1);local header_y=buses[port.key].y;local column=-1-i
    if input and s._project and s._project.offset and (port.local_position.x~=-width or port.local_position.y~=source_y or port.pinned_direction~=1) then
      local id='user/'..port.id;local pos=port.local_position;local d=port.pinned_direction or 1
      local from={x=pos.x,y=pos.y,d=d,plain=true,id=id};local to={x=-1,y=header_y,d=1,plain=true,id=id}
      g:reserve(from.x,from.y,id);g:reserve(from.x+G.dx[d+1],from.y+G.dy[d+1],id)
      g:reserve(to.x,to.y,id);g:reserve(to.x-1,to.y,id)
      connections[#connections+1]={key=port.key,from=from,to=to,id=id,direct_route=true}
      left=math.min(left,pos.x-10);top=math.min(top,pos.y-10);bottom=math.max(bottom,pos.y+10)
      right=math.max(right,g.maxx+2,pos.x+8)
    else
    -- Ordered staircases have no crossings. Unlike a greedy route between
    -- dense lane ends, they cannot seal the next connector into a pocket.
    for x=-width+2,column do g:tile(equipment.belt.name,x,source_y,input and (x==column and 8 or 4) or 12,nil,port.key) end
    for y=source_y+1,header_y-1 do g:tile(equipment.belt.name,column,y,input and 8 or 0,nil,port.key) end
    for x=column,-1 do g:tile(equipment.belt.name,x,header_y,input and 4 or x==column and 0 or 12,nil,port.key) end
    local user={x=-width,y=source_y,d=d,plain=true,id=id}
    local entry={x=-width+1,y=source_y,d=d,plain=true,id=id}
    g:reserve(user.x,user.y,id);g:reserve(entry.x,entry.y,id)
    connections[#connections+1]={key=port.key,from=input and user or entry,to=input and entry or user,id=id,direct_route=true}
    end
  end
  events[#events+1]={stage='ports',first=port_first,last=#g.entities}
  if not s._legacy_clearance then InputDisplays.reserve(c,s,g,plan)end
  local splitters=0
  for _,key in ipairs(keys) do
    local b=buses[key];local start=#g.entities+1;local cut_index=1;local x=b.minx
    while x<=b.maxx do
      local cut=b.cuts[cut_index]
      if cut and x==cut.lo then
        local dir=b.direction
        g:tile(equipment.underground.name,cut.lo,b.y,dir,{type=dir==4 and 'input' or 'output'},key)
        g:tile(equipment.underground.name,cut.hi,b.y,dir,{type=dir==4 and 'output' or 'input'},key)
        g:tunnel('item',cut.lo,b.y,cut.hi,b.y);x=cut.hi+1;cut_index=cut_index+1
      elseif b.forks[x] then
        g:add(equipment.splitter.name,x+0.5,b.y+1,4,{input_priority='left',output_priority='right'},key)
        splitters=splitters+1;x=x+1
      else
        g:tile(equipment.belt.name,x,b.y,b.turns[x] and 8 or b.direction,nil,key);x=x+1
      end
    end
    events[#events+1]={stage='recipe-bus',first=start,last=#g.entities,detail={'',U.icon(key),' ',U.name(key)}}
  end
  for _,tap in ipairs(taps) do
    local b=buses[tap.key];local start=#g.entities+1
    for y=b.y+1,tap.port.y do
      local d=tap.produce and 0 or y==tap.port.y and tap.port.d*4 or 8
      g:tile(equipment.belt.name,tap.column,y,d,nil,tap.key)
    end
    events[#events+1]={stage='routes',first=start,last=#g.entities,detail={'',U.icon(tap.key),' ',U.name(tap.key)},
      from=tap.produce and U.copy(tap.port) or {x=tap.station,y=b.y},to=tap.produce and {x=tap.station,y=b.y} or U.copy(tap.port)}
  end
  Mall.add(g,c,s,plan)
  local limit=Paving.limit(s)
  if limit and Paving.span(s,g)>limit then U.fail('width',Paving.span(s,g)+Paving.margin(s)*2,s.max_width) end
  Hierarchy.describe(plan,buses,length,s)
  for _,route in ipairs(rows) do connections[#connections+1]=route end
  plan.layout_revision=32;plan.layout_stats={closed_buses=0,straight_buses=#keys,production_rows=#plan.production_rows,
    recipe_bus_taps=#taps+#plan.ports,main_bus_taps=0,external_interfaces=#plan.ports,hierarchy_levels=3,generated_main_bus_entities=0,
    compact=true,bus_splitters=splitters,row_limit=row_limit,row_gap=gap}
  return {g=g,events=events,plan=plan,buses=buses,connections=connections,special={},turns=turns,mirror=mirror,
    equipment={belt=equipment.belt.name,underground=equipment.underground.name,splitter=equipment.splitter.name},
    connection_index=1,special_index=1,stage='routes',route_bounds={x0=left,x1=right,y0=top,y1=bottom}}
end
function C.begin(g,events,c,s,plan,specs,equipment,turns,mirror)
  -- Compare complete bus/row geometry, not just the longest row. Splitting a
  -- long row reduces empty land, but every extra connection costs transport.
  local best,best_gap,best_score,best_count;local seen={}
  local limits=s.max_width and {300,128,64,32,16,12,8,6,4,3,2,1} or {32,16,12,8,6,4,3,2,1}
  for _,gap in ipairs({2,3}) do for _,limit in ipairs(limits) do
    local signature={}
    for _,spec in ipairs(specs) do signature[#signature+1]=math.min(limit,spec.node.count)..':'..math.ceil(spec.node.count/limit) end
    signature=gap..'/'..table.concat(signature,',')
    if not seen[signature] then
      seen[signature]=true
      local trial=G.new()
      local ok=pcall(compose,trial,{},c,s,U.copy(plan),specs,equipment,turns,mirror,limit,gap)
      if ok then
        local score=(trial.maxx-trial.minx)*(trial.maxy-trial.miny)+3*#trial.entities
        if not best_score or score<best_score or score==best_score and #trial.entities<best_count then
          best,best_gap,best_score,best_count=limit,gap,score,#trial.entities
        end
      end
    end
  end end
  return compose(g,events,c,s,plan,specs,equipment,turns,mirror,best or 32,best_gap or 3)
end
return C
