local C=require('scripts.catalogue')
local G=require('scripts.geometry')
local U=require('scripts.util')
local D={}
function D.reserve(c,s,g,plan)
  if s.mode~='mall'and s._legacy_rate then return end
  if not plan.power_base and not s._legacy_orientation and not s._legacy_layout then
    for _,port in ipairs(plan.ports)do if port.kind=='in'then plan.power_base={x=port.local_position.x-1,y=port.local_position.y+1};break end end
  end
  if not C.options(c,'display-panel')[1]then return end
  local ports={};for _,port in ipairs(plan.ports)do ports[G.cell(port.local_position.x,port.local_position.y)]=true end
  plan.display_sites={}
  for _,port in ipairs(plan.ports)do if port.kind=='in'then
    local d=port.display_direction or port.pinned_direction or(s._mall_compact_axes and 2 or 1);local p=port.local_position;local chosen
    for radius=1,4 do
      for _,side in ipairs({1,-1})do
        local face=(d+side)%4;local x,y=p.x+G.dx[face+1]*radius,p.y+G.dy[face+1]*radius
        if not chosen and not ports[G.cell(x,y)]and g:free(x,y)then chosen={x=x,y=y,id='display/'..port.id}end
      end
      if chosen then break end
    end
    if not chosen then U.fail('layout-ports')end
    g:reserve(chosen.x,chosen.y,chosen.id);plan.display_sites[port.id]=chosen
  end end
end
function D.add(c,s,g,plan)
  if s.mode~='mall'and s._legacy_rate then return end
  if s._legacy_straight or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout then return end
  local panel=C.options(c,'display-panel')[1]
  if not panel then return end
  plan.input_displays={}
  for _,port in ipairs(plan.ports)do if port.kind=='in'then
    local d=port.display_direction or port.pinned_direction or(s._mall_compact_axes and 2 or 1)
    local p=port.local_position;local chosen=plan.display_sites and plan.display_sites[port.id]
    for _,side in ipairs({1,-1})do
      local face=(d+side)%4
      local x,y=p.x+G.dx[face+1],p.y+G.dy[face+1]
      if not chosen and g:free(x,y)then chosen={x=x,y=y};break end
    end
    if chosen then
      local extra={tags={afp_input_display={key=U.base_key(port.key),id=port.id,index=port.index}}}
      if plan.display_sites then extra.icon=U.signal(port.key);extra.text='';extra.always_show=true;extra.show_in_chart=true
      else extra.control_behavior={parameters={{condition={first_signal=U.signal(port.key),comparator='=',constant=0},icon=U.signal(port.key),text=''}}}end
      local e=g:tile(panel.name,chosen.x,chosen.y,0,extra,port.key)
      plan.input_displays[#plan.input_displays+1]={entity=e.entity_number,key=U.base_key(port.key),port=port.id}
    end
  end end
end
return D
