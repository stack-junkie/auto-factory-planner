local U=require('scripts.util')
local L={}
function L.eligible(n,plan)
  local inputs,outputs=U.sorted(n.input),U.sorted(n.output)
  local key=outputs[1];local f=plan.flows[key]
  return #inputs==1 and #outputs==1 and not n.fuel and inputs[1]~=key
    and U.split(inputs[1])=='item' and U.split(key)=='item' and n.output[key]>n.input[inputs[1]]
    and n.energy/n.speed<=1+1e-6 and not f.bootstrap and not f.controlled and f.surplus<1e-6
end
function L.prepare(plan,s)
  if plan.local_supplies or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout then return end
  -- Visit consumers first so a chain of fast auxiliary recipes can be
  -- expanded into private, direct-only streams without changing raw demand.
  local original,nodes={},{};for _,n in ipairs(plan.nodes)do original[#original+1]=n;nodes[#nodes+1]=n end
  local serial=100000000;plan.direct_keys={}
  for i=#original,1,-1 do local n=original[i]
    local inputs,outputs=U.sorted(n.input),U.sorted(n.output)
    local key=outputs[1];local f=plan.flows[key]
    local localise=L.eligible(n,plan)
    local consumers={}
    if localise then for _,other in ipairs(nodes)do if other~=n and other.input[key]then consumers[#consumers+1]=other end end end
    if #consumers>0 then
      local crafts,count,old_count=0,0,n.count;local copies={}
      for _,consumer in ipairs(consumers)do
        serial=serial+1;local stream=U.stream(key,serial);local amount=consumer.input[key]*consumer.crafts
        local copy=U.copy(n);copy.id=n.id..'/local/'..consumer.id;copy.crafts=amount/n.output[key]
        copy.count=math.max(1,math.ceil(copy.crafts*n.energy/(60*n.speed)-1e-8));copy.output={[stream]=n.output[key]}
        if s.mode~='mall'then copy.count=math.max(copy.count,consumer.count)end
        copy.mall_final=nil;copy.local_supply=true;copy.direct_target=consumer.id
        consumer.input[stream]=consumer.input[key];consumer.input[key]=nil
        local flow=U.copy(f);flow.key=stream;flow.demand=amount;flow.internal=amount;flow.supply=amount;flow.seed=consumer.input[stream]*consumer.count
        flow.external=0;flow.surplus=0;flow.fuel=0
        plan.flows[stream]=flow;plan.direct_keys[stream]=true;copies[#copies+1]=copy
        crafts=crafts+copy.crafts;count=count+copy.count
      end
      if n.mall_final then
        n.crafts=math.max(0,n.crafts-crafts);n.count=1;copies[#copies+1]=n;count=count+1
        f.supply=n.output[key]*n.crafts;f.internal=0;f.demand=f.supply;f.seed=0;f.recycle=false
      else plan.flows[key]=nil end
      plan.flows[inputs[1]].seed=plan.flows[inputs[1]].seed+n.input[inputs[1]]*(count-old_count)
      local next_nodes={}
      for _,other in ipairs(nodes)do if other==n then for _,copy in ipairs(copies)do next_nodes[#next_nodes+1]=copy end else next_nodes[#next_nodes+1]=other end end
      nodes=next_nodes
    end
  end
  plan.nodes=nodes;plan.local_supplies=true
end
return L
