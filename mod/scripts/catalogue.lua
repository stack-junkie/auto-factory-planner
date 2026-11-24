local U=require("scripts.util")
local FluidBoxes=require('scripts.fluid_boxes')
local C={}
function C.build(force)
  local c={force=force,recipes={},by_product={},machines={},available={},infra={}}
  -- Resources and hand-gatherable fuels do not require a crafting recipe.
  for _,e in pairs(prototypes.entity) do
    if e.type=="resource" or e.type=="tree" or e.type=="simple-entity" then
      local mp=e.mineable_properties
      if mp and mp.products then for _,p in pairs(mp.products) do c.available[U.key(p.type,p.name)]=true end end
    end
  end
  for name,r in pairs(force.recipes) do if r.enabled then
    c.recipes[name]=r
    for _,p in pairs(r.products) do
      local amount=U.expected(p)
      if amount>0 then
        local k=U.key(p.type,p.name);c.available[k]=true
        c.by_product[k]=c.by_product[k] or {};table.insert(c.by_product[k],name)
      end
    end
  end end
  for _,a in pairs(c.by_product) do table.sort(a,function(a,b)
    local x,y=c.recipes[a],c.recipes[b];return x.order==y.order and a<b or x.order<y.order
  end) end
  for name,item in pairs(prototypes.item) do
    local e=item.place_result
    if e and c.available[U.key("item",name)] then
      c.infra[e.type]=c.infra[e.type] or {};c.infra[e.type][e.name]=e
      if e.crafting_categories and e.type~="character" then c.machines[e.name]=e end
    end
  end
  return c
end
function C.machines(c,r)
  local a={}
  for name,m in pairs(c.machines) do
    local compatible=false
    for _,cat in pairs(r.categories) do if m.crafting_categories[cat] then compatible=true;break end end
    if m.fixed_recipe and m.fixed_recipe.name~=r.name then compatible=false end
    if compatible and (not m.ingredient_count or m.ingredient_count>=#r.ingredients) then
      if FluidBoxes.assign(m,r.ingredients,r.products)then a[#a+1]=name end
    end
  end
  table.sort(a,function(a,b)
    local x,y=c.machines[a],c.machines[b]
    local sx,sy=x.get_crafting_speed("normal"),y.get_crafting_speed("normal")
    return sx==sy and a<b or sx<sy
  end);return a
end
function C.is_recycling(recipe)
  for _,category in pairs(recipe.categories or{})do
    if category=='recycling'or category:match('^recycling[-_]')then return true end
  end
  return false
end
function C.recipes(c,k,show_recycling)
  local out={};for _,n in ipairs(c.by_product[k] or {}) do
    if (show_recycling or not C.is_recycling(c.recipes[n]))and #C.machines(c,c.recipes[n])>0 then out[#out+1]=n end
  end;return out
end
function C.production_status(c,k,show_recycling)
  if #C.recipes(c,k,show_recycling)>0 then return end
  if not show_recycling and #C.recipes(c,k,true)>0 then return{key=k,reason='recycling-hidden',technologies={}}end
  local known=false
  for _,name in ipairs(c.by_product[k]or{})do if show_recycling or not C.is_recycling(c.recipes[name])then known=true;break end end
  local status={key=k,reason=known and 'no-machine' or 'no-recipes',technologies={}}
  if not known then
    local recipes={}
    for name,r in pairs(c.force.recipes) do if not r.enabled and(show_recycling or not C.is_recycling(r))then
      local net=0
      for _,product in pairs(r.products) do if U.key(product.type,product.name)==k then net=net+U.expected(product) end end
      for _,ingredient in pairs(r.ingredients) do if U.key(ingredient.type,ingredient.name)==k then net=net-ingredient.amount end end
      -- Self-recycling cannot supply the item; do not suggest its technology as an unlock.
      if net>1e-7 then recipes[name]=true end
    end end
    for name,technology in pairs(c.force.technologies) do if not technology.researched and technology.enabled then
      for _,effect in pairs(technology.prototype.effects) do if effect.type=='unlock-recipe' and recipes[effect.recipe] then
        status.technologies[#status.technologies+1]=name;break
      end end
    end end
    table.sort(status.technologies)
  end
  return status
end
function C.options(c,kind,score)
  local out={};for _,p in pairs(c.infra[kind] or {}) do out[#out+1]=p end
  table.sort(out,function(a,b)
    local x,y=score and score(a) or 0,score and score(b) or 0
    if x~=y then return x<y end
    return a.order==b.order and a.name<b.name or a.order<b.order
  end);return out
end
function C.pick(c,kind,override,predicate,score)
  if override then
    local p=(c.infra[kind] or {})[override]
    if p and (not predicate or predicate(p)) then return p end
    U.fail("infrastructure",override)
  end
  for _,p in ipairs(C.options(c,kind,score)) do if not predicate or predicate(p) then return p end end
  U.fail("missing-infrastructure",kind)
end
function C.fuels(c,m)
  local out={};local b=m.burner_prototype
  if not b then return out end
  for name,p in pairs(prototypes.item) do
    if p.fuel_value>0 and C.fuel_compatible(p,b) and c.available[U.key("item",name)] then out[#out+1]=name end
  end
  table.sort(out,function(a,b)
    local x,y=prototypes.item[a],prototypes.item[b]
    return x.fuel_value==y.fuel_value and a<b or x.fuel_value<y.fuel_value
  end);return out
end
function C.fuel_compatible(item,burner)
  for _,category in pairs(item.fuel_categories or {}) do if burner.fuel_categories[category] then return true end end
  return false
end
return C
