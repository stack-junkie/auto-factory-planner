local U=require('scripts.util')
local G=require('scripts.geometry')
local R=require('scripts.router')
local Inputs=require('scripts.inputs')
local A=require('scripts.arrangement')
local C=require('scripts.catalogue')
local M={}
function M.id(port)return port.kind..'/'..Inputs.id(port)end
local function selected(s,plan,port)
  local pin=s.manual_ports and s.manual_ports[M.id(port)]
  if pin then return pin end
  if port.kind=='out'and plan.automatic_outputs then return plan.automatic_outputs[port.id]end
  if plan.fixed_production and port.kind=='in'and s._project then
    if s._project.manual_ports and s._project.manual_ports[M.id(port)]then return end
    local pins=s._project.physical_inputs or(plan.intake_migrated and plan.project_inputs)or s._project.inputs or{}
    for _,old in ipairs(pins)do
      if old.id==Inputs.id(port)then return{position=old.position,direction=old.heading or old.direction,entity_direction=old.direction,surface=s._project.surface}end
    end
  end
end
-- Place production first, then feed it from selected or persisted world sockets.
function M.prepare(g,s,plan,equipment,turns,mirror)
  if(not next(s.manual_ports or{})and not plan.fixed_production)or not plan.project_offset then return end
  if plan.fixed_production then g.plot_front=nil end
  local offset=plan.project_offset
  plan.routing_inputs=U.copy(plan.project_inputs or{})
  if plan.fixed_production then
    for _,port in ipairs(plan.ports)do if port.kind=='in'then
      for _,pin in ipairs(plan.routing_inputs)do if pin.id==Inputs.id(port)then
        local d=(port.pinned_direction or 2)*4;if mirror then d=(8-d)%16 end;d=(d+turns*4)%16
        pin.position={x=offset.x+port.position.x,y=offset.y+port.position.y};pin.direction=d;pin.heading=d
      end end
    end end
  end
  local known={};for _,pin in ipairs(plan.routing_inputs)do known[pin.id]=true end
  for _,port in ipairs(plan.ports)do if port.kind=='in'and not known[Inputs.id(port)]then
    local d=(port.pinned_direction or 2)*4;if mirror then d=(8-d)%16 end;d=(d+turns*4)%16
    plan.routing_inputs[#plan.routing_inputs+1]={id=Inputs.id(port),key=U.base_key(port.key),section=port.section or 1,index=port.index,
      position={x=offset.x+port.position.x,y=offset.y+port.position.y},direction=d,heading=d,active=true,
      name=U.split(port.key)=='item'and equipment.belt.name or equipment.pipe.name}
  end end
  plan.manual_corridor=plan.branch_rows and {axis='y',value=plan.grid_front and plan.grid_front.value or(plan.intake_front or -4)+3,
    minimum=plan.grid_front and plan.grid_front.value}or nil
  for _,port in ipairs(plan.ports)do local pin=selected(s,plan,port)
    if pin and U.split(port.key)=='fluid'then
      local x,y=U.rotate(pin.position.x-offset.x,pin.position.y-offset.y,(4-turns)%4);if mirror then y=-y end
      x,y=math.floor(x+1e-6),math.floor(y+1e-6)
      local d=((pin.direction or 0)-turns*4)%16;if mirror then d=(8-d)%16 end;d=d/4
      local id='manual/'..M.id(port);local sign=port.kind=='in'and 1 or-1
      if plan.fixed_production and port.kind=='in'then
        if g.occupied[G.cell(x,y)]then U.fail('manual-port-blocked',U.name(port.key),pin.position.x,pin.position.y)end
        port.local_position={x=x,y=y};port.position={x=pin.position.x-offset.x,y=pin.position.y-offset.y};port.pinned_direction=d
        id='user/'..port.id
        plan.manual_keys=plan.manual_keys or{};plan.manual_keys[port.key]=true
      end
      for step=0,3 do local k=G.cell(x+G.dx[d+1]*step*sign,y+G.dy[d+1]*step*sign)
        if not g.occupied[k]and not g.reserved[k]then g.reserved[k]=id end
        if g.reserved[k]==id then g.fluid_ports[k]=port.key end
      end
    end
    if pin and U.split(port.key)=='item'then
      port.manual_target=true
      if port.kind=='out'then
        local x,y=U.rotate(pin.position.x-offset.x,pin.position.y-offset.y,(4-turns)%4);if mirror then y=-y end
        local d=((pin.direction or 0)-turns*4)%16;if mirror then d=(8-d)%16 end;d=d/4
        for n=0,2 do local cell=G.cell(math.floor(x+1e-6)-G.dx[d+1]*n,math.floor(y+1e-6)-G.dy[d+1]*n)
          if not g.occupied[cell]and not g.reserved[cell]then g.reserved[cell]='manual/'..M.id(port)end
        end
      end
      if port.kind=='in'then
        if pin.surface and s._project and pin.surface~=s._project.surface then U.fail('manual-port-surface')end
        local x,y=U.rotate(pin.position.x-offset.x,pin.position.y-offset.y,(4-turns)%4);if mirror then y=-y end
        x,y=math.floor(x+1e-6),math.floor(y+1e-6)
        -- Selected sockets outside the production strip are connected after
        -- placement. Including them in the internal header would widen the
        -- factory and pull it away from the controller's primary cell.
        local primary=plan.primary_city_block
        local deferred=primary and(x<primary.bounds.x0+3 or x>=primary.bounds.x1-3)
        if not deferred then
          if g.occupied[G.cell(x,y)]then U.fail('manual-port-blocked',U.name(port.key),pin.position.x,pin.position.y)end
          local d=((pin.direction or 0)-turns*4)%16;if mirror then d=(8-d)%16 end
          port.local_position={x=x,y=y};port.position={x=pin.position.x-offset.x,y=pin.position.y-offset.y};port.pinned_direction=d/4
          plan.manual_keys=plan.manual_keys or{};plan.manual_keys[port.key]=true
          g.plot_front=nil
        end
      end
    end
  end
end
function M.apply(c,s,g,plan,equipment,work)
  if not next(s.manual_ports or{})and not plan.fixed_production then return false end
  local turns,mirror=A.orientation(s)
  local origin=s._project and s._project.origin or s.port_origin
  if not origin and not plan.project_offset then U.fail('manual-port-origin')end
  local offset=plan.project_offset or Inputs.offset(origin,s,plan.local_bounds,plan.orientation)
  plan.project_offset=offset
  plan.routing_inputs=plan.routing_inputs or U.copy(plan.project_inputs)
  local front,body=g.plot_front,g.plot_front_body;g.plot_front=nil;g.plot_front_body=nil
  local requests,occupied={},{}
  for _,port in ipairs(plan.ports)do local pin=selected(s,plan,port)
    if pin then
      if pin.surface and s._project and pin.surface~=s._project.surface then U.fail('manual-port-surface')end
      local x,y=U.rotate(pin.position.x-offset.x,pin.position.y-offset.y,(4-turns)%4);if mirror then y=-y end
      x,y=math.floor(x),math.floor(y)
      local d=((pin.direction or 0)-turns*4)%16;if mirror then d=(8-d)%16 end;d=d/4
      local old=port.local_position;local marker=g.occupied[G.cell(old.x,old.y)]
      local old_entity=marker and marker.entity
      if not old_entity then U.fail('port',U.name(port.key))end
      local cell=G.cell(x,y)
      if work then
        local from,to=U.copy(old),{x=x,y=y}
        work.search={key=port.key,from=from,to=to,failure={key=port.key,from=from,to=to,reason='blocked',expanded=0,range=0}}
      end
      if occupied[cell]or g.occupied[cell]and g.occupied[cell].entity~=old_entity then U.fail('manual-port-blocked',U.name(port.key),pin.position.x,pin.position.y)end
      occupied[cell]=true;requests[#requests+1]={port=port,pin=pin,x=x,y=y,d=d,old=old_entity}
      local id='manual/'..M.id(port);local sign=port.kind=='in'and 1 or-1
      for n=0,(U.split(port.key)=='fluid'and 3 or 2)do local k=G.cell(x+G.dx[d+1]*n*sign,y+G.dy[d+1]*n*sign)
        if g.reserved[k]and g.reserved[k]:match('^manual/')and g.reserved[k]~=id then U.fail('manual-port-blocked',U.name(port.key),pin.position.x,pin.position.y)end
        g.reserved[k]=id
        if U.split(port.key)=='fluid'then g.fluid_ports[k]=port.key end
      end
    end
  end
  for _,v in ipairs(requests)do
    local port,old=v.port,v.old;local id='manual/'..M.id(port);local kind=U.split(port.key)
    local p=port.local_position;local oldd=(old.direction or 0)/4
    local start={x=p.x,y=p.y,d=oldd,plain=true};local target={x=v.x,y=v.y,d=v.d,plain=true}
    if port.kind=='out'and prototypes.entity[old.name].type=='transport-belt'then start.turnable=true end
    if port.kind=='in'then start,target=target,start end
    if kind=='fluid'then if port.kind=='in'then target.d=nil else start.d=nil end end
    -- An exported intermediate must have its own pressure segment. Otherwise
    -- cracking can drain it while a full co-product slows the shared producer.
    local flow=plan.flows and plan.flows[port.key]
    if kind=='fluid'and port.kind=='out'and flow and flow.internal_export and(p.x~=v.x or p.y~=v.y)then
      local pump=C.pick(c,'pump',nil,function(proto)return proto.tile_width==1 and proto.tile_height==2 end)
      local dx,dy=G.dx[v.d+1],G.dy[v.d+1]
      g:tile(equipment.pipe,v.x,v.y,0,nil,port.key)
      g:add(pump.name,v.x+.5-dx*1.5,v.y+.5-dy*1.5,v.d*4,nil,port.key)
      target={x=v.x-dx*3,y=v.y-dy*3,d=v.d,plain=true}
      port.export_pump=true
    end
    if p.x~=v.x or p.y~=v.y then
      local belt=prototypes.entity[kind=='item'and equipment.belt or equipment.pipe]
      local underground=prototypes.entity[kind=='item'and(plan.balanced_underground and plan.balanced_underground[port.key]or equipment.underground)or equipment.pipeug]
      local search=R.begin(start,target,kind,port.key,belt,underground,id,kind=='fluid'and port.kind=='in',old.tags and old.tags.afp_network or port.key)
      if kind=='item'then R.manual(search,plan.manual_corridor)end
      if work then work.search=search end
      search.reuse={[G.cell(p.x,p.y)]=old.entity_number};search.limit=160000
      local sign=port.kind=='in'and-1 or 1
      for n=1,4 do local k=G.cell(p.x+G.dx[oldd+1]*n*sign,p.y+G.dy[oldd+1]*n*sign)
        if g.reserved[k]and not g.reserved[k]:match('^manual/')then g.reserved[k]=nil end
      end
      if port.kind=='out'and(port.manual_target or plan.automatic_outputs and plan.automatic_outputs[port.id])then
        for cell,reservation in pairs(g.reserved)do if reservation=='output-end/'..port.id then g.reserved[cell]=nil end end
      end
      while not R.advance(g,search,4096)do end;R.build(g,search)
      if old.tags then old.tags.afp_port=nil end
    elseif kind=='item'and oldd~=v.d then U.fail('manual-port-turn',U.name(port.key))end
    local e=g.occupied[G.cell(v.x,v.y)].entity;e.tags=e.tags or{}
    e.tags.afp_port={id=port.id,key=U.base_key(port.key),kind=port.kind,rate=port.rate,section=port.section or 1,index=port.index}
    e.tags.afp_port.balanced=port.balanced_export or nil
    local explicit=s.manual_ports and s.manual_ports[M.id(port)]~=nil
    if port.kind=='out'and plan.automatic_outputs and plan.automatic_outputs[port.id]then port.display_direction=(v.d+2)%4 end
    e.tags.afp_manual_port=explicit or nil;port.local_position={x=v.x,y=v.y};port.manual=explicit or nil
    g.minx=math.min(g.minx,v.x);g.miny=math.min(g.miny,v.y);g.maxx=math.max(g.maxx,v.x+1);g.maxy=math.max(g.maxy,v.y+1)
    for _,display in ipairs(plan.input_displays or{})do if display.port==port.id then
      local panel=g.entities[display.entity]
      for _,side in ipairs({1,3})do local face=(v.d+side)%4;local x,y=v.x+G.dx[face+1],v.y+G.dy[face+1]
        if math.floor(panel.position.x)==x and math.floor(panel.position.y)==y then break end
        if g:free(x,y)then
          local oldcell=G.cell(math.floor(panel.position.x),math.floor(panel.position.y));local marker=g.occupied[oldcell]
          g.occupied[oldcell]=nil;panel.position={x=x+.5,y=y+.5};g.occupied[G.cell(x,y)]=marker
          g.minx=math.min(g.minx,x);g.miny=math.min(g.miny,y);g.maxx=math.max(g.maxx,x+1);g.maxy=math.max(g.maxy,y+1);break
        end
      end
    end end
    local x,y=U.rotate(v.x+.5,mirror and-v.y-.5 or v.y+.5,turns);port.position={x=x,y=y}
    for _,pin in ipairs(plan.project_inputs or{})do if port.kind=='in'and pin.id==Inputs.id(port)then
      pin.position=U.copy(v.pin.position);pin.direction=v.pin.entity_direction or v.pin.direction;pin.heading=v.pin.direction;pin.name=e.name
    end end
    for _,interface in ipairs(plan.bus_hierarchy and plan.bus_hierarchy.interfaces or{})do if interface.port==port.id then interface.position=U.copy(port.local_position)end end
  end
  if plan.manual_keys then
    -- The production-front clamp kept outside approaches out of the paving
    -- rectangle. Include their complete routes in coverage and placement.
    for _,e in ipairs(g.entities)do local proto=prototypes.entity[e.name];local w,h=proto.tile_width,proto.tile_height
      if (e.direction or 0)%8==4 then w,h=h,w end
      g.minx=math.min(g.minx,e.position.x-w/2);g.maxx=math.max(g.maxx,e.position.x+w/2)
      g.miny=math.min(g.miny,e.position.y-h/2);g.maxy=math.max(g.maxy,e.position.y+h/2)
    end
  end
  g.plot_front=front;g.plot_front_body=body
  if work then work.search=nil end
  return #requests>0
end
return M
