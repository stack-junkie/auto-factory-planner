local U=require('scripts.util')
local C=require('scripts.catalogue')
local F=require('scripts.flow_plan')
local I=require('scripts.inserters')
local Belts=require('scripts.belt_sizing')
local P={}
function P.accepts(plan,s)
  if s.mode=='mall'or s.layout_search~=true and #plan.nodes~=1 or s._legacy_layout or s._legacy_rate then return false end
  local override=s.infrastructure and s.infrastructure.inserter
  if override then local p=prototypes.entity[override]
    if not p or not I.supported(p)or math.floor(-p.inserter_pickup_position[2]+.5)~=1 or math.floor(p.inserter_drop_position[2]+.5)~=1 then return false end
  end
  for _,f in pairs(plan.flows)do
    local export_only=f.internal_export and not f.bootstrap and f.external<1e-6 and f.surplus<1e-6
    if f.bootstrap or f.controlled and not export_only or f.surplus>1e-6 then return false end
  end
  for _,n in ipairs(plan.nodes)do
    local machine=prototypes.entity[n.machine]
    if n.fuel or machine.tile_width<2 or machine.tile_height<2 then return false end
    local items=0;for key in pairs(n.output)do if U.split(key)=='item'then items=items+1 end end
    if items>1 then return false end
  end
  return true
end
-- A shared belt feeds both ingredients through the same row of inserters.
-- Size that row after direct insertion and belt partitions have been assigned.
local function size_mixed_feeds(c,s,plan,belt)
  local pool
  local lane_capacity=belt.belt_speed*14400
  for _,node in ipairs(plan.nodes)do
    local inputs=U.sorted(node.input)
    local a,b=inputs[1],inputs[2]
    if #inputs==2 and U.split(a)=='item' and U.split(b)=='item'
      and not plan.direct_keys[a] and not plan.direct_keys[b]
      and U.split(next(node.output))=='item' and #U.sorted(node.output)==1 then
      local rate_a=node.crafts*node.input[a]
      local rate_b=node.crafts*node.input[b]
      if math.max(rate_a,rate_b)<=lane_capacity+1e-6 then
        pool=pool or I.short_options(c,s)
        local arm=pool[#pool]
        local slots=c.machines[node.machine].tile_width
        local capacity=slots*math.min(I.capacity(arm,c,a,2),I.capacity(arm,c,b,2))
        local count=math.ceil((rate_a+rate_b)/capacity-1e-8)
        if count>node.count then
          if plan.full_belt_collectors then
            local key=next(node.output)
            if node.output[key]*node.crafts>lane_capacity+1e-6 and count%2==1 then count=count+1 end
          end
          if count>300 then U.fail('too-large') end
          for key,amount in pairs(node.input)do
            plan.flows[key].seed=plan.flows[key].seed+amount*(count-node.count)
          end
          node.count=count
        end
      end
    end
  end
end
function P.prepare(c,s,plan)
  if plan.rate_search then return plan end
  plan.rate_search=true;plan.sections=1;plan.local_items={}
  -- A belt-fed intermediate at its exact theoretical limit has no margin
  -- for inserter stops or filling the consumer buffers. Reserve one machine,
  -- keeping the requested flow balance. Exact direct-feed ratios stay intact.
  local finals={};for _,target in ipairs(plan.targets)do finals[target.key]=true end
  for _,n in ipairs(plan.nodes)do
    local capacity=n.count*60*n.speed/n.energy
    if n.crafts>capacity*.95 and #U.sorted(n.output)==1 then
      local key=U.sorted(n.output)[1];local consumers,sole=0,nil
      for _,other in ipairs(plan.nodes)do if other.input[key]then consumers=consumers+1;sole=other end end
      local inputs=U.sorted(n.input)
      local direct=consumers==1 and #inputs==1 and U.split(key)=='item'and U.split(inputs[1])=='item'and n.output[key]>n.input[inputs[1]]and n.count>=sole.count
        and c.machines[n.machine].tile_width==c.machines[sole.machine].tile_width and not plan.flows[key].internal_export
      local direct_input=false
      for _,source in ipairs(plan.nodes)do if source~=n then
        local ins,outs=U.sorted(source.input),U.sorted(source.output)
        if #ins==1 and #outs==1 and n.input[outs[1]]and source.output[outs[1]]>source.input[ins[1]]and source.count>=n.count then direct_input=true end
      end end
      if (consumers>0 or finals[key])and not direct and not direct_input and n.count<300 then
        n.count=n.count+1;n.transport_reserve=true
      end
    end
  end
  -- A long hand often transfers a partial stack into a fast recipe's small
  -- input buffer. Reserve edge capacity for three-ingredient belt-fed cells.
  local long=C.options(c,'inserter',function(p)return p.get_inserter_rotation_speed('normal')end)
  for _,n in ipairs(plan.nodes)do
    local keys=U.sorted(n.input);local solid=true;for _,key in ipairs(keys)do if U.split(key)~='item'then solid=false end end
    if solid and #keys==3 then
      local capacity=0
      for _,arm in ipairs(long)do if I.supported(arm)and math.floor(-arm.inserter_pickup_position[2]+.5)==2 and math.floor(arm.inserter_drop_position[2]+.5)==2 then
        local value=math.huge;for _,key in ipairs(keys)do value=math.min(value,I.capacity(arm,c,key))end;capacity=math.max(capacity,value*.5)
      end end
      if capacity>0 then
        local load=0;for _,amount in pairs(n.input)do load=math.max(load,amount*n.crafts)end
        n.count=math.max(n.count,math.ceil(load/capacity-1e-8));if n.count>300 then U.fail('too-large')end
      end
    end
  end
  -- A single recipe uses a collector that fills both belt lanes. Keep its
  -- interface intact up to the whole belt capacity, including the exact limit.
  plan.full_belt_collectors=#plan.nodes==1
  if plan.full_belt_collectors then for _,side in ipairs({plan.nodes[1].input,plan.nodes[1].output})do for key in pairs(side)do
    if U.split(key)~='item'then plan.full_belt_collectors=false end
  end end end
  local belt=Belts.planning(c,plan,plan.full_belt_collectors,s);plan.belt=belt.name
  if plan.full_belt_collectors then
    local n=plan.nodes[1];local key=U.sorted(n.output)[1]
    if U.split(key)=='item'and n.output[key]*n.crafts>belt.belt_speed*14400+1e-6 and n.count%2==1 and n.count<300 then n.count=n.count+1 end
  end
  -- Partition only the streams which exceed a belt, retaining partial loads.
  F.partition(c,s,plan,{})
  plan.direct_keys={}
  for _,source in ipairs(plan.nodes)do
    local input,output=U.sorted(source.input),U.sorted(source.output)
    if #input==1 and #output==1 and U.split(input[1])=='item'and U.split(output[1])=='item'then
      local list={};for _,target in ipairs(plan.nodes)do if target.input[output[1]]then list[#list+1]=target end end
      if #list==1 and not plan.flows[output[1]].internal_export then
        local target=list[1];local dry=true;for _,side in ipairs({target.input,target.output})do for key in pairs(side)do if U.split(key)~='item'then dry=false end end end
        local a,b=source.count,target.count;local x,y=a,b;while y~=0 do x,y=y,x%y end;a,b=a/x,b/x
        local width=c.machines[source.machine].tile_width
        local fanout=s.growth_direction and source.count==1 and target.count==2 and width>=2
        if fanout then
          local capacity=0
          for _,arm in ipairs(C.options(c,'inserter'))do if I.supported(arm)and math.floor(-arm.inserter_pickup_position[2]+.5)==1 and math.floor(arm.inserter_drop_position[2]+.5)==1
            and(not(s.infrastructure and s.infrastructure.inserter)or s.infrastructure.inserter==arm.name)then capacity=math.max(capacity,I.direct_capacity(arm,c,output[1]))end end
          fanout=target.input[output[1]]*target.crafts/target.count<=math.floor(width/2)*capacity+1e-6
        end
        local supported=source.output[output[1]]>source.input[input[1]]and(a==1 and b==1 or a==2 and b==1 or a==3 and b==2 or target.count==1 and source.count<=3)or fanout
        if supported and dry and width==c.machines[target.machine].tile_width and(source.count>=target.count or fanout)
          and math.abs(source.output[output[1]]*source.crafts-target.input[output[1]]*target.crafts)<1e-6 then
          source.local_supply=true;source.direct_target=target.id;plan.direct_keys[output[1]]=true;plan.local_items[output[1]]=true
          source.direct_fanout=fanout or nil
        end
      end
    end
  end
  size_mixed_feeds(c,s,plan,belt)
  return plan
end
return P
