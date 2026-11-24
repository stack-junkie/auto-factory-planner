local U=require('scripts.util')
local C=require('scripts.catalogue')
local A=require('scripts.arrangement')
local Paving=require('scripts.paving')
local Belts=require('scripts.belt_sizing')
local Network=require('scripts.power_network')
local Cover=require('scripts.power_cover')
local Power={}
local function push(heap,node)
  local i=#heap+1;heap[i]=node
  while i>1 do local p=math.floor(i/2);if heap[p].score<=node.score then break end;heap[i]=heap[p];i=p;heap[i]=node end
end
local function pop(heap)
  local result=heap[1];local last=table.remove(heap);if #heap==0 then return result end
  local i=1;heap[1]=last
  while i*2<=#heap do local c=i*2;if c+1<=#heap and heap[c+1].score<heap[c].score then c=c+1 end
    if heap[c].score>=last.score then break end;heap[i]=heap[c];i=c;heap[i]=last
  end
  return result
end
local function detour(connected,degrees,target,wire,pw,ph,g,free)
  local heap,best={},{};local reach=math.floor(wire);local steps={}
  for dx=-reach,reach do for dy=-reach,reach do if(math.abs(dx)>=pw or math.abs(dy)>=ph)and dx*dx+dy*dy<=wire*wire then steps[#steps+1]={dx,dy}end end end
  local function distance(x,y)return math.sqrt((x+pw/2-target.position.x)^2+(y+ph/2-target.position.y)^2)end
  for _,pole in ipairs(connected)do if(degrees[pole.entity_number]or 0)<4 then
    local x,y=math.floor(pole.position.x-pw/2),math.floor(pole.position.y-ph/2)
    local node={x=x,y=y,cost=0,root=pole,score=distance(x,y)/wire};best[x..'/'..y]=0;push(heap,node)
  end end
  for count=1,60000 do
    if #heap==0 then return end
    local node=pop(heap)
    if node.cost==best[node.x..'/'..node.y]then
      if distance(node.x,node.y)<=wire+1e-6 then
        local path={};local root=node.root
        while node.parent do table.insert(path,1,{x=node.x,y=node.y});node=node.parent end
        return root,path
      end
      for _,step in ipairs(steps)do local x,y=node.x+step[1],node.y+step[2];local key=x..'/'..y;local cost=node.cost+1
        if x>=g.minx-reach*2 and x<=g.maxx+reach*2 and y>=g.miny-reach*2 and y<=g.maxy+reach*2
          and(not best[key]or cost<best[key])and free(x,y)then
          best[key]=cost;push(heap,{x=x,y=y,cost=cost,score=cost+distance(x,y)/wire,parent=node,root=node.root})
        end
      end
    end
  end
end
function Power.add(c,s,g,plan,reuse,bounds)
  local optimize=not Belts.legacy(s)
  local overrides=s.infrastructure or {}
  local minimum_x=g.minx;local minimum_y=g.miny;local limit=Paving.limit(s);local axis=Paving.axis(s)
  local maximum_x,maximum_y=g.maxx,g.maxy
  if reuse and(s.roboports or s.snap_grid)then limit=nil end
  -- Wire spans can cross belts and pipes. Mall reserves the grid before routing
  -- so transport cannot occupy the last free supply tile beside a local arm.
  local pole=C.pick(c,"electric-pole",overrides.pole or plan and plan.automatic_pole,function(p)return p.get_supply_area_distance("normal")>0 and p.get_max_wire_distance("normal")>0 end,function(p)return p.get_max_wire_distance("normal") end)
  local radius=pole.get_supply_area_distance("normal");local wire=pole.get_max_wire_distance("normal")
  local pw,ph=pole.tile_width,pole.tile_height
  local supply={pole}
  if optimize and(not overrides.pole or s._automatic_pole)then
    for _,p in ipairs(C.options(c,'electric-pole',function(v)return v.get_supply_area_distance('normal')end))do
      if p.get_supply_area_distance('normal')>radius and p.get_max_wire_distance('normal')>0
        and p.tile_width<=2 and p.tile_height<=2 then supply[#supply+1]=p end
    end
  end
  local anchor;local context=s._project;local offset=plan and plan.project_offset or context and context.offset
  if(s.roboports or s.snap_grid)and offset and context then
    local turns,mirror=A.orientation(s)
    local controller=plan and plan.controller_position or context.origin
    local x,y=U.rotate(controller.x-offset.x,controller.y-offset.y,(4-turns)%4)
    anchor={x=x,y=mirror and-y or y}
  end
  local function free_pole(x,y,prototype)
    local w,h=prototype and prototype.tile_width or pw,prototype and prototype.tile_height or ph
    if anchor and math.abs(x+w/2-anchor.x)<w/2+0.35 and math.abs(y+h/2-anchor.y)<h/2+0.35 then return false end
    if bounds and(x<bounds.x0 or y<bounds.y0 or x+w>bounds.x1 or y+h>bounds.y1)then return false end
    if limit and(axis=='y'and(y<minimum_y or y+h>minimum_y+limit)or axis=='x'and(x<minimum_x or x+w>minimum_x+limit))then return false end
    for a=x,x+w-1 do for b=y,y+h-1 do if not g:free(a,b) then return false end end end;return true
  end
  local function place_pole(x,y,extra,prototype)
    local p=prototype or pole;return g:add(p.name,x+p.tile_width/2,y+p.tile_height/2,0,extra)
  end
  local function free_supply(x,y,prototype)
    if not reuse and prototype~=pole and(x<minimum_x or y<minimum_y or x+prototype.tile_width>maximum_x or y+prototype.tile_height>maximum_y)then return false end
    return free_pole(x,y,prototype)
  end
  local poles={}
  if reuse then for _,e in ipairs(g.entities)do if prototypes.entity[e.name].type=='electric-pole'then poles[#poles+1]=e end end end
  local existing=#poles
  local consumers,uncovered={},0
  for _,e in ipairs(g.electric) do
    local ep=prototypes.entity[e.name]
    if not ep.burner_prototype then
      local w,h=ep.tile_width,ep.tile_height;if(e.direction or 0)%8==4 then w,h=h,w end
      local user={entity=e,x=e.position.x,y=e.position.y,hw=(w-1)/2,hh=(h-1)/2,candidates={}}
      for _,q in ipairs(poles)do local r=prototypes.entity[q.name].get_supply_area_distance('normal')
        if math.abs(q.position.x-user.x)<r+user.hw and math.abs(q.position.y-user.y)<r+user.hh then user.covered=true;break end
      end
      if not user.covered then consumers[#consumers+1]=user;uncovered=uncovered+1 end
    end
  end
  -- Choose the free supply tile that powers the most uncovered consumers.
  -- Spatial buckets and lazy gain updates keep large factories inexpensive.
  local extent=radius
  for _,p in ipairs(supply)do local r=p.get_supply_area_distance('normal')
    for _,user in ipairs(consumers)do extent=math.max(extent,r+user.hw,r+user.hh)end
  end
  local bucket_size=math.max(1,math.ceil(extent*2));local buckets={}
  -- Mirrored coordinates can contain IEEE negative zero. Normalize it before
  -- making a string key, otherwise the consumer is stored in a different bucket.
  for _,user in ipairs(consumers)do local id=(math.floor(user.x/bucket_size)+0)..'/'..(math.floor(user.y/bucket_size)+0)
    buckets[id]=buckets[id]or{};buckets[id][#buckets[id]+1]=user
  end
  local seen,heap={},{};local initial_area=(g.maxx-g.minx)*(g.maxy-g.miny)
  local goal=plan and plan.power_base or{x=g.minx,y=g.miny}
  for _,prototype in ipairs(supply)do
    local radius=prototype.get_supply_area_distance('normal');local pw,ph=prototype.tile_width,prototype.tile_height
    local extent=radius;for _,user in ipairs(consumers)do extent=math.max(extent,radius+user.hw,radius+user.hh)end
    for _,user in ipairs(consumers)do
      local reach=math.ceil(extent)
      for dx=-reach,reach do for dy=-reach,reach do
        local x,y=math.floor(user.x-pw/2)+dx,math.floor(user.y-ph/2)+dy;local id=prototype.name..'/'..x..'/'..y
        if not seen[id]then
          seen[id]=true
          if free_supply(x,y,prototype)then
            local cx,cy=x+pw/2,y+ph/2;local candidate={x=x,y=y,w=pw,h=ph,prototype=prototype,users={},gain=0}
            local bx,by=math.floor(cx/bucket_size),math.floor(cy/bucket_size)
            for ax=-1,1 do for ay=-1,1 do for _,target in ipairs(buckets[(bx+ax)..'/'..(by+ay)]or{})do
              if math.abs(cx-target.x)<radius+target.hw and math.abs(cy-target.y)<radius+target.hh then
                candidate.users[#candidate.users+1]=target;candidate.gain=candidate.gain+1
              end
            end end end
            if candidate.gain>0 then
              local area=(math.max(g.maxx,x+pw)-math.min(g.minx,x))*(math.max(g.maxy,y+ph)-math.min(g.miny,y));local extra=math.max(0,area-initial_area)
              local distance=(x-goal.x)^2+(y-goal.y)^2
              candidate.tie=extra/(extra+1)*.25+distance/(distance+1)*.125
              for _,target in ipairs(candidate.users)do target.candidates[#target.candidates+1]=candidate end
              push(heap,{candidate=candidate,gain=candidate.gain,score=-candidate.gain+candidate.tie})
            end
          end
        end
      end end
    end
  end
  local selected,taken={},{}
  local function available(candidate)
    if not free_supply(candidate.x,candidate.y,candidate.prototype)then return false end
    for x=candidate.x,candidate.x+candidate.w-1 do for y=candidate.y,candidate.y+candidate.h-1 do if taken[x..'/'..y]then return false end end end
    return true
  end
  while uncovered>0 do
    local best
    while #heap>0 and not best do local entry=pop(heap);local candidate=entry.candidate
      if candidate.gain>0 then
        if entry.gain~=candidate.gain then push(heap,{candidate=candidate,gain=candidate.gain,score=-candidate.gain+candidate.tie})
        elseif available(candidate)then best=candidate end
      end
    end
    if not best then U.fail('power')end
    if optimize then
      selected[#selected+1]=best
      for x=best.x,best.x+best.w-1 do for y=best.y,best.y+best.h-1 do taken[x..'/'..y]=true end end
    else poles[#poles+1]=place_pole(best.x,best.y)end
    for _,user in ipairs(best.users)do if not user.covered then
      user.covered=true;uncovered=uncovered-1
      for _,candidate in ipairs(user.candidates)do candidate.gain=candidate.gain-1 end
    end end
  end
  if optimize then
    selected=Cover.refine(selected,free_supply,poles)
    for _,candidate in ipairs(selected)do
      poles[#poles+1]=place_pole(candidate.x,candidate.y,not reuse and{tags={afp_production_power=true}}or nil,candidate.prototype)
    end
  end
  if not reuse and plan and plan.power_base and #poles>0 then
    local goal=plan.power_base;local found
    local base,nearest
    if optimize then for _,q in ipairs(poles)do
      local d=(q.position.x-goal.x-pw/2)^2+(q.position.y-goal.y-ph/2)^2
      local reach=prototypes.entity[q.name].get_max_wire_distance('normal')
      if d<=reach^2 and(not nearest or d<nearest)then base=q;nearest=d end
    end end
    if not base then
      for r=0,math.max(6,math.ceil(wire))do
        for dx=-r,r do for dy=-r,r do
          local x,y=goal.x+dx,goal.y+dy
          if not found and free_pole(x,y)then found={x=x,y=y}end
        end end
        if found then break end
      end
      if not found then U.fail('power')end
      base=place_pole(found.x,found.y)
      poles[#poles+1]=base
    end
    base.tags=base.tags or{};base.tags.afp_power_base=true;plan.power_base_entity=base.entity_number
  end
  if optimize then
    local relays={pole}
    if not overrides.pole or s._automatic_pole then
      for _,p in ipairs(C.options(c,'electric-pole',function(v)return v.get_max_wire_distance('normal')end))do
        if p.get_max_wire_distance('normal')>wire and p.tile_width<=2 and p.tile_height<=2 then relays[#relays+1]=p end
      end
    end
    Network.connect(g,poles,relays,free_pole,place_pole,function(connected,degrees,target)
      local compatible={};for _,p in ipairs(connected)do if p.name==pole.name then compatible[#compatible+1]=p end end
      local span=math.min(wire,prototypes.entity[target.name].get_max_wire_distance('normal'))
      return detour(compatible,degrees,target,span,pw,ph,g,free_pole)
    end)
    return pole
  end
  -- Join each pole to the existing network, adding relay poles in free cells.
  if #poles>0 then poles[1].tags=poles[1].tags or{};poles[1].tags.afp_power=true end
  local degrees={}
  if reuse then for _,e in ipairs(g.entities)do for _,wire in ipairs(e.wires or{})do
    if wire[2]==defines.wire_connector_id.pole_copper and wire[4]==defines.wire_connector_id.pole_copper then
      degrees[wire[1]]=(degrees[wire[1]]or 0)+1;degrees[wire[3]]=(degrees[wire[3]]or 0)+1
    end
  end end end
  local function power_wire(a,b)
    g:wire(a,defines.wire_connector_id.pole_copper,b,defines.wire_connector_id.pole_copper)
    degrees[a.entity_number]=(degrees[a.entity_number] or 0)+1;degrees[b.entity_number]=(degrees[b.entity_number] or 0)+1
  end
  local connected={};for i=1,math.max(existing,1)do if poles[i]then connected[#connected+1]=poles[i]end end
  for i=math.max(2,existing+1),#poles do
    local target=poles[i];local nearest,dist
    for _,q in ipairs(connected) do if (degrees[q.entity_number] or 0)<4 then local d=(target.position.x-q.position.x)^2+(target.position.y-q.position.y)^2;if not dist or d<dist then nearest,dist=q,d end end end
    if not nearest then U.fail('power')end
    local attempts=0
    while dist>wire*wire+1e-6 do
      attempts=attempts+1;if attempts>2000 then U.fail("power") end
      local nextp,nextdist
      for dx=-math.floor(wire),math.floor(wire) do for dy=-math.floor(wire),math.floor(wire) do
        if dx*dx+dy*dy<=wire*wire and dx*dx+dy*dy>0 then
          local x,y=math.floor(nearest.position.x-pw/2)+dx,math.floor(nearest.position.y-ph/2)+dy
          local d=(x+pw/2-target.position.x)^2+(y+ph/2-target.position.y)^2
          if d<dist-0.1 and (not nextdist or d<nextdist) and free_pole(x,y) then nextp={x=x,y=y};nextdist=d end
        end
      end end
      if not nextp then
        local root,path;if s.roboports or s.snap_grid then root,path=detour(connected,degrees,target,wire,pw,ph,g,free_pole)end
        if not root then log('AFP POWER RELAY BLOCKED '..serpent.line(nearest.position)..' -> '..serpent.line(target.position));U.fail('power')end
        nearest=root
        for _,point in ipairs(path)do local q=place_pole(point.x,point.y);power_wire(nearest,q);connected[#connected+1]=q;nearest=q end
        dist=(nearest.position.x-target.position.x)^2+(nearest.position.y-target.position.y)^2
        break
      end
      local q=place_pole(nextp.x,nextp.y);power_wire(nearest,q)
      connected[#connected+1]=q;nearest,dist=q,nextdist
    end
    power_wire(nearest,target);connected[#connected+1]=target
  end
  return pole
end
return Power
