local U=require('scripts.util')
local Grid=require('scripts.grid')
local B={}
function B.measure(bounds,size,phase)
  local x0=math.floor((bounds.x0-phase.x)/size+1e-7)
  local y0=math.floor((bounds.y0-phase.y)/size+1e-7)
  local x1=math.max(x0+1,math.ceil((bounds.x1-phase.x)/size-1e-7))
  local y1=math.max(y0+1,math.ceil((bounds.y1-phase.y)/size-1e-7))
  return{x0=x0,y0=y0,x1=x1,y1=y1,columns=x1-x0,rows=y1-y0,units=(x1-x0)*(y1-y0)}
end
function B.prepare(c,s,g,plan,turns,mirror)
  if not s.snap_grid then return end
  local size=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
  local body={x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy}
  local footprint=U.copy(body)
  -- Gateways and service poles on the four-tile boundary road belong to
  -- that boundary, rather than consuming a neighbouring production block.
  if plan.grid_strip and plan.grid_strip.axis=='x'then local line=plan.grid_strip.line
    if footprint.x0>=line-2 then footprint.x0=math.max(footprint.x0,line)end
    if footprint.x1<=line+size+2 then footprint.x1=math.min(footprint.x1,line+size)end
  end
  if plan.grid_front and(plan.grid_front.axis or'y')=='y'then local line=plan.grid_front.line
    if footprint.y0>=line-2 then footprint.y0=math.max(footprint.y0,line)end
  end
  local cells=B.measure(footprint,size,phase)
  if plan.primary_city_block then local primary=plan.primary_city_block.bounds
    local ix=math.floor((primary.x0-phase.x)/size+.5);local iy=math.floor((primary.y0-phase.y)/size+.5)
    cells.x0=math.min(cells.x0,ix);cells.y0=math.min(cells.y0,iy)
    cells.x1=math.max(cells.x1,ix+1);cells.y1=math.max(cells.y1,iy+1)
    cells.columns=cells.x1-cells.x0;cells.rows=cells.y1-cells.y0;cells.units=cells.columns*cells.rows
  end
  local bounds={x0=phase.x+cells.x0*size,y0=phase.y+cells.y0*size,x1=phase.x+cells.x1*size,y1=phase.y+cells.y1*size}
  cells.size=size;cells.origin=U.copy(Grid.origin(s));cells.phase=phase;cells.bounds=bounds;cells.factory_bounds=body
  cells.area=(body.x1-body.x0)*(body.y1-body.y0);cells.perimeter=2*(body.x1-body.x0+body.y1-body.y0)
  plan.city_blocks=cells;plan.grid_ports={}
  for _,x in ipairs({bounds.x0,bounds.x1})do for _,y in ipairs({bounds.y0,bounds.y1})do
    plan.grid_ports[#plan.grid_ports+1]={position={x=x,y=y},planned=true}
  end end
end
return B
