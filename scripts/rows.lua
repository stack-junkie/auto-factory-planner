local Util = require('scripts.util')
local Geometry = require('scripts.geometry')
local Pipes = require('scripts.pipes')

local Rows = {}

-- Ports use four directions (north = 0); blueprint entities use sixteen.
local NORTH, EAST, SOUTH, WEST = 0, 4, 8, 12
local RATE_EPSILON = 1e-6

local function pickup_distance(prototype)
  return math.floor(-prototype.inserter_pickup_position[2] + 0.5)
end

local function drop_distance(prototype)
  return math.floor(prototype.inserter_drop_position[2] + 0.5)
end

local function inserter_reach(prototype)
  return pickup_distance(prototype) + drop_distance(prototype)
end

local function place_inserter(grid, prototype, x, y, direction, key, is_output)
  if not is_output then
    return grid:tile(prototype.name, x, y, direction, {use_filters = false}, key)
  end

  local requirements = type(key) == 'table' and key or {{key = key}}
  local filters = {}
  for index, requirement in ipairs(requirements) do
    local _, name = Util.split(requirement.key)
    filters[index] = {index = index, name = name, quality = 'normal', comparator = '='}
  end

  local settings = {use_filters = false}
  if prototype.filter_count >= #filters then
    settings = {use_filters = true, filters = filters}
  end
  return grid:tile(prototype.name, x, y, direction, settings, key)
end

local function input_groups(options, inputs, chosen_inserters)
  local groups, used, present = {}, {}, {}
  for _, requirement in ipairs(inputs) do
    present[requirement] = true
  end

  for _, requirement in ipairs(inputs) do
    if not used[requirement] then
      local group = options.shared and options.shared[requirement]
        or {requirements = {requirement}, inserter = chosen_inserters[requirement]}

      -- A shared arm is usable only when its whole group belongs to this feed.
      for _, member in ipairs(group.requirements) do
        if not present[member] then
          group = {requirements = {requirement}, inserter = chosen_inserters[requirement]}
          break
        end
      end

      groups[#groups + 1] = group
      for _, member in ipairs(group.requirements) do
        used[member] = true
      end
    end
  end
  return groups
end

local function describe_groups(row, groups)
  row.input_groups = row.input_groups or {}
  for _, group in ipairs(groups) do
    local keys = {}
    for _, requirement in ipairs(group.requirements) do
      keys[#keys + 1] = requirement.key
    end
    row.input_groups[#row.input_groups + 1] = {keys = keys, inserter = group.inserter.name}
  end
end

local function reserve_port(grid, port, key, is_input)
  local fluid_key = Util.split(key) == 'fluid' and key or nil
  grid:reserve(port.x, port.y, port.id, fluid_key)

  local direction = is_input and ((port.d or 2) + 2) % 4 or port.d or 0
  for distance = 1, 2 do
    grid:reserve(
      port.x + Geometry.dx[direction + 1] * distance,
      port.y + Geometry.dy[direction + 1] * distance,
      port.id,
      fluid_key
    )
  end
end

local function record_event(options, stage, first_entity, recipe)
  options.events[#options.events + 1] = {
    stage = stage,
    first = first_entity,
    last = #options.g.entities,
    detail = recipe,
  }
end

-- A normal production row: two ingredients share the two lanes of
-- one input belt, and all machines unload onto the same return belt.
local function build_simple_row(options, node, prototype, chosen_inserters, inputs, output)
  local grid = options.g
  local width, height = prototype.tile_width, prototype.tile_height
  local input_reach = pickup_distance(chosen_inserters[inputs[1]]) + 1
  local output_reach = drop_distance(chosen_inserters[output]) + 1
  local machine_left = options.x + (options.compact and 0 or 3) + output_reach
  local feed_x = machine_left + width + input_reach - 1
  local output_x = machine_left - output_reach
  local head = options.compact and 2 or options.y + 3
  local machine_top = head + (options.compact and 1 or 3)
  local pitch = height + 1
  local count = options.count
  local bottom = machine_top + (count - 1) * pitch + height - 1
  local groups = input_groups(options, inputs, chosen_inserters)
  local row = {
    id = #options.plan.production_rows + 1,
    node = node.id,
    count = count,
    machines = {},
    input_inserters = {},
    output_inserters = {},
    packed = #inputs == 2,
  }
  describe_groups(row, groups)
  options.plan.production_rows[#options.plan.production_rows + 1] = row

  local first_entity = #grid.entities + 1
  for machine_index = 1, count do
    local y = machine_top + (machine_index - 1) * pitch
    local machine = grid:add(prototype.name, machine_left + width / 2, y + height / 2, NORTH, {
      recipe = node.recipe,
      recipe_quality = 'normal',
    })
    row.machines[#row.machines + 1] = machine.entity_number

    for group_index, group in ipairs(groups) do
      local offset = #groups == 1 and math.floor((height - 1) / 2)
        or math.floor((group_index - 1) * (height - 1) / (#groups - 1))
      local arm = place_inserter(grid, group.inserter, machine_left + width, y + offset, EAST, group.requirements)
      row.input_inserters[#row.input_inserters + 1] = arm.entity_number
    end

    local arm = place_inserter(
      grid, chosen_inserters[output], machine_left - 1, y + math.floor((height - 1) / 2), EAST, output.key, true
    )
    row.output_inserters[#row.output_inserters + 1] = arm.entity_number
  end
  record_event(options, 'machines', first_entity, options.recipe)

  first_entity = #grid.entities + 1
  local last_pickup_y = machine_top + (count - 1) * pitch + math.floor((height - 1) / 2)
  local feed_end = options.compact and #groups == 1 and last_pickup_y or bottom
  local output_end = options.compact and last_pickup_y or bottom
  for y = head, feed_end do
    grid:tile(options.belt.name, feed_x, y, SOUTH, nil, inputs)
  end
  for y = head, output_end do
    grid:tile(options.belt.name, output_x, y, NORTH, nil, output.key)
  end

  local source = {x = output_x, y = head - 1, d = 0, plain = true, id = 'row/' .. row.id .. '/out'}
  reserve_port(grid, source, output.key, false)
  options.connect(output.key, source, true, output.amount * options.crafts, output_x)

  if #inputs == 1 then
    local port = {x = feed_x, y = head - 1, d = 2, plain = true, id = 'row/' .. row.id .. '/in'}
    reserve_port(grid, port, inputs[1].key, true)
    options.connect(inputs[1].key, port, false, inputs[1].amount * options.crafts, feed_x)
  else
    -- An empty belt behind the merge keeps it straight even while one feed
    -- is empty. The two sideways feeds load opposite lanes without mixing.
    grid:tile(options.belt.name, feed_x, head - 1, SOUTH, nil, inputs)
    if options.compact then
      grid:tile(options.belt.name, feed_x - 1, head, EAST, nil, inputs[1].key)
    end

    for input_index, requirement in ipairs(inputs) do
      local side = input_index == 1 and (options.compact and -2 or -1) or 1
      local port = {
        x = feed_x + side,
        y = head,
        d = input_index == 1 and 1 or 3,
        plain = true,
        id = 'row/' .. row.id .. '/in/' .. input_index,
      }
      if options.compact then
        grid:reserve(port.x, port.y, port.id)
        for distance = 1, 2 do
          grid:reserve(port.x, port.y - distance, port.id)
        end
      else
        reserve_port(grid, port, requirement.key, true)
      end
      options.connect(requirement.key, port, false, requirement.amount * options.crafts, feed_x + side)
    end
  end

  row.pitch = pitch
  row.head = head
  row.foot = bottom
  record_event(options, 'branches', first_entity, options.recipe)
  return options.compact and feed_x + (#inputs == 2 and 1 or 0) + (options.gap or 3) or feed_x + 5
end

-- Choose a free arm position whose belt terminal is farthest from existing
-- terminals. Keep the first candidate on ties to preserve routing order.
local function choose_item_slot(grid, slots, terminals, offset, distance)
  local position, selected_slot, best_score
  for _, slot in ipairs(slots) do
    local dx, dy = Geometry.dx[slot.face + 1], Geometry.dy[slot.face + 1]
    local inserter_x, inserter_y = slot.x + dx * offset, slot.y + dy * offset
    local terminal_x, terminal_y = inserter_x + dx * distance, inserter_y + dy * distance

    if not slot.used and grid:free(inserter_x, inserter_y) and grid:free(terminal_x, terminal_y)
      and grid:free(terminal_x + dx, terminal_y + dy)
      and grid:free(terminal_x + 2 * dx, terminal_y + 2 * dy) then
      local score = math.huge
      for _, terminal in ipairs(terminals) do
        score = math.min(score, math.abs(terminal_x - terminal.x) + math.abs(terminal_y - terminal.y))
      end
      if not best_score or score > best_score then
        best_score = score
        selected_slot = slot
        position = {x = inserter_x, y = inserter_y, face = slot.face}
      end
    end
  end
  return position, selected_slot
end

local function build_generic_row(options, node, prototype, requirements, chosen_inserters)
  local grid = options.g
  local width, height = prototype.tile_width, prototype.tile_height
  local outputs, inputs = {}, {}
  for _, requirement in ipairs(requirements) do
    local list = requirement.input and inputs or outputs
    list[#list + 1] = requirement
  end

  local compact = options.fluid_compact
  local machine_left = compact and options.x + #outputs * 3 + options.reach + 2
    or options.x + 4 + #outputs * 4 + options.reach + 3
  local head = options.y + 3
  local pitch = compact and math.max(height + 2 * options.reach + 4, 2 * #requirements + 5)
    or height + 2 * options.reach + 2 * #requirements + 6
  local bottom = head + options.count * pitch - 1
  local rails = {}
  for index, requirement in ipairs(outputs) do
    rails[requirement] = {
      x = options.x + (compact and (index - 1) * 3 or 3 + (index - 1) * 4),
      input = false,
      req = requirement,
      taps = {},
    }
  end
  for index, requirement in ipairs(inputs) do
    rails[requirement] = {
      x = machine_left + width + options.reach + (compact and 1 + (index - 1) * 3 or 3 + (index - 1) * 4),
      input = true,
      req = requirement,
      taps = {},
    }
  end

  local row = {
    id = #options.plan.production_rows + 1,
    node = node.id,
    count = options.count,
    machines = {},
    input_inserters = {},
    output_inserters = {},
    packed = false,
    pitch = pitch,
    head = head,
    foot = bottom,
  }
  options.plan.production_rows[#options.plan.production_rows + 1] = row

  local first_entity = #grid.entities + 1
  for machine_index = 1, options.count do
    local cell_top = head + (machine_index - 1) * pitch
    local machine_top = cell_top + (compact and 2 * options.reach or 2 * #requirements + 4 + options.reach)
    local machine_x, machine_y = machine_left + width / 2, machine_top + height / 2
    local entity = grid:add(prototype.name, machine_x, machine_y, NORTH, {
      recipe = node.recipe,
      recipe_quality = 'normal',
    })
    row.machines[#row.machines + 1] = entity.entity_number

    local fluid_connections = options.ends(prototype, machine_x, machine_y, NORTH)
    local used_boxes, terminals, ports = {}, {}, {}
    for index, requirement in ipairs(requirements) do
      if Util.split(requirement.key) == 'fluid' then
        local connection
        for _, candidate in ipairs(fluid_connections) do
          if candidate.box == requirement.box and not used_boxes[candidate.box] then
            connection = candidate
            break
          end
        end
        if not connection then
          Util.fail('fluid-ports', prototype.localised_name)
        end
        used_boxes[connection.box] = true

        local port = {
          x = connection.x,
          y = connection.y,
          d = connection.face,
          id = 'row/' .. row.id .. '/' .. machine_index .. '/' .. index,
        }
        grid:reserve(port.x, port.y, port.id, requirement.key)
        for distance = 1, 2 do
          grid:reserve(
            port.x + Geometry.dx[port.d + 1] * distance,
            port.y + Geometry.dy[port.d + 1] * distance,
            port.id,
            requirement.key
          )
        end
        ports[requirement] = port
        terminals[#terminals + 1] = port
      end
    end

    local slots = {}
    for x = machine_left, machine_left + width - 1 do
      slots[#slots + 1] = {x = x, y = machine_top - 1, face = 0}
      slots[#slots + 1] = {x = x, y = machine_top + height, face = 2}
    end
    for y = machine_top, machine_top + height - 1 do
      slots[#slots + 1] = {x = machine_left - 1, y = y, face = 3}
      slots[#slots + 1] = {x = machine_left + width, y = y, face = 1}
    end

    for index, requirement in ipairs(requirements) do
      if Util.split(requirement.key) == 'item' then
        local inserter = chosen_inserters[requirement]
        local pickup, drop = pickup_distance(inserter), drop_distance(inserter)
        local offset = (requirement.input and drop or pickup) - 1
        local distance = requirement.input and pickup or drop
        local position, selected_slot = choose_item_slot(grid, slots, terminals, offset, distance)
        if not position then
          Util.fail('item-ports', prototype.localised_name)
        end
        selected_slot.used = true

        local direction = (requirement.input and position.face or (position.face + 2) % 4) * 4
        local arm = place_inserter(
          grid, inserter, position.x, position.y, direction, requirement.key, not requirement.input
        )
        local list = requirement.input and row.input_inserters or row.output_inserters
        list[#list + 1] = arm.entity_number

        local port = {
          x = position.x + Geometry.dx[position.face + 1] * distance,
          y = position.y + Geometry.dy[position.face + 1] * distance,
          d = requirement.input and (position.face + 2) % 4 or position.face,
          id = 'row/' .. row.id .. '/' .. machine_index .. '/' .. index,
          plain = true,
        }
        grid:reserve(port.x, port.y, port.id)
        local away = requirement.input and position.face or port.d
        for clearance = 1, 2 do
          grid:reserve(
            port.x + Geometry.dx[away + 1] * clearance,
            port.y + Geometry.dy[away + 1] * clearance,
            port.id
          )
        end
        ports[requirement] = port
        terminals[#terminals + 1] = port
      end
    end

    for index, requirement in ipairs(requirements) do
      local rail = rails[requirement]
      local port = ports[requirement]
      local is_fluid = Util.split(requirement.key) == 'fluid'
      local y = cell_top + 2 + index * 2
      rail.last = y

      local stub
      if is_fluid then
        stub = {x = rail.x, y = y}
        rail.taps[Geometry.cell(rail.x, y)] = true
      else
        stub = {
          x = rail.x + (requirement.input and -1 or 1),
          y = y + (requirement.input and 1 or 0),
          d = 3,
          plain = true,
          id = port.id,
        }
        rail.taps[y] = requirement.input and true or nil
        grid:reserve(stub.x, stub.y, port.id)
        for distance = 1, 2 do
          grid:reserve(stub.x + (requirement.input and -distance or distance), stub.y, port.id)
        end
        if requirement.input then
          grid:reserve(rail.x - 1, y - 1, 'unused/' .. port.id)
        end
      end

      options.local_routes[#options.local_routes + 1] = {
        key = requirement.key,
        from = is_fluid and port or requirement.input and stub or port,
        to = is_fluid and stub or requirement.input and port or stub,
        id = port.id,
        local_route = true,
      }
    end
  end
  record_event(options, 'machines', first_entity, options.recipe)

  first_entity = #grid.entities + 1
  for _, requirement in ipairs(requirements) do
    local rail = rails[requirement]
    local is_fluid = Util.split(requirement.key) == 'fluid'
    local rail_end = is_fluid and (compact and rail.last or bottom) or head + (options.count - 1) * pitch + 2
    if not is_fluid then
      for index, candidate in ipairs(requirements) do
        if candidate == requirement then
          rail_end = rail_end + 2 * index
          break
        end
      end
    end

    if is_fluid and compact then
      Pipes.line(grid, options.pipe, options.pipeug, rail.x, head, rail.x, rail_end, requirement.key, rail.taps)
    else
      for y = head, rail_end do
        if is_fluid then
          grid:tile(options.pipe.name, rail.x, y, NORTH, nil, requirement.key)
        elseif rail.taps[y] then
          grid:add(options.splitter.name, rail.x, y + 0.5, SOUTH, {output_priority = 'right'}, requirement.key)
        else
          grid:tile(options.belt.name, rail.x, y, requirement.input and SOUTH or NORTH, nil, requirement.key)
        end
      end
    end

    local port = {
      x = rail.x,
      y = head - 1,
      d = not is_fluid and (requirement.input and 2 or 0) or nil,
      plain = true,
      id = 'row/' .. row.id .. '/rail/' .. requirement.key .. '/' .. tostring(requirement.input),
    }
    reserve_port(grid, port, requirement.key, requirement.input)
    options.connect(requirement.key, port, not requirement.input, requirement.amount * options.crafts, rail.x)
  end
  record_event(options, 'branches', first_entity, options.recipe)
  return machine_left + width + options.reach + (compact and 3 + #inputs * 3 or 7 + #inputs * 4)
end

-- Two shared feeds supply up to four ingredients. The second feed branches
-- through the gaps between machines, crossing the first feed underground.
-- All inserters keep their ordinary reach; no extra technology is required.
local function build_dense_row(options, node, prototype, chosen_inserters, inputs, output)
  local grid = options.g
  local width, height = prototype.tile_width, prototype.tile_height
  local machine_left = options.x + inserter_reach(chosen_inserters[output])
  local output_x = options.x
  local feed_x = machine_left + width + 1
  local extra_feed_x = feed_x + (#inputs == 4 and 6 or 4)
  local head, machine_top, pitch = 2, 6, height + 2
  local bottom = machine_top + (options.count - 1) * pitch + height - 1
  local row = {
    id = #options.plan.production_rows + 1,
    node = node.id,
    count = options.count,
    machines = {},
    input_inserters = {},
    output_inserters = {},
    packed = true,
    compact = true,
    feed_belts = 2,
    pitch = pitch,
    head = head,
    foot = bottom,
  }
  options.plan.production_rows[#options.plan.production_rows + 1] = row

  local near_groups = input_groups(options, {inputs[1], inputs[2]}, chosen_inserters)
  local upper_inputs = {}
  for index = 3, #inputs do
    upper_inputs[#upper_inputs + 1] = inputs[index]
  end
  local upper_groups = input_groups(options, upper_inputs, chosen_inserters)
  describe_groups(row, near_groups)
  describe_groups(row, upper_groups)

  local first_entity = #grid.entities + 1
  for machine_index = 1, options.count do
    local y = machine_top + (machine_index - 1) * pitch
    local machine = grid:add(prototype.name, machine_left + width / 2, y + height / 2, NORTH, {
      recipe = node.recipe,
      recipe_quality = 'normal',
    })
    row.machines[#row.machines + 1] = machine.entity_number

    for group_index, group in ipairs(near_groups) do
      local offset = #near_groups == 1 and math.floor((height - 1) / 2) or (group_index - 1) * (height - 1)
      local arm = place_inserter(grid, group.inserter, machine_left + width, y + offset, EAST, group.requirements)
      row.input_inserters[#row.input_inserters + 1] = arm.entity_number
    end
    for group_index, group in ipairs(upper_groups) do
      local x = machine_left + (#upper_groups == 1 and math.floor((width - 1) / 2) or (group_index - 1) * (width - 1))
      local arm = place_inserter(grid, group.inserter, x, y - 1, NORTH, group.requirements)
      row.input_inserters[#row.input_inserters + 1] = arm.entity_number
    end

    local inserter = chosen_inserters[output]
    local arm = place_inserter(
      grid, inserter, machine_left - pickup_distance(inserter), y + math.floor((height - 1) / 2), EAST, output.key, true
    )
    row.output_inserters[#row.output_inserters + 1] = arm.entity_number
  end
  record_event(options, 'machines', first_entity, options.recipe)

  first_entity = #grid.entities + 1
  for y = head, bottom do
    grid:tile(options.belt.name, feed_x, y, SOUTH, nil, {inputs[1], inputs[2]})
  end
  for y = head, machine_top + (options.count - 1) * pitch + math.floor((height - 1) / 2) do
    grid:tile(options.belt.name, output_x, y, NORTH, nil, output.key)
  end

  local forks = {}
  for machine_index = 1, options.count - 1 do
    forks[machine_top + (machine_index - 1) * pitch - 3] = true
  end
  local tail = machine_top + (options.count - 1) * pitch - 2
  for y = head, tail do
    if forks[y] then
      grid:add(options.splitter.name, extra_feed_x, y + 0.5, SOUTH, {output_priority = 'right'}, upper_inputs)
    else
      grid:tile(options.belt.name, extra_feed_x, y, y == tail and WEST or SOUTH, nil, upper_inputs)
    end
  end

  for machine_index = 1, options.count do
    local y = machine_top + (machine_index - 1) * pitch - 2
    for x = feed_x + 2, extra_feed_x - 1 do
      grid:tile(options.belt.name, x, y, WEST, nil, upper_inputs)
    end
    grid:tile(options.underground.name, feed_x + 1, y, WEST, {type = 'input'}, upper_inputs)
    grid:tile(options.underground.name, feed_x - 1, y, WEST, {type = 'output'}, upper_inputs)
    grid:tunnel('item', feed_x + 1, y, feed_x - 1, y)
    for x = machine_left, feed_x - 2 do
      grid:tile(options.belt.name, x, y, WEST, nil, upper_inputs)
    end
  end

  local source = {x = output_x, y = head - 1, d = 0, plain = true, id = 'row/' .. row.id .. '/out'}
  reserve_port(grid, source, output.key, false)
  options.connect(output.key, source, true, output.amount * options.crafts, output_x)

  local function connect_feed(rail_x, first_input, second_input)
    if second_input then
      grid:tile(options.belt.name, rail_x, head - 1, SOUTH, nil, {first_input, second_input})
      grid:tile(options.belt.name, rail_x - 1, head, EAST, nil, first_input.key)
      for index, requirement in ipairs({first_input, second_input}) do
        local port = {
          x = rail_x + (index == 1 and -2 or 1),
          y = head,
          d = index == 1 and 1 or 3,
          plain = true,
          id = 'row/' .. row.id .. '/in/' .. requirement.key,
        }
        grid:reserve(port.x, port.y, port.id)
        for distance = 1, 2 do
          grid:reserve(port.x, port.y - distance, port.id)
        end
        options.connect(requirement.key, port, false, requirement.amount * options.crafts, port.x)
      end
    else
      local port = {x = rail_x, y = head - 1, d = 2, plain = true, id = 'row/' .. row.id .. '/in/' .. first_input.key}
      reserve_port(grid, port, first_input.key, true)
      options.connect(first_input.key, port, false, first_input.amount * options.crafts, rail_x)
    end
  end

  connect_feed(feed_x, inputs[1], inputs[2])
  connect_feed(extra_feed_x, inputs[3], inputs[4])
  record_event(options, 'branches', first_entity, options.recipe)
  return extra_feed_x + (#inputs == 4 and 4 or 3)
end

-- Both feeds run along the same side of every machine. A long arm reaches
-- over the near belt to the far one; the row grows without per-machine taps.
local function build_parallel_row(options, node, prototype, chosen_inserters, output)
  local grid = options.g
  local group = options.parallel
  local width, height = prototype.tile_width, prototype.tile_height
  local output_x = options.x
  local machine_left = output_x + 2
  local near_x = machine_left + width + 1
  local far_x = near_x + 1
  local head, machine_top, pitch = 2, 5, height + 1
  local middle = math.floor((height - 1) / 2)
  local bottom = machine_top + (options.count - 1) * pitch + height - 1
  local row = {
    id = #options.plan.production_rows + 1,
    node = node.id,
    count = options.count,
    machines = {},
    packed = true,
    compact = true,
    feed_belts = 2,
    feed_style = 'parallel',
    input_inserters = {},
    output_inserters = {},
    long_input_inserters = {},
    pitch = pitch,
    head = head,
    foot = bottom,
  }
  options.plan.production_rows[#options.plan.production_rows + 1] = row
  local near_groups = input_groups(options, group.near, chosen_inserters)
  describe_groups(row, near_groups)
  describe_groups(row, {{requirements = group.far, inserter = chosen_inserters[group.far[1]]}})

  local first_entity = #grid.entities + 1
  for machine_index = 1, options.count do
    local y = machine_top + (machine_index - 1) * pitch
    local machine = grid:add(prototype.name, machine_left + width / 2, y + height / 2, NORTH, {
      recipe = node.recipe,
      recipe_quality = 'normal',
    })
    row.machines[#row.machines + 1] = machine.entity_number

    for group_index, feed_group in ipairs(near_groups) do
      local inserter_y = y + (group_index - 1) * (height - 1)
      local arm = place_inserter(grid, feed_group.inserter, machine_left + width, inserter_y, EAST, feed_group.requirements)
      row.input_inserters[#row.input_inserters + 1] = arm.entity_number
    end

    local arm = place_inserter(grid, chosen_inserters[group.far[1]], machine_left + width, y + middle, EAST, group.far)
    row.input_inserters[#row.input_inserters + 1] = arm.entity_number
    row.long_input_inserters[#row.long_input_inserters + 1] = arm.entity_number

    arm = place_inserter(grid, chosen_inserters[output], machine_left - 1, y + middle, EAST, output.key, true)
    row.output_inserters[#row.output_inserters + 1] = arm.entity_number
  end
  record_event(options, 'machines', first_entity, options.recipe)

  first_entity = #grid.entities + 1
  local near_end = #near_groups == 1 and machine_top + (options.count - 1) * pitch or bottom
  for y = head, near_end do
    grid:tile(options.belt.name, near_x, y, SOUTH, nil, group.near)
  end
  for y = 4, machine_top + (options.count - 1) * pitch + middle do
    grid:tile(options.belt.name, far_x, y, SOUTH, nil, group.far)
  end
  for y = head, machine_top + (options.count - 1) * pitch + middle do
    grid:tile(options.belt.name, output_x, y, NORTH, nil, output.key)
  end

  local function connect_input(requirement, x, y, direction, suffix)
    local port = {x = x, y = y, d = direction, plain = true, id = 'row/' .. row.id .. '/in/' .. suffix}
    grid:reserve(x, y, port.id)
    for distance = 1, 2 do
      grid:reserve(x, y - distance, port.id)
    end
    options.connect(requirement.key, port, false, requirement.amount * options.crafts, x)
  end

  local function merge_inputs(rail_x, items)
    grid:tile(options.belt.name, rail_x, head - 1, SOUTH, nil, items)
    grid:tile(options.belt.name, rail_x - 1, head, EAST, nil, items[1].key)
    for index, requirement in ipairs(items) do
      connect_input(requirement, rail_x + (index == 1 and -2 or 1), head, index == 1 and 1 or 3, requirement.key)
    end
  end

  merge_inputs(near_x, group.near)
  local last_x
  if #group.far == 1 then
    last_x = near_x + 4
    connect_input(group.far[1], last_x, 4, 3, group.far[1].key)
    for x = far_x + 1, last_x - 1 do
      grid:tile(options.belt.name, x, 4, WEST, nil, group.far)
    end
  else
    local merge_x = near_x + 6
    last_x = merge_x + 1
    merge_inputs(merge_x, group.far)
    for y = head, 3 do
      grid:tile(options.belt.name, merge_x, y, SOUTH, nil, group.far)
    end
    for x = far_x + 1, merge_x do
      grid:tile(options.belt.name, x, 4, WEST, nil, group.far)
    end
  end

  local source = {x = output_x, y = head - 1, d = 0, plain = true, id = 'row/' .. row.id .. '/out'}
  reserve_port(grid, source, output.key, false)
  options.connect(output.key, source, true, output.amount * options.crafts, output_x)
  record_event(options, 'branches', first_entity, options.recipe)
  return last_x + (options.gap or 3)
end

local function can_build_simple_row(node, prototype, chosen_inserters, inputs, outputs, items_only, lane_capacity)
  if not items_only or #inputs < 1 or #inputs > 2 or #outputs ~= 1 or prototype.tile_height < #inputs then
    return false
  end

  local input_reach = inserter_reach(chosen_inserters[inputs[1]])
  for _, requirement in ipairs(inputs) do
    if inserter_reach(chosen_inserters[requirement]) ~= input_reach then
      return false
    end
    if #inputs == 2 and requirement.amount * node.crafts > lane_capacity + RATE_EPSILON then
      return false
    end
  end
  return true
end

local function can_build_dense_row(
  options, node, prototype, requirements, chosen_inserters, inputs, outputs, lane_capacity
)
  if not options.compact or #inputs < 3 or #inputs > 4 or #outputs ~= 1
    or prototype.tile_width < 2 or prototype.tile_height < 2 then
    return false
  end

  for _, requirement in ipairs(requirements) do
    if Util.split(requirement.key) ~= 'item' then
      return false
    elseif requirement.input then
      local inserter = chosen_inserters[requirement]
      if pickup_distance(inserter) ~= 1 or drop_distance(inserter) ~= 1 then
        return false
      end
      if requirement.amount * node.crafts > lane_capacity + RATE_EPSILON then
        return false
      end
    end
  end
  return true
end

local function can_build_parallel_row(options, node, lane_capacity)
  if not options.compact or options.parallel == nil then
    return false
  end

  for _, group in ipairs({options.parallel.near, options.parallel.far}) do
    if #group == 2 then
      for _, requirement in ipairs(group) do
        if requirement.amount * node.crafts > lane_capacity + RATE_EPSILON then
          return false
        end
      end
    end
  end
  return true
end

-- Machines extend along local Y; each completed row advances options.x.
-- chosen_inserters and options.shared are indexed by requirement tables.
-- options.count and options.crafts describe the current batch while building.
function Rows.build(options, node, prototype, requirements, chosen_inserters)
  local inputs, outputs = {}, {}
  local items_only = true
  for _, requirement in ipairs(requirements) do
    if Util.split(requirement.key) ~= 'item' then
      items_only = false
    end
    local list = requirement.input and inputs or outputs
    list[#list + 1] = requirement
  end

  -- belt_speed is tiles/tick; one lane carries four items/tile at 60 ticks/s
  -- and rates in the production plan are measured per minute. Fluid-only
  -- layouts have no belt prototype and never check item lane capacity.
  local lane_capacity = options.belt and options.belt.belt_speed * 14400
  local simple_row = can_build_simple_row(node, prototype, chosen_inserters, inputs, outputs, items_only, lane_capacity)
  local dense_row = can_build_dense_row(
    options, node, prototype, requirements, chosen_inserters, inputs, outputs, lane_capacity
  )
  local parallel_row = can_build_parallel_row(options, node, lane_capacity)

  local pitch = prototype.tile_height + 2 * options.reach + 2 * #requirements + 6
  local row_limit
  if simple_row or dense_row or parallel_row then
    row_limit = options.row_limit or 32
  else
    row_limit = math.max(1, math.floor(220 / pitch))
  end
  if options.row_limit then
    row_limit = math.min(row_limit, options.row_limit)
  end

  local completed_machines = 0
  while completed_machines < node.count do
    local start_x = options.x
    options.count = math.min(row_limit, node.count - completed_machines)
    options.crafts = node.crafts * options.count / node.count

    if parallel_row then
      options.x = build_parallel_row(options, node, prototype, chosen_inserters, outputs[1])
    elseif simple_row then
      options.x = build_simple_row(options, node, prototype, chosen_inserters, inputs, outputs[1])
    elseif dense_row then
      options.x = build_dense_row(options, node, prototype, chosen_inserters, inputs, outputs[1])
    else
      options.x = build_generic_row(options, node, prototype, requirements, chosen_inserters)
    end

    local row = options.plan.production_rows[#options.plan.production_rows]
    row.bus = 'recipe'
    row.recipe = node.recipe
    row.inputs = {}
    row.returns = {}
    row.bounds = {x0 = start_x, y0 = row.head, x1 = options.x - 1, y1 = row.foot}
    for _, requirement in ipairs(requirements) do
      local keys = requirement.input and row.inputs or row.returns
      keys[#keys + 1] = requirement.key
    end
    completed_machines = completed_machines + options.count
  end

  return options.x
end

return Rows
