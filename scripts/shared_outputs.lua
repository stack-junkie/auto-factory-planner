local U=require('scripts.util')
local G=require('scripts.geometry')
local O={}
function O.face_inward(part)
  local old=part.g;old:transform(2,true);local g=G.new()
  for _,e in ipairs(old.entities)do local extra=U.copy(e);extra.position=nil;extra.entity_number=nil
    g:add(e.name,e.position.x,e.position.y,e.direction,extra)
  end
  for cell,id in pairs(old.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$')
    g:reserve(-tonumber(x)-1,tonumber(y),id,old.fluid_ports[cell])
  end
  for _,t in ipairs(old.tunnels)do
    if t.horizontal then g:tunnel(t.kind,-t.hi-1,t.y,-t.lo-1,t.y)
    else g:tunnel(t.kind,-t.x-1,t.lo,-t.x-1,t.hi)end
  end
  for _,row in ipairs(part.rows)do local b=row.bounds
    row.bounds={x0=-b.x1,y0=b.y0,x1=-b.x0,y1=b.y1}
  end
  for _,t in ipairs(part.terminals)do local p=t.port;p.x=-p.x-1;p.d=(4-(p.d or 0))%4 end
  for _,line in ipairs(part.corridors or{})do line.x=-line.x-1 end
  for _,line in ipairs(part.collectors or{})do line.x=-line.x-1 end
  part.g=g
end
function O.mark(box,part)
  if #(part.collectors or{})==1 then local line=part.collectors[1]
    box.output_x=box.x0+line.x-part.bounds.x0;box.output_key=line.key
  end
  return box
end
-- Only the collector stripe can overlap, never machines, arms or feed belts.
function O.overlap(a,b)
  return a.output_key and a.output_key==b.output_key and a.output_x==b.output_x
    and math.max(a.x0,b.x0)==a.output_x and math.min(a.x1,b.x1)==a.output_x+1
end
function O.add(g,plan,lines,terminals,belt)
  local groups={}
  for _,line in ipairs(lines)do local id=line.key..'/'..line.x
    local group=groups[id]
    if not group then group={key=line.key,x=line.x,y0=line.y0,y1=line.y1,rate=0,ports={}};groups[id]=group end
    group.y0=math.min(group.y0,line.y0);group.y1=math.max(group.y1,line.y1);group.rate=group.rate+line.rate
    group.ports[line.port_id]=true
  end
  local replaced={};local additions={}
  for _,id in ipairs(U.sorted(groups))do local group=groups[id];local count=0
    for _ in pairs(group.ports)do count=count+1 end
    for y=group.y0,group.y1 do g:tile(belt.name,group.x,y,8,nil,group.key)end
    if count>1 then
      for _,t in ipairs(terminals)do if group.ports[t.port.id]then
        replaced[t]=true;local cell=G.cell(t.port.x,t.port.y)
        if g.reserved[cell]==t.port.id then g.reserved[cell]=nil end
      end end
      local p={x=group.x,y=group.y1+1,d=2,plain=true,id='shared-output/'..id}
      g:reserve(p.x,p.y,p.id)
      additions[#additions+1]={key=group.key,port=p,rate=group.rate,produce=true,forward=true,vertical=true}
      plan.shared_collectors=plan.shared_collectors or{}
      plan.shared_collectors[#plan.shared_collectors+1]={key=group.key,x=group.x,y0=group.y0,y1=group.y1,banks=count,rate=group.rate}
    end
  end
  local result={};for _,t in ipairs(terminals)do if not replaced[t]then result[#result+1]=t end end
  for _,t in ipairs(additions)do result[#result+1]=t end
  return result
end
return O
