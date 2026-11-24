local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local Mall=require('scripts.mall')
local CellLinks=require('scripts.cell_links')
local SharedFeed=require('scripts.shared_feed')
local RateCollectors=require('scripts.rate_collectors')
local FluidCells=require('scripts.fluid_cells')
local S={}
local eps=1e-6
local function pick(pool,c,keys,rate,direct)
  for _,p in ipairs(pool)do
    local capacity=math.huge
    for _,key in ipairs(keys)do capacity=math.min(capacity,(direct and I.direct_capacity or I.capacity)(p,c,key,#keys))end
    if capacity>=rate-eps then return p,capacity end
  end
end
local function adjacent(a,b)
  local slots={}
  for x=a.x,a.x+a.w-1 do
    if x>=b.x and x<b.x+b.w then
      if a.y+a.h+1==b.y then slots[#slots+1]={x=x,y=a.y+a.h,d=0}
      elseif b.y+b.h+1==a.y then slots[#slots+1]={x=x,y=b.y+b.h,d=8}end
    end
  end
  for y=a.y,a.y+a.h-1 do
    if y>=b.y and y<b.y+b.h then
      if a.x+a.w+1==b.x then slots[#slots+1]={x=a.x+a.w,y=y,d=12}
      elseif b.x+b.w+1==a.x then slots[#slots+1]={x=b.x+b.w,y=y,d=4}end
    end
  end
  return slots
end
local function order(group)
  local nodes={};for _,n in ipairs(group.nodes)do nodes[#nodes+1]=n end
  table.sort(nodes,function(a,b)return a.id<b.id end)
  if group.grouped then
    local weights,powers={},{}
    for i,a in ipairs(nodes)do powers[i]=2^(i-1);weights[i]={}
      for j,b in ipairs(nodes)do local value=0
        for _,pair in ipairs({{a,b},{b,a}})do for key in pairs(pair[1].output)do if pair[2].input[key]then
          value=value+(pair[1].local_supply and 100000 or 1000)+pair[2].input[key]*pair[2].crafts
        end end end
        for key in pairs(a.input)do if b.input[key]then value=value+0.1 end end
        weights[i][j]=value
      end
    end
    local states={};for i in ipairs(nodes)do states[powers[i]]={[i]={score=0,path=string.format('%02d',i)}}end
    local maximum=2^#nodes-1
    for mask=1,maximum do for i,state in pairs(states[mask]or{})do
      for j in ipairs(nodes)do if math.floor(mask/powers[j])%2==0 then
        local nextmask=mask+powers[j];states[nextmask]=states[nextmask]or{}
        local value=state.score+weights[i][j];local path=state.path..string.format('%02d',j);local old=states[nextmask][j]
        if not old or value>old.score+1e-7 or math.abs(value-old.score)<1e-7 and path<old.path then states[nextmask][j]={score=value,path=path}end
      end end
    end end
    local best
    for _,state in pairs(states[maximum])do
      if not best or state.score>best.score+1e-7 or math.abs(state.score-best.score)<1e-7 and state.path<best.path then best=state end
    end
    local result={};for token in best.path:gmatch('%d%d')do result[#result+1]=nodes[tonumber(token)]end;return result
  end
  local best,bestscore
  local function score(list)
    local score=0
    for j=2,#list do local a,b=list[j-1],list[j]
      for _,pair in ipairs({{a,b},{b,a}})do for key in pairs(pair[1].output)do if pair[2].input[key]then
        score=score+(pair[1].local_supply and 100000 or 1000)+pair[2].input[key]*pair[2].crafts
      end end end
    end
    return score
  end
  if #nodes<=7 then
    local function visit(list,used)
      if #list==#nodes then local value=score(list);if not bestscore or value>bestscore then best,bestscore={},value;for _,n in ipairs(list)do best[#best+1]=n end end;return end
      for i,n in ipairs(nodes)do if not used[i]then used[i]=true;list[#list+1]=n;visit(list,used);list[#list]=nil;used[i]=nil end end
    end
    visit({},{})
  end
  return best or nodes
end
local function positions(c,group)
  if group.compact_fanout then
    local source,target
    for _,n in ipairs(group.nodes)do if n.direct_fanout then source=n else target=n end end
    local p=c.machines[source.machine];local q=c.machines[target.machine]
    return{{node=source,x=math.floor(p.tile_width/2),y=0,side=-1},
      {node=target,x=0,y=p.tile_height+1,side=1},{node=target,x=q.tile_width,y=p.tile_height+1,side=1}}
  end
  local hub,ordinary,supplies=nil,0,{}
  for _,n in ipairs(group.nodes)do if not n.local_supply then ordinary=ordinary+1;hub=n end end
  if ordinary==1 and hub.count==1 then
    for _,n in ipairs(group.nodes)do if n.local_supply and n.direct_target==hub.id then for i=1,n.count do supplies[#supplies+1]=n end end end
    if #supplies==3 then
      local p=c.machines[hub.machine];local left=c.machines[supplies[1].machine];local top=c.machines[supplies[3].machine]
      local x=left.tile_width+1
      return {{node=supplies[1],x=0,y=0,side=1},{node=hub,x=x,y=0,side=1},
        {node=supplies[2],x=x+p.tile_width+1,y=0,side=1},{node=supplies[3],x=x,y=-top.tile_height-1,side=-1}}
    end
  end
  -- Dedicated producer/consumer banks retain overlapping edges for ratios
  -- such as three wire assemblers feeding two circuit assemblers.
  if #group.nodes==2 then
    for _,source in ipairs(group.nodes)do local target=group.nodes[1]==source and group.nodes[2]or group.nodes[1]
      local key=U.sorted(source.output)[1]
      if target.input[key]and target.count==1 and source.count>=2 and source.count<=3 and not source.mall_final then
        local a,b=c.machines[source.machine],c.machines[target.machine];local x=a.tile_width+1
        local side=source.count==3 and 1 or-1
        local result={{node=source,x=0,y=0,side=side},{node=target,x=x,y=0,side=side},{node=source,x=x+b.tile_width+1,y=0,side=side}}
        if source.count==3 then result[#result+1]={node=source,x=x,y=-a.tile_height-1,side=-1}end
        return result
      end
      if target.input[key]and source.count>=2 and target.count>=2 and not source.mall_final then
        local a,b=c.machines[source.machine],c.machines[target.machine];local result={}
        if group.touching and source.local_supply then
          local function gcd(x,y)while y~=0 do x,y=y,x%y end;return x end
          local copies=gcd(source.count,target.count);local na,nb=source.count/copies,target.count/copies
          local sp=a.tile_width;local tp=b.tile_width+(na>nb and 1 or 0)
          local extent=math.max(na*sp,(nb-1)*tp+b.tile_width);local shift=math.floor((extent-((nb-1)*tp+b.tile_width))/2)
          for unit=0,copies-1 do
            for i=1,na do result[#result+1]={node=source,x=unit*(extent+1)+(i-1)*sp,y=0,side=-1}end
            for i=1,nb do result[#result+1]={node=target,x=unit*(extent+1)+shift+(i-1)*tp,y=a.tile_height+1,side=1}end
          end
          return result
        end
        local pitch=math.max(a.tile_width,b.tile_width)+1
        for i=1,source.count do result[#result+1]={node=source,x=(i-1)*pitch,y=0,side=-1}end
        local shift=(source.count-target.count)*pitch/2
        for i=1,target.count do result[#result+1]={node=target,x=math.floor(shift)+(i-1)*pitch,y=a.tile_height+1,side=1}end
        return result
      end
    end
  end
  local result,x={},0;local sorted=order(group)
  local function stock_gap(n)
    if not group.grouped then return true end
    local key=U.sorted(n.output)[1];local count=0
    for _,other in ipairs(group.nodes)do if other.input[key]then count=count+1 end end
    return count==1
  end
  for i,n in ipairs(sorted)do
    local p=c.machines[n.machine]
    for copy=1,n.count do result[#result+1]={node=n,x=x,y=0,side=-1};x=x+p.tile_width+(group.touching and #sorted==1 and 0 or 1) end
    if n.mall_final and stock_gap(n)and sorted[i+1]and sorted[i+1].input[U.sorted(n.output)[1]]then x=x+2 end
    if sorted[i+1]and sorted[i+1].mall_final then
      local k=U.sorted(sorted[i+1].output)[1]
      if stock_gap(sorted[i+1])and n.input[k]then x=x+2 end
    end
  end
  return result
end
local function line(g,equipment,y,from,to,key,d,pickups)
  while not g:free(to,y)do to=to+1 end
  local x=from
  while x<=to do
    if g:free(x,y)then
      local blocked=x+1
      if blocked<=to and not g:free(blocked,y)then
        while blocked<=to and not g:free(blocked,y)do blocked=blocked+1 end
        -- One free cell between obstacles cannot be both the exit of one
        -- underground pair and the entrance of the next. Bridge both holes.
        while blocked<to and not g:free(blocked+1,y)do
          if pickups and pickups[G.cell(blocked,y)]then U.fail('item-ports',equipment.belt.localised_name)end
          blocked=blocked+1
          while blocked<=to and not g:free(blocked,y)do blocked=blocked+1 end
        end
        if blocked>to or blocked-x>equipment.underground.max_underground_distance then U.fail('infrastructure',equipment.underground.name)end
        g:tile(equipment.underground.name,x,y,d,{type=d==4 and 'input'or'output'},key)
        g:tile(equipment.underground.name,blocked,y,d,{type=d==4 and 'output'or'input'},key)
        g:tunnel('item',x,y,blocked,y);x=blocked+1
      else g:tile(equipment.belt.name,x,y,d,nil,key);x=x+1 end
    else U.fail('layout-ports')end
  end
  return to
end
local function build(c,s,group,short,targets,equipment,bus_order,tight,layout)
  local long={};local override=s.infrastructure and s.infrastructure.inserter
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+0.5)==2 and math.floor(p.inserter_drop_position[2]+0.5)==2 and(not override or override==p.name)then long[#long+1]=p end
  end
  local g=G.new();local machines,rows,stocks,links,terminals,corridors={},{},{},{},{},{}
  local collectors=s._defer_outputs and{}or nil
  local function arm(p,x,y,d,keys,output)
    local _,name=U.split(keys[1])
    return g:tile(p.name,x,y,d,output and p.filter_count>0 and {use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}}}or{use_filters=false},keys)
  end
  local rank={};for i,key in ipairs(bus_order or{})do rank[key]=i end
  local lane_capacity=equipment.belt.belt_speed*14400
  local function pack(raw)
    local keys=U.sorted(raw);local packed={}
    table.sort(keys,function(a,b)local ar,br=rank[a]or 100000,rank[b]or 100000;return ar==br and a<b or ar<br end)
    for _,key in ipairs(keys)do local previous=packed[#packed]
      if raw[key]>lane_capacity*2+eps then U.fail('item-ports',equipment.belt.localised_name)end
      if not s._separate_feeds and previous and #previous.keys==1 and raw[key]<=lane_capacity+eps and raw[previous.keys[1]]<=lane_capacity+eps then previous.keys[2]=key
      else packed[#packed+1]={keys={key}}end
    end
    return packed
  end
  local shared=layout and pack(layout.raw)
  local shared_feed=layout and not layout.collector
  if shared and(#shared==0 or #shared>(#long>0 and 3 or 1))then U.fail('item-ports',equipment.belt.localised_name)end
  local placement=layout and layout.positions or positions(c,group);local left=0
  if layout then for _,v in ipairs(placement)do
    if layout.collector then
      -- Feed from the outer edges; leave inserter/belt/inserter in the middle.
      v.side=v.bank==1 and -1 or 1
      v.y=v.bank==1 and -c.machines[v.node.machine].tile_height-1 or 2
    else
      v.side=v.bank==1 and 1 or-1
      v.y=v.bank==1 and -c.machines[v.node.machine].tile_height-1 or #shared+1
    end
  end end
  for _,v in ipairs(placement)do left=math.min(left,v.x)end
  for _,v in ipairs(placement)do v.x=v.x-left
    local n=v.node;local p=c.machines[n.machine];v.w=p.tile_width;v.h=p.tile_height
    local entity=g:add(p.name,v.x+v.w/2,v.y+v.h/2,0,{recipe=n.recipe,recipe_quality='normal'})
    local m={node=n,box=v,entity=entity,key=U.sorted(n.output)[1],need={},remaining=0,dual=layout~=nil,rate_cell=s.mode~='mall'}
    for key,amount in pairs(n.input)do m.need[key]=amount*n.crafts/n.count end
    m.remaining=n.output[m.key]*n.crafts/n.count
    local row={node=n.id,recipe=n.recipe,count=1,machines={entity.entity_number},input_inserters={},output_inserters={},mall_cell=true,straight_cell=true,
      bounds={x0=v.x-2,y0=v.y-4,x1=v.x+v.w+2,y1=v.y+v.h+4}}
    m.row=row;rows[#rows+1]=row;machines[#machines+1]=m
  end
  -- Put a stock chest on a dependency edge when that also enables direct
  -- chest-to-machine transfer; otherwise use the opposite side of the feeds.
  for _,m in ipairs(machines)do local target=m.node.mall_final and targets[U.base_key(m.key)]
    if target then
      local b=m.box;local candidates={}
      for _,other in ipairs(machines)do if other.need[m.key]then
        if other.box.x==b.x+b.w+3 and other.box.y==b.y then candidates[#candidates+1]={x=b.x+b.w,y=b.y+math.floor((b.h-1)/2),dx=1,dy=0,d=12}
        elseif b.x==other.box.x+other.box.w+3 and other.box.y==b.y then candidates[#candidates+1]={x=b.x-1,y=b.y+math.floor((b.h-1)/2),dx=-1,dy=0,d=4}end
      end end
      local edges=layout and b.side>0 and {{0,-1,8},{1,0,12},{-1,0,4}} or {{0,1,0},{1,0,12},{-1,0,4},{0,-1,8}}
      for _,edge in ipairs(edges)do
        for offset=0,(edge[1]==0 and b.w or b.h)-1 do
          candidates[#candidates+1]={x=edge[1]>0 and b.x+b.w or edge[1]<0 and b.x-1 or b.x+offset,
            y=edge[2]>0 and b.y+b.h or edge[2]<0 and b.y-1 or b.y+offset,dx=edge[1],dy=edge[2],d=edge[3]}
        end
      end
      local chosen
      for _,v in ipairs(candidates)do if g:free(v.x,v.y)and g:free(v.x+v.dx,v.y+v.dy)then chosen=v;break end end
      if not chosen then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
      local v=chosen;local selected=pick(short,c,{m.key},m.remaining)
      if not selected then U.fail('mall-final',c.machines[m.node.machine].localised_name)end
      local take=arm(selected,v.x,v.y,v.d,{m.key},true);local chest=Mall.chest(c,s,target.stacks)
      local box=g:tile(chest.name,v.x+v.dx,v.y+v.dy,0,{bar=target.stacks,tags={afp_mall={key=U.base_key(m.key),stacks=target.stacks}}},m.key)
      m.stock={x=v.x+v.dx,y=v.y+v.dy,w=1,h=1};m.chest=box
      m.row.output_inserters[#m.row.output_inserters+1]=take.entity_number
      stocks[#stocks+1]={key=U.base_key(m.key),stock=target.stock,stacks=target.stacks,chest=box.entity_number,inserter=take.entity_number}
      m.remaining=math.max(0,m.remaining-target.rate)
    end
  end
  local edges={}
  for _,a in ipairs(machines)do for _,b in ipairs(machines)do if a~=b and b.need[a.key]then
    for _,v in ipairs(adjacent(a.stock or a.box,b.box))do edges[#edges+1]={a=a,b=b,v=v,rate=b.need[a.key],stock=a.stock~=nil}end
    if group.grouped and a.stock then
      for _,v in ipairs(adjacent(a.box,b.box))do edges[#edges+1]={a=a,b=b,v=v,rate=b.need[a.key],stock=false}end
    end
  end end end
  table.sort(edges,function(a,b)if a.rate~=b.rate then return a.rate>b.rate end;if a.a.entity.entity_number~=b.a.entity.entity_number then return a.a.entity.entity_number<b.a.entity.entity_number end;return a.v.x==b.v.x and a.v.y<b.v.y or a.v.x<b.v.x end)
  for _,edge in ipairs(edges)do local a,b,v=edge.a,edge.b,edge.v;local key=a.key;local rate=math.min(a.remaining,b.need[key]or 0)
    if rate>eps and g:free(v.x,v.y)then
      local selected=pick(short,c,{key},rate,true)or short[#short];rate=math.min(rate,I.direct_capacity(selected,c,key))
      local e=arm(selected,v.x,v.y,v.d,{key},false);a.remaining=a.remaining-rate;b.need[key]=b.need[key]-rate
      b.row.input_inserters[#b.row.input_inserters+1]=e.entity_number
      if not edge.stock then a.row.output_inserters[#a.row.output_inserters+1]=e.entity_number end
      links[#links+1]={key=key,source=(edge.stock and a.chest or a.entity).entity_number,target=b.entity.entity_number,inserter=e.entity_number,rate=rate,stock=edge.stock}
    end
  end
  for _,m in ipairs(machines)do
    if m.node.local_supply and m.remaining>eps then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
    for key,rate in pairs(m.need)do if rate>eps and key:match('^item@100%d+:')then U.fail('item-ports',c.machines[m.node.machine].localised_name)end end
  end
  for _,m in ipairs(machines)do if s.mode=='mall'and m.remaining>eps and not m.stock then
    local selected=pick(short,c,{m.key},m.remaining);local b=m.box;local x=b.x
    if not selected then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
    local upper=layout and b.side>0;local ay=upper and b.y-1 or b.y+b.h;local cy=upper and ay-1 or ay+1
    while x<b.x+b.w and not(g:free(x,ay)and g:free(x,cy))do x=x+1 end
    if x==b.x+b.w then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
    local take=arm(selected,x,ay,upper and 8 or 0,{m.key},true);local chest=Mall.chest(c,s,1)
    local box=g:tile(chest.name,x,cy,0,{bar=1},m.key)
    m.export_inventory={x=x,y=cy,w=1,h=1};m.export_chest=box;m.row.output_inserters[#m.row.output_inserters+1]=take.entity_number
  end end
  local cell_links=CellLinks.add(g,c,group,machines,short,equipment,arm)
  local banks={}
  for _,m in ipairs(machines)do local b=m.box;local id=shared_feed and 'shared' or b.y..'/'..b.side
    banks[id]=banks[id]or{side=b.side,y=b.y,h=b.h,machines={},raw={}}
    local bank=banks[id];bank.machines[#bank.machines+1]=m
    for key,rate in pairs(m.need)do if rate>eps then bank.raw[key]=(bank.raw[key]or 0)+rate end end
  end
  local lanes={};local pickups={}
  for _,id in ipairs(U.sorted(banks))do local bank=banks[id];local packed=pack(bank.raw)
    local per_side=#long>0 and(group.grouped and 3 or 2)or 1
    if not tight and group.grouped and #packed>2 then U.fail('item-ports',c.machines[bank.machines[1].node.machine].localised_name)end
    if #packed>(group.grouped and 3 or 2)and group.parts and #group.parts>1 then U.fail('item-ports',c.machines[bank.machines[1].node.machine].localised_name)end
    if #packed>per_side and(#U.sorted(banks)>1 or #packed>per_side*2)then U.fail('item-ports',c.machines[bank.machines[1].node.machine].localised_name)end
    for i,lane in ipairs(packed)do
      local face={side=shared_feed and 0 or(i<=per_side and bank.side or-bank.side),y=bank.y,h=bank.h,machines=bank.machines,raw=bank.raw}
      local index=(i-1)%per_side+1
      local total=math.min(per_side,#packed-math.floor((i-1)/per_side)*per_side)
      if face.side>0 then index=total-index+1 end
      lane.y=shared_feed and i-1 or(face.side<0 and face.y-(tight and index+1 or index*2)or face.y+face.h-1+(tight and index+1 or index*2))
      lane.index=index;lane.bank=face;lanes[#lanes+1]=lane
      for _,m in ipairs(face.machines)do
        local needed,rate={},0
        for _,key in ipairs(lane.keys)do if(m.need[key]or 0)>eps then needed[#needed+1]=key;rate=rate+m.need[key]end end
        if rate>eps then
          local local_index=shared_feed and(m.box.side>0 and i or #packed-i+1)or index
          local side=shared_feed and m.box.side or face.side
          local pool=local_index==1 and short or long;local remaining=rate
          for offset=0,m.box.w-1 do if remaining>eps then
            -- A long inserter can reach the second adjacent belt from the
            -- same strip as the short inserter. Use separate positions in
            -- that strip instead of burying the first belt under its base.
            local reach=tight and math.max(1,local_index-1)or local_index
            local y=side<0 and m.box.y-reach or m.box.y+m.box.h+reach-1
            local x=m.box.x+offset
            if g:free(x,y)and not pickups[G.cell(x,y)]and g:free(x,lane.y)then
              local selected,capacity=pick(pool,c,needed,remaining)
              if not selected then selected=pool[#pool];if selected then capacity=math.huge;for _,key in ipairs(needed)do capacity=math.min(capacity,I.capacity(selected,c,key,#needed))end end end
              if selected then local e=arm(selected,x,y,side<0 and 0 or 8,needed,false);m.row.input_inserters[#m.row.input_inserters+1]=e.entity_number;pickups[G.cell(x,lane.y)]=true;lane.last_pickup=math.max(lane.last_pickup or x,x);remaining=remaining-capacity end
            end
          end end
          if remaining>eps then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
        end
      end
    end
  end
  if s.mode~='mall'then
    for _,terminal in ipairs(RateCollectors.add(g,c,machines,short,long,equipment,arm,line,lanes,pickups,s._forward_outputs,group.compact_fanout,collectors))do terminals[#terminals+1]=terminal end
  else
  local exports={}
  for _,m in ipairs(machines)do if m.remaining>eps then exports[m.key]=exports[m.key]or{};exports[m.key][#exports[m.key]+1]=m end end
  if layout and next(exports)then U.fail('item-ports',equipment.belt.localised_name)end
  if #U.sorted(exports)>1 then U.fail('item-ports',c.machines[machines[1].node.machine].localised_name)end
  for key,list in pairs(exports)do
    local y;local last,rate=-1,0
    for _,m in ipairs(list)do
      local b=m.export_inventory or m.stock or m.box;local x=b.x+math.floor((b.w-1)/2);local ay=b.y+b.h
      local pool=short;local drop=ay+1
      for _,lane in ipairs(lanes)do if lane.y==drop then pool=long;ay=ay+1;drop=drop+2;break end end
      if y and y~=drop then U.fail('item-ports',c.machines[m.node.machine].localised_name)end;y=drop
      local selected=pick(pool,c,{key},m.remaining)
      if not selected or not g:free(x,ay)then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
      local e=arm(selected,x,ay,0,{key},true);m.row.output_inserters[#m.row.output_inserters+1]=e.entity_number
      last=math.max(last,x);rate=rate+m.remaining
    end
    line(g,equipment,y,-1,last,key,12)
    local port={x=-2,y=y,d=3,plain=true,id='straight/export/'..key};g:reserve(port.x,port.y,port.id)
    terminals[#terminals+1]={key=key,port=port,rate=rate,produce=true}
  end
  end
  for i,lane in ipairs(lanes)do
    local last=assert(lane.last_pickup,'Ingredient belt has no pickup')
    last=line(g,equipment,lane.y,-1,last,lane.keys,4,pickups)
    local to={x=-2,y=lane.y,d=1,plain=true,id='straight/lane/'..i}
    g:reserve(to.x,to.y,to.id)
    if #lane.keys==1 then terminals[#terminals+1]={key=lane.keys[1],port=to,rate=lane.bank.raw[lane.keys[1]],produce=false}
    else terminals[#terminals+1]={keys=lane.keys,port=to,rates=lane.bank.raw,produce=false,mixed=true}end
    corridors[#corridors+1]={keys=lane.keys,x0=-1,x1=last,y=lane.y,side=lane.bank.side,shared_feed=layout~=nil}
  end
  return {g=g,rows=rows,stocks=stocks,links=links,cell_links=cell_links,terminals=terminals,straight_cell=true,corridors=corridors,collectors=collectors,compact_feeds=tight,dual_feed=layout~=nil}
end
function S.build(c,s,group,short,targets,equipment,bus_order)
  if #group.nodes==1 then
    local n=group.nodes[1];local inputs=U.sorted(n.input)
    if #inputs>c.machines[n.machine].tile_width and #inputs<=4 then
      -- Leave enough edge slots for both mixed ingredient pairs.
      local rank={};for i,key in ipairs(bus_order or{})do rank[key]=i end
      table.sort(inputs,function(a,b)return(rank[a]or 100000)==(rank[b]or 100000)and a<b or(rank[a]or 100000)<(rank[b]or 100000)end)
      local pools={short,{}}
      for _,arm in ipairs(C.options(c,'inserter'))do if I.supported(arm)and math.floor(-arm.inserter_pickup_position[2]+.5)==2 and math.floor(arm.inserter_drop_position[2]+.5)==2 then pools[2][#pools[2]+1]=arm end end
      local rates,capacities={},{}
      for group_index=1,2 do
        local keys={inputs[group_index*2-1],inputs[group_index*2]};rates[group_index]=0;capacities[group_index]=0
        for _,key in ipairs(keys)do rates[group_index]=rates[group_index]+n.input[key]*n.crafts end
        for _,arm in ipairs(pools[group_index])do local capacity=math.huge;for _,key in ipairs(keys)do capacity=math.min(capacity,I.capacity(arm,c,key,#keys))end;capacities[group_index]=math.max(capacities[group_index],capacity)end
        if capacities[group_index]==0 then U.fail('missing-infrastructure','inserter')end
      end
      while math.ceil(rates[1]/(n.count*capacities[1])-eps)+math.ceil(rates[2]/(n.count*capacities[2])-eps)>c.machines[n.machine].tile_width do
        n.count=n.count+1;if n.count>300 then U.fail('too-large')end
      end
      return FluidCells.build(c,s,group,short,equipment,bus_order)
    end
  end
  if not(s._legacy_branches or s._legacy_intake or s._legacy_straight or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout)then
    local ok,result=pcall(build,c,s,group,short,targets,equipment,bus_order,true)
    if ok then return SharedFeed.choose(c,s,group,result,function(c,part)part.touching=group.touching;return positions(c,part)end,function(layout)return build(c,s,group,short,targets,equipment,bus_order,true,layout)end)end
    -- Busy machines may need more inserter positions than fit in one strip.
    if type(result)~='table'or result[1]~='afp-error.item-ports'then error(result,0)end
    local separate=U.copy(s);separate._separate_feeds=true
    local fit,part=pcall(build,c,separate,group,short,targets,equipment,bus_order,true)
    if fit then return SharedFeed.choose(c,separate,group,part,function(c,unit)unit.touching=group.touching;return positions(c,unit)end,function(layout)return build(c,separate,group,short,targets,equipment,bus_order,true,layout)end)end
    if type(part)~='table'or part[1]~='afp-error.item-ports'then error(part,0)end
  end
  local ok,part=pcall(build,c,s,group,short,targets,equipment,bus_order,false)
  if ok then return part end
  if type(part)~='table'or part[1]~='afp-error.item-ports'then error(part,0)end
  if(s._legacy_intake or s._legacy_branches)and not(s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout)then
    local separate=U.copy(s);separate._separate_feeds=true
    return build(c,separate,group,short,targets,equipment,bus_order,true)
  end
  error(part,0)
end
return S
