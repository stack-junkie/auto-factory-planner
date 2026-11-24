local Util = require('scripts.util')

local Arrangement = {}

-- Dependencies determine the direction of ordinary streams. Feedback edges
-- already carry the model's bootstrap flag and may travel around a local loop.
function Arrangement.order(plan)
  local producers, indices = {}, {}

  for index, node in ipairs(plan.nodes) do
    indices[#indices + 1] = index
    for key, amount in pairs(node.output) do
      if amount > 1e-7 then
        producers[key] = producers[key] or {}
        local list = producers[key]
        list[#list + 1] = index
      end
    end
  end

  local function less(left_index, right_index)
    local left = plan.nodes[left_index]
    local right = plan.nodes[right_index]
    local left_section = left.section or 1
    local right_section = right.section or 1

    if left_section ~= right_section then
      return left_section < right_section
    end
    if left.id == right.id then
      return left_index < right_index
    end
    return left.id < right.id
  end

  table.sort(indices, less)
  for _, list in pairs(producers) do
    table.sort(list, less)
  end

  local ordered, visited = {}, {}
  local function visit(index)
    if visited[index] then
      return
    end
    -- Mark before descending so feedback loops do not recurse forever.
    visited[index] = true

    local node = plan.nodes[index]
    for _, key in ipairs(Util.sorted(node.input)) do
      if node.input[key] > 1e-7 then
        for _, producer_index in ipairs(producers[key] or {}) do
          visit(producer_index)
        end
      end
    end
    ordered[#ordered + 1] = node
  end

  for _, index in ipairs(indices) do
    visit(index)
  end
  plan.nodes = ordered
end

function Arrangement.rows(plan)
  local reservoirs, imports = {}, {}
  for _, port in ipairs(plan.ports) do
    local flow = plan.flows[port.key]
    if port.kind == 'in' then
      imports[port.key] = true
    end

    if Util.split(port.key) == 'fluid' then
      local needs_reservoir = port.kind == 'in' and flow.recycle
        or port.kind == 'out' and flow.demand > 0 and Util.base_key(port.key) ~= plan.target
      if needs_reservoir then
        reservoirs[port.key] = true
      end
    end
  end

  local rows = {}
  local previous
  for _, key in ipairs(Util.sorted(plan.flows)) do
    local flow = plan.flows[key]
    local is_item = Util.split(key) == 'item'
    local row = {
      closed = is_item and flow.bootstrap or false,
      fluid = not is_item,
      taps = {},
      sensors = {},
    }

    row.above = row.closed and 3 or 0
    if reservoirs[key] then
      row.below = 11
    elseif is_item and flow.controlled and imports[key] then
      row.below = 7
    else
      row.below = 1
    end

    local gap = previous and (row.fluid or previous.fluid) and 4 or 3
    row.y = previous and previous.y - row.below - previous.above - gap or 0
    rows[key] = row
    previous = row
  end

  return rows
end

function Arrangement.orientation(settings)
  local growth=settings.growth_direction
  if type(growth)=='number'and growth>=1 and growth<=4 and growth%1==0 then
    return (growth-1-(settings._mall_compact_axes and 2 or 1))%4,false
  end
  local is_left = settings.side == 2
  local direction = (settings.direction or 2) - 2
  if settings._mall_compact_axes and not settings._single_recipe then
    return direction % 4, is_left
  end
  return (direction + (is_left and -1 or 1)) % 4, not is_left
end

function Arrangement.growth_direction(settings,plan,context)
  if settings.growth_direction then return settings.growth_direction end
  local compact=context and context.mall_compact_axes
  if compact==nil and plan then compact=plan.rate_search or plan.mall_compact_axes end
  if compact==nil then compact=settings._mall_compact_axes end
  if compact==nil then compact=settings.mode=='mall'or settings.layout_search~=false end
  local legacy=Util.copy(settings);legacy._mall_compact_axes=compact
  if plan then legacy._single_recipe=plan.perpendicular_rows end
  local turns,mirror
  if context and context.orientation then turns,mirror=context.orientation.turns,context.orientation.mirror
  else turns,mirror=Arrangement.orientation(legacy)end
  local x,y=Util.rotate(compact and 0 or 1,compact and(mirror and-1 or 1)or 0,turns)
  return y<0 and 1 or x>0 and 2 or y>0 and 3 or 4
end

function Arrangement.ports(plan, settings, rows)
  local top, bottom = 0, 0
  for _, row in pairs(rows) do
    top = math.min(top, row.y - row.above)
    bottom = math.max(bottom, row.y)
  end

  table.sort(plan.ports, function(left, right)
    if rows[left.key].y ~= rows[right.key].y then
      return rows[left.key].y < rows[right.key].y
    end
    if left.kind ~= right.kind then
      return left.kind < right.kind
    end
    return left.id < right.id
  end)

  local first_y = math.floor((top + bottom) / 2 - (#plan.ports - 1))
  local has_fluids = false
  for key in pairs(plan.flows) do
    if Util.split(key) == 'fluid' then
      has_fluids = true
    end
  end

  -- Fluid ports need more room for separate approaches to their staging points.
  local entrance_x = -(has_fluids and (3 * #plan.ports + 8) or (#plan.ports + 4))
  local turns, mirror = Arrangement.orientation(settings)
  for index, port in ipairs(plan.ports) do
    port.index = index
    port.local_position = {x = entrance_x, y = first_y + (index - 1) * 2}
    port.staging_position = has_fluids and {x = entrance_x + 3 * index, y = port.local_position.y - 1} or nil

    local x, y = Util.rotate(
      port.local_position.x + 0.5,
      (mirror and -1 or 1) * (port.local_position.y + 0.5),
      turns
    )
    port.position = {x = x, y = y}
  end
end

return Arrangement
