local U=require('scripts.util')
local I={}
function I.capacity(p,c,key,ingredients)
  local _,name=U.split(key);local item=prototypes.item[name]
  local stack=math.min(item.stack_size,1+(p.inserter_stack_size_bonus or 0)+(p.bulk and c.force.bulk_inserter_capacity_bonus or p.uses_inserter_stack_size_bonus and c.force.inserter_stack_size_bonus or 0))
  local switching=ingredients and ingredients>1 and .65 or 1
  return p.get_inserter_rotation_speed('normal')*3600*stack*0.5*switching
end
function I.direct_capacity(p,c,key)
  local _,name=U.split(key);local item=prototypes.item[name]
  local stack=math.min(item.stack_size,1+(p.inserter_stack_size_bonus or 0)+(p.bulk and c.force.bulk_inserter_capacity_bonus or p.uses_inserter_stack_size_bonus and c.force.inserter_stack_size_bonus or 0))
  -- Inventory transfers have no belt pickup wait. Both half turns round up
  -- to whole ticks; reserve one tick per stop for pickup and drop.
  local swing=math.ceil(0.5/p.get_inserter_rotation_speed('normal'))
  return 3600*stack/(2*swing+2)
end
function I.supported(p)
  local a,b=p.inserter_pickup_position,p.inserter_drop_position
  return not p.burner_prototype and a and b and math.abs(a[1])<0.1 and math.abs(b[1])<0.1 and a[2]<-0.9 and b[2]>0.9
    and math.abs(-a[2]-math.floor(-a[2]+0.5))<0.3 and math.abs(b[2]-math.floor(b[2]+0.5))<0.3
end
return I
