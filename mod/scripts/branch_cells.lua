local U=require('scripts.util')
local G=require('scripts.geometry')
local B={}
-- The intake header follows the main bus (x); production follows its branch
-- (y). Transform the cell, keeping the header and its fixed world pins intact.
function B.align(part)
  local old=part.g;old:transform(1,true)
  local g=G.new()
  for _,e in ipairs(old.entities)do local extra=U.copy(e);extra.position=nil;extra.entity_number=nil
    g:add(e.name,e.position.x,e.position.y,e.direction,extra)
  end
  for cell,id in pairs(old.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$')
    g:reserve(tonumber(y),tonumber(x),id,old.fluid_ports[cell])
  end
  for _,t in ipairs(old.tunnels)do
    if t.horizontal then g:tunnel(t.kind,t.y,t.lo,t.y,t.hi)else g:tunnel(t.kind,t.lo,t.x,t.hi,t.x)end
  end
  for _,row in ipairs(part.rows)do local b=row.bounds;row.bounds={x0=b.y0,y0=b.x0,x1=b.y1,y1=b.x1}
    if row.output_collector then local p=row.output_collector.tap;p.x,p.y=p.y,p.x end
  end
  for _,t in ipairs(part.terminals)do local p=t.port;p.x,p.y=p.y,p.x;p.d=(3-(p.d or 1))%4 end
  for _,line in ipairs(part.corridors or{})do line.x=line.y;line.y0=line.x0;line.y1=line.x1;line.vertical=true end
  for _,line in ipairs(part.collectors or{})do line.x=line.y;line.y0=line.x0;line.y1=line.x1;line.d=2;line.vertical=true end
  if part.central_spine then local line=part.central_spine;line.x=line.y;line.y0=line.x0;line.y1=line.x1;line.feed_x=line.feed_y;line.direction=0 end
  part.g=g;part.branch_rows=true
  return part
end
return B
