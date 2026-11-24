local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local F=require('scripts.fluid_boxes')
local R=require('scripts.router')
local ItemExport=require('scripts.item_export')
local Cells={}
local eps=1e-6
function Cells.has_fluid(group)
  for _,n in ipairs(group.nodes)do for _,side in ipairs({n.input,n.output})do for key in pairs(side)do if U.split(key)=='fluid'then return true end end end end
  return false
end
local function ports(c,n,turn,mirror)
  local p=c.machines[n.machine];local r=c.recipes[n.recipe];local ingredients,products=r.ingredients,r.products;local assigned=F.assign(p,ingredients,products)
  if not assigned then U.fail('item-ports',p.localised_name)end
  local result={}
  for _,side in ipairs({{ingredients,true},{products,false}})do for _,v in ipairs(side[1])do if v.type=='fluid'then
    local key;for k in pairs(side[2]and n.input or n.output)do if U.base_key(k)==U.key('fluid',v.name)then key=k end end
    local best
    for _,box in pairs(p.fluidbox_prototypes)do if box.index==assigned[v]then for _,connection in ipairs(box.pipe_connections)do if connection.connection_type=='normal'then
      local pos=connection.positions[1];local x,y=pos.x,pos.y;local face=(connection.direction or 0)/4
      if mirror then x=-x;face=(-face)%4 end
      x,y=U.rotate(x,y,turn);face=(face+turn)%4
      local q={key=key,input=side[2],x=x+G.dx[face+1],y=y+G.dy[face+1],face=face}
      if not best or(face==(side[2]and 2 or 0)and best.face~=face)then best=q end
    end end end end
    if best then result[#result+1]=best end
  end end end
  return result
end
local function ground_direction(p,want)
  for _,box in pairs(p.fluidbox_prototypes)do for _,connection in pairs(box.pipe_connections)do if connection.connection_type=='normal'then
    return ((want-(connection.direction or 0)/4)%4)*4
  end end end
  return want*4
end
local function paired(c,n,p,w,h,turn,equipment,maximum)
  local count_banks=math.ceil(n.count/maximum)
  if count_banks<2 then U.fail('item-ports',p.localised_name)end
  local per_bank=math.ceil(n.count/count_banks)
  local normal=ports(c,n,turn,false);local opposite=(turn+2)%4;local reflected
  for _,mirror in ipairs({false,true})do if not mirror or p.use_mirroring then
    local matches=true;local candidates=ports(c,n,opposite,mirror)
    for _,q in ipairs(normal)do local found=false
      for _,other in ipairs(candidates)do if q.key==other.key and q.input==other.input
        and math.abs(q.x-other.x)<eps and math.abs(q.y+other.y)<eps and(q.face+2)%4==other.face then found=true end end
      if not found then matches=false end
    end
    if matches then reflected={mirror=mirror,ports=candidates};break end
  end end
  if not reflected then U.fail('item-ports',p.localised_name)end
  local keys={input={},output={}}
  for _,q in ipairs(normal)do local list=keys[q.input and'input'or'output'];list[#list+1]=q.key end
  if #keys.input==0 or #keys.output==0 then U.fail('item-ports',p.localised_name)end
  local part={g=G.new(),rows={},stocks={},links={},terminals={},corridors={},fluid_cell=true,local_routes={},cell_links={},facing_banks=true}
  local g=part.g;local banks,headers={},{}
  for i=1,count_banks do
    local start=0
    if i>1 then local input=(i-1)%2==1;local list=keys[input and'input'or'output'];start=banks[i-1].start+h+2*#list+1 end
    banks[i]={start=start,count=math.min(per_bank,n.count-(i-1)*per_bank)}
  end
  -- Alternating banks share their input headers, then their output headers.
  -- Matching ports face each other; only one set of tracks fills each gap.
  for boundary=0,count_banks do
    local input=boundary%2==1;local list=keys[input and'input'or'output']
    local header={input=input,tracks={},count=0,width=0}
    for _,i in ipairs(boundary==0 and{1}or boundary==count_banks and{count_banks}or{boundary,boundary+1})do
      header.count=header.count+banks[i].count;header.width=math.max(header.width,banks[i].count*w)
    end
    for ordinal,key in ipairs(list)do
      local y=boundary==0 and(-2-2*(ordinal-1))or banks[boundary].start+h+(boundary==count_banks and 2 or 1)+2*(ordinal-1)
      header.tracks[key]=y
    end
    headers[boundary]=header
  end
  for i,bank in ipairs(banks)do
    local reverse=i%2==0;local qs=reverse and reflected.ports or normal
    local row={node=n.id,recipe=n.recipe,count=bank.count,machines={},input_inserters={},output_inserters={},bus='recipe',pitch=w,fluid_cell=true,facing=true}
    part.rows[#part.rows+1]=row
    for machine=1,bank.count do
      local left=(machine-1)*w
      local e=g:add(p.name,left+w/2,bank.start+h/2,(reverse and opposite or turn)*4,
        {recipe=n.recipe,recipe_quality='normal',mirror=reverse and reflected.mirror or nil})
      row.machines[#row.machines+1]=e.entity_number
      for _,q in ipairs(qs)do
        local header=headers[q.face==0 and i-1 or i]
        local track=header.tracks[q.key];if not track or header.input~=q.input then U.fail('item-ports',p.localised_name)end
        local x,y=math.floor(left+w/2+q.x),math.floor(bank.start+h/2+q.y)
        local remote=track-G.dy[q.face+1]
        if y==remote then g:tile(equipment.pipe.name,x,y,0,nil,q.key)
        else
          if not g:tunnel_free('fluid',x,y,x,remote)then U.fail('item-ports',p.localised_name)end
          g:tile(equipment.pipeug.name,x,y,ground_direction(equipment.pipeug,(q.face+2)%4),nil,q.key)
          g:tile(equipment.pipeug.name,x,remote,ground_direction(equipment.pipeug,q.face),nil,q.key)
          g:tunnel('fluid',x,y,x,remote)
        end
      end
    end
    local y0,y1=bank.start,bank.start+h
    for _,header in ipairs({headers[i-1],headers[i]})do for _,y in pairs(header.tracks)do y0=math.min(y0,y);y1=math.max(y1,y+1)end end
    row.bounds={x0=-2,y0=y0,x1=bank.count*w,y1=y1}
  end
  for boundary=0,count_banks do local header=headers[boundary]
    for _,key in ipairs(keys[header.input and'input'or'output'])do local y=header.tracks[key]
      for x=-1,header.width-1 do g:tile(equipment.pipe.name,x,y,0,nil,key)end
      local port={x=-2,y=y,id='fluid/shared/'..n.id..'/'..boundary..'/'..key}
      g:reserve(port.x,port.y,port.id,key)
      part.terminals[#part.terminals+1]={key=key,port=port,produce=not header.input,fluid=true,shared=boundary>0 and boundary<count_banks,
        rate=(header.input and n.input[key]or n.output[key])*n.crafts*header.count/n.count}
    end
  end
  return part
end
local function build(c,s,n,pool,equipment,order,maximum,alternate,facing)
  local p=c.machines[n.machine];local turn,best
  for d=0,3 do
    local score=0
    for _,q in ipairs(ports(c,n,d,false))do if q.face~=(q.input and 2 or 0)then score=score+1 end end
    if not best or score<best then turn,best=d,score end
  end
  if best>0 then U.fail('item-ports',p.localised_name)end
  local w,h=p.tile_width,p.tile_height;if turn%2==1 then w,h=h,w end
  local rank={};for i,key in ipairs(order or{})do rank[key]=i end
  local inputs,outputs={},{}
  for _,side in ipairs({{n.input,inputs},{n.output,outputs}})do for key,amount in pairs(side[1])do if U.split(key)=='item'then side[2][#side[2]+1]={key=key,rate=amount*n.crafts/n.count}end end end
  table.sort(inputs,function(a,b)local ar,br=rank[a.key]or 100000,rank[b.key]or 100000;return ar==br and a.key<b.key or ar<br end)
  if #outputs>1 or #inputs>4 then U.fail('item-ports',p.localised_name)end
  local long={};local override=s.infrastructure and s.infrastructure.inserter
  for _,arm in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(arm)and math.floor(-arm.inserter_pickup_position[2]+.5)==2 and math.floor(arm.inserter_drop_position[2]+.5)==2 and(not override or override==arm.name)then long[#long+1]=arm end
  end
  -- The water inlet occupies one inserter tile on the machine edge. Choose
  -- which ingredients share a belt by the arms needed on the two feeds.
  -- Keep the existing lane order on ties.
  local split=2
  if #inputs>=3 and #long>0 then
    local function arms_needed(arms,items)
      local rate,best=0,0
      for _,item in ipairs(items)do rate=rate+item.rate end
      for _,candidate in ipairs(arms)do
        local capacity=math.huge
        for _,item in ipairs(items)do
          capacity=math.min(capacity,I.capacity(candidate,c,item.key,#items))
        end
        best=math.max(best,capacity)
      end
      return best>0 and math.ceil(rate/best-eps) or math.huge
    end
    local best=math.huge
    local original=inputs
    local function try(first,second)
      local near,far={},{}
      for i,item in ipairs(original)do
        local feed=(i==first or i==second)and near or far
        feed[#feed+1]=item
      end
      if #far>2 then return end
      local slots=arms_needed(pool,near)+arms_needed(long,far)
      if slots>=best then return end
      best=slots;split=#near;inputs=near
      for _,item in ipairs(far)do inputs[#inputs+1]=item end
    end
    try(1,2)
    for first=1,#original do
      try(first,nil)
      for second=first+1,#original do try(first,second) end
    end
  end
  local groups={};for i=1,#inputs do
    local index=i<=split and 1 or 2
    if not groups[index]then groups[index]={keys={},rate=0,rates={}}end
    local group=groups[index];local item=inputs[i]
    group.keys[#group.keys+1]=item.key;group.rate=group.rate+item.rate;group.rates[item.key]=item.rate
  end
  local lane=equipment.belt.belt_speed*14400
  local maximum=math.min(n.count,maximum)
  for _,v in ipairs(inputs)do maximum=math.min(maximum,math.max(1,math.floor(lane/v.rate+eps)))end
  for _,v in ipairs(outputs)do maximum=math.min(maximum,math.max(1,math.floor(lane*.8/v.rate+eps)))end
  if facing then
    if #inputs>0 or #outputs>0 then U.fail('item-ports',p.localised_name)end
    return paired(c,n,p,w,h,turn,equipment,maximum)
  end
  local g=G.new();local part={g=g,rows={},stocks={},links={},terminals={},corridors={},fluid_cell=true,local_routes={},cell_links={}}
  local bank_count=math.ceil(n.count/maximum);local per_bank=math.ceil(n.count/bank_count);local done,top=0,0
  local fluid_outputs=0;for key in pairs(n.output)do if U.split(key)=='fluid'then fluid_outputs=fluid_outputs+1 end end
  local track_offset=s._shape_rows=='spaced'and 4 or(#groups==0 and #outputs==0 and 2 or 3)
  -- Keep the underground pipe exit beyond the outermost ingredient belt.
  track_offset=math.max(track_offset,#groups+2)
  local track_pitch=s._shape_rows=='spaced'and 3 or 2
  -- Leave one empty tile between the last input pipe and the next bank's
  -- outer output pipe. Underground mouths face their own tracks, so they
  -- can sit against the closed back of a neighbouring fluid's mouth.
  local bank_gap=track_offset+1+math.max(0,fluid_outputs-1)*track_pitch
  local function arm(selected,x,y,d,keys,output)
    local extra={use_filters=false}
    if output and selected.filter_count>0 then extra={use_filters=true,filters={{index=1,name=select(2,U.split(keys[1])),quality='normal',comparator='='}}}end
    return g:tile(selected.name,x,y,d,extra,keys)
  end
  while done<n.count do
    local count=math.min(per_bank,n.count-done);local start=top
    local row={node=n.id,recipe=n.recipe,count=count,machines={},input_inserters={},output_inserters={},bus='recipe',pitch=w,fluid_cell=true}
    part.rows[#part.rows+1]=row
    for _,group in ipairs(groups)do group.last_pickup=nil end
    for _,output in ipairs(outputs)do output.last_drop=nil;output.drops={}end
    local tracks,track_order={},{}
    for _,q in ipairs(ports(c,n,turn,false))do if not tracks[q.key]then
      local index=0;for _,old in ipairs(track_order)do if old.input==q.input then index=index+1 end end
      local y=start+(q.input and h+track_offset+index*track_pitch or -track_offset-index*track_pitch)
      tracks[q.key]={y=y,input=q.input};track_order[#track_order+1]=q
    end end
    for i=1,count do
      local left=(i-1)*w;local mirrored=alternate and p.use_mirroring and i%2==0
      local machine=g:add(p.name,left+w/2,start+h/2,turn*4,{recipe=n.recipe,recipe_quality='normal',mirror=mirrored or nil})
      row.machines[#row.machines+1]=machine.entity_number
      for _,q in ipairs(ports(c,n,turn,mirrored))do
        local x=math.floor(left+w/2+q.x);local y=math.floor(start+h/2+q.y);local track=tracks[q.key]
        local remote=track.y+(q.input and -1 or 1)
        if y==remote then
          g:tile(equipment.pipe.name,x,y,0,nil,q.key)
        else
          if not g:tunnel_free('fluid',x,y,x,remote)then U.fail('item-ports',p.localised_name)end
          g:tile(equipment.pipeug.name,x,y,ground_direction(equipment.pipeug,(q.face+2)%4),nil,q.key)
          g:tile(equipment.pipeug.name,x,remote,ground_direction(equipment.pipeug,q.face),nil,q.key)
          g:tunnel('fluid',x,y,x,remote)
        end
      end
      for index,group in ipairs(groups)do
        local candidates=index==1 and pool or long;local remaining=group.rate
        for x=left,left+w-1 do if remaining>eps and g:free(x,start+h)then
          local selected,capacity
          for _,v in ipairs(candidates)do local value=math.huge;for _,key in ipairs(group.keys)do value=math.min(value,I.capacity(v,c,key,#group.keys))end
            if value>=remaining-eps then selected,capacity=v,value;break end
          end
          if not selected then selected=candidates[#candidates];if selected then capacity=math.huge;for _,key in ipairs(group.keys)do capacity=math.min(capacity,I.capacity(selected,c,key,#group.keys))end end end
          if selected then local e=arm(selected,x,start+h,8,group.keys,false);row.input_inserters[#row.input_inserters+1]=e.entity_number;group.last_pickup=math.max(group.last_pickup or x,x);remaining=remaining-capacity end
        end end
        if remaining>eps then U.fail('item-ports',p.localised_name)end
      end
      for _,output in ipairs(outputs)do local remaining=output.rate
        for x=left,left+w-1 do if remaining>eps and g:free(x,start-1)then
          local selected=pool[#pool];for _,v in ipairs(pool)do if I.capacity(v,c,output.key)>=remaining-eps then selected=v;break end end
          local capacity=I.capacity(selected,c,output.key)
          output.drops[x]=(output.drops[x]or 0)+math.min(remaining,capacity)
          local e=arm(selected,x,start-1,8,{output.key},true);row.output_inserters[#row.output_inserters+1]=e.entity_number;remaining=remaining-capacity
          output.last_drop=math.max(output.last_drop or x,x)
        end end
        if remaining>eps then U.fail('item-ports',p.localised_name)end
      end
    end
    for _,q in ipairs(track_order)do local track=tracks[q.key]
      for x=-1,count*w-1 do g:tile(equipment.pipe.name,x,track.y,0,nil,q.key)end
      local port={x=-2,y=track.y,id='fluid/terminal/'..n.id..'/'..done..'/'..q.key};g:reserve(port.x,port.y,port.id,q.key)
      part.terminals[#part.terminals+1]={key=q.key,port=port,produce=not q.input,rate=(q.input and n.input[q.key]or n.output[q.key])*n.crafts*count/n.count,fluid=true}
    end
    for index,group in ipairs(groups)do
      local y=start+h+index;local last=assert(group.last_pickup,'Ingredient belt has no pickup');for x=-1,last do g:tile(equipment.belt.name,x,y,4,nil,group.keys)end
      local port={x=-2,y=y,d=1,plain=true,id='feed/'..n.id..'/'..done..'/'..index};g:reserve(port.x,port.y,port.id)
      local t={port=port,produce=false}
      if #group.keys==1 then t.key=group.keys[1];t.rate=group.rate*count
      else t.mixed=true;t.keys=group.keys;t.rates={};for key,rate in pairs(group.rates)do t.rates[key]=rate*count end end
      part.terminals[#part.terminals+1]=t
      part.corridors[#part.corridors+1]={keys=group.keys,x0=-1,x1=last,y=y}
    end
    for _,output in ipairs(outputs)do
      local balanced=s._balanced_items and s._balanced_items[output.key]
      local last=assert(output.last_drop,'Output belt has no drop');local tap
      if balanced and fluid_outputs==0 then
        for x=1,last-1 do if not output.drops[x]then
          local left,right=0,0
          for drop,rate in pairs(output.drops)do if drop<x then left=left+rate else right=right+rate end end
          if left>eps and math.abs(left-right)<eps then tap=x;break end
        end end
      end
      local port
      if tap then
        local first=U.sorted(output.drops)[1]
        for x=first,last do g:tile(equipment.belt.name,x,start-2,x<tap and 4 or x>tap and 12 or 0,nil,output.key)end
        g:tile(equipment.belt.name,tap,start-3,0,nil,output.key)
        port={x=tap,y=start-4,d=0,plain=true,id='output/'..n.id..'/'..done,balanced=true}
        g.miny=math.min(g.miny,port.y)
        row.output_collector={key=output.key,tap={x=tap,y=start-2},left_rate=output.rate*count/2,right_rate=output.rate*count/2}
      else
        for x=-1,last do g:tile(equipment.belt.name,x,start-2,12,nil,output.key)end
        port={x=-2,y=start-2,d=3,plain=true,id='output/'..n.id..'/'..done}
        if balanced then port=ItemExport.collector(g,equipment,output.key,port)end
      end
      g:reserve(port.x,port.y,port.id)
      part.terminals[#part.terminals+1]={key=output.key,port=port,produce=true,rate=output.rate*count}
    end
    row.bounds={x0=-2,y0=g.miny,x1=count*w,y1=g.maxy};done=done+count;top=g.maxy+bank_gap
  end
  return part
end
local function cost(part)
  local g=part.g;return(g.maxx-g.minx)*(g.maxy-g.miny)+#g.entities*.1+#part.terminals*8
end
function Cells.build(c,s,group,pool,equipment,order)
  if #group.nodes~=1 then
    for _,n in ipairs(group.nodes)do if not Cells.has_fluid({nodes={n}})then U.fail('item-ports',c.machines[n.machine].localised_name)end end
    local parts={};for _,n in ipairs(group.nodes)do parts[#parts+1]=Cells.build(c,s,{nodes={n}},pool,equipment,order)end
    local prefer_short=s.snap_grid and s._shape_rows=='double'
    local function combine(reverse,gap,columns)
      local result={g=G.new(),rows={},stocks={},links={},terminals={},corridors={},fluid_cell=true,local_routes={},cell_links={}}
      local tops={0,0};local pitch=0;for _,part in ipairs(parts)do pitch=math.max(pitch,part.g.maxx-part.g.minx+7)end
      local terminals={}
      for ordinal=1,#parts do local part=parts[reverse and #parts+1-ordinal or ordinal]
        local column=(ordinal-1)%columns+1;local dx=(column-1)*pitch;local dy=tops[column]-part.g.miny;local g=result.g;local offset=#g.entities
        for _,e in ipairs(part.g.entities)do local extra=U.copy(e);extra.entity_number=nil;extra.position=nil;g:add(e.name,e.position.x+dx,e.position.y+dy,e.direction,extra)end
        for cell,id in pairs(part.g.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$');g:reserve(tonumber(x)+dx,tonumber(y)+dy,ordinal..'/'..id,part.g.fluid_ports[cell])end
        for _,t in ipairs(part.g.tunnels)do if t.horizontal then g:tunnel(t.kind,t.lo+dx,t.y+dy,t.hi+dx,t.y+dy)else g:tunnel(t.kind,t.x+dx,t.lo+dy,t.x+dx,t.hi+dy)end end
        for _,original in ipairs(part.rows)do local row=U.copy(original);row.bounds.x0=row.bounds.x0+dx;row.bounds.x1=row.bounds.x1+dx;row.bounds.y0=row.bounds.y0+dy;row.bounds.y1=row.bounds.y1+dy
          if row.output_collector then local tap=row.output_collector.tap;tap.x=tap.x+dx;tap.y=tap.y+dy end
          for _,list in ipairs({row.machines,row.input_inserters,row.output_inserters})do for i,id in ipairs(list)do list[i]=id+offset end end
          result.rows[#result.rows+1]=row
        end
        for _,original in ipairs(part.terminals)do local t=U.copy(original);t.port.x=t.port.x+dx;t.port.y=t.port.y+dy;t.port.id=ordinal..'/'..t.port.id
          if t.fluid then terminals[t.key]=terminals[t.key]or{};terminals[t.key][#terminals[t.key]+1]=t else result.terminals[#result.terminals+1]=t end
        end
        tops[column]=part.g.maxy+dy+gap
      end
      local g=result.g
      local mixed_count,mixed_index=0,0
      for _,t in ipairs(result.terminals)do if t.mixed then mixed_count=mixed_count+1 end end
      for _,t in ipairs(result.terminals)do if not t.fluid then
        local p=t.port;local d=t.produce and p.d or(p.d+2)%4
        if not t.produce and mixed_count>0 then
          local start=t.mixed and p.x-2-mixed_index*4 or p.x-2-4*mixed_count
          for x=start,p.x do
            local cell=G.cell(x,p.y);if not g.occupied[cell]and not g.reserved[cell]then g:reserve(x,p.y,p.id)end
          end
          if t.mixed then
            for _,y in ipairs({p.y-1,p.y+1})do local cell=G.cell(start,y);if not g.occupied[cell]and not g.reserved[cell]then g:reserve(start,y,p.id)end end
            mixed_index=mixed_index+1
          end
        end
        for step=1,3 do local x,y=p.x+G.dx[d+1]*step,p.y+G.dy[d+1]*step
          if not g.occupied[G.cell(x,y)]and not g.reserved[G.cell(x,y)]then g:reserve(x,y,p.id)end
        end
      end end
      for _,key in ipairs(U.sorted(terminals))do for _,t in ipairs(terminals[key])do
        g:tile(equipment.pipe.name,t.port.x,t.port.y,0,nil,t.key)
        -- Protect every branch's outward approach before joining any fluid.
        -- A first manifold must not seal the mouths of the other fractions.
        for step=1,3 do g.fluid_ports[G.cell(t.port.x-step,t.port.y)]=t.key end
      end end
      for _,key in ipairs(U.sorted(terminals))do local list=terminals[key];local anchor=list[1];local net=0
        for _,t in ipairs(list)do net=net+(t.produce and -1 or 1)*t.rate end
        for i=2,#list do local t=list[i]
          local component=R.fluid_component(g,t.port,key)
          if not component[G.cell(anchor.port.x,anchor.port.y)]then
            R.route(g,t.port,anchor.port,'fluid',key,equipment.pipe,equipment.pipeug,t.port.id,true)
          end
        end
        if math.abs(net)>eps then anchor.rate=math.abs(net);anchor.produce=net<0;result.terminals[#result.terminals+1]=anchor end
      end
      for _,t in ipairs(result.terminals)do if t.fluid then t.port=R.fluid_exit(g,t.port,t.key)end end
      return result
    end
    local best,last,best_score
    for _,columns in ipairs(prefer_short and{1,2}or{1})do for _,reverse in ipairs({false,true})do for _,gap in ipairs({1,2})do
      local ok,part=pcall(combine,reverse,gap,columns)
      if ok then local score=cost(part)+(prefer_short and(part.g.maxy-part.g.miny)*20 or 0)
        if not best_score or score<best_score then best,best_score=part,score end
      else last=part end
    end end end
    if best then return best end;error(last,0)
  end
  local n=group.nodes[1];local best,last,best_score
  local maximum=n.count
  if s._cell_width then maximum=math.min(maximum,math.max(1,math.floor((s._cell_width-2)/c.machines[n.machine].tile_width)))end
  local widths={maximum,math.ceil(maximum/2),math.ceil(maximum/3)};local seen={}
  local function consider(ok,part)
    if ok then
      local score=cost(part)
      if s._cell_width and s.snap_grid then score=score+(part.g.maxy-part.g.miny)*s._cell_width*4 end
      if not best_score or score<best_score then best,best_score=part,score end
    else last=part end
  end
  for _,maximum in ipairs(widths)do if not seen[maximum]then seen[maximum]=true
    for _,alternate in ipairs({true,false})do
      local ok,part=pcall(build,c,s,n,pool,equipment,order,maximum,alternate)
      consider(ok,part)
    end
    if s._shape_rows~='spaced'and s._shape_rows~='single'then consider(pcall(build,c,s,n,pool,equipment,order,maximum,false,true))end
  end end
  if not best then error(last,0)end
  return best
end
return Cells
