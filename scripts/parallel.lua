local U=require("scripts.util")
local C=require("scripts.catalogue")
local A=require("scripts.arrangement")
local SharedRows=require('scripts.shared_rows')
local Belts=require('scripts.belt_sizing')
local P={}
-- Independent copies keep every internal stream within one belt's capacity,
-- including feedback loops. Dedicated shared rows can explicitly rebalance
-- their collector; other producers retain the conservative one-lane limit.
function P.prepare(c,s,plan)
  if plan.sections then return plan end
  local maxrate,produced=0,0;local balanced=SharedRows.balanceable(c,s,plan)
  for k,f in pairs(plan.flows) do if U.split(k)=="item" then
    maxrate=math.max(maxrate,f.demand+f.fuel,f.supply);produced=math.max(produced,f.supply/(balanced[k]and 2 or 1))
  end end
  local sections=1
  if maxrate>0 then
    local belt=Belts.planning(c,plan,balanced,s)
    local capacity=belt.belt_speed*28800
    -- Inserters deposit on one lane. Reserve 20% of that lane's throughput for
    -- corners and merges; external feeds can use both lanes of their belt.
    sections=math.max(1,math.ceil(math.max(maxrate/capacity,produced/(capacity*0.5*0.8))-1e-8))
    plan.belt=belt.name
  end
  if sections>32 then U.fail("too-large") end
  if sections>1 then
    local nodes,flows,ports={},{},{}
    for section=1,sections do
      for _,node in ipairs(plan.nodes) do
        local n=U.copy(node);n.id=node.id.."/"..section;n.section=section;n.crafts=node.crafts/sections
        n.count=math.max(1,math.ceil(n.crafts*n.energy/(60*n.speed)-1e-8));n.input={};n.output={}
        for k,a in pairs(node.input) do n.input[U.stream(k,section)]=a end
        for k,a in pairs(node.output) do n.output[U.stream(k,section)]=a end
        nodes[#nodes+1]=n
      end
      for k,f in pairs(plan.flows) do
        local key=U.stream(k,section);local copy=U.copy(f);copy.key=key;copy.section=section
        for _,field in ipairs({"demand","internal","supply","fuel","seed","external","surplus"}) do copy[field]=f[field]/sections end
        -- Default thresholds are per section; geometry refines them after routing.
        copy.low=math.max(1,math.ceil(copy.seed+copy.demand/6));copy.high=math.max(copy.low+1,math.ceil(copy.low+copy.demand/6))
        flows[key]=copy
      end
      for _,port in ipairs(plan.ports) do
        local copy=U.copy(port);copy.key=U.stream(port.key,section);copy.id=port.kind.."/"..copy.key
        copy.rate=port.rate/sections;copy.section=section;ports[#ports+1]=copy
      end
    end
    plan.nodes,plan.flows,plan.ports=nodes,flows,ports
  end
  plan.sections=sections
  table.sort(plan.ports,function(a,b)
    if a.kind~=b.kind then return a.kind<b.kind end
    local ak,bk=U.base_key(a.key),U.base_key(b.key)
    if ak~=bk then return ak<bk end
    return (a.section or 1)<(b.section or 1)
  end)
  A.order(plan);A.ports(plan,s,A.rows(plan))
  return plan
end
return P
