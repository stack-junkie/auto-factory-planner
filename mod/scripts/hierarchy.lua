local U=require('scripts.util')
local H={}
-- The main bus belongs to the player. This module describes the interface;
-- it receives no geometry builder and cannot create a main-bus entity.
function H.describe(plan,buses,length,settings)
  local direction=((settings.direction or 2)-1)*4
  local h={levels=3,generated_levels=2,main={id='main',external=true,built=false,direction=direction,lanes={},entities={}},
    recipe={id='recipe',target=plan.target,lanes={},direction=(direction+(settings.side==2 and -4 or 4))%16},
    interfaces={},lines=plan.production_rows}
  plan.bus_hierarchy=h
  local x0,y0,x1,y1=0,0,length,0
  for _,key in ipairs(U.sorted(buses)) do
    local b=buses[key]
    h.recipe.lanes[#h.recipe.lanes+1]={key=key,x0=b.minx or 0,x1=b.fluid and length or b.maxx,y=b.y,closed=b.closed,
      group=b.group,lane=b.lane,role=b.role}
    if b.role then h.recipe.group_size=4;h.recipe.group_gap=2 end
    x0=math.min(x0,b.minx or 0);x1=math.max(x1,b.maxx or length);y0=math.min(y0,b.y-b.above);y1=math.max(y1,b.y+b.below)
  end
  h.recipe.bounds={x0=x0,y0=y0,x1=x1,y1=y1}
  h.main.interface={from=U.copy(plan.ports[1].local_position),to=U.copy(plan.ports[#plan.ports].local_position)}
  for _,port in ipairs(plan.ports) do
    h.interfaces[#h.interfaces+1]={key=port.key,kind=port.kind,from=port.kind=='in' and 'main' or 'recipe',
      to=port.kind=='in' and 'recipe' or 'main',port=port.id,position=U.copy(port.local_position)}
  end
  return h
end
return H
