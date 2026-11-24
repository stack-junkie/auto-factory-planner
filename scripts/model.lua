local U=require("scripts.util")
local Belts=require('scripts.belt_sizing')
local C=require("scripts.catalogue")
local LP=require("scripts.simplex")
local I=require('scripts.inserters')
local Mall=require('scripts.mall')
local SharedRows=require('scripts.shared_rows')
local M={}
function M.has_rate_targets(s)
  local first=s.targets and s.targets[1]
  return s.mode~='mall'and first~=nil and first.stacks==nil and first.stock==nil
end
function M.targets(s)
  if s.mode=='mall' then return s.targets or {} end
  if M.has_rate_targets(s)then return s.targets end
  return {{key=s.target,rate=s.rate}}
end
function M.is_target(s,key)
  for _,target in ipairs(M.targets(s)) do if target.key==key then return true end end
  return false
end
function M.unavailable(c,s)
  local result={}
  if s.mode=='mall' then for i,target in ipairs(s.targets or {}) do if target.key then
    local d=s.decisions and s.decisions[target.key];local r=d and d.mode=='craft'and c.recipes[d.recipe]
    local status=C.production_status(c,target.key,s.show_recycling or r and C.is_recycling(r))
    if status then status.index=i;result[#result+1]=status end
  end end end
  return result
end
function M.pending(c,state)
  local queue={};for _,target in ipairs(M.targets(state)) do queue[#queue+1]=target.key end
  for _,route in ipairs(state.conversions or{})do
    local recipe=c.recipes[route.recipe];if not recipe then U.fail('recipe',route.recipe)end
    for _,v in ipairs(recipe.ingredients)do queue[#queue+1]=U.key(v.type,v.name)end
  end
  local seen={};local nodes={}
  local i=1
  while i<=#queue do
    local k=queue[i];i=i+1
    if not seen[k] then
      seen[k]=true
      local d=state.decisions[k]
      if not d then return k end
      if d.mode=="craft" then
        local r=c.recipes[d.recipe]
        if not r then U.fail("recipe",d.recipe) end
        if not d.machine or not c.machines[d.machine] then return k end
        if not nodes[d.recipe.."/"..d.machine] then
          nodes[d.recipe.."/"..d.machine]=true
          for _,p in ipairs(r.ingredients) do queue[#queue+1]=U.key(p.type,p.name) end
        end
      end
    end
  end
  return nil,seen
end
function M.calculate(c,s)
  Mall.migrate(s)
  local unavailable=M.unavailable(c,s)
  if #unavailable>0 then U.fail('mall-unavailable',#unavailable) end
  local pending,seen=M.pending(c,s)
  if pending then U.fail("unresolved",U.name(pending)) end
  local nodes,index={},{}
  local function add_node(d)
    local id=d.recipe.."/"..d.machine
      if not index[id] then
        local r,m=c.recipes[d.recipe],c.machines[d.machine]
        local valid=false;for _,n in ipairs(C.machines(c,r)) do if n==m.name then valid=true end end
        if not valid then U.fail("machine",d.machine) end
        local effect=m.effect_receiver and m.effect_receiver.base_effect or {}
        local prod=math.min(r.prototype.maximum_productivity,(r.productivity_bonus or 0)+(effect.productivity or 0))
        local node={id=id,recipe=r.name,machine=m.name,input={},output={},crafts=0,
          speed=m.get_crafting_speed("normal")*(1+(effect.speed or 0)),energy=r.energy,fuel=d.fuel,productivity=prod}
        for _,v in ipairs(r.ingredients) do U.add(node.input,U.key(v.type,v.name),v.amount) end
        for _,v in ipairs(r.products) do
          local a,p=U.expected(v)
          U.add(node.output,U.key(v.type,v.name),a+math.max(0,a-(v.ignored_by_productivity or 0)*p)*prod)
        end
        if m.burner_prototype then
          local fuels=C.fuels(c,m);node.fuel=node.fuel or fuels[1]
          local fp=node.fuel and prototypes.item[node.fuel]
          if not fp or not C.fuel_compatible(fp,m.burner_prototype) or not c.available[U.key("item",node.fuel)] then U.fail("fuel",m.localised_name) end
          -- Prototype energy usage is joules/tick; crafting time is seconds.
          node.fuel_per_craft=(m.energy_usage or m.get_max_energy_usage("normal"))*60*(r.energy/node.speed)/m.burner_prototype.effectivity/fp.fuel_value
          if fp.burnt_result then U.add(node.output,U.key("item",fp.burnt_result.name),node.fuel_per_craft) end
        end
        nodes[#nodes+1]=node;index[id]=#nodes
      end
  end
  for _,k in ipairs(U.sorted(seen))do if s.decisions[k].mode=='craft'then add_node(s.decisions[k])end end
  for _,route in ipairs(s.conversions or{})do add_node(route)end
  if #nodes==0 then U.fail('target-external') end
  local targets,rates,finals={},{},{}
  for _,entry in ipairs(M.targets(s)) do
    local d=s.decisions[entry.key]
    if not d or d.mode~='craft' then U.fail('target-external') end
    if rates[entry.key] then U.fail('duplicate-target',U.name(entry.key)) end
    local target=U.copy(entry);targets[#targets+1]=target
    if s.mode=='mall' then
      if U.split(entry.key)~='item' or not entry.stacks or entry.stacks<1 or entry.stacks%1~=0 then U.fail('mall-stock') end
      Mall.chest(c,s,entry.stacks)
      target.stock=entry.stacks*prototypes.item[select(2,U.split(entry.key))].stack_size
      local id=d.recipe..'/'..d.machine;local n=nodes[index[id]];n.mall_final=true;finals[index[id]]=true
      target.rate=(n.output[entry.key] or 0)*60*n.speed/n.energy
    end
    if not target.rate or target.rate<=0 then U.fail('rate') end
    rates[entry.key]=target.rate
  end
  if #targets==0 then U.fail('target') end
  if #nodes>150 then U.fail("too-large") end
  local A,b,cost,balance_rows={},{},{},{}
  for j=1,#nodes do cost[j]=-1 end
  for _,k in ipairs(U.sorted(seen)) do
    if s.decisions[k].mode=="craft" then
      local row={};for j,n in ipairs(nodes) do row[j]=(n.input[k] or 0)-(n.output[k] or 0) end
      A[#A+1]=row;b[#b+1]=-(rates[k] or 0);balance_rows[k]=#b
    end
  end
  -- A conversion fixes consumption of its source, while the source balance
  -- prevents the solver from importing a resource selected for internal reuse.
  local sources={};local allocations={}
  for _,route in ipairs(s.conversions or{})do
    local j=index[route.recipe..'/'..route.machine];local node=nodes[j]
    local amount=node.input[route.source]
    if not amount or not route.rate or route.rate<=0 or route.rate>1000000 then U.fail('conversion-rate')end
    sources[route.source]=true
    local previous=allocations[j]
    if previous and math.abs(previous-route.rate/amount)>1e-7 then U.fail('conversion-duplicate')end
    allocations[j]=route.rate/amount
  end
  for j,crafts in pairs(allocations)do
    local lower,upper={},{}
    for k=1,#nodes do lower[k]=k==j and -1 or 0;upper[k]=k==j and 1 or 0 end
    A[#A+1]=lower;b[#b+1]=-crafts;A[#A+1]=upper;b[#b+1]=crafts
  end
  for key in pairs(sources)do
    local row={};for j,n in ipairs(nodes)do row[j]=(n.input[key]or 0)-(n.output[key]or 0)end
    A[#A+1]=row;b[#b+1]=0
  end
  local x,err=LP.solve(A,b,cost);if not x then U.fail("balance",err) end
  if s.mode=='mall' then
    local usable,short,long={},{},{}
    for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal') end)) do
      if I.supported(p) and (not s.infrastructure or not s.infrastructure.inserter or s.infrastructure.inserter==p.name) then
        usable[#usable+1]=p
        local pick=math.floor(-p.inserter_pickup_position[2]+0.5);local put=math.floor(p.inserter_drop_position[2]+0.5)
        if pick==1 and put==1 then short[#short+1]=p elseif pick==2 and put==2 then long[#long+1]=p end
      end
    end
    local function capacity(pool,group)
      local best=0
      for _,p in ipairs(pool) do
        local rate=math.huge;for _,req in ipairs(group) do rate=math.min(rate,I.capacity(p,c,req.key)) end
        best=math.max(best,rate)
      end
      return best
    end
    local pool=#short>0 and short or usable;local factor=1;local limits={}
    for j in pairs(finals) do
      local n=nodes[j];local limit=60*n.speed/n.energy;local inputs={}
      for _,side in ipairs({n.input,n.output}) do for key,amount in pairs(side) do if U.split(key)=='item' then
        limit=math.min(limit,capacity(pool,{{key=key}})/amount)
        if side==n.input then inputs[#inputs+1]={key=key,amount=amount} end
      end end end
      if n.fuel then inputs[#inputs+1]={key=U.key('item',n.fuel),amount=n.fuel_per_craft} end
      table.sort(inputs,function(a,b)return a.amount==b.amount and a.key<b.key or a.amount>b.amount end)
      if #inputs>=3 and #inputs<=4 and #long>0 and c.machines[n.machine].tile_height>=3 then
        local group,amount={},0;for i=3,#inputs do group[#group+1]=inputs[i];amount=amount+inputs[i].amount end
        limit=math.min(limit,capacity(long,group)/amount)
      end
      if n.fuel then limit=math.min(limit,capacity(pool,{{key=U.key('item',n.fuel)}})/n.fuel_per_craft) end
      limits[j]=limit
      if x[j]>0 then factor=math.min(factor,limit/x[j]) end
    end
    local demand,supply={},{}
    for key,rate in pairs(rates) do demand[key]=rate end
    for j,n in ipairs(nodes) do
      for key,amount in pairs(n.input) do U.add(demand,key,amount*x[j]) end
      for key,amount in pairs(n.output) do U.add(supply,key,amount*x[j]) end
      if n.fuel then U.add(demand,U.key('item',n.fuel),n.fuel_per_craft*x[j]) end
    end
    local hasitems=false;for key in pairs(demand) do if U.split(key)=='item' then hasitems=true end end
    if hasitems then
      local belt=Belts.ceiling(c,s)
      local beltcap=belt.belt_speed*28800
      local balanced=SharedRows.capacity_keys(c,s,nodes,x)
      for key,amount in pairs(demand) do if U.split(key)=='item' and amount>0 then factor=math.min(factor,beltcap/amount) end end
      for key,amount in pairs(supply) do if U.split(key)=='item' and amount>0 then factor=math.min(factor,beltcap*(balanced[key]and 0.8 or 0.4)/amount) end end
    end
    if factor<=0 then U.fail('missing-infrastructure','inserter') end
    for key,rate in pairs(rates) do rates[key]=rate*factor end
    if next(allocations)then
      for key,row in pairs(balance_rows)do b[row]=-(rates[key]or 0)end
      for j,limit in pairs(limits)do
        local row={};for k=1,#nodes do row[k]=k==j and 1 or 0 end
        A[#A+1]=row;b[#b+1]=limit
      end
      local result,reason=LP.solve(A,b,cost);if not result then U.fail('balance',reason)end;x=result
    else for j in ipairs(x)do x[j]=x[j]*factor end end
    for _,target in ipairs(targets) do target.rate=rates[target.key] end
  end
  local plan={nodes={},flows={},ports={},target=targets[1].key,rate=targets[1].rate,targets=targets,mode=s.mode or 'rate'}
  local function flow(k)
    if not plan.flows[k] then plan.flows[k]={key=k,demand=0,internal=0,supply=0,fuel=0,seed=0} end;return plan.flows[k]
  end
  for key,rate in pairs(rates) do flow(key).demand=rate end
  for j,n in ipairs(nodes) do if x[j]>1e-7 then
    n.crafts=x[j];n.count=math.max(1,math.ceil(n.crafts*n.energy/(60*n.speed)-1e-8))
    if n.count>300 then U.fail("too-large") end
    for k,a in pairs(n.input) do local f=flow(k);f.demand=f.demand+a*n.crafts;f.internal=f.internal+a*n.crafts;f.seed=f.seed+a*n.count end
    for k,a in pairs(n.output) do flow(k).supply=flow(k).supply+a*n.crafts end
    if n.fuel then local f=flow(U.key("item",n.fuel));f.fuel=f.fuel+n.fuel_per_craft*n.crafts end
    plan.nodes[#plan.nodes+1]=n
  end end
  -- Find feedback edges in the chosen recipe graph. Only actual cycles need
  -- an additional bootstrap input; ordinary intermediates must not be imported.
  local edges={}
  for i,a in ipairs(plan.nodes) do edges[i]={};for j,z in ipairs(plan.nodes) do
    for k in pairs(a.output) do if z.input[k] then edges[i][j]=true end end
  end end
  local function reachable(from,to,visited)
    if from==to then return true end
    visited=visited or {};if visited[from] then return false end;visited[from]=true
    for nextnode in pairs(edges[from]) do if reachable(nextnode,to,visited) then return true end end;return false
  end
  for i,a in ipairs(plan.nodes) do for j,z in ipairs(plan.nodes) do
    if edges[i][j] and reachable(j,i) then for k in pairs(a.output) do if z.input[k] then flow(k).bootstrap=true end end end
  end end
  for _,k in ipairs(U.sorted(plan.flows)) do
    local f=plan.flows[k];f.external=math.max(0,f.demand-f.supply)+f.fuel
    f.surplus=math.max(0,f.supply-f.demand)
    f.recycle=f.supply>1e-7 and f.internal>1e-7
    f.internal_export=f.recycle and rates[k]~=nil
    f.controlled=f.recycle and (f.bootstrap or f.external>1e-7 or f.surplus>1e-7 or rates[k]~=nil and s.mode~='mall')
    f.low=math.max(1,math.ceil(f.seed+f.demand/6))
    f.high=math.max(f.low+1,math.ceil(f.low+f.demand/6))
    if s.thresholds and s.thresholds[k] then
      f.low=s.thresholds[k].low;f.high=s.thresholds[k].high
      if not f.low or not f.high or f.low<0 or f.high<=f.low or f.low%1~=0 or f.high%1~=0 or f.high>2147483647 then U.fail("threshold",U.name(k)) end
    end
    if f.external>1e-7 or f.bootstrap then plan.ports[#plan.ports+1]={id="in/"..k,key=k,kind="in",rate=f.external} end
    local out=f.surplus+(rates[k] or 0)
    if out>1e-7 then plan.ports[#plan.ports+1]={id="out/"..k,key=k,kind="out",rate=out} end
  end
  local signature={target=plan.target,rate=plan.rate,targets=targets,mode=plan.mode,nodes={}}
  for _,node in ipairs(plan.nodes) do signature.nodes[#signature.nodes+1]={id=node.id,crafts=node.crafts,input=node.input,output=node.output,speed=node.speed,fuel=node.fuel,fuel_per_craft=node.fuel_per_craft} end
  plan.model_signature=U.fingerprint(signature)
  return plan
end
return M
