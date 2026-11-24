local U=require('scripts.util')
local A=require('scripts.arrangement')
local G=require('scripts.geometry')
local Inputs={}
function Inputs.id(port) return U.base_key(port.key)..'/'..(port.section or 1) end
local function basis(s)
  local turns,mirror=A.orientation(s)
  local rx,ry=U.rotate(1,0,turns);local mx,my=U.rotate(0,mirror and -1 or 1,turns)
  return rx,ry,mx,my,turns,mirror
end
function Inputs.offset(origin,s,bounds,orientation)
  local rx,ry,mx,my=basis(s)
  if orientation then
    rx,ry=U.rotate(1,0,orientation.turns)
    mx,my=U.rotate(0,orientation.mirror and -1 or 1,orientation.turns)
  end
  return {x=origin.x+rx*(1.5-bounds.x0)+mx*(-0.5-bounds.y0),y=origin.y+ry*(1.5-bounds.x0)+my*(-0.5-bounds.y0)}
end
-- Called after the layout chooses its ordinary port locations, before it
-- reserves terminals. Persisted positions are world positions, so changing
-- recipe order, bounds, paving or orientation cannot renumber the entrance.
function Inputs.assign(s,plan)
  local context=s._project
  if plan.fixed_production then
    local pins=U.copy(context and(context.physical_inputs or context.inputs)or{});local by_id={};local maximum=0
    for _,pin in ipairs(pins)do by_id[pin.id]=pin;maximum=math.max(maximum,pin.index or 0);pin.active=false end
    local _,_,_,_,turns,mirror=basis(s)
    for _,port in ipairs(plan.ports)do if port.kind=='in'then
      local id=Inputs.id(port);local pin=by_id[id]
      if not pin then
        maximum=maximum+1
        pin={id=id,key=U.base_key(port.key),section=port.section or 1,index=maximum,position={
          x=plan.project_offset.x+port.position.x,y=plan.project_offset.y+port.position.y},direction=((mirror and 0 or 8)+turns*4)%16}
        pins[#pins+1]=pin;by_id[id]=pin
      end
      pin.active=true;port.index=pin.index
      -- Keep automatic intake slots when a resource is removed or appended.
      -- Their world connections are routed after the production body is placed.
      port.local_position.x=(plan.intake_header_offset or 0)+2*(pin.index-1)
      local x,y=U.rotate(port.local_position.x+.5,(mirror and-1 or 1)*(port.local_position.y+.5),turns)
      port.position={x=x,y=y}
    end end
    local x,y=U.rotate(1,0,turns)
    plan.project_inputs=pins;plan.project_input_axis={x=x,y=y}
    return
  end
  -- Establish the interior origin from an explicitly selected connection on
  -- the first build. Infrastructure must never determine that translation.
  if not plan.project_offset and not(context and context.offset)then
    for _,port in ipairs(plan.ports)do
      local pin=s.manual_ports and s.manual_ports[port.kind..'/'..Inputs.id(port)]
      if pin and port.position then
        local dx,dy=U.rotate(0,-1,(pin.direction or 0)/4)
        local sign=port.kind=='in'and 1 or -1
        plan.project_offset={x=pin.position.x-port.position.x+dx*6*sign,y=pin.position.y-port.position.y+dy*6*sign}
        break
      end
    end
  end
  if not context then return end
  local pins=U.copy(context.inputs or {});local by_id={};local maximum=0
  local rx,ry,mx,my,turns,mirror=basis(s)
  for _,pin in ipairs(pins) do by_id[pin.id]=pin;maximum=math.max(maximum,pin.index or 0);pin.active=false end
  if context.offset then
    local axis=context.input_axis or (s._mall_compact_axes and {x=rx,y=ry} or {x=mx,y=my});local last
    for _,pin in ipairs(pins) do
      local distance=pin.position.x*axis.x+pin.position.y*axis.y
      if not last or distance>last.distance then last={position=pin.position,distance=distance} end
    end
    for _,port in ipairs(plan.ports) do if port.kind=='in' then
      local id=Inputs.id(port);local pin=by_id[id]
      if not pin then
        local position
        if last then position={x=last.position.x+axis.x*2,y=last.position.y+axis.y*2}
        else
          local p=port.position
          position={x=context.offset.x+p.x,y=context.offset.y+p.y}
        end
        maximum=maximum+1
        local heading=s._mall_compact_axes and 8 or 4
        pin={id=id,key=U.base_key(port.key),section=port.section or 1,index=maximum,position=position,
          direction=(heading+turns*4)%16}
        if mirror then pin.direction=((8-heading)%16+turns*4)%16 end
        pins[#pins+1]=pin;by_id[id]=pin;last={position=position,distance=position.x*axis.x+position.y*axis.y}
      end
      pin.active=true
    end end
    local offset=U.copy(context.offset)
    if context.orientation and (context.orientation.turns~=turns or context.orientation.mirror~=mirror) and #pins>0 then
      local bx,by,ax,ay=rx,ry,mx,my
      if s._mall_compact_axes then bx,by,ax,ay=mx,my,rx,ry end
      local front,along=-math.huge,math.huge
      for _,pin in ipairs(pins) do
        front=math.max(front,pin.position.x*bx+pin.position.y*by)
        along=math.min(along,pin.position.x*ax+pin.position.y*ay)
      end
      -- A rotated factory gets a new interior origin. The entrance itself
      -- stays in world space, with a routing bay clear of production rows.
      offset={x=bx*(front+11.5)+ax*(along-0.5),y=by*(front+11.5)+ay*(along-0.5)}
    end
    for _,port in ipairs(plan.ports) do if port.kind=='in' then
      local pin=by_id[Inputs.id(port)]
      local x,y=pin.position.x-offset.x,pin.position.y-offset.y
      local position={x=math.floor(x*rx+y*ry+1e-6),y=math.floor(x*mx+y*my+1e-6)}
      if position.x~=port.local_position.x or position.y~=port.local_position.y then port.staging_position=nil end
      port.local_position=position
      port.position={x=x,y=y};port.index=pin.index
      local d=(pin.direction-turns*4)%16;if mirror then d=(8-d)%16 end
      port.pinned_direction=d/4
      if U.split(port.key)=='fluid'and pin.heading then local heading=(pin.heading-turns*4)%16;if mirror then heading=(8-heading)%16 end;port.display_direction=heading/4;port.pinned_direction=heading/4 end
    end end
    plan.project_offset=offset
  end
  plan.project_inputs=pins
  plan.project_input_axis=U.copy(context.input_axis or (s._mall_compact_axes and {x=rx,y=ry} or {x=mx,y=my}))
end
function Inputs.protect(g,s,plan)
  if plan.fixed_production then
    for _,port in ipairs(plan.ports)do if port.kind=='in'then
      local p=port.local_position;local d=port.pinned_direction or 2
      for n=1,3 do local x,y=p.x-G.dx[d+1]*n,p.y-G.dy[d+1]*n
        if not g.reserved[G.cell(x,y)]then g:reserve(x,y,'external/'..Inputs.id(port))end
      end
    end end
    return
  end
  local context=s._project
  if not context or not context.offset then
    if s._legacy_layout or s._legacy_rate then return end
    -- Reserve the outside approaches on the first generation as well. After
    -- placement these same cells are protected by the persisted input pins;
    -- introducing that clearance only on update would move relay poles.
    for _,port in ipairs(plan.ports)do if port.kind=='in'or plan.rate_search then
      local p=port.local_position;local d=port.display_direction or port.pinned_direction or(s._mall_compact_axes and 2 or 1)
      for n=1,3 do local x,y=p.x-G.dx[d+1]*n,p.y-G.dy[d+1]*n
        if not g.reserved[G.cell(x,y)]then g:reserve(x,y,'external/'..Inputs.id(port))end
      end
    end end
    return
  end
  local rx,ry,mx,my,turns,mirror=basis(s)
  local offset=plan.project_offset or context.offset
  for _,pin in ipairs(plan.project_inputs or {}) do
    local selected=s.manual_ports and s.manual_ports['in/'..pin.id]
    local position=selected and selected.position or pin.position
    local x,y=position.x-offset.x,position.y-offset.y
    x,y=math.floor(x*rx+y*ry+1e-6),math.floor(x*mx+y*my+1e-6)
    local heading=selected and selected.direction or pin.heading or (U.split(pin.key)=='fluid' and (4+turns*4)%16 or pin.direction)
    local d=(heading-turns*4)%16;if mirror then d=(8-d)%16 end
    for n=1,3 do local px,py=x-G.dx[d/4+1]*n,y-G.dy[d/4+1]*n
      if not g.reserved[G.cell(px,py)] then g:reserve(px,py,'external/'..pin.id) end
    end
  end
  if plan.rate_search then for _,port in ipairs(plan.ports)do if port.kind=='out'then
    local d=s._mall_compact_axes and 2 or 1;local p=port.local_position
    for n=1,3 do local x,y=p.x-G.dx[d+1]*n,p.y-G.dy[d+1]*n
      if not g.reserved[G.cell(x,y)]then g:reserve(x,y,'external-output/'..port.id)end
    end
  end end end
end
function Inputs.inactive(g,s,plan)
  local context=s._project
  if not context or not context.offset then return end
  local rx,ry,mx,my,turns,mirror=basis(s)
  local offset=plan.project_offset or context.offset
  for _,pin in ipairs(plan.project_inputs or {}) do if not pin.active and pin.name then
    local x,y=pin.position.x-offset.x,pin.position.y-offset.y
    x,y=math.floor(x*rx+y*ry+1e-6),math.floor(x*mx+y*my+1e-6)
    local d=(pin.direction-turns*4)%16;if mirror then d=(8-d)%16 end
    g:tile(pin.name,x,y,d,{tags={afp_port={key=pin.key,kind='in',section=pin.section,index=pin.index,inactive=true}}},pin.key)
    local id='inactive/'..pin.id
    local fluid=U.split(pin.key)=='fluid' and pin.key or nil
    if fluid then
      for i=1,4 do local nx,ny=x+G.dx[i],y+G.dy[i]
        if not g.reserved[G.cell(nx,ny)] then g:reserve(nx,ny,id,fluid) end
      end
    else for n=1,2 do g:reserve(x+G.dx[d/4+1]*n,y+G.dy[d/4+1]*n,id) end end
  end end
end
function Inputs.finish(g,s,plan)
  local context=s._project;if not context then return end
  plan.project_offset=plan.project_offset or Inputs.offset(context.origin,s,plan.local_bounds)
  local pins=plan.project_inputs or {};local by_id={};local maximum=0
  for _,pin in ipairs(pins) do by_id[pin.id]=pin;maximum=math.max(maximum,pin.index or 0) end
  -- Geometry is still canonical here; the prototype and direction at the
  -- terminal are recorded after routing, including an explicitly chosen tier.
  local turns,mirror=A.orientation(s)
  for _,port in ipairs(plan.ports) do if port.kind=='in' then
    local id=Inputs.id(port);local pin=by_id[id];local marker=g.occupied[G.cell(port.local_position.x,port.local_position.y)]
    if not pin then
      maximum=maximum+1
      pin={id=id,key=U.base_key(port.key),section=port.section or 1,index=port.index or maximum};pins[#pins+1]=pin
    end
    local e=marker.entity;local x,y=e.position.x,e.position.y
    if mirror then y=-y end;x,y=U.rotate(x,y,turns)
    pin.position={x=plan.project_offset.x+x,y=plan.project_offset.y+y};pin.name=e.name;pin.active=true
    local d=e.direction or 0;if mirror then d=(8-d)%16 end;pin.direction=(d+turns*4)%16
    local heading=s._mall_compact_axes and 8 or 4;if mirror then heading=(8-heading)%16 end
    pin.heading=pin.heading or (heading+turns*4)%16
    e.tags.afp_port.index=pin.index
  end end
  plan.project_inputs=pins
end
return Inputs
