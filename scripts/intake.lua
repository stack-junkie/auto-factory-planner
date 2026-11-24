local U=require('scripts.util')
local G=require('scripts.geometry')
local Inputs=require('scripts.inputs')
local N={}
function N.order(s,plan)
  local result,known={},{}
  local function add(key)if not known[key]then result[#result+1]=key;known[key]=true end end
  local context=s._project or{}
  local pins=U.copy(context.inputs or{})
  table.sort(pins,function(a,b)return a.index<b.index end)
  -- Older versions alphabetized the bus independently of the actual input
  -- sockets. Migrate that order once; afterwards retain the whole history.
  if context.intake_revision or #pins==0 then
    for _,key in ipairs(context.recipe_bus_order or{})do add(key)end
  else for _,pin in ipairs(pins)do add(pin.key)end end
  for _,key in ipairs(s.input_order or{})do
    for _,stream in ipairs(U.sorted(plan.flows))do if U.base_key(stream)==key then add(stream)end end
  end
  for _,port in ipairs(plan.ports)do if port.kind=='in'then add(port.key)end end
  for _,key in ipairs(context.recipe_bus_order or{})do add(key)end
  return result
end
function N.prepare(s,plan,ports,order,turns,mirror)
  plan.intake_revision=plan.branch_rows and 2 or 1
  local context=s._project;local front=-4
  if plan.branch_rows and context and context.offset and context.plot_origin and(context.intake_revision or 0)<2 then
    local _,y=U.rotate(context.plot_origin.x-context.offset.x,context.plot_origin.y-context.offset.y,(4-turns)%4)
    front=math.floor((mirror and -y or y)+1e-6)
  end
  local rank={};for i,key in ipairs(order)do rank[key]=i end
  table.sort(ports,function(a,b)
    local ar,br=rank[a.key]or math.huge,rank[b.key]or math.huge
    return ar==br and a.id<b.id or ar<br
  end)
  for i,p in ipairs(ports)do
    p.index=i;p.local_position={x=(plan.intake_header_offset or 0)+2*(i-1),y=front};p.staging_position=nil
    local x,y=U.rotate(p.local_position.x+0.5,(mirror and -1 or 1)*(p.local_position.y+0.5),turns)
    p.position={x=x,y=y}
  end
  local assigned=s
  if plan.branch_rows and context and context.offset and(context.intake_revision or 0)<2 then
    -- Correct the old interior entrance once. Later revisions keep these
    -- boundary positions fixed, including when the factory grows.
    assigned=U.copy(s);local migrated=assigned._project
    for _,pin in ipairs(migrated.inputs or{})do
      local x=(plan.intake_header_offset or 0)+2*((pin.index or 1)-1)+.5;local y=front+.5
      local wx,wy=U.rotate(x,mirror and -y or y,turns)
      pin.position={x=context.offset.x+wx,y=context.offset.y+wy}
      pin.direction=((mirror and 0 or 8)+turns*4)%16;pin.heading=pin.direction
    end
    plan.intake_migrated=true
  end
  Inputs.assign(assigned,plan)
  local first=ports[1]and ports[1].local_position or{x=0,y=-4}
  plan.power_base={x=first.x-1,y=first.y+(plan.branch_rows and 3 or 1)}
end
-- A two-row item cell needs a fork, not a serial junction with crossed
-- destinations. Build both monotone branches before placing power poles.
function N.fork(g,plan,key,net,equipment,inlet)
  local manual=plan.fixed_production or plan.manual_keys and plan.manual_keys[key]
  if not plan.branch_rows or not manual and(#plan.nodes~=1 or #U.sorted(plan.nodes[1].input)~=1)or U.split(key)~='item'or net.export or #net.sources~=1 or #net.sinks~=2 then return false end
  local source=inlet or net.sources[1].port;local sinks={net.sinks[1].port,net.sinks[2].port}
  table.sort(sinks,function(a,b)return a.x<b.x end)
  local left,right=sinks[1],sinks[2]
  if manual and not inlet and left.d==2 and right.d==2 and left.y==right.y then
    -- Locate the fork beside its production bank. The selected world socket
    -- can be anywhere; an ordinary route feeds this short, monotone fork.
    local centre=math.max(left.x,math.min(right.x,source.x))
    for radius=0,right.x-left.x do for _,x in ipairs(radius==0 and{centre}or{centre-radius,centre+radius})do
      if x>=left.x and x<=right.x and N.fork(g,plan,key,net,equipment,{x=x,y=left.y-8,d=2,left_feed=x<right.x})then return true end
    end end
    return false
  end
  local sx=source.left_feed and source.x or source.x-1
  if source.d~=2 or left.d~=2 or right.d~=2 or left.y~=right.y or sx<left.x or sx+1>right.x then return false end
  local row=source.y+4;local branch=row+1
  if branch>=left.y then return false end
  local tiles,occupied,tunnels={},{},{}
  local function tile(x,y,d,name,kind)
    local cell=G.cell(x,y)
    if g.reserved[cell]and g.reserved[cell]:match('^output%-end/')then return false end
    if occupied[cell]or not g:free(x,y,'item',key,g.reserved[cell])then return false end
    occupied[cell]=true;tiles[#tiles+1]={x=x,y=y,d=d,name=name or equipment.belt.name,kind=kind};return true
  end
  for y=source.y,row-1 do if not tile(source.x,y,8)then return false end end
  for x=sx,sx+1 do local cell=G.cell(x,row)
    if g.reserved[cell]and g.reserved[cell]:match('^output%-end/')or not g:free(x,row,'item',key,g.reserved[cell])then return false end;occupied[cell]=true
  end
  for x=sx,left.x,-1 do if not tile(x,branch,x==left.x and 8 or 12)then return false end end
  for y=branch+1,left.y do if not tile(left.x,y,8)then return false end end
  local x=sx+1
  while x<=right.x do
    -- Cross the protected final-output column with exactly one underground
    -- pair; turns stay on surface belts before and after its endpoints.
    local nextcell=G.cell(x+1,branch)
    if g.reserved[nextcell]and g.reserved[nextcell]:match('^output%-end/')then
      local last=x+2
      while g.reserved[G.cell(last,branch)]and g.reserved[G.cell(last,branch)]:match('^output%-end/')do last=last+1 end
      if x==sx+1 or last>=right.x or last-x>equipment.underground.max_underground_distance or not g:tunnel_free('item',x,branch,last,branch)then return false end
      if not tile(x,branch,4,equipment.underground.name,'input')or not tile(last,branch,4,equipment.underground.name,'output')then return false end
      tunnels[#tunnels+1]={x0=x,x1=last,y=branch};x=last+1
    else
      if not tile(x,branch,x==right.x and 8 or 4)then return false end;x=x+1
    end
  end
  for y=branch+1,right.y do if not tile(right.x,y,8)then return false end end
  g:add(equipment.splitter.name,sx+1,row+.5,8,nil,key)
  for _,t in ipairs(tiles)do g:tile(t.name,t.x,t.y,t.d,t.kind and{type=t.kind}or nil,key)end
  for _,t in ipairs(tunnels)do g:tunnel('item',t.x0,t.y,t.x1,t.y)end
  plan.intake_forks=plan.intake_forks or{}
  plan.intake_forks[#plan.intake_forks+1]={key=key,splitter={x=sx+1,y=row+.5},branch_y=branch,
    source=U.copy(source),left=U.copy(left),right=U.copy(right),underground_pairs=#tunnels}
  if inlet then
    net.sinks={{port={x=source.x,y=source.y-1,d=2,plain=true,id='fork/'..key},rate=net.sources[1].rate}}
  else net.direct=true end
  return true
end
function N.build(g,plan,ports,buses,belt)
  local points,occupied,moves={},{},{}
  local common=ports[1]and ports[1].local_position.y or -4
  local previous_source,previous_target=-math.huge,-math.huge
  for _,p in ipairs(ports)do
    local pos=p.local_position;local target=buses[p.key].x
    if pos.y~=common or (p.pinned_direction or 2)~=2 or pos.x<=previous_source or target<=previous_target then return end
    previous_source,previous_target=pos.x,target
    moves[#moves+1]={port=p,source=pos.x,target=target}
  end
  local bottom=common+1;local y=common+2
  for _,m in ipairs(moves)do if m.target<m.source then m.turn=y;y=y+1;bottom=math.max(bottom,y)end end
  y=common+2
  for i=#moves,1,-1 do local m=moves[i];if m.target>m.source then m.turn=y;y=y+1;bottom=math.max(bottom,y)end end
  local function tile(m,x,y,d)
    local key=G.cell(x,y)
    if occupied[key]or not g:free(x,y,nil,nil,'user/'..m.port.id)then return false end
    occupied[key]=true;points[#points+1]={key=m.port.key,x=x,y=y,d=d};return true
  end
  for _,m in ipairs(moves)do
    if m.turn then
      for py=common,m.turn-1 do if not tile(m,m.source,py,8)then return end end
      local step=m.target>m.source and 1 or -1
      for x=m.source,m.target-step,step do if not tile(m,x,m.turn,step>0 and 4 or 12)then return end end
      for py=m.turn,bottom do if not tile(m,m.target,py,8)then return end end
    else for py=common,bottom do if not tile(m,m.source,py,8)then return end end end
  end
  for _,p in ipairs(points)do g:tile(belt.name,p.x,p.y,p.d,nil,p.key)end
  plan.entrance_layout={kind='ordered-fan',y0=common,y1=bottom,ports={}}
  for _,m in ipairs(moves)do
    local b=buses[m.port.key];b.import={x=m.target,y=bottom,d=2};b.first=math.min(b.first,bottom);b.last=math.max(b.last,bottom)
    plan.entrance_layout.ports[#plan.entrance_layout.ports+1]={key=m.port.key,index=m.port.index,from=U.copy(m.port.local_position),to={x=m.target,y=bottom}}
  end
  return bottom
end
return N
