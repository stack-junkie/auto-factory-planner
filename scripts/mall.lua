local U=require('scripts.util')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local Mall={}
function Mall.migrate(s)
  if not s then return end
  for _,target in ipairs(s.targets or {}) do if target.stock~=nil then
    local _,name=U.split(target.key or 'item:')
    local item=name and prototypes.item[name]
    target.stacks=target.stacks or math.ceil(target.stock/(item and item.stack_size or 100))
    target.stock=nil
  end end
end
function Mall.chests(c)
  local result={}
  for _,kind in ipairs({'container','logistic-container'}) do for _,p in ipairs(C.options(c,kind)) do
    local size=p.get_inventory_size(defines.inventory.chest,'normal')
    if p.tile_width==1 and p.tile_height==1 and size and size>0
      and (p.inventory_type=='with_bar' or p.inventory_type=='with_filters_and_bar') then result[#result+1]=p end
  end end
  table.sort(result,function(a,b)
    local x,y=a.get_inventory_size(defines.inventory.chest,'normal'),b.get_inventory_size(defines.inventory.chest,'normal')
    if x~=y then return x<y end
    return a.order==b.order and a.name<b.name or a.order<b.order
  end)
  return result
end
function Mall.chest(c,s,stacks)
  local override=s.infrastructure and s.infrastructure.chest
  for _,p in ipairs(Mall.chests(c)) do if not override or p.name==override then
    local size=p.get_inventory_size(defines.inventory.chest,'normal')
    if size>=stacks then return p end
    if override then U.fail('mall-capacity',p.localised_name,stacks,size) end
  end end
  if override then U.fail('infrastructure',override) end
  U.fail('missing-infrastructure','container')
end
function Mall.configure(project)
  for _,buffer in ipairs(project.buffers or {}) do
    local _,name=U.split(buffer.key);local item=prototypes.item[name]
    if item then
      buffer.stacks=buffer.stacks or math.ceil(buffer.stock/item.stack_size)
      buffer.stock=buffer.stacks*item.stack_size
      local chest,arm=project.members[buffer.chest],project.members[buffer.inserter]
      if chest and chest.valid and chest.inventory_supports_bar(defines.inventory.chest) then
        local prototype=chest.type=='entity-ghost' and chest.ghost_prototype or chest.prototype
        chest.set_inventory_bar(defines.inventory.chest,math.min(buffer.stacks,prototype.get_inventory_size(defines.inventory.chest,'normal'))+1)
      end
      if arm and arm.valid and arm.type~='entity-ghost' then arm.disabled_by_script=false;arm.inserter_stack_size_override=0 end
    end
  end
end
function Mall.add(g,c,s,plan)
  if s.mode~='mall' or plan.mall_buffers then return end
  local targets={};for _,target in ipairs(plan.targets) do targets[target.key]=target end
  plan.mall_buffers={}
  for _,port in ipairs(plan.ports) do local target=targets[U.base_key(port.key)]
    if port.kind=='out' and target then
      local _,name=U.split(port.key);local stacks=math.ceil(target.stacks/(plan.sections or 1));local stock=stacks*prototypes.item[name].stack_size
      local chest=Mall.chest(c,s,stacks)
      local arm=C.pick(c,'inserter',s.infrastructure and s.infrastructure.inserter,function(p)
        return I.supported(p) and math.floor(-p.inserter_pickup_position[2]+0.5)==1 and math.floor(p.inserter_drop_position[2]+0.5)==1
      end,function(p)return p.get_inserter_rotation_speed('normal') end)
      local pos=port.local_position
      local box=g:tile(chest.name,pos.x-2,pos.y,0,{bar=stacks,tags={afp_mall={key=U.base_key(port.key),stacks=stacks}}},port.key)
      local inserter=g:tile(arm.name,pos.x-1,pos.y,4,{use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}},
        tags={afp_mall_output=true}},port.key)
      plan.mall_buffers[#plan.mall_buffers+1]={key=U.base_key(port.key),stock=stock,stacks=stacks,chest=box.entity_number,inserter=inserter.entity_number}
    end
  end
end
return Mall
