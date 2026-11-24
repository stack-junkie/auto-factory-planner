local P={}
local A=require('scripts.arrangement')
local function valid(value,maximum)return type(value)=='number'and value%1==0 and value>=1 and value<=maximum end
function P.get(index,seed)
  storage.afp_preferences=storage.afp_preferences or{}
  local saved=storage.afp_preferences[index]
  if not saved then
    seed=seed or{}
    saved={growth_direction=valid(seed.growth_direction,4)and seed.growth_direction or valid(seed.direction,4)and A.growth_direction(seed,seed.plan)or 2}
    storage.afp_preferences[index]=saved
  end
  if not valid(saved.growth_direction,4)then
    saved.growth_direction=valid((seed or{}).growth_direction,4)and seed.growth_direction or A.growth_direction(saved)
  end
  return {growth_direction=saved.growth_direction,direction=saved.direction,side=saved.side}
end
function P.remember(index,settings)
  local saved=P.get(index,settings)
  if valid(settings.direction,4)then saved.direction=settings.direction end
  if valid(settings.side,2)then saved.side=settings.side end
  saved.growth_direction=A.growth_direction(settings,settings.plan)
  storage.afp_preferences[index]=saved
end
function P.remove(index)if storage.afp_preferences then storage.afp_preferences[index]=nil end end
return P
