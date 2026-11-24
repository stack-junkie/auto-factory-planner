local U=require('scripts.util')
local C=require('scripts.catalogue')
local Paving=require('scripts.paving')
local Grid=require('scripts.grid')
local R={}
local eps=1e-6
function R.reserve(c,s,g,plan,turns,mirror)
  if not Paving.grid_roads(s)or not plan.grid_strip then return end
  local prototype=Grid.prototype(c,s);local step=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
  local w,h=prototype.tile_width,prototype.tile_height
  for _,x in ipairs({plan.grid_strip.line,plan.grid_strip.line+step})do
    for row=math.floor((g.miny-phase.y)/step)-1,math.ceil((g.maxy-phase.y)/step)+1 do local y=phase.y+row*step
      for a=math.floor(x-w/2+eps),math.floor(x+w/2-eps)do for b=math.floor(y-h/2+eps),math.floor(y+h/2-eps)do
        local cell=a..','..b
        if not g.occupied[cell]and not g.reserved[cell]then g.reserved[cell]='roboport-grid'end
      end end
    end
  end
end
function R.release(g)
  for cell,id in pairs(g.reserved)do if id=='roboport-grid'then g.reserved[cell]=nil end end
end
local function rectangle(g,margin)return {x0=g.minx-margin,y0=g.miny-margin,x1=g.maxx+margin,y1=g.maxy+margin}end
local function covered(p,x,y,r)return math.abs(p.x-x)<=r+eps and math.abs(p.y-y)<=r+eps end
-- Sweep coverage rectangles, checking every strip rather than sampling tiles.
local function gap(ports,b,r)
  local edges={b.y0,b.y1}
  for _,p in ipairs(ports)do for _,y in ipairs({p.y-r,p.y+r})do if y>b.y0 and y<b.y1 then edges[#edges+1]=y end end end
  table.sort(edges)
  for i=2,#edges do if edges[i]>edges[i-1]+eps then local y=(edges[i]+edges[i-1])/2;local intervals={}
    for _,p in ipairs(ports)do if math.abs(p.y-y)<=r+eps then intervals[#intervals+1]={p.x-r,p.x+r}end end
    table.sort(intervals,function(a,z)return a[1]<z[1]end)
    local x=b.x0
    for _,v in ipairs(intervals)do
      if v[1]>x+eps then return {x=(x+math.min(v[1],b.x1))/2,y=y}end
      x=math.max(x,v[2]);if x>=b.x1-eps then break end
    end
    if x<b.x1-eps then return {x=(x+b.x1)/2,y=y}end
  end end
end
local function grid_rectangle(c,s,g,plan,turns,mirror,prototype,target,virtual)
  local step=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
  local radius=prototype.construction_radius;local w,h=prototype.tile_width,prototype.tile_height
  local axis=Paving.axis(s);local reference=Grid.reference(s);local controller
  local project=s._project and s._project.id and storage.afp_projects and storage.afp_projects[s._project.id]
  local owned={};for _,entity in pairs(project and project.members or{})do if entity.valid then owned[entity.unit_number or 0]=true end end
  local surface=s.grid_anchor and game.surfaces[s.grid_anchor.surface]or project and project.anchor.surface
  local force=reference and reference.force or project and project.anchor.force
  local offset=plan.project_offset or s._project and s._project.offset or{x=0,y=0}
  if s._project and s._project.id then
    local offset=plan.project_offset or s._project.offset or{x=0,y=0}
    local target=plan.controller_position or s._project.origin
    local x,y=U.rotate(target.x-offset.x,target.y-offset.y,(4-turns)%4)
    controller={x=x,y=mirror and -y or y}
  end
  local function existing(x,y)
    if not surface then return end
    local wx,wy=U.rotate(x,mirror and -y or y,turns)
    local entity=surface.find_entity(prototype.name,{wx+offset.x,wy+offset.y})
    if entity and entity.valid and entity.type=='roboport'and(not force or entity.force==force)
      and(entity==reference or not owned[entity.unit_number or 0])then return entity end
  end
  local function free(x,y)
    if controller and math.abs(controller.x-x)<w/2+.35 and math.abs(controller.y-y)<h/2+.35 then return false end
    for a=math.floor(x-w/2+eps),math.floor(x+w/2-eps)do for b=math.floor(y-h/2+eps),math.floor(y+h/2-eps)do
      if not g:free(a,b,nil,nil,'roboport-grid')then return false end
    end end
    return true
  end
  local columns=axis=='x'and 2 or math.max(2,math.ceil((target.x1-target.x0-2*radius)/step-eps)+1)
  local rows=axis=='y'and 2 or math.max(2,math.ceil((target.y1-target.y0-2*radius)/step-eps)+1)
  if plan.city_blocks then columns=plan.city_blocks.columns+1;rows=plan.city_blocks.rows+1 end
  local best
  for extra=0,4 do
    local nx=columns+(axis=='y'and extra or 0);local ny=rows+(axis=='x'and extra or 0)
    if nx*ny>1500 then U.fail('too-large')end
    local ix0=math.ceil((target.x1-radius-phase.x)/step-eps)-(nx-1)
    local ix1=math.floor((target.x0+radius-phase.x)/step+eps)
    local iy0=math.ceil((target.y1-radius-phase.y)/step-eps)-(ny-1)
    local iy1=math.floor((target.y0+radius-phase.y)/step+eps)
    if plan.grid_strip and plan.grid_strip.axis=='x'then
      local column=math.floor((plan.grid_strip.line-phase.x)/step+.5)
      ix0=math.max(ix0,column);ix1=math.min(ix1,column)
    end
    if plan.grid_front and(plan.grid_front.axis or'y')=='y'then
      local row=math.floor((plan.grid_front.line-phase.y)/step+.5)
      iy0=math.max(iy0,row);iy1=math.min(iy1,row)
    elseif plan.grid_front then
      local column=math.floor((plan.grid_front.line-phase.x)/step+.5)
      ix0=math.max(ix0,column);ix1=math.min(ix1,column)
    end
    if plan.city_blocks then
      ix0=plan.city_blocks.x0;ix1=ix0
      iy0=plan.city_blocks.y0;iy1=iy0
    end
    for ix=ix0,ix1 do for iy=iy0,iy1 do
      local points={};local valid=true
      for dx=0,nx-1 do for dy=0,ny-1 do
        local x,y=phase.x+(ix+dx)*step,phase.y+(iy+dy)*step
        if not free(x,y)then valid=false;break end
        points[#points+1]={x=x,y=y,reference=existing(x,y)~=nil or nil}
      end;if not valid then break end end
      if valid and not gap(points,target,radius)then
        local x0,y0=phase.x+ix*step-w/2,phase.y+iy*step-h/2
        local x1,y1=phase.x+(ix+nx-1)*step+w/2,phase.y+(iy+ny-1)*step+h/2
        local area=(math.max(g.maxx,x1)-math.min(g.minx,x0))*(math.max(g.maxy,y1)-math.min(g.miny,y0))
        local distance=math.abs(x0+x1-target.x0-target.x1)+math.abs(y0+y1-target.y0-target.y1)
        local score=area+distance*.01
        if not best or score<best.score then best={points=points,score=score,columns=nx,rows=ny}end
      end
    end end
    if best then break end
  end
  if not best then
    log('AFP GRID SPACE '..serpent.line{target=target,phase=phase,columns=columns,rows=rows,axis=axis,front=g.plot_front,controller=controller,strip=plan.grid_strip,city_blocks=plan.city_blocks})
    U.fail('roboport-space',prototype.localised_name)
  end
  if virtual then
    plan.grid_ports={}
    for _,p in ipairs(best.points)do plan.grid_ports[#plan.grid_ports+1]={position={x=p.x,y=p.y},planned=true,reference=p.reference}end
    return 0
  end
  local added=0;plan.roboports={}
  for _,p in ipairs(best.points)do
    local entity
    if p.reference then
      for x=p.x-w/2,p.x+w/2-1 do for y=p.y-h/2,p.y+h/2-1 do g:reserve(x,y,'grid-anchor')end end
      g.electric[#g.electric+1]={name=prototype.name,position={x=p.x,y=p.y},direction=0}
      g.minx=math.min(g.minx,p.x-w/2);g.maxx=math.max(g.maxx,p.x+w/2)
      g.miny=math.min(g.miny,p.y-h/2);g.maxy=math.max(g.maxy,p.y+h/2)
    else entity=g:add(prototype.name,p.x,p.y,0,{tags={afp_roboport=true}}).entity_number;added=added+1 end
    plan.roboports[#plan.roboports+1]={entity=entity,reference=p.reference,position={x=p.x,y=p.y},
      construction_radius=radius,logistic_radius=prototype.logistic_radius}
  end
  plan.roboport_grid={size=step,origin=U.copy(Grid.origin(s)),columns=best.columns,rows=best.rows}
  plan.roboport_prototype=prototype.name
  return added
end
function R.plan_grid(c,s,g,plan,turns,mirror)
  if not s.snap_grid or not plan.city_blocks then return end
  return grid_rectangle(c,s,g,plan,turns,mirror,Grid.prototype(c,s),plan.city_blocks.bounds,true)
end
function R.add(c,s,g,plan,turns,mirror,inside)
  if not s.roboports or not Grid.available(c,s)then return 0 end
  local prototype=Grid.prototype(c,s);local radius=prototype.construction_radius;local span=prototype.logistic_radius*2
  local w,h=prototype.tile_width,prototype.tile_height
  if radius<math.max(w,h)/2+Paving.width or span<math.max(w,h)+1 then U.fail('roboport-space',prototype.localised_name)end
  local body=rectangle(g,0);local target=plan.roboport_bounds or rectangle(g,Paving.width);local ports={};local added=0
  plan.roboport_bounds=target
  if s.snap_grid then return grid_rectangle(c,s,g,plan,turns,mirror,prototype,target)end
  local anchor;local context=s._project;local offset=plan.project_offset or context and context.offset
  local grid=s.snap_grid and Grid.size(c,s)
  local phase={x=0,y=0}
  if grid and offset then
    phase.x,phase.y=U.rotate(-offset.x,-offset.y,(4-turns)%4)
    if mirror then phase.y=-phase.y end
  end
  local function aligned(x,y)
    if not grid then return true end
    local dx,dy=(x-phase.x)/grid,(y-phase.y)/grid
    return math.abs(dx-math.floor(dx+.5))<eps and math.abs(dy-math.floor(dy+.5))<eps
  end
  if offset and context then
    local x,y=U.rotate(context.origin.x-offset.x,context.origin.y-offset.y,(4-turns)%4)
    anchor={x=x,y=mirror and-y or y}
  end
  for _,e in ipairs(g.entities)do if e.tags and e.tags.afp_roboport then ports[#ports+1]={x=e.position.x,y=e.position.y,entity=e.entity_number}end end
  local function free(x,y)
    if not aligned(x,y)then return false end
    local left,top=x-w/2,y-h/2
    if inside and(left<body.x0 or top<body.y0 or left+w>body.x1 or top+h>body.y1)then return false end
    if anchor and math.abs(anchor.x-x)<w/2+0.35 and math.abs(anchor.y-y)<h/2+0.35 then return false end
    for a=left,left+w-1 do for b=top,top+h-1 do if not g:free(a,b)then return false end end end
    return true
  end
  local function place(p)
    local e=g:add(prototype.name,p.x,p.y,0,{tags={afp_roboport=true}})
    p.entity=e.entity_number;ports[#ports+1]=p;added=added+1
    if #ports>1500 then U.fail('too-large')end
  end
  local sample=math.max(4,math.floor(span/2));local jitter=math.max(w,h,math.min(12,math.floor(sample/2)))
  -- Start with complete construction cells. A point-greedy cover can spend many
  -- ports on overlapping squares even in an empty rectangular plot.
  local columns=math.max(1,math.ceil((target.x1-target.x0)/(radius*2)-eps))
  local rows=math.max(1,math.ceil((target.y1-target.y0)/(radius*2)-eps))
  for ix=1,columns do for iy=1,rows do
    local cell={x0=target.x0+(ix-1)*(target.x1-target.x0)/columns,x1=target.x0+ix*(target.x1-target.x0)/columns,
      y0=target.y0+(iy-1)*(target.y1-target.y0)/rows,y1=target.y0+iy*(target.y1-target.y0)/rows}
    if gap(ports,cell,radius)then
      local cx=math.floor((cell.x0+cell.x1)/2-w/2)+w/2
      local cy=math.floor((cell.y0+cell.y1)/2-h/2)+h/2
      -- Construction squares are wider than network connections. Prefer a
      -- centre that also touches an existing logistic square, avoiding relays.
      for _,p in ipairs(ports)do
        local x0,x1=math.max(cell.x1-radius,p.x-span),math.min(cell.x0+radius,p.x+span)
        local y0,y1=math.max(cell.y1-radius,p.y-span),math.min(cell.y0+radius,p.y+span)
        if x0<=x1 and y0<=y1 then
          cx=math.floor(math.max(x0,math.min(x1,cx))-w/2)+w/2
          cy=math.floor(math.max(y0,math.min(y1,cy))-h/2)+h/2
          break
        end
      end
      local found
      for r=0,jitter do
        for dx=-r,r do for dy=-r,r do if not found and(r==0 or math.abs(dx)==r or math.abs(dy)==r)then
          local x,y=cx+dx,cy+dy
          if x-radius<=cell.x0+eps and x+radius>=cell.x1-eps and y-radius<=cell.y0+eps and y+radius>=cell.y1-eps and free(x,y)then found={x=x,y=y}end
        end end end
        if found then place(found);break end
      end
    end
  end end
  local candidates,seen={},{}
  local reach=inside and 0 or radius
  local step=grid or sample
  for ix=math.floor((body.x0-reach-phase.x)/step),math.ceil((body.x1+reach-phase.x)/step)do
    for iy=math.floor((body.y0-reach-phase.y)/step),math.ceil((body.y1+reach-phase.y)/step)do
      local cx=grid and phase.x+ix*step or math.floor(ix*step-w/2)+w/2
      local cy=grid and phase.y+iy*step or math.floor(iy*step-h/2)+h/2;local found
      for r=0,grid and 0 or jitter do
        for dx=-r,r do for dy=-r,r do if not found and(r==0 or math.abs(dx)==r or math.abs(dy)==r)then
          local x,y=cx+dx,cy+dy;local id=x..'/'..y
          if not seen[id]and free(x,y)then found={x=x,y=y};seen[id]=true end
        end end end
        if found then candidates[#candidates+1]=found;break end
      end
    end
  end
  local samples={}
  local function points(a,b)
    local values={a,b};for v=a+sample,b-1,sample do values[#values+1]=v end;return values
  end
  for _,x in ipairs(points(target.x0,target.x1))do for _,y in ipairs(points(target.y0,target.y1))do samples[#samples+1]={x=x,y=y}end end
  while true do local missing=gap(ports,target,radius);if not missing then break end
    local best,score
    for _,p in ipairs(candidates)do if free(p.x,p.y)and covered(p,missing.x,missing.y,radius)then
      local gain=1
      for _,point in ipairs(samples)do if covered(p,point.x,point.y,radius)then
        local old=false;for _,q in ipairs(ports)do if covered(q,point.x,point.y,radius)then old=true;break end end
        if not old then gain=gain+1 end
      end end
      local area=(math.max(g.maxx,p.x+w/2)-math.min(g.minx,p.x-w/2))*(math.max(g.maxy,p.y+h/2)-math.min(g.miny,p.y-h/2))
      local value=gain/(1+math.max(0,area-(g.maxx-g.minx)*(g.maxy-g.miny))*0.02)
      if not score or value>score then best,score=p,value end
    end end
    if not best then U.fail('roboport-space',prototype.localised_name)end
    place{x=best.x,y=best.y}
  end
  local function neighbours(a,b)return math.abs(a.x-b.x)<=span+eps and math.abs(a.y-b.y)<=span+eps end
  while #ports>1 do
    local connected={[1]=true};local queue={1};local head=1
    while queue[head]do local i=queue[head];head=head+1
      for j,p in ipairs(ports)do if not connected[j]and neighbours(ports[i],p)then connected[j]=true;queue[#queue+1]=j end end
    end
    if #queue==#ports then break end
    local vertices={};local goals={};local parents={};local pending={};local visited={}
    for i,p in ipairs(ports)do vertices[#vertices+1]=p;if connected[i]then pending[#pending+1]=#vertices;visited[#vertices]=true else goals[#vertices]=true end end
    for _,p in ipairs(candidates)do if free(p.x,p.y)then vertices[#vertices+1]=p end end
    local buckets={}
    for i,p in ipairs(vertices)do local id=(math.floor(p.x/span)+0)..'/'..(math.floor(p.y/span)+0);buckets[id]=buckets[id]or{};buckets[id][#buckets[id]+1]=i end
    head=1;local found
    while pending[head]and not found do local i=pending[head];head=head+1;local p=vertices[i]
      for dx=-1,1 do for dy=-1,1 do for _,j in ipairs(buckets[(math.floor(p.x/span)+dx)..'/'..(math.floor(p.y/span)+dy)]or{})do
        if not visited[j]and neighbours(p,vertices[j])then visited[j]=true;parents[j]=i;pending[#pending+1]=j;if goals[j]then found=j;break end end
      end end end
    end
    if not found then U.fail('roboport-network',prototype.localised_name)end
    local first=found
    while parents[first]and parents[parents[first]]do first=parents[first]end
    if first<=#ports or not free(vertices[first].x,vertices[first].y)then U.fail('roboport-network',prototype.localised_name)end
    place{x=vertices[first].x,y=vertices[first].y}
    plan.roboport_bridges=(plan.roboport_bridges or 0)+1
  end
  plan.roboports={};for _,p in ipairs(ports)do plan.roboports[#plan.roboports+1]={entity=p.entity,position={x=p.x,y=p.y},construction_radius=prototype.construction_radius,logistic_radius=prototype.logistic_radius}end
  plan.roboport_prototype=prototype.name
  return added
end
function R.covered(g,plan)
  if not plan.roboports then return true end
  if #plan.roboports==0 then return false end
  local ports={};for _,p in ipairs(plan.roboports)do ports[#ports+1]={x=p.position.x,y=p.position.y}end
  return not gap(ports,plan.roboport_bounds or rectangle(g,Paving.width),plan.roboports[1].construction_radius)
end
return R
