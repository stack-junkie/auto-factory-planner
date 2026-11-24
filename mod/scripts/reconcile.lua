local U=require('scripts.util')
local D={}
function D.identity(e)
  return e.type..'/'..tostring(e.type=='entity-ghost' and (e.ghost_unit_number or e.unit_number) or e.unit_number)..'/'..e.surface.index..'/'..D.key{name=e.type=='entity-ghost' and e.ghost_name or e.name,position=e.position}
end
function D.key(spec)
  return spec.name..'/'..string.format('%.4f/%.4f',spec.position.x,spec.position.y)
end
local function signature(spec)
  local copy=U.copy(spec)
  for _,key in ipairs({'entity_number','position','tags','wires','connections','neighbours'}) do copy[key]=nil end
  copy.direction=copy.direction or 0;copy.quality=copy.quality or 'normal'
  -- A stock edit changes a native inventory bar in place, preserving goods.
  local p=prototypes.entity[copy.name]
  if p.type=='container' or p.type=='logistic-container' then copy.bar=nil end
  return U.fingerprint(copy)
end
local function purpose(spec)
  local tags=spec and spec.tags or {}
  return tags.afp_stream or (tags.afp_mall and tags.afp_mall.key) or (tags.afp_port and U.base_key(tags.afp_port.key)),tags.afp_process
end
function D.partition(project,desired,protected_entity)
  local inventory=game.create_inventory(1);local stack=inventory[1];stack.set_stack{name='blueprint'}
  local ok,result=pcall(function()
    stack.set_blueprint_entities(desired,false)
    local normalized=stack.get_blueprint_entities() or {};local wanted={}
    for _,spec in ipairs(normalized) do local stream,process=purpose(spec)
      wanted[D.key(spec)]={slot=spec.entity_number,signature=signature(spec),stream=stream,process=process}
    end
    local minx,miny,maxx,maxy=math.huge,math.huge,-math.huge,-math.huge
    local candidates={};local count=0;local records={}
    for slot,e in pairs(project.members or {}) do if e.valid then
      records[D.identity(e)]=project.specs and project.specs[slot]
    end end
    for id,spec in pairs(project.retiring_specs or {}) do records[id]=records[id] or spec end
    for _,list in ipairs({project.members or {},project.retiring or {}}) do for _,e in pairs(list) do
      if e.valid and e~=protected_entity and e.type~='deconstructible-tile-proxy' and e.force==project.anchor.force and not candidates[D.identity(e)] then
        candidates[D.identity(e)]=e;count=count+1
        minx=math.min(minx,e.bounding_box.left_top.x);miny=math.min(miny,e.bounding_box.left_top.y)
        maxx=math.max(maxx,e.bounding_box.right_bottom.x);maxy=math.max(maxy,e.bounding_box.right_bottom.y)
      end
    end end
    local keep={}
    if count>0 then
      local mapping=stack.create_blueprint{surface=project.anchor.surface,force=project.anchor.force,
        area={{minx-0.01,miny-0.01},{maxx+0.01,maxy+0.01}},include_entities=true,include_modules=true}
      for _,spec in ipairs(stack.get_blueprint_entities() or {}) do local e=mapping[spec.entity_number]
        if e and candidates[D.identity(e)] then
          local key=D.key{name=spec.name,position=e.position};local target=wanted[key]
          local old=records[D.identity(e)] or (e.type=='entity-ghost' and {tags=e.tags})
          local stream,process=purpose(old)
          if target and signature(spec)==target.signature and (not target.stream or target.stream==stream)
            and (not target.process or target.process==process) then keep[target.slot]=e;candidates[D.identity(e)]=nil end
        end
      end
    end
    local retire={};for _,e in pairs(candidates) do retire[#retire+1]=e end
    return {keep=keep,retire=retire,records=records}
  end)
  inventory.destroy()
  if not ok then error(result,0) end
  return result.keep,result.retire,result.records
end
function D.retag(project,entities)
  for slot,e in pairs(project.members) do if e.valid and e.type=='entity-ghost' then
    local spec=entities[slot]
    if spec then e.tags=U.copy(spec.tags or {}) end
  end end
end
local function wire_key(a,ac,b,bc)
  local x=a..'/'..ac;local y=b..'/'..bc
  return x<y and x..'|'..y or y..'|'..x
end
-- Native blueprints add the new wires, including connections to kept real
-- entities. Remove only previously planned wires; player/foreign wiring stays.
function D.remove_old_wires(project,desired,keep)
  if not project.specs then return end
  local new={};local objects={}
  for _,spec in ipairs(desired) do objects[spec.entity_number]=D.key(spec) end
  for _,spec in ipairs(desired) do for _,wire in ipairs(spec.wires or {}) do
    new[wire_key(objects[wire[1]],wire[2],objects[wire[3]],wire[4])]=true
  end end
  local retained={};for _,e in pairs(keep) do retained[D.identity(e)]=true end
  for _,spec in ipairs(project.specs) do for _,wire in ipairs(spec.wires or {}) do
    local a,b=project.specs[wire[1]],project.specs[wire[3]]
    local ae,be=project.members[wire[1]],project.members[wire[3]]
    if a and b and ae and be and ae.valid and be.valid and retained[D.identity(ae)] and retained[D.identity(be)]
      and not new[wire_key(D.key(a),wire[2],D.key(b),wire[4])] then
      local ac=ae.get_wire_connector(wire[2],false);local bc=be.get_wire_connector(wire[4],false)
      if ac and bc then ac.disconnect_from(bc) end
    end
  end end
end
return D
