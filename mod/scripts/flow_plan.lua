local U=require('scripts.util')
local Belts=require('scripts.belt_sizing')
local C=require('scripts.catalogue')
local Local=require('scripts.local_supplies')
local I=require('scripts.inserters')
local F={}
local eps=1e-6
local function fluid_capacity(nodes)
  for pass=1,#nodes do
    local demand,supply={},{ }
    for _,n in ipairs(nodes)do
      for key,a in pairs(n.input)do if U.split(key)=='fluid'then demand[key]=(demand[key]or 0)+a*n.count*60*n.speed/n.energy end end
      for key,a in pairs(n.output)do if U.split(key)=='fluid'then supply[key]=(supply[key]or 0)+a*n.count*60*n.speed/n.energy end end
    end
    local changed=false
    for _,key in ipairs(U.sorted(demand))do if supply[key]and demand[key]>supply[key]+eps then
      for _,n in ipairs(nodes)do if n.output[key]then
        n.count=n.count+math.ceil((demand[key]-supply[key])*n.energy/(n.output[key]*60*n.speed)-1e-8)
        n.installed_fluid_capacity=true;changed=true;break
      end end
    end end
    if not changed then break end
  end
end
function F.accepts(plan,s)
  if s.mode=='mall' or s._legacy_layout or s._legacy_rate or s._legacy_orientation then return false end
  local override=s.infrastructure and s.infrastructure.inserter
  if override then local p=prototypes.entity[override]
    if not p or not I.supported(p)or math.floor(-p.inserter_pickup_position[2]+.5)~=1 or math.floor(p.inserter_drop_position[2]+.5)~=1 then return false end
  end
  local fluid=false
  for key,f in pairs(plan.flows)do
    fluid=fluid or U.split(key)=='fluid'
    if f.bootstrap or f.controlled or f.surplus>eps then return false end
  end
  if not fluid then return false end
  local producers={};local solid=false
  for _,n in ipairs(plan.nodes)do
    if n.fuel then return false end
    local item_outputs=0;for key in pairs(n.output)do if U.split(key)=='item'then item_outputs=item_outputs+1 end end
    if item_outputs>1 then return false end
    local ordinary=true;for _,side in ipairs({n.input,n.output})do for key in pairs(side)do if U.split(key)=='fluid'then ordinary=false end end end
    solid=solid or ordinary
    for key in pairs(n.output)do producers[key]=producers[key]or{};producers[key][#producers[key]+1]=n end
  end
  if not solid then return false end
  local active,done={},{}
  local function visit(n)
    if active[n.id]then return false end;if done[n.id]then return true end;active[n.id]=true
    for key in pairs(n.input)do for _,p in ipairs(producers[key]or{})do if not visit(p)then return false end end end
    active[n.id]=nil;done[n.id]=true;return true
  end
  for _,n in ipairs(plan.nodes)do if not visit(n)then return false end end
  return true
end
function F.prepare(c,s,plan)
  if plan.flow_compact then return plan end
  plan.flow_compact=true;plan.sections=1
  local belt=Belts.planning(c,plan,false,s)
  plan.belt=belt.name;plan.local_items={}
  local nodes={};for _,n in ipairs(plan.nodes)do nodes[#nodes+1]=n end
  local serial=100000000
  -- Divide an expanding intermediate among its consumers, without duplicating
  -- unrelated recipes or rounding every machine bank up in every belt section.
  for _,n in ipairs(plan.nodes)do if Local.eligible(n,plan)then
    local key=U.sorted(n.output)[1];local consumers={}
    for _,target in ipairs(nodes)do if target~=n and target.input[key]then consumers[#consumers+1]=target end end
    if #consumers>0 then
      local replacements={}
      for _,target in ipairs(consumers)do
        serial=serial+1;local stream=U.stream(key,serial);local amount=target.input[key]*target.crafts
        local copy=U.copy(n);copy.id=n.id..'/local/'..target.id;copy.crafts=amount/n.output[key]
        copy.count=math.max(1,math.ceil(copy.crafts*n.energy/(60*n.speed)-1e-8));copy.output={[stream]=n.output[key]}
        copy.local_supply=true;copy.direct_target=target.id
        target.input[stream]=target.input[key];target.input[key]=nil
        local f=U.copy(plan.flows[key]);f.key=stream;f.demand=amount;f.internal=amount;f.supply=amount;f.external=0;f.surplus=0
        plan.flows[stream]=f;plan.local_items[stream]=true;replacements[#replacements+1]=copy
      end
      local next_nodes={};for _,old in ipairs(nodes)do if old==n then for _,copy in ipairs(replacements)do next_nodes[#next_nodes+1]=copy end else next_nodes[#next_nodes+1]=old end end
      nodes=next_nodes;plan.flows[key]=nil
    end
  end end
  plan.nodes=nodes
  local pool={};local override=s.infrastructure and s.infrastructure.inserter
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+.5)==1 and math.floor(p.inserter_drop_position[2]+.5)==1
      and(not override or p.name==override)then pool[#pool+1]=p end
  end
  local function capacity(key)local value=0;for _,p in ipairs(pool)do value=math.max(value,I.capacity(p,c,key))end;return value end
  for _,n in ipairs(nodes)do
    local p=c.machines[n.machine];local inputs,outputs={},{};local fluid=false
    for key,amount in pairs(n.input)do if U.split(key)=='item'then inputs[#inputs+1]={amount*n.crafts,capacity(key)}else fluid=true end end
    for key,amount in pairs(n.output)do if U.split(key)=='item'then outputs[#outputs+1]={amount*n.crafts,capacity(key)}else fluid=true end end
    if #inputs>p.tile_width or fluid and #inputs+#outputs>p.tile_width then U.fail('item-ports',p.localised_name)end
    while true do
      local ins,outs=0,0
      for _,v in ipairs(inputs)do if v[2]==0 then U.fail('missing-infrastructure','inserter')end;ins=ins+math.ceil(v[1]/(n.count*v[2])-1e-8)end
      for _,v in ipairs(outputs)do if v[2]==0 then U.fail('missing-infrastructure','inserter')end;outs=outs+math.ceil(v[1]/(n.count*v[2])-1e-8)end
      if ins<=p.tile_width and outs<=p.tile_height and(not fluid or ins+outs<=p.tile_width)then break end
      n.count=n.count+1;if n.count>3000 then U.fail('too-large')end
    end
  end
  -- Rounded consumers run at full speed while their belts are filling. Size
  -- shared fluid producers for that installed load so one overprovisioned
  -- consumer cannot starve its siblings during startup.
  fluid_capacity(nodes)
  return F.partition(c,s,plan,pool)
end
local function gcd(a,b)while b~=0 do a,b=b,a%b end;return a end
function F.groups(c,s,plan,pool)
  local producers,consumers,parent,sizes={},{},{},{}
  for _,n in ipairs(plan.nodes)do parent[n.id]=n.id;sizes[n.id]=n.count
    for key in pairs(n.output)do producers[key]=n end
    for key in pairs(n.input)do consumers[key]=consumers[key]or{};consumers[key][#consumers[key]+1]=n end
  end
  local function root(id)while parent[id]~=id do id=parent[id]end;return id end
  local function join(a,b)
    a,b=root(a),root(b);if a~=b then parent[a]=b;sizes[b]=sizes[a]+sizes[b]end
  end
  local function dry(n)
    for _,side in ipairs({n.input,n.output})do for key in pairs(side)do if U.split(key)=='fluid'then return false end end end
    return true
  end
  local existing={}
  for _,n in ipairs(plan.nodes)do
    if n.compact_group then
      if existing[n.compact_group]then join(n.id,existing[n.compact_group])else existing[n.compact_group]=n.id end
    elseif n.local_supply then join(n.id,n.direct_target)
    elseif dry(n)and n.count<=6 then for key in pairs(n.output)do
      local list=consumers[key]or{}
      if #list==1 and dry(list[1])and key~=plan.target and sizes[root(n.id)]+sizes[root(list[1].id)]<=48 then join(n.id,list[1].id);plan.local_items[key]=true end
    end end
  end
  local groups={}
  for _,n in ipairs(plan.nodes)do local id=root(n.id);groups[id]=groups[id]or{id=id,nodes={},local_keys={},direct={}}
    groups[id].nodes[#groups[id].nodes+1]=n
  end
  for key in pairs(plan.local_items)do local source=producers[key];local list=consumers[key]or{}
    if source and #list>0 then
      local group=groups[root(source.id)];local private=true
      for _,target in ipairs(list)do if root(target.id)~=root(source.id)then private=false end end
      if private then group.local_keys[key]=true end
      if #list==1 then
      local target=list[1]
      local copies=gcd(source.count,target.count);local a,b=source.count/copies,target.count/copies
      local p,q=c.machines[source.machine],c.machines[target.machine]
      -- Staggered banks require an overlapping inventory edge for every
      -- supplier and consumer. A slow consumer bank uses a local belt instead.
      local capacity=0;for _,arm in ipairs(pool)do capacity=math.max(capacity,I.direct_capacity(arm,c,key))end
      local pitch=math.max(p.tile_width,q.tile_width)+1;local shift=math.floor((a-b)*pitch/2)
      local feasible=source.local_supply and a>=2 and b>=2 and a<=6 and b<=6 and p.tile_width==q.tile_width
      if feasible then
        local source_rate=source.output[key]*source.crafts/source.count
        local target_rate=target.input[key]*target.crafts/target.count
        local remaining={};for j=1,b do remaining[j]=target_rate end
        for i=1,a do local supplied=source_rate
          for j=1,b do
            local lo=math.max((i-1)*pitch,shift+(j-1)*pitch);local hi=math.min((i-1)*pitch+p.tile_width-1,shift+(j-1)*pitch+q.tile_width-1)
            local rate=math.min(supplied,remaining[j],math.max(0,hi-lo+1)*capacity)
            supplied=supplied-rate;remaining[j]=remaining[j]-rate
          end
          if supplied>eps then feasible=false end
        end
        for _,v in ipairs(remaining)do if v>eps then feasible=false end end
      end
      if feasible then group.direct[#group.direct+1]={source=source,target=target,copies=copies,a=a,b=b,key=key}end
      end
    end
  end
  local ordered,active,done={},{},{}
  local function visit(id)
    if done[id]then return end;assert(not active[id],'Cyclic compact production group');active[id]=true
    for _,n in ipairs(groups[id].nodes)do for key in pairs(n.input)do local source=producers[key]
      if source and root(source.id)~=id then visit(root(source.id))end
    end end
    active[id]=nil;done[id]=true;ordered[#ordered+1]=groups[id]
  end
  local ids=U.sorted(groups)
  table.sort(ids,function(a,b)
    local function fluid(id)for _,n in ipairs(groups[id].nodes)do if not dry(n)then return true end end;return false end
    local af,bf=fluid(a),fluid(b);if af~=bf then return af end;return a<b
  end)
  for _,id in ipairs(ids)do visit(id)end
  return ordered
end
function F.partition(c,s,plan,pool)
  local groups=F.groups(c,s,plan,pool);local direct,owners,pairs_list={},{},{}
  for _,group in ipairs(groups)do
    for _,spec in ipairs(group.direct)do direct[spec.key]=true;pairs_list[#pairs_list+1]=spec end
    for _,n in ipairs(group.nodes)do owners[n.id]=group.id end
  end
  local belt=prototypes.entity[plan.belt];local lanes,normal,streams={},{},{};local serial=200000000;local split=false
  for _,key in ipairs(U.sorted(plan.flows))do local f=plan.flows[key]
    local output_capacity=belt.belt_speed*(plan.full_belt_collectors and 28800 or 14400*.8)
    local count=U.split(key)=='item'and math.max(1,math.ceil(math.max(f.supply/output_capacity,f.external/(belt.belt_speed*28800))-1e-8))or 1
    if count>32 then U.fail('too-large')end
    normal[key]=count;lanes[key]=direct[key]and 1 or count
  end
  local function copies(n)
    local value=1;for _,side in ipairs({n.input,n.output})do for key in pairs(side)do value=value*lanes[key]/gcd(value,lanes[key]);if value>32 then U.fail('too-large')end end end;return value
  end
  -- Use the same banks for every stream of a single-recipe factory.
  -- Independent input/output counts can multiply to an unnecessary LCM;
  -- merging banks on fewer output streams can overload one belt lane.
  if plan.full_belt_collectors and #plan.nodes==1 then
    local count=1
    for _,side in ipairs({plan.nodes[1].input,plan.nodes[1].output})do for key in pairs(side)do count=math.max(count,lanes[key])end end
    for _,side in ipairs({plan.nodes[1].input,plan.nodes[1].output})do for key in pairs(side)do lanes[key]=count end end
  end
  for pass=1,#pairs_list*2+1 do
    local changed=false
    for _,spec in ipairs(pairs_list)do if direct[spec.key]then
      local a,b=copies(spec.source),copies(spec.target)
      if a~=b or spec.copies%a~=0 then direct[spec.key]=nil;lanes[spec.key]=normal[spec.key];changed=true
      elseif lanes[spec.key]~=a then lanes[spec.key]=a;changed=true end
    end end
    if not changed then break end
  end
  for _,key in ipairs(U.sorted(plan.flows))do local count=lanes[key];streams[key]={}
    for i=1,count do
      if count==1 then streams[key][i]=key else serial=serial+1;streams[key][i]=U.stream(key,serial);split=true end
    end
  end
  if not split then return plan end
  local nodes,flows,ports,local_items={},{},{},{}
  for _,n in ipairs(plan.nodes)do
    local count=copies(n)
    for i=1,count do
      local copy=U.copy(n);copy.compact_group=owners[n.id]
      if count>1 then copy.id=n.id..'/bank/'..i end
      copy.crafts=n.crafts/count;copy.count=math.max(1,math.ceil(n.count/count-1e-8));copy.input={};copy.output={}
      for _,side in ipairs({{'input',n.input},{'output',n.output}})do for key,a in pairs(side[2])do copy[side[1]][streams[key][(i-1)%lanes[key]+1]]=a end end
      if n.local_supply and not direct[U.sorted(n.output)[1]]then
        -- Rounding split banks can break an exact direct-insertion ratio.
        -- Such banks must retain an ordinary transport connection instead.
        copy.local_supply=nil;copy.direct_target=nil;copy.compact_group=nil
      end
      nodes[#nodes+1]=copy
    end
  end
  for key,f in pairs(plan.flows)do for _,stream in ipairs(streams[key])do
    local copy=U.copy(f);copy.key=stream
    for _,field in ipairs({'demand','internal','supply','external','fuel','seed','surplus'})do copy[field]=(copy[field]or 0)/lanes[key]end
    flows[stream]=copy;if plan.local_items[key]then local_items[stream]=true end
  end end
  for _,p in ipairs(plan.ports)do for i,key in ipairs(streams[p.key])do
    local copy=U.copy(p);copy.key=key;copy.id=p.kind..'/'..key;copy.section=i;copy.rate=p.rate/lanes[p.key];ports[#ports+1]=copy
  end end
  if not plan.rate_search then fluid_capacity(nodes)end
  plan.nodes,plan.flows,plan.ports,plan.local_items=nodes,flows,ports,local_items
  plan.flow_partitions={}
  for key,count in pairs(lanes)do if count>1 then plan.flow_partitions[#plan.flow_partitions+1]={key=key,count=count,streams=streams[key]}end end
  return plan
end
return F
