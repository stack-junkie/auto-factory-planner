local U=require('scripts.util')
local A=require('scripts.arrangement')
local Paving=require('scripts.paving')
local Mall=require('scripts.mall')
local Inputs=require('scripts.inputs')
local Reconcile=require('scripts.reconcile')
local Catalogue=require('scripts.catalogue')
local Model=require('scripts.model')
local Layout=require('scripts.layout')
local Grid=require('scripts.grid')
local P={}
local function init()
  storage.afp_projects=storage.afp_projects or {}
  for _,s in pairs(storage.afp or {}) do Mall.migrate(s) end
  for _,project in pairs(storage.afp_projects) do if project.stock_units~='stacks' then
    Mall.migrate(project.config);Mall.configure(project);project.stock_units='stacks'
  end end
end
function P.context(id)
  local project=storage.afp_projects and storage.afp_projects[id]
  if not project or not project.anchor.valid then U.fail('project-missing') end
  if not project.inputs then
    if project.revision>0 and project.config then
      local specs=project.specs or project.pending
      if not specs then
        local c=Catalogue.build(project.anchor.force);local s=P.configuration(project.config)
        -- Reconstruct historical layouts and accept only a complete
        -- positional match before recovering missing entrance metadata.
        for _,variant in ipairs({{frame=true},{belts=true},{v18=true},{dual=true},{groups=true},{branches=true},{intake=true},{straight=true},{cells=true},{rows=true},{bus=true},{orientation=true},{layout=true},{}}) do
          s._project=variant.frame and{id=id,origin=U.copy(project.anchor.position),surface=project.anchor.surface.index}or nil
          s._legacy_belts=variant.belts
          s._legacy_clearance=next(variant)~=nil and not variant.belts and not variant.frame;s._legacy_rate=s._legacy_clearance
          s._legacy_dual=variant.dual
          s._legacy_groups=variant.groups
          s._legacy_branches=variant.branches
          s._legacy_intake=variant.intake or variant.straight or variant.cells or variant.rows or variant.bus or variant.orientation or variant.layout
          s._legacy_straight=variant.straight or variant.cells or variant.rows or variant.bus or variant.orientation or variant.layout
          s._legacy_layout=variant.layout;s._legacy_orientation=variant.orientation
          s._legacy_bus=variant.bus or variant.orientation or variant.layout
          s._legacy_rows=variant.rows or s._legacy_bus
          s._legacy_cells=variant.cells or s._legacy_rows
          local ok,plan=pcall(function() return Layout.generate(c,s,Model.calculate(c,s)) end)
          if ok then
            local candidate=U.copy(plan.entities);local offset=plan.project_offset or Inputs.offset(project.anchor.position,s,plan.local_bounds,plan.orientation)
            for _,spec in ipairs(candidate) do spec.position.x=spec.position.x+offset.x;spec.position.y=spec.position.y+offset.y end
            local matches=true
            for slot,e in pairs(project.members) do if e.valid then
              local spec=candidate[slot]
              if not spec or spec.name~=(e.type=='entity-ghost' and e.ghost_name or e.name)
                or math.abs(spec.position.x-e.position.x)>0.01 or math.abs(spec.position.y-e.position.y)>0.01 then matches=false;break end
            end end
            if matches then
              specs=candidate;project.offset=offset;project.specs=U.copy(specs)
              project.orientation=U.copy(plan.orientation);project.mall_compact_axes=plan.mall_compact_axes;project.layout_revision=plan.layout_revision
              project.production_frame=plan.fixed_production==true
              break
            end
          end
        end
        if not specs then
          specs={}
          for slot,e in pairs(project.members) do if e.valid and e.type=='entity-ghost' and e.tags.afp_port then
            specs[#specs+1]={name=e.ghost_name,entity_number=slot,position=U.copy(e.position),direction=e.direction,tags={afp_port=e.tags.afp_port}}
          end end
          local found={};for _,spec in ipairs(specs) do local port=spec.tags.afp_port;if port.kind=='in' then found[Inputs.id(port)]=true end end
          local model=Model.calculate(c,s);Layout.prepare(c,s,model)
          for _,port in ipairs(model.ports) do if port.kind=='in' and not found[Inputs.id(port)] then U.fail('project-input-migration') end end
          if #specs==0 then U.fail('project-input-migration') end
        end
      end
      project.inputs={}
      for _,spec in ipairs(specs) do local port=spec.tags and spec.tags.afp_port
        if port and port.kind=='in' then project.inputs[#project.inputs+1]={id=Inputs.id(port),key=port.key,section=port.section or 1,
          index=port.index or #project.inputs+1,position=U.copy(spec.position),direction=spec.direction or 0,name=spec.name,active=not port.inactive} end
      end
      table.sort(project.inputs,function(a,b)return a.index<b.index end)
      local turns,mirror=A.orientation(project.config)
      if project.orientation then turns,mirror=project.orientation.turns,project.orientation.mirror end
      local x,y
      if project.mall_compact_axes then x,y=U.rotate(1,0,turns)else x,y=U.rotate(0,mirror and -1 or 1,turns)end
      project.input_axis={x=x,y=y}
      local heading=project.mall_compact_axes and 8 or 4;if mirror then heading=(8-heading)%16 end
      for _,pin in ipairs(project.inputs) do pin.heading=(heading+turns*4)%16 end
      if not project.offset then
        -- Older pending plans already carry world positions. Their original
        -- origin can be recovered from the old unmodified layout as well.
        local c=Catalogue.build(project.anchor.force);local s=P.configuration(project.config)
        s._legacy_orientation=not project.layout_revision or project.layout_revision<15
        s._legacy_bus=not project.layout_revision or project.layout_revision<16
        s._legacy_rows=not project.layout_revision or project.layout_revision<17
        s._legacy_cells=not project.layout_revision or project.layout_revision<18
        s._legacy_straight=not project.layout_revision or project.layout_revision<19
        s._legacy_intake=not project.layout_revision or project.layout_revision<20
        s._legacy_branches=not project.layout_revision or project.layout_revision<21
        s._legacy_dual=not project.layout_revision or project.layout_revision<23
        s._legacy_groups=not project.layout_revision or project.layout_revision<22
        s._legacy_clearance=not project.layout_revision or project.layout_revision<24;s._legacy_rate=s._legacy_clearance
        s._legacy_belts=project.layout_revision and(project.layout_revision<=32 or project.layout_revision==38)
        local plan=Layout.generate(c,s,Model.calculate(c,s));project.offset=Inputs.offset(project.anchor.position,s,plan.local_bounds,plan.orientation)
      end
    else project.inputs={} end
  end
  if not project.recipe_bus_order and project.revision>0 and project.config then
    local keys={}
    for _,spec in ipairs(project.specs or project.pending or{})do
      local kind=prototypes.entity[spec.name].type
      if kind=='transport-belt'or kind=='underground-belt'or kind=='splitter'then
        for key in (spec.tags and spec.tags.afp_stream or''):gmatch('[^|]+')do keys[key]=true end
      end
    end
    project.recipe_bus_order=U.sorted(keys)
  end
  local orientation=U.copy(project.orientation)
  if not orientation and project.config then local turns,mirror=A.orientation(project.config);orientation={turns=turns,mirror=mirror} end
  local roboports={};for _,spec in ipairs(project.specs or{})do if spec.tags and spec.tags.afp_roboport then roboports[#roboports+1]={name=spec.name,position=U.copy(spec.position)}end end
  local reset_inputs=project.status=='demolished'
  return {id=id,revision=project.revision,origin=U.copy(project.anchor.position),surface=project.anchor.surface.index,offset=U.copy(project.offset),roboports=roboports,
    plot_origin=U.copy(project.area and project.area.origin),
    mall_compact_axes=project.mall_compact_axes,
    production_start=project.production_start,
    production_frame=project.production_frame,
    primary_city_block=U.copy(project.primary_city_block),
    physical_inputs=reset_inputs and{}or U.copy(project.inputs),
    manual_ports=U.copy(project.config and project.config.manual_ports),
    factory_signature=project.factory_signature or(project.config and U.factory_signature(project.config)),
    layout_strategy=project.layout_strategy or(project.layout_revision and project.layout_revision>=24 and project.config.mode~='mall'and project.mall_compact_axes==false and'generic'or nil),
    inputs=reset_inputs and{}or U.copy(project.routing_inputs or project.inputs),input_axis=U.copy(project.input_axis),orientation=orientation,recipe_bus_order=U.copy(project.recipe_bus_order),layout_revision=project.layout_revision,intake_revision=project.intake_revision,intake_header_offset=project.intake_header_offset}
end
function P.default_width(name)
  local port=prototypes.entity[name or'roboport']
  if not port or port.type~='roboport' or port.construction_radius<=0 then
    local candidates={}
    for _,prototype in pairs(prototypes.entity) do if prototype.type=='roboport' and prototype.construction_radius>0 then candidates[#candidates+1]=prototype end end
    table.sort(candidates,function(a,b)return a.order==b.order and a.name<b.name or a.order<b.order end)
    port=candidates[1]
  end
  if port then return math.floor(port.logistic_radius*2),port end
end
local function valid(e) return e and e.valid end
local function identity(e)
  if e.type=='entity-ghost' then return 'g'..(e.ghost_unit_number or e.unit_number or tostring(e)) end
  return 'e'..(e.unit_number or tostring(e))
end
function P.configuration(s)
  Mall.migrate(s)
  local result={}
  for _,key in ipairs({'mode','target','rate','targets','decisions','direction','side','growth_direction','infrastructure','thresholds','max_width','input_rows','input_order','layout_search','paving','roboports','snap_grid','compression_weights','grid_anchor','manual_ports','port_origin','show_recycling','conversions','byproduct_exports'}) do result[key]=U.copy(s[key]) end
  for _,key in ipairs({'conversions','byproduct_exports'})do if result[key]and not next(result[key])then result[key]=nil end end
  return result
end
function P.get(anchor)
  if not valid(anchor) or anchor.name~='afp-controller' then U.fail('project-missing') end
  init();local id=anchor.unit_number
  local project=storage.afp_projects[id]
  if not project then
    project={id=id,anchor=anchor,revision=0,members={},retiring={},status='new',marks={}}
    storage.afp_projects[id]=project
  end
  anchor.rotatable=false
  return project
end
function P.copy_settings(source,destination,player_index)
  local player=game.get_player(player_index)
  if not player or not valid(source)or not valid(destination)or source.name~='afp-controller'or destination.name~='afp-controller'or source==destination then return end
  if source.force~=player.force or destination.force~=player.force then U.fail('project-force')end
  local from=P.get(source);local current=storage.afp and storage.afp[player_index]
  local settings=from.copied_settings or from.config
  if current and current.project_id==from.id and current.project_revision==from.revision
    and(current.project_settings_revision or 0)==(from.settings_revision or 0)then settings=current end
  if not settings or not settings.target and not(settings.mode=='mall'and settings.targets and #settings.targets>0)then return end
  local project=P.get(destination)
  -- Copy parameters only. The recipient retains its own factory, revision,
  -- input sockets and construction queue until the player applies a plan.
  project.copied_settings=P.configuration(U.copy(settings))
  if source.surface.index~=destination.surface.index then project.copied_settings.grid_anchor=nil end
  for _,pin in pairs(project.copied_settings.manual_ports or{})do
    pin.position.x=pin.position.x+destination.position.x-source.position.x
    pin.position.y=pin.position.y+destination.position.y-source.position.y
    pin.surface=destination.surface.index
  end
  if next(project.copied_settings.manual_ports or{})then project.copied_settings.port_origin=U.copy(destination.position)end
  project.settings_revision=(project.settings_revision or 0)+1
  return project
end
local function clear_marks(project)
  for _,mark in ipairs(project.marks or {}) do if mark.valid then mark.destroy() end end;project.marks={}
end
local function box(spec)
  local prototype=prototypes.entity[spec.name];local w,h=prototype.tile_width,prototype.tile_height
  if (spec.direction or 0)%8==4 then w,h=h,w end
  return {{spec.position.x-w/2,spec.position.y-h/2},{spec.position.x+w/2,spec.position.y+h/2}}
end
local function overlaps(a,b)
  local l,t=b.left_top.x,b.left_top.y;local r,d=b.right_bottom.x,b.right_bottom.y
  return a[1][1]<r-1e-6 and a[2][1]>l+1e-6 and a[1][2]<d-1e-6 and a[2][2]>t+1e-6
end
local function collides(a,b)
  local x,y=a.collision_mask.layers,b.collision_mask.layers
  for layer in pairs(x) do if y[layer] then return true end end
  return false
end
local function collision_box(spec)
  local bounds=prototypes.entity[spec.name].collision_box
  local x0,y0,x1,y1=math.huge,math.huge,-math.huge,-math.huge
  for _,x in ipairs({bounds.left_top.x,bounds.right_bottom.x})do
    for _,y in ipairs({bounds.left_top.y,bounds.right_bottom.y})do
      local a,b=U.rotate(x,y,(spec.direction or 0)/4)
      x0=math.min(x0,a);y0=math.min(y0,b);x1=math.max(x1,a);y1=math.max(y1,b)
    end
  end
  return {{spec.position.x+x0,spec.position.y+y0},{spec.position.x+x1,spec.position.y+y1}}
end
local function natural(e)
  return e.type=='tree'or e.type=='simple-entity'and e.prototype.count_as_rock_for_filtered_deconstruction
end
local function obstructs(e,spec)
  return collides(prototypes.entity[spec.name],e.prototype)and overlaps(collision_box(spec),e.bounding_box)
end
local function owned(project)
  local set={}
  for _,e in pairs(project.members) do if valid(e) and e.force==project.anchor.force then set[identity(e)]=true end end
  for _,e in ipairs(project.retiring) do if valid(e) and e.force==project.anchor.force then set[identity(e)]=true end end
  return set
end
local function plot_bounds(project,area)
  local p=project.anchor.position
  local a=area.origin or {x=p.x+area.rx*1.5-area.mx*0.5,y=p.y+area.ry*1.5-area.my*0.5}
  local b={x=a.x+area.rx*area.width+area.mx*area.length,y=a.y+area.ry*area.width+area.my*area.length}
  return {{math.min(a.x,b.x),math.min(a.y,b.y)},{math.max(a.x,b.x),math.max(a.y,b.y)}}
end
local function terrain(project,entities,ignore)
  local result={};local seen={}
  for _,spec in ipairs(entities)do
    for _,e in ipairs(project.anchor.surface.find_entities_filtered{area=collision_box(spec),type={'tree','simple-entity'}})do
      if e.minable and natural(e)and not seen[identity(e)]and obstructs(e,spec)then
        result[#result+1]=e;seen[identity(e)]=true;ignore[identity(e)]=true
      end
    end
  end
  return result
end
local function release_terrain(project,entities)
  local remaining={}
  for _,e in ipairs(project.retiring or{})do if valid(e)then
    local needed=not natural(e)
    if not needed then for _,spec in ipairs(entities)do if obstructs(e,spec)then needed=true;break end end end
    if needed then remaining[#remaining+1]=e
    else e.cancel_deconstruction(project.anchor.force)end
  end end
  project.retiring=remaining
end
local function order_terrain(project,entities,player_index)
  for _,e in ipairs(entities)do if valid(e)and not e.order_deconstruction(project.anchor.force,player_index)
    and not e.to_be_deconstructed(project.anchor.force)then return false,e end end
  return true
end
local function conflicts(project,entities,ignore)
  local surface,force=project.anchor.surface,project.anchor.force;local found={}
  for _,spec in ipairs(entities) do
    local area=collision_box(spec);local prototype=prototypes.entity[spec.name];local blocked=false
    for _,other in ipairs(surface.find_entities_filtered{area=area}) do
      if valid(other) and other.type~='character' and other.type~='item-entity' and not ignore[identity(other)] then
        local op=other.type=='entity-ghost' and other.ghost_prototype or other.prototype
        if collides(prototype,op) and overlaps(area,other.bounding_box) then blocked=true;break end
      end
    end
    if not blocked and not surface.can_place_entity{name=spec.name,position=spec.position,direction=spec.direction,force=force} then
      for x=math.floor(area[1][1]+1e-6),math.ceil(area[2][1]-1e-6)-1 do
        for y=math.floor(area[1][2]+1e-6),math.ceil(area[2][2]-1e-6)-1 do
          local tile=surface.get_tile(x,y)
          for layer in pairs(prototype.collision_mask.layers) do if tile.collides_with(layer) then blocked=true end end
        end
      end
    end
    if blocked then found[#found+1]=area;if #found>=32 then break end end
  end
  return found
end
local function mark_conflicts(project,areas)
  clear_marks(project)
  for _,area in ipairs(areas) do project.marks[#project.marks+1]=rendering.draw_rectangle{
    surface=project.anchor.surface,left_top=area[1],right_bottom=area[2],color={r=1,g=0.2,b=0.15},width=3,filled=false} end
end
function P.built(event)
  local e=event.entity;if not valid(e) then return end
  if e.name=='afp-controller' then P.get(e);return end
  local tags=event.tags or (e.type=='entity-ghost' and e.tags) or {};local token=tags.afp_project
  local project=token and storage.afp_projects and storage.afp_projects[token.id]
  if project and project.revision==token.revision then
    local spec=project.specs and project.specs[token.slot]
    if spec and (e.surface~=project.anchor.surface or e.force~=project.anchor.force
      or math.abs(e.position.x-spec.position.x)>0.01 or math.abs(e.position.y-spec.position.y)>0.01
      or (e.type=='entity-ghost' and e.ghost_name or e.name)~=spec.name) then return end
    project.members[token.slot]=e
    for _,buffer in ipairs(project.buffers or {}) do if token.slot==buffer.chest or token.slot==buffer.inserter then Mall.configure(project);break end end
  end
end
function P.removed(event)
  local e=event.entity;if not valid(e) then return end
  local project=storage.afp_projects and storage.afp_projects[e.unit_number]
  if project and project.anchor==e then
    project.status='orphaned';project.pending=nil;project.pending_tiles=nil;clear_marks(project)
    for _,buffer in ipairs(project.buffers or {}) do
      local arm=project.members[buffer.inserter];if valid(arm) and arm.type~='entity-ghost' then arm.disabled_by_script=false end
    end
  end
end
local function placement(project,s,plan,revision)
  local bounds=plan.local_bounds;if not bounds then U.fail('stale-plan') end
  local width,height=bounds.x1-bounds.x0,bounds.y1-bounds.y0
  if plan.width_axis=='y' then width,height=height,width end
  local factory=plan.production_bounds or bounds
  local factory_width=plan.width_axis=='y'and factory.y1-factory.y0 or factory.x1-factory.x0
  if s.max_width and factory_width+(plan.clearance or 0)*2>s.max_width then U.fail('width',factory_width+(plan.clearance or 0)*2,s.max_width) end
  local turns,mirror=A.orientation(s)
  if plan.orientation then turns,mirror=plan.orientation.turns,plan.orientation.mirror end
  local rx,ry=U.rotate(1,0,turns);local mx,my=U.rotate(0,mirror and -1 or 1,turns)
  local origin=project.anchor.position;local entities=U.copy(plan.entities)
  local offset=plan.project_offset or project.offset or Inputs.offset(origin,s,bounds,plan.orientation)
  local chunks={}
  for _,e in ipairs(entities) do
    e.position={x=offset.x+e.position.x,y=offset.y+e.position.y}
    e.tags=e.tags or {};e.tags.afp_project={id=project.id,revision=revision,slot=e.entity_number}
    local key=math.floor(e.position.x/32)..'/'..math.floor(e.position.y/32)
    if not chunks[key] then chunks[key]=true;project.anchor.surface.request_to_generate_chunks(e.position,0) end
  end
  local tiles=U.copy(plan.tiles or {})
  for _,tile in ipairs(tiles) do
    tile.position={x=math.floor(offset.x+tile.position.x),y=math.floor(offset.y+tile.position.y)}
    local key=math.floor(tile.position.x/32)..'/'..math.floor(tile.position.y/32)
    if not chunks[key] then chunks[key]=true;project.anchor.surface.request_to_generate_chunks(tile.position,0) end
  end
  project.anchor.surface.force_generate_chunk_requests()
  local corner={x=offset.x+rx*bounds.x0+mx*bounds.y0,y=offset.y+ry*bounds.x0+my*bounds.y0}
  if plan.width_axis=='y' then rx,ry,mx,my=mx,my,rx,ry end
  return entities,{width=width,length=height,limit=s.max_width or width,rx=rx,ry=ry,mx=mx,my=my,origin=corner},tiles
end
local function draw_boundary(project)
  local area=project.area;if not area then return end
  local bounds=plot_bounds(project,area)
  project.marks[#project.marks+1]=rendering.draw_rectangle{surface=project.anchor.surface,
    left_top=bounds[1],right_bottom=bounds[2],
    color={r=0.3,g=0.85,b=0.45},width=1,filled=false}
end
function P.preview(id,s,plan)
  local project=storage.afp_projects[id]
  return placement(project,s,plan,project.revision+1)
end
local function build(project)
  local ignored={};for _,e in pairs(project.members) do if valid(e) then ignored[identity(e)]=true end end
  local clearing=terrain(project,project.pending,ignored)
  local areas=conflicts(project,project.pending,ignored)
  for _,area in ipairs(Paving.conflicts(project,project.pending_tiles)) do areas[#areas+1]=area end
  if #areas>0 then project.status='blocked';mark_conflicts(project,areas);return false end
  if #clearing>0 then
    local ok,failed=order_terrain(project,clearing)
    if not ok then project.status='blocked';project.error={'afp-error.project-deconstruction',failed.localised_name};mark_conflicts(project,{box{name=failed.name,position=failed.position,direction=failed.direction}});return false end
    project.retiring=clearing;project.status='deconstructing';return false
  end
  local inventory=game.create_inventory(1);local stack=inventory[1];stack.set_stack{name='blueprint'}
  stack.set_blueprint_entities(project.pending)
  local minx,miny,maxx,maxy=math.huge,math.huge,-math.huge,-math.huge
  for _,spec in ipairs(project.pending) do local bounds=box(spec)
    minx=math.min(minx,bounds[1][1]);miny=math.min(miny,bounds[1][2]);maxx=math.max(maxx,bounds[2][1]);maxy=math.max(maxy,bounds[2][2])
  end
  local offset={x=math.floor((minx+maxx)/2),y=math.floor((miny+maxy)/2)}
  local kept={};for slot,e in pairs(project.members) do if valid(e) then kept[slot]=e end end
  local existing={};for _,e in pairs(kept) do existing[identity(e)]=true end
  local ok,result=pcall(function() return stack.build_blueprint{surface=project.anchor.surface,force=project.anchor.force,position=offset,
    build_mode=defines.build_mode.normal,skip_fog_of_war=false,raise_built=true} end)
  inventory.destroy()
  if not ok then project.error=tostring(result);project.status='blocked';return false end
  for _,e in ipairs(result) do
    if valid(e) and e.type=='entity-ghost' then local tag=e.tags.afp_project
      if tag and tag.id==project.id and tag.revision==project.revision then project.members[tag.slot]=e end
    end
  end
  for _,spec in ipairs(project.pending) do local e=project.members[spec.entity_number]
    if not valid(e) or (e.type=='entity-ghost' and e.ghost_name or e.name)~=spec.name
      or math.abs(e.position.x-spec.position.x)>0.01 or math.abs(e.position.y-spec.position.y)>0.01 then
      for _,ghost in pairs(project.members) do if valid(ghost) and ghost.type=='entity-ghost' and not existing[identity(ghost)] then ghost.destroy() end end
      project.members=kept;project.status='blocked';project.error='incomplete-blueprint';return false
    end
  end
  Mall.configure(project);Paving.build(project,project.pending_tiles)
  project.pending=nil;project.pending_tiles=nil
  local ghosts=false
  for _,e in pairs(project.members) do if valid(e) and e.type=='entity-ghost' then ghosts=true;break end end
  if not ghosts then for _,record in pairs(project.paving_tiles or {}) do if valid(record.ghost) then ghosts=true;break end end end
  project.status=ghosts and 'building' or 'ready';project.error=nil;clear_marks(project);draw_boundary(project)
  return true
end
function P.apply(id,s,plan,player_index,expected_revision)
  init();local project=storage.afp_projects[id]
  if not project or not valid(project.anchor) then U.fail('project-missing') end
  if player_index and game.get_player(player_index).force~=project.anchor.force then U.fail('project-force') end
  if expected_revision and expected_revision~=project.revision then U.fail('project-revision') end
  local controller=plan.controller_position;local move_controller=controller and
    (math.abs(controller.x-project.anchor.position.x)>.01 or math.abs(controller.y-project.anchor.position.y)>.01)
  if move_controller and not project.anchor.surface.can_place_entity{name='afp-controller',position=controller,force=project.anchor.force}then U.fail('controller-space')end
  local revision=project.revision+1;local entities,area,tiles=placement(project,s,plan,revision)
  local ignored=owned(project);local clearing=terrain(project,entities,ignored)
  if move_controller then ignored[identity(project.anchor)]=true end
  local areas=conflicts(project,entities,ignored)
  for _,conflict in ipairs(Paving.conflicts(project,tiles)) do areas[#areas+1]=conflict end
  if #areas>0 then mark_conflicts(project,areas);U.fail('project-conflict',#areas) end
  -- Native blueprint capture omits entities marked for deconstruction. If a
  -- newer revision wants that location again, inspect it after cancelling its
  -- old order; a changed object is re-queued below, a matching one is retained.
  local wanted={};for _,spec in ipairs(entities) do wanted[Reconcile.key(spec)]=true end
  local cancelled={};local seen={}
  for _,list in ipairs({project.members,project.retiring}) do for _,e in pairs(list) do
    if valid(e) and e.type~='entity-ghost' and e.type~='deconstructible-tile-proxy' and e.force==project.anchor.force
      and not seen[identity(e)] and wanted[Reconcile.key{name=e.name,position=e.position}] and e.to_be_deconstructed(project.anchor.force) then
      e.cancel_deconstruction(project.anchor.force);cancelled[#cancelled+1]=e;seen[identity(e)]=true
    end
  end end
  local ok,keep,replace,records=pcall(Reconcile.partition,project,entities,Grid.reference(s))
  if not ok then for _,e in ipairs(cancelled) do if valid(e) then e.order_deconstruction(project.anchor.force,player_index) end end;error(keep,0) end
  if move_controller and not project.anchor.teleport(controller)then U.fail('controller-space')end
  release_terrain(project,entities)
  Reconcile.remove_old_wires(project,entities,keep)
  local retiring={};local kept_count=0;local retiring_specs={}
  for _,e in pairs(keep) do
    kept_count=kept_count+1
    if e.to_be_deconstructed(project.anchor.force) then e.cancel_deconstruction(project.anchor.force) end
  end
  for _,e in ipairs(replace) do if valid(e) and e.force==project.anchor.force then
    if e.type=='entity-ghost' then e.destroy()
    else
      retiring_specs[Reconcile.identity(e)]=U.copy(records[Reconcile.identity(e)])
      if not e.order_deconstruction(project.anchor.force,player_index) and not e.to_be_deconstructed(project.anchor.force) then U.fail('project-deconstruction',e.localised_name) end
      retiring[#retiring+1]=e
    end
  end end
  for _,e in ipairs(Paving.retire(project,player_index,tiles)) do retiring[#retiring+1]=e end
  local cleared,failed=order_terrain(project,clearing,player_index)
  if not cleared then U.fail('project-deconstruction',failed.localised_name)end
  for _,e in ipairs(clearing)do retiring[#retiring+1]=e end
  project.members=keep;project.retiring=retiring;project.revision=revision;project.config=P.configuration(s);project.demolishing=nil
  project.copied_settings=nil
  project.factory_signature=plan.factory_signature;project.layout_strategy=plan.layout_strategy
  project.retiring_specs=retiring_specs
  project.specs=U.copy(entities);project.offset=U.copy(plan.project_offset or project.offset or Inputs.offset(project.anchor.position,s,plan.local_bounds,plan.orientation))
  project.orientation=U.copy(plan.orientation);project.layout_revision=plan.layout_revision;project.mall_compact_axes=plan.mall_compact_axes
  project.production_start=plan.production_start
  project.production_frame=plan.fixed_production==true
  project.primary_city_block=U.copy(plan.primary_city_block)
  project.inputs=U.copy(plan.project_inputs or project.inputs or {});project.input_axis=U.copy(plan.project_input_axis or project.input_axis)
  project.routing_inputs=U.copy(plan.routing_inputs)
  project.recipe_bus_order=U.copy(plan.recipe_bus_order or project.recipe_bus_order)
  project.intake_revision=plan.intake_revision or project.intake_revision
  project.intake_header_offset=plan.intake_header_offset or 0
  project.changes={kept=kept_count,removed=#replace,added=#entities-kept_count}
  project.pending=entities;project.pending_tiles=tiles;project.area=area;project.buffers=U.copy(plan.mall_buffers or {});project.status='deconstructing';project.error=nil
  Reconcile.retag(project,entities);Mall.configure(project)
  clear_marks(project);draw_boundary(project)
  if #retiring==0 then build(project) end
  return project
end
function P.can_demolish(project)
  if not project or not valid(project.anchor)or project.demolishing then return false end
  if project.pending then return true end
  for _,list in ipairs({project.members or{},project.retiring or{}})do for _,e in pairs(list)do
    if valid(e)and e~=project.anchor and e.force==project.anchor.force then return true end
  end end
  for _,record in pairs(project.paving_tiles or{})do if record.built or valid(record.ghost)then return true end end
  return false
end
function P.demolish(id,player_index,expected_revision)
  init();local project=storage.afp_projects[id]
  if not project or not valid(project.anchor)then U.fail('project-missing')end
  if player_index and game.get_player(player_index).force~=project.anchor.force then U.fail('project-force')end
  if expected_revision and expected_revision~=project.revision then U.fail('project-revision')end
  if not P.can_demolish(project)then return project end
  local objects,seen,records={},{},U.copy(project.retiring_specs or{})
  for slot,e in pairs(project.members)do if valid(e)then records[Reconcile.identity(e)]=U.copy(project.specs and project.specs[slot])end end
  for _,list in ipairs({project.members,project.retiring})do for _,e in pairs(list)do
    if valid(e)and e~=project.anchor and e.force==project.anchor.force and e.type~='deconstructible-tile-proxy'
      and e.type~='tree'and not(e.type=='simple-entity'and e.prototype.count_as_rock_for_filtered_deconstruction)and not seen[identity(e)]then
      if e.type~='entity-ghost'and not e.minable then U.fail('project-deconstruction',e.localised_name)end
      objects[#objects+1]=e;seen[identity(e)]=true
    end
  end end
  local retiring={}
  for _,e in ipairs(objects)do if e.type~='entity-ghost'then
    if not e.order_deconstruction(project.anchor.force,player_index)and not e.to_be_deconstructed()then U.fail('project-deconstruction',e.localised_name)end
    retiring[#retiring+1]=e
  end end
  for _,e in ipairs(Paving.retire(project,player_index,{}))do retiring[#retiring+1]=e end
  for _,e in ipairs(objects)do if valid(e)and e.type=='entity-ghost'then e.destroy()end end
  project.members={};project.retiring=retiring;project.retiring_specs=records;project.revision=project.revision+1
  project.pending=nil;project.pending_tiles=nil;project.buffers={};project.error=nil
  project.demolishing=#retiring>0 or nil;project.status=project.demolishing and'demolishing'or'demolished'
  project.changes={kept=0,removed=#objects,added=0}
  clear_marks(project);draw_boundary(project)
  return project
end
function P.init()
  init()
  for _,project in pairs(storage.afp_projects)do
    if valid(project.anchor)and project.pending then release_terrain(project,project.pending)end
  end
end
function P.tick(event)
  for _,project in pairs(storage.afp_projects or {}) do if valid(project.anchor) then
    if project.pending and event.tick%60==0 then
      local remaining={};for _,e in ipairs(project.retiring) do if valid(e) then remaining[#remaining+1]=e end end;project.retiring=remaining
      if #remaining==0 then build(project) end
    end
    if event.tick%60==0 then
      Paving.observe(project)
      if project.demolishing then
        local remaining={};for _,e in ipairs(project.retiring)do if valid(e)then remaining[#remaining+1]=e end end
        project.retiring=remaining
        if #remaining==0 then project.demolishing=nil;project.status='demolished' end
      end
      local ghosts=0
      for _,e in pairs(project.members) do if valid(e) and e.type=='entity-ghost' then ghosts=ghosts+1 end end
      for _,record in pairs(project.paving_tiles or {}) do if valid(record.ghost) then ghosts=ghosts+1 end end
      if not project.pending and not project.demolishing and project.status~='new'and project.status~='demolished'then project.status=ghosts>0 and 'building' or 'ready' end
    end
  end end
end
return P
