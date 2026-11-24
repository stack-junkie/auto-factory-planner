local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local Belts=require('scripts.belt_sizing')
local S={}
local epsilon=1e-6
local function legacy(s)
  return s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout
end
local function spec(c,s,n,pool)
  if n.mall_final or n.fuel or n.count<2 or #U.sorted(n.input)~=1 or #U.sorted(n.output)~=1 then return end
  local input,output=U.sorted(n.input)[1],U.sorted(n.output)[1]
  if U.split(input)~='item' or U.split(output)~='item' then return end
  local p=c.machines[n.machine]
  if p.tile_width<2 or p.tile_height<2 then return end
  local required=n.input[input]*n.crafts/n.count;local produced=n.output[output]*n.crafts/n.count
  local feed,arms,take
  for count=1,p.tile_width do
    for _,candidate in ipairs(pool)do if I.capacity(candidate,c,input)*count>=required-epsilon then feed,arms=candidate,count;break end end
    if feed then break end
  end
  for _,candidate in ipairs(pool)do if I.capacity(candidate,c,output)>=produced-epsilon then take=candidate;break end end
  if not feed or not take then return end
  return {prototype=p,input=input,output=output,feed=feed,arms=arms,take=take,input_rate=required,output_rate=produced}
end
function S.balanceable(c,s,plan)
  local result={}
  if s.mode~='mall'and s._legacy_rate or legacy(s)then return result end
  for key,f in pairs(plan.flows)do if U.split(key)~='item'or f.bootstrap or f.controlled or f.surplus>epsilon then return result end end
  local producers={}
  for _,n in ipairs(plan.nodes)do
    local p=c.machines[n.machine]
    if n.fuel or #U.sorted(n.output)~=1 or not p or p.tile_width<2 or p.tile_height<2 then return result end
    for key in pairs(n.output)do producers[key]=producers[key]or{};producers[key][#producers[key]+1]=n end
  end
  local visiting,visited={},{}
  local function acyclic(n)
    if visited[n.id]then return true end
    if visiting[n.id]then return false end;visiting[n.id]=true
    for key in pairs(n.input)do for _,source in ipairs(producers[key]or{})do if not acyclic(source)then return false end end end
    visiting[n.id]=nil;visited[n.id]=true;return true
  end
  for _,n in ipairs(plan.nodes)do if not acyclic(n)then return result end end
  local belt=C.pick(c,'transport-belt',Belts.legacy(s)and s.infrastructure and s.infrastructure.belt or nil,nil,function(p)return p.belt_speed end)
  local lane_capacity=belt.belt_speed*14400
  local pool={};local override=s.infrastructure and s.infrastructure.inserter
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+0.5)==1 and math.floor(p.inserter_drop_position[2]+0.5)==1 and(not override or override==p.name)then pool[#pool+1]=p end
  end
  for _,n in ipairs(plan.nodes)do local v=spec(c,s,n,pool)
    if v and not producers[v.input]and(v.output_rate<=lane_capacity/2+epsilon or math.ceil(n.count/2)*v.output_rate<=lane_capacity+epsilon)then
      local count,dominant=0,false
      for _,other in ipairs(plan.nodes)do if other.input[v.output]then
        count=count+1
        if other.input[v.output]*other.crafts>=n.output[v.output]*n.crafts*0.8 then dominant=true end
      end end
      -- The clustering rules leave widely shared intermediates in their
      -- own cell. Only those guaranteed shared rows may use both output lanes.
      if count>=3 and not dominant then result[v.output]=true end
    end
  end
  return result
end
function S.capacity_keys(c,s,nodes,crafts)
  local plan={nodes={},flows={}}
  for j,node in ipairs(nodes)do
    local n=U.copy(node);n.crafts=crafts[j];n.count=math.max(1,math.ceil(n.crafts*n.energy/(60*n.speed)-1e-8));plan.nodes[#plan.nodes+1]=n
    for _,side in ipairs({n.input,n.output})do for key in pairs(side)do plan.flows[key]={surplus=0}end end
  end
  return S.balanceable(c,s,plan)
end
function S.build(c,s,group,pool,equipment,width)
  if legacy(s)or #group.nodes~=1 then return end
  if s.mode~='mall'and s.input_rows=='double'then return end
  local n=group.nodes[1];local v=spec(c,s,n,pool);if not v then return end
  local p=v.prototype;local pitch=p.tile_width+(group.touching and 0 or 1)
  local maximum=width and math.max(1,math.floor((width-4)/pitch))or n.count
  local g=G.new();local rows,terminals,balances={},{},{}
  local lane_capacity=equipment.belt.belt_speed*14400
  if v.output_rate>lane_capacity+epsilon then return end
  local total_rate=n.count*v.output_rate
  if total_rate>lane_capacity+epsilon and math.ceil(n.count/2)*v.output_rate>lane_capacity+epsilon then return end
  local half=math.ceil(n.count/2)
  local paired=s.growth_direction and not s._legacy_straight
  local done=0;local row_y=0
  while done<n.count do
    local count=math.min(maximum,n.count-done)
    -- Never overload a whole output belt, including a manually chosen tier.
    count=math.min(count,math.max(1,math.floor(lane_capacity*2/v.output_rate+epsilon)))
    local row={node=n.id,recipe=n.recipe,count=count,machines={},input_inserters={},output_inserters={},mall_cell=true,shared_row=true,pitch=pitch}
    local take_y=row_y+p.tile_height+1;local feed_y=row_y-2
    local positions={};local last_feed=-1
    for i=1,count do
      local x=(i-1)*pitch
      local machine=g:add(p.name,x+p.tile_width/2,row_y+p.tile_height/2,0,{recipe=n.recipe,recipe_quality='normal'})
      row.machines[#row.machines+1]=machine.entity_number
      local mirrored=paired and i%2==0
      for j=1,v.arms do
        local offset=paired and p.tile_width-j or(v.arms==1 and math.floor((p.tile_width-1)/2)or math.floor((j-1)*(p.tile_width-1)/(v.arms-1)))
        if mirrored then offset=p.tile_width-1-offset end
        local arm=g:tile(v.feed.name,x+offset,row_y-1,0,{use_filters=false},v.input)
        row.input_inserters[#row.input_inserters+1]=arm.entity_number
        last_feed=math.max(last_feed,x+offset)
      end
      local ax=x+(paired and(mirrored and 0 or p.tile_width-1)or math.floor((p.tile_width-1)/2));positions[i]=ax
      local _,name=U.split(v.output)
      local arm=g:tile(v.take.name,ax,row_y+p.tile_height,0,v.take.filter_count>0 and{use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}}}or{use_filters=false},v.output)
      row.output_inserters[#row.output_inserters+1]=arm.entity_number
    end
    local straight=not s._legacy_straight and not legacy(s)
    local forward=straight and s._forward_outputs and s._forward_outputs[v.output]
    local function output_x(x)return forward and positions[1]+positions[count]-x or x end
    -- An unsplit forward collector needs no two-tile tail before its socket.
    -- Start at the first real drop and leave only the routed outlet blank.
    local first_output=forward and total_rate<=lane_capacity+epsilon and positions[1]or -1
    for x=straight and -1 or -2,last_feed do g:tile(equipment.belt.name,x,feed_y,4,nil,v.input)end
    if not straight then g:tile(equipment.belt.name,-2,feed_y-1,8,nil,v.input)end
    local split={};local total=count*v.output_rate
    if total_rate>lane_capacity+epsilon then
      -- Partition the whole bank between belt lanes, even when a width
      -- limit divides it into several rows that later share one trunk.
      local shifted=math.min(count,math.max(0,done+count-half))
      if shifted>0 then split[positions[count-shifted+1]-1]=true end
    end
    for x=positions[count],first_output,-1 do
      if split[x]then
        local splitter=g:add(equipment.splitter.name,output_x(x)+0.5,take_y,forward and 4 or 12,{output_priority=forward and'left'or'right'},v.output)
        g:tile(equipment.belt.name,output_x(x-1),take_y-1,8,nil,v.output)
        balances[#balances+1]={entity=splitter.entity_number,key=v.output,row=#rows+1,capacity=lane_capacity,rate=total,combined_rate=total_rate}
      else g:tile(equipment.belt.name,output_x(x),take_y,forward and 4 or 12,nil,v.output)end
    end
    local input={x=-2,y=straight and feed_y or feed_y-2,d=straight and 1 or 2,plain=true,id='shared/'..(#rows+1)..'/in'}
    local output={x=output_x(first_output-1),y=take_y,d=forward and 1 or 3,plain=true,id='shared/'..(#rows+1)..'/out'}
    for nudge=0,2 do g:reserve(input.x-(straight and nudge or 0),input.y-(straight and 0 or nudge),input.id);g:reserve(output.x+(forward and nudge or-nudge),output.y,output.id)end
    terminals[#terminals+1]={key=v.input,port=input,rate=v.input_rate*count,produce=false}
    terminals[#terminals+1]={key=v.output,port=output,rate=v.output_rate*count,produce=true,forward=forward}
    row.bounds={x0=-2,y0=feed_y-2,x1=math.max((count-1)*pitch+p.tile_width,output.x+1),y1=take_y+1}
    rows[#rows+1]=row;done=done+count;row_y=row_y+p.tile_height+9
  end
  return {g=g,rows=rows,stocks={},links={},terminals=terminals,shared_row=true,balances=balances}
end
return S
