local U=require('scripts.util')
local G=require('scripts.geometry')
local O={}
function O.reverse_collectors(s,g,plan)
  if not s.snap_grid or not plan.rate_search then return end
  local changed=false
  for _,p in ipairs(plan.ports)do if p.kind=='out'and not p.manual_target then
    local flow=plan.flows[p.key]
    for _,line in ipairs(plan.shared_collectors or{})do if line.key==p.key and(not flow or(flow.internal or 0)==0)
      and p.local_position.x==line.x and p.local_position.y==line.y1+1 then
      local old=p.local_position;local marker=g.occupied[G.cell(old.x,old.y)]
      for y=line.y0,line.y1 do g.occupied[G.cell(line.x,y)].entity.direction=0 end
      marker.entity.direction=0
      local y=line.y0-1
      if g:free(line.x,y,'item',p.key)then
        g.occupied[G.cell(old.x,old.y)]=nil;g.occupied[G.cell(line.x,y)]=marker
        marker.entity.position={x=line.x+.5,y=y+.5}
      else
        -- A crossing can start at the first collector tile itself.
        -- Keep the lower end pointing into the collector, with no export tag.
        if marker.entity.tags then marker.entity.tags.afp_port=nil end
        y=line.y0
      end
      p.local_position={x=line.x,y=y};p.display_direction=2;line.direction=0
      changed=true
    end end
  end end
  return changed
end
function O.gateways(s,g,plan,turns,mirror)
  if not s.snap_grid or not plan.rate_search or not plan.city_blocks then return end
  local b=plan.city_blocks.bounds;local used={};plan.automatic_outputs={}
  for _,p in ipairs(plan.ports)do if p.kind=='out'and U.split(p.key)=='item'and not p.manual_target then
    local source=p.local_position;local d=0
    local x=math.max(b.x0+3,math.min(b.x1-4,source.x));local y=b.y0-3
    local chosen
    for radius=0,b.x1-b.x0 do for _,candidate in ipairs(radius==0 and{x}or{x-radius,x+radius})do
      local cell=G.cell(candidate,y);local allow=g.reserved[cell]=='output-end/'..p.id and g.reserved[cell]or nil
      if not chosen and candidate>=b.x0+3 and candidate<=b.x1-4 and not used[cell]and g:free(candidate,y,'item',p.key,allow)then chosen=candidate end
    end;if chosen then break end end
    if not chosen then U.fail('layout-ports')end
    x=chosen;used[G.cell(x,y)]=true
    local wx,wy=U.rotate(x+.5,mirror and-y-.5 or y+.5,turns)
    local direction=d*4;if mirror then direction=(8-direction)%16 end
    local offset=plan.project_offset
    plan.automatic_outputs[p.id]={position={x=wx+offset.x,y=wy+offset.y},direction=(direction+turns*4)%16,
      surface=s._project and s._project.surface}
  end end
end
function O.reserve(g,plan)
  if not plan.branch_rows then return end
  for _,p in ipairs(plan.ports)do if p.kind=='out'and U.split(p.key)=='item'then
    local d=((p.display_direction or 2)+2)%4;local x,y=p.local_position.x,p.local_position.y
    local lo,hi=d%2==0 and g.miny or g.minx,d%2==0 and g.maxy or g.maxx
    local distance=d==0 and y-lo or d==1 and hi-x or d==2 and hi-y or x-lo
    for n=1,distance+100 do local px,py=x+G.dx[d+1]*n,y+G.dy[d+1]*n;local cell=G.cell(px,py)
      if g.occupied[cell]then U.fail('layout-ports')end
      g.reserved[cell]='output-end/'..p.id
    end
  end end
end
function O.extend(g,plan,belt,turns,mirror)
  if not plan.branch_rows then return end
  if plan.primary_city_block and plan.rate_search then return end
  for _,p in ipairs(plan.ports)do if p.kind=='out'and U.split(p.key)=='item'and not p.manual_target then
    local d=((p.display_direction or 2)+2)%4;local x,y=p.local_position.x,p.local_position.y
    local last=d==0 and g.miny or d==1 and g.maxx-1 or d==2 and g.maxy-1 or g.minx
    local function at_end()return(d%2==0 and y or x)==last end
    local old=g.occupied[G.cell(x,y)];if old and old.entity.tags then old.entity.tags.afp_port=nil end
    while not at_end()do
      x=x+G.dx[d+1];y=y+G.dy[d+1]
      if g.occupied[G.cell(x,y)]then log('AFP OUTPUT BLOCKED '..p.id..' at '..x..'/'..y..' by '..g.occupied[G.cell(x,y)].entity.name);U.fail('layout-ports')end
      g:tile(belt.name,x,y,d*4,nil,p.key)
    end
    p.local_position={x=x,y=y}
    for _,interface in ipairs(plan.bus_hierarchy and plan.bus_hierarchy.interfaces or{})do if interface.port==p.id then interface.position=U.copy(p.local_position)end end
    local wx,wy=U.rotate(x+.5,(mirror and -1 or 1)*(y+.5),turns);p.position={x=wx,y=wy}
    local e=g.occupied[G.cell(x,y)].entity;e.tags=e.tags or{}
    e.tags.afp_port={id=p.id,key=U.base_key(p.key),kind=p.kind,rate=p.rate,section=p.section or 1,index=p.index}
  end end
end
return O
