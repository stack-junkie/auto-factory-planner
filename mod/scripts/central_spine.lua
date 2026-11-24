local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local S={}
local function arm(c,reach,keys,required,mixed)
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+.5)==reach and math.floor(p.inserter_drop_position[2]+.5)==reach then
      local capacity=math.huge
      for _,key in ipairs(keys)do capacity=math.min(capacity,I.capacity(p,c,key,mixed and #keys or 1))end
      if capacity>=required-1e-6 then return p end
    end
  end
end
function S.spec(c,s,n,belt)
  if s.infrastructure and s.infrastructure.inserter or n.fuel or n.count<2 or n.count>28 then return end
  local inputs,outputs=U.sorted(n.input),U.sorted(n.output);local p=c.machines[n.machine]
  if #inputs~=2 or #outputs~=1 or p.tile_width<2 or p.tile_height<2 then return end
  for _,key in ipairs(inputs)do if U.split(key)~='item'or n.input[key]*n.crafts>belt.belt_speed*14400+1e-6 then return end end
  if U.split(outputs[1])~='item'or n.output[outputs[1]]*n.crafts>belt.belt_speed*28800+1e-6 then return end
  local demand=(n.input[inputs[1]]+n.input[inputs[2]])*n.crafts/n.count
  local produced=n.output[outputs[1]]*n.crafts/n.count
  local near_in=arm(c,1,inputs,demand,true);local far_in=arm(c,2,inputs,demand,true)
  local near_out=arm(c,1,outputs,produced);local far_out=arm(c,2,outputs,produced)
  if near_in and far_in and near_out and far_out then return{inputs=inputs,output=outputs[1],near_in=near_in,far_in=far_in,near_out=near_out,far_out=far_out}end
end
function S.build(c,s,group,equipment)
  local n=group.nodes[1];local spec=S.spec(c,s,n,equipment.belt);if not spec then U.fail('layout-ports')end
  local g=G.new();local p=c.machines[n.machine];local upper=math.ceil(n.count/2)
  -- Both banks share the same two stripes. The far hand reaches across the
  -- neighbouring belt; each bank unloads onto a different output lane.
  local feed_y=p.tile_height+1;local output_y=feed_y+1;local lower_y=p.tile_height+4
  local rows={};local last_feed,last_output=-1,-1
  for bank=1,2 do
    local count=bank==1 and upper or n.count-upper;local y=bank==1 and 0 or lower_y
    local row={node=n.id,recipe=n.recipe,count=count,machines={},input_inserters={},output_inserters={},
      crafts_per_machine=n.crafts/n.count,central_spine=true,bounds={x0=0,y0=y,x1=count*p.tile_width,y1=y+p.tile_height}}
    for copy=1,count do local x=(copy-1)*p.tile_width
      local machine=g:add(p.name,x+p.tile_width/2,y+p.tile_height/2,0,{recipe=n.recipe,recipe_quality='normal'})
      row.machines[#row.machines+1]=machine.entity_number
      local ay=bank==1 and p.tile_height or lower_y-1
      local input=bank==1 and spec.near_in or spec.far_in;local output=bank==1 and spec.far_out or spec.near_out
      local input_offset=math.min(math.floor(p.tile_width/2),p.tile_width-2);local output_offset=p.tile_width-1
      if copy%2==0 then input_offset=p.tile_width-1-input_offset;output_offset=0 end
      local input_x=x+input_offset;local output_x=x+output_offset
      local take=g:tile(input.name,input_x,ay,bank==1 and 8 or 0,{use_filters=false},spec.inputs)
      local put=g:tile(output.name,output_x,ay,bank==1 and 0 or 8,{use_filters=false},spec.output)
      row.input_inserters[#row.input_inserters+1]=take.entity_number;row.output_inserters[#row.output_inserters+1]=put.entity_number
      last_feed=math.max(last_feed,input_x);last_output=math.max(last_output,output_x)
    end
    rows[#rows+1]=row
  end
  for x=-2,last_feed do g:tile(equipment.belt.name,x,feed_y,4,nil,spec.inputs)end
  for x=1,last_output do g:tile(equipment.belt.name,x,output_y,12,nil,spec.output)end
  if equipment.underground.max_underground_distance<3 then U.fail('layout-ports')end
  local exit=g:tile(equipment.underground.name,0,output_y,12,{type='input'},spec.output)
  -- Keep the initial frame stable, but choose the other end after placing
  -- neighbouring buildings instead of trapping the export between them.
  g.minx=math.min(g.minx,-3)
  local keys=U.copy(spec.inputs);if s._spine_swap then keys[1],keys[2]=keys[2],keys[1]end
  local terminals={
    {key=keys[1],port={x=-2,y=feed_y-1,d=2,plain=true,id='central/in/1'},rate=n.input[keys[1]]*n.crafts,produce=false},
    {key=keys[2],port={x=-2,y=feed_y+1,d=0,plain=true,id='central/in/2'},rate=n.input[keys[2]]*n.crafts,produce=false},
    {key=spec.output,port={x=-4,y=output_y,d=3,plain=true,id='central/out'},rate=n.output[spec.output]*n.crafts,produce=true}}
  for _,t in ipairs(terminals)do g:reserve(t.port.x,t.port.y,t.port.id)end
  return{g=g,rows=rows,stocks={},links={},terminals=terminals,straight_cell=true,
    corridors={{keys=spec.inputs,x0=-2,x1=last_feed,y=feed_y}},
    central_export={input=exit.entity_number,key=spec.output},
    central_spine={key=spec.output,x0=0,x1=last_output,y=output_y,feed_y=feed_y,rate=n.output[spec.output]*n.crafts,banks=2}}
end
function S.connect(c,g,plan,terminals)
  if not plan.central_exports then return end
  local choices=C.options(c,'underground-belt',function(p)return p.belt_speed end)
  local maximum=0;for _,p in ipairs(choices)do maximum=math.max(maximum,p.max_underground_distance)end
  for _,crossing in ipairs(plan.central_exports or{})do
    local source
    for _,t in ipairs(terminals)do if t.port.id==crossing.port_id then source=t.port;break end end
    if not source then U.fail('layout-ports')end
    local input=g.entities[crossing.input];local d=input.direction/4;local dx,dy=G.dx[d+1],G.dy[d+1]
    local ix,iy=math.floor(input.position.x),math.floor(input.position.y);local selected
    for length=3,maximum do
      local x,y=ix+dx*length,iy+dy*length;local sx,sy=x+dx,y+dy
      if g:free(x,y,'item',crossing.key,source.id)and g:free(sx,sy,'item',crossing.key,source.id)and g:tunnel_free('item',ix,iy,x,y)then
        local open=false
        for side=0,3 do if side~=(d+2)%4 and g:free(sx+G.dx[side+1],sy+G.dy[side+1],'item',crossing.key,source.id)then open=true end end
        if open then selected={x=x,y=y,sx=sx,sy=sy,length=length};break end
      end
    end
    if not selected then U.fail('layout-ports')end
    local proto
    for _,p in ipairs(choices)do if p.max_underground_distance>=selected.length then proto=p;break end end
    local cell=G.cell(source.x,source.y);if g.reserved[cell]==source.id then g.reserved[cell]=nil end
    source.x,source.y=selected.sx,selected.sy;g:reserve(source.x,source.y,source.id)
    input.name=proto.name
    g:tile(proto.name,selected.x,selected.y,d*4,{type='output'},crossing.key)
    g:tunnel('item',ix,iy,selected.x,selected.y)
    crossing.length=selected.length
  end
end
function S.root(c,s,group,equipment)
  if #group.nodes~=1 then return end
  local n=group.nodes[1];local inputs,outputs=U.sorted(n.input),U.sorted(n.output)
  if n.fuel or n.count~=1 or #inputs~=1 or #outputs~=1 or U.split(inputs[1])~='item'or U.split(outputs[1])~='item'then return end
  local p=c.machines[n.machine];local feed,take,count
  for arms=1,p.tile_width do feed=arm(c,1,inputs,n.input[inputs[1]]*n.crafts/arms)
    if feed then count=arms;break end
  end
  take=arm(c,1,outputs,n.output[outputs[1]]*n.crafts)
  if not feed or not take then return end
  local g=G.new();local row={node=n.id,recipe=n.recipe,count=1,machines={},input_inserters={},output_inserters={},
    crafts_per_machine=n.crafts,corner_root=true,bounds={x0=0,y0=0,x1=p.tile_width,y1=p.tile_height}}
  row.machines[1]=g:add(p.name,p.tile_width/2,p.tile_height/2,0,{recipe=n.recipe,recipe_quality='normal'}).entity_number
  local last=-1
  for i=1,count do local x=count==1 and math.floor(p.tile_width/2)or math.floor((i-1)*(p.tile_width-1)/(count-1))
    row.input_inserters[#row.input_inserters+1]=g:tile(feed.name,x,-1,0,{use_filters=false},inputs[1]).entity_number;last=math.max(last,x)
  end
  for x=-1,last do g:tile(equipment.belt.name,x,-2,4,nil,inputs[1])end
  local y=math.floor(p.tile_height/2)
  row.output_inserters[1]=g:tile(take.name,p.tile_width,y,12,{use_filters=false},outputs[1]).entity_number
  g:tile(equipment.belt.name,p.tile_width+1,y,4,nil,outputs[1])
  local incoming={x=-2,y=-2,d=1,plain=true,id='corner/in'}
  local outgoing={x=p.tile_width+2,y=y,d=1,plain=true,id='corner/out'}
  g:reserve(incoming.x,incoming.y,incoming.id);g:reserve(outgoing.x,outgoing.y,outgoing.id)
  return{g=g,rows={row},stocks={},links={},straight_cell=true,
    terminals={{key=inputs[1],port=incoming,rate=n.input[inputs[1]]*n.crafts,produce=false},
      {key=outputs[1],port=outgoing,rate=n.output[outputs[1]]*n.crafts,produce=true,forward=true}},
    corridors={{keys=inputs,x0=-1,x1=last,y=-2}}}
end
return S
