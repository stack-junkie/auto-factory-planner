local C={}
C.defaults={units=10000,perimeter=10,area=1,objects=1}
C.keys={'units','perimeter','area','objects'}
local base_prices={['transport-belt']=1,['underground-belt']=3,splitter=10}
local prices
local function transport_prices()
  local speeds={}
  -- Research must not renumber tiers. Equal-speed variants share a tier,
  -- while each distinct faster tier costs 1.5 times the previous one.
  for _,p in pairs(prototypes.entity)do if base_prices[p.type]then
    speeds[p.type]=speeds[p.type]or{};speeds[p.type][p.belt_speed]=true
  end end
  local multipliers={}
  for kind,values in pairs(speeds)do
    local ordered={};for speed in pairs(values)do ordered[#ordered+1]=speed end;table.sort(ordered)
    multipliers[kind]={};for tier,speed in ipairs(ordered)do multipliers[kind][speed]=1.5^(tier-1)end
  end
  prices={}
  for name,p in pairs(prototypes.entity)do if base_prices[p.type]then
    prices[name]=base_prices[p.type]*multipliers[p.type][p.belt_speed]
  end end
end
function C.unit_cost(entities)
  if not prices then transport_prices()end
  local cost=0
  for _,e in ipairs(entities or{})do
    cost=cost+(prices[e.name]or 1)
  end
  return cost
end
function C.weights(settings)
  local result={};local supplied=settings and settings.compression_weights or{}
  for _,key in ipairs(C.keys)do
    local value=tonumber(supplied[key])
    result[key]=value and value>=0 and value<math.huge and value or C.defaults[key]
  end
  return result
end
function C.evaluate(plan,settings)
  local grid=plan.city_blocks
  local b=grid and grid.factory_bounds or plan.fixed_production_bounds or plan.local_bounds
  if not b then return end
  local width,height=b.x1-b.x0,b.y1-b.y0
  plan.compression={units=grid and grid.units or 0,columns=grid and grid.columns or 0,rows=grid and grid.rows or 0,
    area=width*height,perimeter=2*(width+height),objects=#(plan.entities or{}),unit_cost=C.unit_cost(plan.entities),weights=C.weights(settings)}
  local m=plan.compression;m.cost=0
  for _,key in ipairs(C.keys)do m.cost=m.cost+(key=='objects'and m.unit_cost or m[key])*m.weights[key]end
  return plan.compression
end
function C.score(plan)
  local m=plan.compression
  local weights=m.weights or C.defaults;local cost=0
  for _,key in ipairs(C.keys)do cost=cost+(key=='objects'and(m.unit_cost or m.objects or 0)or(m[key]or 0))*weights[key]end
  return{cost}
end
return C
