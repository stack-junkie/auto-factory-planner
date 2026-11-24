local Bus = {size = 4, gap = 2}

function Bus.pack(plan, keys, order)
  local inputs, outputs = {}, {}

  for _, key in ipairs(keys) do
    local flow = plan.flows[key]
    local is_output = (flow.internal or 0) + (flow.fuel or 0) < 1e-6 and (flow.external or 0) < 1e-6
    local lanes = is_output and outputs or inputs
    lanes[#lanes + 1] = key
  end

  if order then
    local rank = {}
    for index, key in ipairs(order) do
      rank[key] = index
    end

    local function less(left, right)
      local left_rank = rank[left] or math.huge
      local right_rank = rank[right] or math.huge
      if left_rank == right_rank then
        return left < right
      end
      return left_rank < right_rank
    end

    table.sort(inputs, less)
    table.sort(outputs, less)
  end

  local lanes_by_key, ordered_keys = {}, {}
  local position = -1

  -- Input belts form blocks of four, separated by a two-tile corridor.
  for index, key in ipairs(inputs) do
    local starts_group = index > 1 and (index - 1) % Bus.size == 0
    position = position + 1 + (starts_group and Bus.gap or 0)
    lanes_by_key[key] = {
      position = position,
      group = math.floor((index - 1) / Bus.size) + 1,
      lane = (index - 1) % Bus.size + 1,
      role = 'input',
    }
    ordered_keys[#ordered_keys + 1] = key
  end

  -- Each output belt has its own corridor after the input blocks.
  for _, key in ipairs(outputs) do
    position = position + 1 + (#ordered_keys > 0 and Bus.gap or 0)
    lanes_by_key[key] = {position = position, role = 'output'}
    ordered_keys[#ordered_keys + 1] = key
  end

  return lanes_by_key, ordered_keys, position + 1
end

return Bus
