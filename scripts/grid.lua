local Util = require('scripts.util')

local Grid = {}

function Grid.prototype(catalogue, settings)
  local selected_roboport = settings.infrastructure and settings.infrastructure.roboport or settings.grid_anchor and settings.grid_anchor.name
  local function valid(p)return p and p.type=='roboport'and p.construction_radius>0 and p.logistic_radius>0 and not p.burner_prototype end
  -- Geometry is independent of research. Building the port is checked
  -- separately; researching robotics must not change the factory's grid.
  local p=prototypes.entity[selected_roboport or 'roboport']
  if valid(p)then return p end
  if selected_roboport then Util.fail('infrastructure',selected_roboport)end
  local names={};for name,prototype in pairs(prototypes.entity)do if valid(prototype)then names[#names+1]=name end end
  table.sort(names);if names[1]then return prototypes.entity[names[1]]end
  Util.fail('missing-infrastructure','roboport')
end

function Grid.available(catalogue,settings)
  local p=Grid.prototype(catalogue,settings)
  return catalogue.infra and catalogue.infra.roboport and catalogue.infra.roboport[p.name]~=nil or false
end

function Grid.width(settings)
  local name=settings.infrastructure and settings.infrastructure.roboport or settings.grid_anchor and settings.grid_anchor.name or 'roboport'
  local p=prototypes.entity[name]
  return p and p.type=='roboport'and math.floor(p.logistic_radius*2)or nil
end

function Grid.origin(settings)
  local anchor=settings.grid_anchor
  if anchor and settings._project and anchor.surface~=settings._project.surface then Util.fail('grid-anchor-surface')end
  return anchor and anchor.position or {x=0,y=0}
end

function Grid.reference(settings)
  local anchor=settings.grid_anchor
  local surface=anchor and game.surfaces[anchor.surface]
  local entity=surface and surface.find_entity(anchor.name,anchor.position)
  if entity and entity.valid and entity.type=='roboport'and entity.unit_number==anchor.unit_number then return entity end
end

function Grid.phase(settings,plan,turns,mirror)
  local origin=Grid.origin(settings)
  local offset=plan.project_offset or settings._project and settings._project.offset or{x=0,y=0}
  local x,y=Util.rotate(origin.x-offset.x,origin.y-offset.y,(4-turns)%4)
  return {x=x+0,y=(mirror and -y or y)+0}
end

function Grid.primary(catalogue,settings,plan,turns,mirror)
  local size=Grid.size(catalogue,settings);local grid=Grid.origin(settings)
  local controller=settings._project and settings._project.origin or settings.port_origin or{x=.5,y=.5}
  local ix=math.floor((controller.x-grid.x)/size);local iy=math.floor((controller.y-grid.y)/size)
  local world={x0=grid.x+ix*size,y0=grid.y+iy*size,x1=grid.x+(ix+1)*size,y1=grid.y+(iy+1)*size}
  local offset=plan.project_offset or{x=0,y=0};local bounds={x0=math.huge,y0=math.huge,x1=-math.huge,y1=-math.huge}
  for _,x in ipairs({world.x0,world.x1})do for _,y in ipairs({world.y0,world.y1})do
    local a,b=Util.rotate(x-offset.x,y-offset.y,(4-turns)%4);if mirror then b=-b end
    bounds.x0=math.min(bounds.x0,a);bounds.x1=math.max(bounds.x1,a);bounds.y0=math.min(bounds.y0,b);bounds.y1=math.max(bounds.y1,b)
  end end
  return{x=ix,y=iy,size=size,world_bounds=world,bounds=bounds,controller=Util.copy(controller)}
end

function Grid.controller_corner(catalogue,settings,primary)
  local b=primary.world_bounds;local origin=settings._project and settings._project.origin or primary.controller
  local surface=settings._project and game.surfaces[settings._project.surface]
  local inset=2.5;local best
  for _,x in ipairs({b.x0+inset,b.x1-inset})do for _,y in ipairs({b.y0+inset,b.y1-inset})do
    local same=math.abs(x-origin.x)<.01 and math.abs(y-origin.y)<.01
    if same or not surface or surface.can_place_entity{name='afp-controller',position={x=x,y=y},force=catalogue.force}then
      local distance=math.abs(x-origin.x)+math.abs(y-origin.y)
      if not best or distance<best.distance then best={x=x,y=y,distance=distance}end
    end
  end end
  if not best then Util.fail('controller-space')end
  return{x=best.x,y=best.y}
end

function Grid.bind(settings,entity)
  settings.grid_anchor={position=Util.copy(entity.position),surface=entity.surface.index,name=entity.name,unit_number=entity.unit_number}
  settings.infrastructure=settings.infrastructure or{};settings.infrastructure.roboport=entity.name
  settings.snap_grid=true;settings.roboports=true;settings.max_width=math.floor(entity.prototype.logistic_radius*2)
end

function Grid.size(catalogue, settings)
  local prototype = Grid.prototype(catalogue, settings)
  local size = math.max(1, math.floor(prototype.logistic_radius * 2))
  return size, prototype
end

function Grid.apply(stack, catalogue, settings, controller)
  if not controller then
    return
  end

  local size = Grid.size(catalogue, settings)
  stack.blueprint_snap_to_grid = {x = size, y = size}
  stack.blueprint_absolute_snapping = true
  local origin=Grid.origin(settings)
  stack.blueprint_position_relative_to_grid = {x = (origin.x+2)%size, y = (origin.y+2)%size}
end

function Grid.controller(player, catalogue, settings)
  if not player.clear_cursor() then
    Util.fail('cursor')
  end

  local inventory = game.create_inventory(1)
  local ok, err = pcall(function()
    local stack = inventory[1]
    stack.set_stack{name = 'blueprint'}
    stack.set_blueprint_entities{
      {entity_number = 1, name = 'afp-controller', position = {x = 0.5, y = 0.5}},
    }

    local grid_settings = Util.copy(settings)
    grid_settings.snap_grid = true
    Grid.apply(stack, catalogue, grid_settings, true)

    stack.label = 'AFP · Controller'
    player.cursor_stack.swap_stack(stack)
  end)

  -- The temporary inventory must also be released when blueprint setup fails.
  inventory.destroy()
  if not ok then
    error(err, 0)
  end
end

return Grid
