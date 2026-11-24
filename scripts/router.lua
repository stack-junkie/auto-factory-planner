local U=require("scripts.util")
local G=require("scripts.geometry")
local Pipes=require('scripts.pipes')
local Recursive=require('scripts.recursive_route')
local R={}
-- Merge only into the component containing the destination. Matching fluid
-- names alone can make a branch turn back into its own disconnected source.
local function target_component(g,to,network)
  local result,queue,tunnels={},{},{}
  local function add(x,y)
    local key=G.cell(x,y);local occupied=g.occupied[key]
    if occupied and occupied.fluid==network and not result[key]then
      local kind=prototypes.entity[occupied.entity.name].type
      if kind=='pipe'or kind=='pipe-to-ground'then result[key]=true;queue[#queue+1]={x=x,y=y}end
    end
  end
  for _,t in ipairs(g.tunnels)do if t.kind=='fluid'then
    local a=t.horizontal and G.cell(t.lo,t.y)or G.cell(t.x,t.lo)
    local b=t.horizontal and{x=t.hi,y=t.y}or{x=t.x,y=t.hi}
    tunnels[a]=b;tunnels[G.cell(b.x,b.y)]=t.horizontal and{x=t.lo,y=t.y}or{x=t.x,y=t.lo}
  end end
  local function open(x,y,d)
    local occupied=g.occupied[G.cell(x,y)];if not occupied or occupied.fluid~=network then return false end
    local entity=occupied.entity;local p=prototypes.entity[entity.name]
    if p.type=='pipe'then return true end
    if p.type=='pipe-to-ground'then for _,box in pairs(p.fluidbox_prototypes)do for _,connection in pairs(box.pipe_connections)do
      if connection.connection_type=='normal'and((connection.direction or 0)+(entity.direction or 0))%16==d*4 then return true end
    end end end
    return false
  end
  add(to.x,to.y)
  local index=1
  while index<=#queue do local p=queue[index];index=index+1
    for d=0,3 do local x,y=p.x+G.dx[d+1],p.y+G.dy[d+1]
      if open(p.x,p.y,d)and open(x,y,(d+2)%4)then add(x,y)end
    end
    local other=tunnels[G.cell(p.x,p.y)];if other then add(other.x,other.y)end
  end
  return result
end
R.fluid_component=target_component
function R.fluid_exit(g,port,network,goal)
  local best,score
  for _,cell in ipairs(U.sorted(target_component(g,port,network)))do
    local x,y=cell:match('^(-?%d+),(-?%d+)$');x,y=tonumber(x),tonumber(y)
    if prototypes.entity[g.occupied[cell].entity.name].type=='pipe'then
      local open=false;for d=1,4 do if g:free(x+G.dx[d],y+G.dy[d],'fluid',network,port.id)then open=true;break end end
      local distance=goal and math.abs(x-goal.x)+math.abs(y-goal.y)or x
      if open and(not score or distance<score or distance==score and(x<best.x or x==best.x and y<best.y))then
        best={x=x,y=y,id=port.id};score=distance
      end
    end
  end
  return best or port
end
local function push(h,v)
  local i=#h+1;h[i]=v
  while i>1 do local p=math.floor(i/2);if h[p].f<=v.f then break end;h[i]=h[p];i=p;h[i]=v end
end
local function pop(h)
  local r=h[1];local v=table.remove(h);if #h==0 then return r end
  local i=1;h[1]=v
  while true do local a=i*2;if a>#h then break end
    if a+1<=#h and h[a+1].f<h[a].f then a=a+1 end
    if h[a].f>=v.f then break end;h[i]=h[a];i=a;h[i]=v
  end;return r
end
local function statekey(x,y,d,forced) return x..","..y..","..d..","..(forced and 1 or 0) end
local function reset(s)
  s.h={};s.best={};s.pops=0
  if s.source_cells then
    for _,cell in ipairs(U.sorted(s.source_cells))do
      local x,y=cell:match('^(-?%d+),(-?%d+)$');x,y=tonumber(x),tonumber(y)
      local n={x=x,y=y,d=4,forced=false,g=0,f=math.abs(x-s.to.x)+math.abs(y-s.to.y)}
      push(s.h,n);s.best[statekey(x,y,4,false)]=0
    end
    return
  end
  local n={x=s.from.x,y=s.from.y,d=s.from.d or 4,forced=s.from.d~=nil,g=0}
  n.f=math.abs(n.x-s.to.x)+math.abs(n.y-s.to.y);push(s.h,n)
end
function R.begin(from,to,kind,key,belt,underground,id,merge,network,bridge)
  local s={from=from,to=to,kind=kind,key=key,belt=belt.name,underground=underground and underground.name,id=id,merge=merge,
    maxspan=underground and (underground.max_underground_distance or 0) or 0,retries=0,expanded=0,limit=160000,avoid={},network=network or key,bridge=bridge}
  if kind=="fluid" and underground then
    for _,f in pairs(underground.fluidbox_prototypes) do for _,c in ipairs(f.pipe_connections) do
      if c.connection_type=="underground" then s.maxspan=c.max_underground_distance end
    end end
  end
  s.minx=math.min(from.x,to.x)-48;s.maxx=math.max(from.x,to.x)+48
  s.miny=math.min(from.y,to.y)-48;s.maxy=math.max(from.y,to.y)+48
  reset(s);return s
end
function R.manual(s,corridor)
  s.heuristic_weight=1;s.turn_cost=2;s.tunnel_cost=1;s.strict_terminal=true;s.corridor=corridor
  if corridor and corridor.axis=='y'and corridor.minimum then
    local from,to,edge=s.from,s.to,corridor.minimum
    if from.y<edge and to.y>=edge and from.d==2 and to.d==2
      or to.y<edge and from.y>=edge and from.d==0 and to.d==0 then s.turn_boundary=edge end
  end
end
function R.advance(g,s,budget)
  local from,to,kind,key,id=s.from,s.to,s.kind,s.key,s.id
  local network=s.network or key
  if s.merge and not s.merge_cells then s.merge_cells=target_component(g,to,network)end
  if kind=='fluid'and s.pops==0 and not(s.merge_cells and s.merge_cells[G.cell(from.x,from.y)])then
    local marker=g.occupied[G.cell(from.x,from.y)]
    if marker and marker.fluid==network and prototypes.entity[marker.entity.name].type=='pipe'then
      local exits={};s.source_component=target_component(g,from,network)
      for cell in pairs(s.source_component)do
        local x,y=cell:match('^(-?%d+),(-?%d+)$');x,y=tonumber(x),tonumber(y)
        if prototypes.entity[g.occupied[cell].entity.name].type=='pipe'then
          for d=1,4 do if g:free(x+G.dx[d],y+G.dy[d],'fluid',network,id)then exits[cell]=true;break end end
        end
      end
      if next(exits)then s.source_cells=exits;reset(s)end
    end
  end
  local function mergeable(x,y)
    if not s.merge then return false end
    if s.merge_cells and not s.merge_cells[G.cell(x,y)]then return false end
    local o=g.occupied[G.cell(x,y)]
    return o and o.fluid==network and prototypes.entity[o.entity.name].type=="pipe"
  end
  local function free(x,y)
    if s.source_cells and s.source_cells[G.cell(x,y)]then return true end
    if s.reuse and s.reuse[G.cell(x,y)]then return true end
    if mergeable(x,y) then return true end
    if kind=='fluid'and x==from.x and y==from.y then
      local occupied=g.occupied[G.cell(x,y)]
      if occupied and occupied.fluid==network and prototypes.entity[occupied.entity.name].type=='pipe'then return true end
    end
    if x==from.x and y==from.y or x==to.x and y==to.y then return g:free(x,y,kind,network,g.reserved[G.cell(x,y)],s.bridge) end
    return g:free(x,y,kind,network,id)
  end
  local function fail(reason)
    if g.debug_layout then helpers.write_file('local-route-failure.json',helpers.table_to_json({entities=g.entities,reserved=g.reserved,item_ports=g.item_ports,from=from,to=to,key=key,id=id,reason=reason}),false)end
    s.failure={reason=reason,from=U.copy(from),to=U.copy(to),key=key,expanded=s.expanded,range=s.maxspan}
    log("AFP route failed "..(type(key)=='table'and table.concat(key,'|')or key).." "..serpent.line(from).." -> "..serpent.line(to).." underground="..s.maxspan.." reason="..reason.." expanded="..s.expanded)
    U.fail("route",U.name(type(key)=='table'and key[1]or key))
  end
  if not free(from.x,from.y) or not free(to.x,to.y) then fail("endpoint") end
  if kind=='item'then return Recursive.advance(g,s,budget,free,fail)end
  local goal
  for _=1,budget do
    if #s.h==0 then fail("blocked") end
    if s.pops>=s.limit then fail("limit") end
    s.pops=s.pops+1;s.expanded=s.expanded+1
    local n=pop(s.h);local nk=statekey(n.x,n.y,n.d,n.forced)
    if not s.best[nk] or n.g<=s.best[nk]+1e-6 then
      s.cursor={x=n.x,y=n.y}
      if mergeable(n.x,n.y) or n.x==to.x and n.y==to.y and (not to.d or not s.strict_terminal and not n.forced or n.d==to.d) then goal=n;break end
      for d=0,3 do if (n.d==4 or d~=(n.d+2)%4) and (not n.forced or d==n.d) then
        local dx,dy=G.dx[d+1],G.dy[d+1]
        local function offer(len,tunnel)
          local x,y=n.x+dx*len,n.y+dy*len
          if kind=='fluid'and s.source_component and s.source_component[G.cell(x,y)]then return end
          if tunnel and (not n.parent or x==to.x and y==to.y and (to.plain or kind=="fluid" and not to.d)) then return end
          if tunnel and mergeable(x,y) then return end
          if x<s.minx or x>s.maxx or y<s.miny or y>s.maxy or not free(x,y) then return end
          if x==to.x and y==to.y and to.d and ((d+2)%4==to.d or tunnel and d~=to.d) then return end
          if tunnel and not g:tunnel_free(kind,n.x,n.y,x,y) then return end
          local turning=n.d~=4 and n.d~=d
          if turning and s.turn_boundary and n.y<s.turn_boundary then return end
          local bend=turning and(s.turn_cost or .2)or 0
          if turning and s.corridor then bend=bend+math.abs(n[s.corridor.axis]-s.corridor.value)*.05 end
          local cost=n.g+len+(tunnel and(s.tunnel_cost or 5)or 0)+bend
          local forced=tunnel or false;local k=statekey(x,y,d,forced)
          if s.best[k] and s.best[k]<=cost or s.avoid[k] then return end
          s.best[k]=cost;push(s.h,{x=x,y=y,d=d,forced=forced,g=cost,f=cost+(s.heuristic_weight or 2)*(math.abs(x-to.x)+math.abs(y-to.y)),parent=n,jump=tunnel,len=len})
        end
        offer(1,false)
        if s.underground and not n.forced and (n.d==4 or n.d==d) then for len=2,s.maxspan do offer(len,true) end end
      end end
    end
  end
  if not goal then return false end
  local path={};while goal do table.insert(path,1,goal);goal=goal.parent end
  local seen={}
  for _,n in ipairs(path) do
    local cell=G.cell(n.x,n.y)
    if seen[cell] then
      if s.retries>=12 then fail("cycle") end
      s.avoid[statekey(n.x,n.y,n.d,n.forced)]=true;s.retries=s.retries+1;reset(s);return false
    end
    seen[cell]=true
  end
  s.path=path;s.h=nil;s.best=nil;s.avoid=nil;return true
end
function R.build(g,s)
  local from,to,kind,key,id=s.from,s.to,s.kind,s.key,s.id
  local network=s.network or key
  local belt=prototypes.entity[s.belt];local underground=s.underground and prototypes.entity[s.underground]
  local path=s.path;local made={};local i=1
  local function mergeable(x,y)
    if s.merge_cells and not s.merge_cells[G.cell(x,y)]then return false end
    local occupied=g.occupied[G.cell(x,y)]
    return s.merge and occupied and occupied.fluid==network and prototypes.entity[occupied.entity.name].type=="pipe"
  end
  local function pipe_dir(want)
    local base=0
    for _,f in pairs(underground.fluidbox_prototypes) do for _,c in ipairs(f.pipe_connections) do if c.connection_type=="normal" then base=(c.direction or 0)/4;break end end end
    return ((want-base)%4)*4
  end
  while i<=#path do
    local n,nextn=path[i],path[i+1]
    if mergeable(n.x,n.y) then break end
    local occupied=g.occupied[G.cell(n.x,n.y)]
    if s.reuse and s.reuse[G.cell(n.x,n.y)]then
      if kind=='item'then occupied.entity.direction=(nextn and nextn.d or to.d or n.d)*4 end
      i=i+1
    elseif i==1 and kind=='fluid'and occupied and occupied.fluid==network and prototypes.entity[occupied.entity.name].type=='pipe'then
      i=i+1
    else
    local last=i
    if kind=='fluid'and underground and nextn and not nextn.jump then
      local d=nextn.d
      while path[last+1]and not path[last+1].jump and path[last+1].d==d and not mergeable(path[last+1].x,path[last+1].y)do last=last+1 end
      -- Leave the entrance of an already planned tunnel for the jump branch.
      -- Compressing it into a surface pipe would skip both underground ends.
      if path[last+1]and path[last+1].jump then last=last-1 end
    end
    if last-i>=6 then
      local keep={};for index=i,last do local p=path[index];local cell=G.cell(p.x,p.y)
        if g.reserved[cell]then keep[cell]=true end
      end
      local first=#g.entities+1
      Pipes.line(g,belt,underground,n.x,n.y,path[last].x,path[last].y,network,keep)
      for index=first,#g.entities do made[#made+1]=g.entities[index]end
      i=last+1
    elseif nextn and nextn.jump then
      local d=nextn.d;local a,b
      if kind=="item" then
        a=g:tile(underground.name,n.x,n.y,d*4,{type="input"},key)
        b=g:tile(underground.name,nextn.x,nextn.y,d*4,{type="output"},key)
      else
        a=g:tile(underground.name,n.x,n.y,pipe_dir((d+2)%4),nil,network)
        b=g:tile(underground.name,nextn.x,nextn.y,pipe_dir(d),nil,network)
      end
      made[#made+1]=a;made[#made+1]=b;g:tunnel(kind,n.x,n.y,nextn.x,nextn.y);i=i+2
    else
      local d=nextn and nextn.d or to.d or n.d
      if d==4 then d=0 end
      made[#made+1]=g:tile(belt.name,n.x,n.y,kind=="item" and d*4 or 0,nil,kind=="fluid" and network or key);i=i+1
    end
    end
  end
  return made
end
function R.route(g,from,to,kind,key,belt,underground,id,merge,limit)
  local s=R.begin(from,to,kind,key,belt,underground,id,merge)
  if limit then s.limit=limit end
  while not R.advance(g,s,4096) do end
  return R.build(g,s)
end
return R
