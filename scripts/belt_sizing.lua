local U=require('scripts.util')
local C=require('scripts.catalogue')
local G=require('scripts.geometry')
local B={}
local eps=1e-6
local kinds={['transport-belt']=true,['underground-belt']=true,splitter=true}
local function speed(p)return p.belt_speed end
function B.legacy(s)
  for key,value in pairs(s or{})do if type(key)=='string'and key:match('^_legacy_')and value then return true end end
  return false
end
function B.ceiling(c,s)
  if B.legacy(s)then return C.pick(c,'transport-belt',s.infrastructure and s.infrastructure.belt,nil,speed)end
  local pool=C.options(c,'transport-belt',speed)
  if #pool==0 then U.fail('missing-infrastructure','transport-belt')end
  return pool[#pool]
end
-- This is a routing capacity, not the equipment bill. Individual entities
-- are sized after every inserter, junction and external extension is known.
function B.planning(c,plan,full,s)
  if B.legacy(s)then return B.ceiling(c,s)end
  local required=0
  for key,f in pairs(plan.flows)do if U.split(key)=='item'then
    local divisor=full==true and 28800 or type(full)=='table'and full[key]and 28800*.8 or 14400*.8
    required=math.max(required,(f.external or f.demand or 0)/28800,(f.supply or 0)/divisor)
  end end
  local pool=C.options(c,'transport-belt',speed)
  for _,p in ipairs(pool)do if p.belt_speed>=required-1e-12 then return p end end
  return B.ceiling(c)
end
local function labelled(e,key)
  local text=e.tags and e.tags.afp_stream
  if not text then return true end
  for value in text:gmatch('[^|]+')do if value==key then return true end end
  return false
end
local function graph()
  local a={};local n=0
  local function node()n=n+1;a[n]={};return n end
  local function edge(u,v,cap,cost)
    local f={to=v,cap=cap,cost=cost or 0,initial=cap,reverse=#a[v]+1}
    local r={to=u,cap=0,cost=-(cost or 0),reverse=#a[u]+1}
    a[u][#a[u]+1]=f;a[v][#a[v]+1]=r;return f
  end
  return a,node,edge
end
-- Successive shortest augmenting paths. Residual edges let another pickup
-- rebalance both sides of a belt instead of permanently using the first lane.
local function send(a,source,sink,required)
  local sent=0
  while sent<required-eps do
    local distance,prev,queued={[source]=0},{},{[source]=true};local queue={source};local head=1
    while head<=#queue do
      local u=queue[head];head=head+1;queued[u]=nil
      for i,e in ipairs(a[u])do if e.cap>eps then
        local d=distance[u]+e.cost
        if not distance[e.to]or d<distance[e.to]-1e-9 then
          distance[e.to]=d;prev[e.to]={u,i}
          if not queued[e.to]then queue[#queue+1]=e.to;queued[e.to]=true end
        end
      end end
    end
    if not prev[sink]then break end
    local amount=required-sent;local v=sink
    while v~=source do local p=prev[v];amount=math.min(amount,a[p[1]][p[2]].cap);v=p[1]end
    v=sink
    while v~=source do local p=prev[v];local e=a[p[1]][p[2]];e.cap=e.cap-amount;a[v][e.reverse].cap=a[v][e.reverse].cap+amount;v=p[1]end
    sent=sent+amount
  end
  return sent
end
function B.apply(c,g,plan)
  plan.belt_flow={direction='source-to-consumer',networks={}}
  local pools={};for kind in pairs(kinds)do pools[kind]=C.options(c,kind,speed)end
  local pieces,at,byid,loads,minimum={},{},{},{},{}
  local balanced={}
  for _,port in ipairs(plan.ports)do if port.kind=='out'and port.balanced_export then balanced[U.base_key(port.key)]=port.rate end end
  local function cell(x,y)return G.cell(math.floor(x),math.floor(y))end
  for _,e in ipairs(g.entities)do
    byid[e.entity_number]=e
    local p=prototypes.entity[e.name]
    if kinds[p.type]then
      local d=(e.direction or 0)/4;local count=p.type=='splitter'and 2 or 1
      local parts={};pieces[e.entity_number]=parts;loads[e.entity_number]={}
      for half=1,count do
        local offset=count==2 and(half==1 and -.5 or .5)or 0
        local part={entity=e,kind=p.type,d=d,x=math.floor(e.position.x-G.dy[d+1]*offset),y=math.floor(e.position.y+G.dx[d+1]*offset),half=half}
        parts[#parts+1]=part;at[G.cell(part.x,part.y)]=part;loads[e.entity_number][half]={0,0,0,0}
      end
    end
  end
  local pairs_,paired={},{}
  for _,t in ipairs(g.tunnels)do if t.kind=='item'then
    local a=at[G.cell(t.horizontal and t.lo or t.x,t.horizontal and t.y or t.lo)]
    local b=at[G.cell(t.horizontal and t.hi or t.x,t.horizontal and t.y or t.hi)]
    if a and b then
      if a.entity.type=='output'then a,b=b,a end
      pairs_[#pairs_+1]={a=a,b=b,length=t.hi-t.lo};paired[a.entity.entity_number]=b;paired[b.entity.entity_number]=a
    end
  end end
  -- Some legacy collectors predate geometry tunnel records.
  for _,parts in pairs(pieces)do local a=parts[1]
    if a.kind=='underground-belt'and a.entity.type=='input'and not paired[a.entity.entity_number]then
      for length=1,prototypes.entity[a.entity.name].max_underground_distance do
        local b=at[G.cell(a.x+G.dx[a.d+1]*length,a.y+G.dy[a.d+1]*length)]
        if b and b.entity.name==a.entity.name and b.d==a.d and b.kind=='underground-belt'then
          if b.entity.type=='output'then pairs_[#pairs_+1]={a=a,b=b,length=length};paired[a.entity.entity_number]=b;paired[b.entity.entity_number]=a end
          break
        end
      end
    end
  end
  local machine={};local nodes={};local shared_inputs,feed_loads={},{}
  for _,n in ipairs(plan.nodes)do nodes[n.id]=n end
  for _,row in ipairs(plan.production_rows or{})do
    local n=nodes[row.node]
    if plan.rate_search and not plan.full_belt_collectors and row.shared_row and n then
      for key in pairs(n.input)do shared_inputs[U.base_key(key)]=true end
    end
    local allocated=n
    if n and row.crafts_per_machine then
      allocated={input=n.input,output=n.output,crafts=row.crafts_per_machine,count=1,fuel=n.fuel,fuel_per_craft=n.fuel_per_craft}
    end
    for _,id in ipairs(row.machines)do machine[id]=allocated end
  end
  local stocks={};for _,b in ipairs(plan.mall_buffers or{})do stocks[b.chest]=b end
  local targets={};for _,t in ipairs(plan.targets)do targets[U.base_key(t.key)]=t.rate end
  local keys={};for key in pairs(plan.flows)do if U.split(key)=='item'then keys[U.base_key(key)]=true end end
  for _,key in ipairs(U.sorted(keys))do
    local a,node,edge=graph();local source,sink=node(),node();local bn,inventory,inputs,outputs={},{},{},{}
    local meters={};local required,demanded=0,0
    local function supply(v,rate)if rate>eps then edge(source,v,rate);required=required+rate end end
    local function demand(v,rate)if rate>eps then edge(v,sink,rate);demanded=demanded+rate end end
    local function lane(part,index,input)
      local value=bn[part.entity.entity_number];return value and value[part.half][index+(input and 0 or 2)]
    end
    for _,e in ipairs(g.entities)do local parts=pieces[e.entity_number]
      if parts and labelled(e,key)then
        bn[e.entity_number]={}
        for half,part in ipairs(parts)do
          local v={node(),node(),node(),node()};bn[e.entity_number][half]=v
          for side=1,2 do
            -- A splitter has independent incoming and outgoing lane limits.
            -- Both halves preserve left/right lanes when distributing items.
            local mid=part.kind=='splitter'and node()or v[side+2]
            local function capacity(u,z,slot)
              local used=loads[e.entity_number][half][slot];local previous=0;local refs={}
              for tier,p in ipairs(pools[part.kind])do
                local limit=p.belt_speed*14400
                local cap=math.max(0,limit-math.max(previous,used));previous=math.max(previous,limit)
                if cap>eps then refs[#refs+1]=edge(u,z,cap,(tier-1)*1000+.001)end
              end
              meters[#meters+1]={id=e.entity_number,half=half,slot=slot,refs=refs}
            end
            capacity(v[side],mid,side)
            if part.kind=='splitter'then
              local outlet=node();v[side+4]=mid;v[side+6]=outlet;capacity(outlet,v[side+2],side+2)
            end
          end
        end
        if parts[1].kind=='splitter'then
          for half=1,2 do for side=1,2 do for other=1,2 do
            local v,z=bn[e.entity_number][half],bn[e.entity_number][other]
            edge(v[side+4],z[side+6],1e12,.001)
          end end end
        end
      end
    end
    local function emitting(p)return p.kind~='underground-belt'or p.entity.type=='output'end
    local function connects(p,q)
      return p and q and p~=q and emitting(p)and q.entity.type~='output'and q.d~=(p.d+2)%4
    end
    -- Surface adjacency, including turns and side loading. A single side
    -- connection without a rear feed bends a normal belt; its lanes persist.
    for _,parts in pairs(pieces)do for _,p in ipairs(parts)do if bn[p.entity.entity_number]and emitting(p)then
      local q=at[G.cell(p.x+G.dx[p.d+1],p.y+G.dy[p.d+1])]
      if connects(p,q)and bn[q.entity.entity_number]then
        local rear=at[G.cell(q.x-G.dx[q.d+1],q.y-G.dy[q.d+1])]
        local rear_feed=rear and rear.d==q.d and emitting(rear)
        local sides=0
        for _,d in ipairs({(q.d+1)%4,(q.d+3)%4})do local s=at[G.cell(q.x-G.dx[d+1],q.y-G.dy[d+1])]
          if s and s.d==d and emitting(s)then sides=sides+1 end
        end
        local bend=q.kind=='transport-belt'and not rear_feed and sides==1
        for side=1,2 do
          local into
          if p.d==q.d or bend then into=side else
            local cross=G.dx[q.d+1]*G.dy[p.d+1]-G.dy[q.d+1]*G.dx[p.d+1]
            into=cross>0 and 1 or 2
          end
          edge(lane(p,side,false),lane(q,into,true),1e12,.001)
        end
      end
    end end end
    for _,pair in ipairs(pairs_)do if bn[pair.a.entity.entity_number]and bn[pair.b.entity.entity_number]then
      for side=1,2 do edge(lane(pair.a,side,false),lane(pair.b,side,true),1e12,.001)end
    end end
    local function amount(side)
      local sum=0;for k,v in pairs(side)do if U.base_key(k)==key then sum=sum+v end end;return sum
    end
    for id,n in pairs(machine)do
      inputs[id]=node();outputs[id]=node()
      supply(outputs[id],amount(n.output)*n.crafts/n.count)
      demand(inputs[id],amount(n.input)*n.crafts/n.count+(n.fuel and key==U.key('item',n.fuel)and n.fuel_per_craft*n.crafts/n.count or 0))
    end
    for id,e in pairs(byid)do local t=prototypes.entity[e.name].type
      if t=='container'or t=='logistic-container'then inventory[id]=node()
        local b=stocks[id];if b and U.base_key(b.key)==key then demand(inventory[id],targets[key]or 0)end
      end
    end
    local function contact(e,pos,drop)
      local x,y=U.rotate(pos[1],pos[2],(e.direction or 0)/4)
      x=x+e.position.x;y=y+e.position.y
      local marker=g.occupied[cell(x,y)];if not marker then return{}end
      local target=marker.entity;local id=target.entity_number;local part=at[cell(x,y)]
      if part and bn[id]then
        if drop then
          local across=-(x-part.x-.5)*G.dy[part.d+1]+(y-part.y-.5)*G.dx[part.d+1]
          return{lane(part,across<-.01 and 1 or 2,true)}
        end
        return{lane(part,1,false),lane(part,2,false)}
      end
      local v=inventory[id]or(drop and inputs[id]or outputs[id]);return v and{v}or{}
    end
    for _,e in ipairs(g.entities)do local p=prototypes.entity[e.name]
      if p.type=='inserter'and labelled(e,key)then
        local from=contact(e,p.inserter_pickup_position,false);local to=contact(e,p.inserter_drop_position,true)
        for _,u in ipairs(from)do for _,v in ipairs(to)do edge(u,v,1e12,.01)end end
      end
    end
    for _,port in ipairs(plan.ports)do if U.base_key(port.key)==key then
      local p=port.local_position;local part=at[G.cell(p.x,p.y)]
      if part and bn[part.entity.entity_number]then local v=node()
        if port.kind=='in'then supply(v,port.rate);for side=1,2 do edge(v,lane(part,side,true),1e12)end
        else demand(v,port.rate);for side=1,2 do edge(lane(part,side,false),v,port.balanced_export and port.rate*.6 or 1e12)end end
      end
    end end
    local needed=math.max(required,demanded);local sent=send(a,source,sink,needed)
    plan.belt_flow.networks[key]={supply=required,demand=demanded,delivered=sent}
    if sent<needed-eps then if g.debug_layout then helpers.write_file('belt-flow-failure.json',helpers.table_to_json{key=key,required=needed,supply=required,demand=demanded,sent=sent,entities=g.entities,ports=plan.ports,nodes=plan.nodes,rows=plan.production_rows},false)end;log('AFP BELT FLOW '..key..' missing='..(needed-sent));U.fail('belt-flow',U.name(key),U.fmt(needed-sent))end
    local feeding={}
    for _,m in ipairs(meters)do local total=0;for _,e in ipairs(m.refs)do total=total+e.initial-e.cap end
      loads[m.id][m.half][m.slot]=loads[m.id][m.half][m.slot]+total
      if shared_inputs[key]then
        feeding[m.id]=feeding[m.id]or{};feeding[m.id][m.half]=feeding[m.id][m.half]or{0,0,0,0}
        feeding[m.id][m.half][m.slot]=total
      end
    end
    if balanced[key]then
      local threshold=balanced[key]*.4
      for id,halves in pairs(loads)do if bn[id]then for _,slots in ipairs(halves)do
        if math.max(slots[1]+slots[2],slots[3]+slots[4])>=threshold then minimum[id]=math.max(minimum[id]or 0,balanced[key]/2/.95)end
      end end end
    end
    -- A packed row's inserters prefer the near lane. A feasible assignment
    -- across two lanes does not guarantee that native pickups will balance it.
    -- Size its shared feed for that concentration, retaining two-lane output
    -- collectors and ordinary low-volume connections.
    for id,halves in pairs(feeding)do for _,slots in pairs(halves)do
      local ceiling=pools[pieces[id][1].kind];ceiling=ceiling[#ceiling].belt_speed*14400
      feed_loads[id]=math.max(feed_loads[id]or 0,math.min(ceiling,math.max(slots[1]+slots[2],slots[3]+slots[4])))
    end end
  end
  local needed={}
  for id,halves in pairs(loads)do local rate=feed_loads[id]or 0;for _,slots in ipairs(halves)do for _,load in ipairs(slots)do rate=math.max(rate,load)end end;needed[id]=rate end
  local function select(kind,rate,length)
    for _,p in ipairs(pools[kind])do if p.belt_speed*14400>=rate-eps and(not length or p.max_underground_distance>=length)then return p end end
    U.fail('missing-infrastructure',kind)
  end
  for _,pair in ipairs(pairs_)do
    local a,b=pair.a.entity,pair.b.entity
    local chosen=select('underground-belt',math.max(needed[a.entity_number],needed[b.entity_number],minimum[a.entity_number]or 0,minimum[b.entity_number]or 0),pair.length)
    a.name=chosen.name;b.name=chosen.name
  end
  plan.belt_loads={}
  for id,rate in pairs(needed)do local e=byid[id];local kind=pieces[id][1].kind
    local design=math.max(rate,minimum[id]or 0)
    if kind~='underground-belt'or not paired[id]then e.name=select(kind,design).name end
    plan.belt_loads[id]={lanes=loads[id],peak_lane=rate,design_lane=design,capacity_per_lane=prototypes.entity[e.name].belt_speed*14400}
  end
  plan.automatic_belts=true
end
return B
