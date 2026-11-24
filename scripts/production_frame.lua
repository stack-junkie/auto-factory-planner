local U=require('scripts.util')
local Grid=require('scripts.grid')
local Paving=require('scripts.paving')
local F={}
function F.prepare(s,plan,turns,mirror)
  for key,value in pairs(s)do if type(key)=='string'and key:match('^_legacy_')and value then return end end
  local context=s._project
  -- Historical malls retain their existing intake-driven frame during migration.
  if not plan.rate_search and context then
    if context.production_frame==false or(context.revision or 0)>0 and not context.production_frame and(context.layout_revision or 0)<52 then return end
  end
  local origin=s._project and s._project.origin or s.port_origin or(s.snap_grid and{x=.5,y=.5})
  if not origin then return end
  -- This frame is independent of both saved and newly selected world sockets.
  local x,y=U.rotate(4.5,mirror and-3.5 or 3.5,turns)
  plan.project_offset={x=origin.x+x,y=origin.y+y}
  plan.fixed_production=true
  plan.production_anchor={x=-4.5,y=-3.5}
end
function F.place(c,s,plan,fluid,bay)
  plan.production_frame_placed=true
  local anchor=plan.production_anchor
  local x=math.floor(anchor.x+4.5+1e-6)
  local front=math.ceil(anchor.y+.5-1e-6)
  local available
  if Paving.grid_roads(s)then
    local primary=Grid.primary(c,s,plan,plan.orientation.turns,plan.orientation.mirror)
    plan.primary_city_block=primary;plan.controller_position=Grid.controller_corner(c,s,primary)
    local bounds=primary.bounds;local margin=Paving.road_width/2
    -- Fluid manifolds need a free bypass beside their boundary pipe.
    local inset=margin+1;local approach=fluid and 3 or 0
    x=bounds.x0+inset+approach;front=bounds.y0+inset
    plan.grid_strip={axis='x',line=bounds.x0};plan.grid_front={axis='y',line=bounds.y0,value=bounds.y0+margin}
    plan.building_setback=1;plan.building_inset=inset
    available=primary.size-2*inset-approach
  end
  plan.production_clearance=bay
  plan.production_start=front+bay
  return x,front+bay,front,available
end
function F.align(c,s,g,plan,turns,mirror)
  if not s.snap_grid or plan.production_frame_placed then return end
  for key,value in pairs(s)do if type(key)=='string'and key:match('^_legacy_')and value then return end end
  local primary=Grid.primary(c,s,plan,turns,mirror);local inset=Paving.road_width/2+1
  local dx=primary.bounds.x0+inset-g.minx;local dy=primary.bounds.y0+inset-g.miny
  local x,y=U.rotate(dx,mirror and-dy or dy,turns)
  plan.project_offset=plan.project_offset or{x=0,y=0}
  plan.project_offset.x=plan.project_offset.x+x;plan.project_offset.y=plan.project_offset.y+y
  primary=Grid.primary(c,s,plan,turns,mirror)
  plan.primary_city_block=primary;plan.controller_position=Grid.controller_corner(c,s,primary)
  plan.grid_strip={axis='x',line=primary.bounds.x0};plan.grid_front={axis='y',line=primary.bounds.y0,value=primary.bounds.y0+2}
  plan.building_setback=1;plan.building_inset=inset
end
return F
