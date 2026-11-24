local U=require('scripts.util')
local G=require('scripts.geometry')
local I=require('scripts.inserters')
local FluidBoxes=require('scripts.fluid_boxes')
local Straight=require('scripts.straight_cells')
local Cells={}
local eps=1e-6
local function choose(pool,c,key,rate,slots)
  for count=1,slots do for _,p in ipairs(pool)do if I.capacity(p,c,key)*count>=rate-eps then return p,count end end end
  U.fail('item-ports',U.name(key))
end
local function arm(g,p,x,y,d,key,output)
  local _,name=U.split(key)
  local extra=output and p.filter_count>0 and{use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}}}or{use_filters=false}
  return g:tile(p.name,x,y,d,extra,key)
end
local function fluid_ports(c,n,d)
  local p=c.machines[n.machine];local recipe=c.recipes[n.recipe];local ingredients,products=recipe.ingredients,recipe.products
  local assignment=FluidBoxes.assign(p,ingredients,products)
  local active={}
  for key in pairs(n.input)do if U.split(key)=='fluid'then active[key]={input=true}end end
  for key in pairs(n.output)do if U.split(key)=='fluid'then active[key]={input=false}end end
  local result={}
  for _,values in ipairs({ingredients,products})do for _,v in ipairs(values)do if v.type=='fluid'then
    local key=U.stream(U.key('fluid',v.name),n.section);local box=assignment[v]
    for _,fb in pairs(p.fluidbox_prototypes)do if fb.index==box then for _,conn in ipairs(fb.pipe_connections)do if conn.connection_type=='normal'then
      local pos=conn.positions[d/4+1];local face=((conn.direction or 0)+d)%16/4
      result[#result+1]={key=key,input=active[key].input,dx=pos.x+G.dx[face+1],dy=pos.y+G.dy[face+1],face=face}
      break
    end end end end
  end end end
  return result
end
function Cells.build(c,s,n,pool,equipment,maximum,rank)
  local p=c.machines[n.machine];local fluids={};local rotation=0
  for _,side in ipairs({n.input,n.output})do for key in pairs(side)do if U.split(key)=='fluid'then fluids[key]=true end end end
  if next(fluids)then
    local score
    for d=0,12,4 do local ports=fluid_ports(c,n,d);local value=0
      for _,q in ipairs(ports)do if q.face%2==0 then value=value+1 end end
      if not score or value<score then score=value;rotation=d end
    end
  end
  local w,h=p.tile_width,p.tile_height;if rotation%8==4 then w,h=h,w end
  local inputs,outputs={},{}
  for _,side in ipairs({{n.input,inputs},{n.output,outputs}})do for key,amount in pairs(side[1])do if U.split(key)=='item'then
    local selected,count=choose(pool,c,key,amount*n.crafts/n.count,w)
    for j=1,count do side[2][#side[2]+1]={key=key,inserter=selected,rate=amount*n.crafts/n.count/count}end
  end end end
  table.sort(inputs,function(a,b)local ar,br=rank[a.key]or 100000,rank[b.key]or 100000;return ar==br and a.key>b.key or ar>br end)
  table.sort(outputs,function(a,b)return a.key<b.key end)
  local inside=#inputs+#outputs<=w and #outputs<=1
  if #inputs>w or #outputs>h or next(fluids)and not inside then U.fail('item-ports',p.localised_name)end
  if #inputs>0 or inside and #outputs>0 then
    if equipment.underground.max_underground_distance<h+2 then U.fail('infrastructure',equipment.underground.name)end
  end
  local lane=equipment.belt.belt_speed*14400*.8
  local count=math.min(maximum,n.count)
  for _,v in ipairs(inputs)do
    local capacity=equipment.input_capacity[v.key]or equipment.belt.belt_speed*28800
    count=math.min(count,math.max(1,math.floor(capacity/v.rate+eps)))
  end
  for key,amount in pairs(n.output)do if U.split(key)=='item'then count=math.min(count,math.max(1,math.floor(lane/(amount*n.crafts/n.count)+eps)))end end
  count=math.max(1,count)
  local banks=math.ceil(n.count/count);local perbank=math.ceil(n.count/banks)
  local g=G.new();local part={g=g,rows={},stocks={},links={},terminals={},local_routes={},underpasses=0,side_fluids=0}
  local portspec=fluid_ports(c,n,rotation);local pad=next(fluids)and 2*#portspec+5 or 0
  local pitch=h+3;local bankpitch=w+(inside and 5 or 7)+pad*2
  local firsttop=7
  local remaining=n.count
  for bank=1,banks do
    local copies=math.min(perbank,remaining);remaining=remaining-copies
    local left=(bank-1)*bankpitch+pad
    local row={node=n.id,recipe=n.recipe,count=copies,machines={},input_inserters={},output_inserters={},bus='recipe',pitch=pitch,
      bounds={x0=left-pad,y0=0,x1=left+w+pad+5,y1=firsttop+(copies-1)*pitch+h+2},underground_feed=true}
    part.rows[#part.rows+1]=row
    local channels={};for _,v in ipairs(inputs)do channels[#channels+1]={spec=v,input=true}end
    if inside then for _,v in ipairs(outputs)do channels[#channels+1]={spec=v,input=false}end end
    local space=#channels==1 and math.floor((w-1)/2)or 0
    for j,ch in ipairs(channels)do ch.x=left+(#channels==2 and(j-1)*(w-1)or space+j-1)end
    local header={}
    for j,q in ipairs(portspec)do if not header[q.key]then
      local x=left+(q.face==3 and -2-2*j or w+1+2*j);local y=1
      local id='fluid/'..n.id..'/'..bank..'/'..q.key
      header[q.key]={x=x,y=y,id=id,face=q.face,input=q.input}
      g:reserve(x,y,id,q.key)
      part.terminals[#part.terminals+1]={key=q.key,port={x=x,y=y,id=id},produce=not q.input,rate=(q.input and n.input[q.key]or n.output[q.key])*n.crafts*copies/n.count,fluid=true}
    end end
    local output_bottom
    for i=1,copies do
      local top=firsttop+(i-1)*pitch
      local machine=g:add(p.name,left+w/2,top+h/2,rotation,{recipe=n.recipe,recipe_quality='normal'})
      row.machines[#row.machines+1]=machine.entity_number
      for _,ch in ipairs(channels)do
        local v=ch.spec;local d=ch.input and 8 or 0
        local lo,hi=ch.input and top-2 or top-1,ch.input and top+h or top+h+1
        g:tile(equipment.underground.name,ch.x,lo,d,{type=ch.input and'input'or'output'},v.key)
        g:tile(equipment.underground.name,ch.x,hi,d,{type=ch.input and'output'or'input'},v.key)
        g:tunnel('item',ch.x,lo,ch.x,hi);part.underpasses=part.underpasses+1
        local e=arm(g,v.inserter,ch.x,ch.input and top-1 or top+h,0,v.key,not ch.input)
        local list=ch.input and row.input_inserters or row.output_inserters;list[#list+1]=e.entity_number
      end
      if not inside then for j,v in ipairs(outputs)do
        local y=top+(#outputs==1 and math.floor((h-1)/2)or math.floor((j-1)*(h-1)/math.max(1,#outputs-1)))
        local e=arm(g,v.inserter,left+w,y,12,v.key,true);row.output_inserters[#row.output_inserters+1]=e.entity_number
        g:tile(equipment.belt.name,left+w+1,y,4,nil,v.key)
        output_bottom=math.max(output_bottom or y,y)
      end end
      for _,q in ipairs(portspec)do
        local x,y=math.floor(left+w/2+q.dx),math.floor(top+h/2+q.dy);local head=header[q.key]
        local id=head.id
        for step=0,2 do g:reserve(x+G.dx[q.face+1]*step,y+G.dy[q.face+1]*step,id,q.key)end
        part.local_routes[#part.local_routes+1]={key=q.key,from={x=x,y=y,d=q.face},to={x=head.x,y=head.y},id=id,local_route=true,
          bounds={x0=left-pad-3,y0=0,x1=left+w+pad+6,y1=row.bounds.y1+1}}
        part.side_fluids=part.side_fluids+(q.face%2==1 and 1 or 0)
      end
    end
    local inputindex=0
    for j,ch in ipairs(channels)do
      local v=ch.spec;local y=firsttop-3;local id='under/'..n.id..'/'..bank..'/'..j
      if ch.input then
        inputindex=inputindex+1;local x=ch.x
        if #inputs>=2 then
          local step=equipment.underground.max_underground_distance>=2*#inputs and 2 or 3
          x=left+step*(inputindex-1);local common=-3;local turn=common+inputindex
          for py=common+1,turn-1 do g:tile(equipment.belt.name,x,py,8,nil,v.key)end
          if x~=ch.x then for px=x,ch.x+1,-1 do g:tile(equipment.belt.name,px,turn,12,nil,v.key)end end
          for py=turn,y do g:tile(equipment.belt.name,ch.x,py,8,nil,v.key)end
          y=common
        end
        g:reserve(x,y,id)
        part.terminals[#part.terminals+1]={key=v.key,port={x=x,y=y,d=2,plain=true,id=id},produce=false,rate=v.rate*copies,feed_length=copies*pitch+8}
      else g:tile(equipment.belt.name,ch.x,firsttop-2,0,nil,v.key)end
    end
    local outputx
    if not inside then
      local key=outputs[1].key;local x=left+w+2;local bottom=assert(output_bottom,'Output belt has no drop')
      for y=firsttop-2,bottom do g:tile(equipment.belt.name,x,y,0,nil,key)end
      outputx=x
    elseif #outputs>0 then outputx=channels[#channels].x end
    if outputx then
      local key=outputs[1].key;local bay=left+w+4;local y=firsttop-3
      for x=outputx,bay do g:tile(equipment.belt.name,x,y,x==bay and 0 or 4,nil,key)end
      local id='collect/'..n.id..'/'..bank;g:reserve(bay,y-1,id)
      part.terminals[#part.terminals+1]={key=key,port={x=bay,y=y-1,d=0,plain=true,id=id},produce=true,rate=n.output[key]*n.crafts*copies/n.count}
    end
  end
  return part
end
local function rotate(part)
  local old=part.g;local nextg=G.new()
  for _,e in ipairs(old.entities)do local extra=U.copy(e);extra.entity_number=nil;extra.position=nil
    local d=((e.direction or 0)+4)%16;nextg:add(e.name,-e.position.y,e.position.x,d,extra)
    nextg.entities[#nextg.entities].direction=d
  end
  for cell,id in pairs(old.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$');nextg:reserve(-tonumber(y)-1,tonumber(x),id,old.fluid_ports[cell])end
  for _,t in ipairs(part.terminals)do local p=t.port;p.x,p.y=-p.y-1,p.x;if p.d then p.d=(p.d+1)%4 end end
  for _,r in ipairs(part.rows)do local b=r.bounds;r.bounds={x0=-b.y1,y0=b.x0,x1=-b.y0,y1=b.x1};r.bus='recipe'end
  part.g=nextg;return part
end
local function direct_bank(c,s,spec,pool,equipment)
  local a,b=c.machines[spec.source.machine],c.machines[spec.target.machine]
  if a.tile_width~=a.tile_height or a.tile_width~=b.tile_width or a.tile_height~=b.tile_height
    or #U.sorted(spec.target.input)~=2 or equipment.underground.max_underground_distance<a.tile_width+2 then return end
  local w,h=a.tile_width,a.tile_height;local pitch=h+1;local shift=math.floor((spec.a-spec.b)*pitch/2)
  for j=1,spec.b do if (shift+(j-1)*pitch+math.floor((h-1)/2))%pitch~=h then return end end
  local input=U.sorted(spec.source.input)[1];local other
  for key in pairs(spec.target.input)do if key~=spec.key then other=key end end
  local output=U.sorted(spec.target.output)[1]
  local function pick(key,rate,direct)
    for _,p in ipairs(pool)do if(direct and I.direct_capacity or I.capacity)(p,c,key)>=rate-eps then return p end end
  end
  local sr=spec.source.crafts/spec.source.count;local tr=spec.target.crafts/spec.target.count
  local feed=pick(input,spec.source.input[input]*sr);local iron=pick(other,spec.target.input[other]*tr)
  local take=pick(output,spec.target.output[output]*tr)
  if not feed or not iron or not take then return end
  local per_side=spec.target.output[output]*tr*spec.b*spec.copies
  if per_side>equipment.belt.belt_speed*14400*.8+eps then return end
  local g=G.new();local part={g=g,rows={},stocks={},links={},terminals={},local_routes={},underpasses=0,side_fluids=0,direct_key=spec.key}
  local copperx,ironx,collect=-2,2*w+2,-6
  local last=spec.copies*spec.a*pitch-2
  for y=-2,last do
    g:tile(equipment.belt.name,copperx,y,8,nil,input);g:tile(equipment.belt.name,ironx,y,8,nil,other)
    g:tile(equipment.belt.name,collect,y,0,nil,output)
  end
  for unit=1,spec.copies do
    local y0=(unit-1)*spec.a*pitch
    local source={node=spec.source.id,recipe=spec.source.recipe,count=spec.a,machines={},input_inserters={},output_inserters={},bus='recipe',pitch=pitch,direct_cell=true,
      bounds={x0=collect,y0=y0-2,x1=ironx+1,y1=y0+spec.a*pitch}}
    local target={node=spec.target.id,recipe=spec.target.recipe,count=spec.b,machines={},input_inserters={},output_inserters={},bus='recipe',pitch=pitch,direct_cell=true,
      bounds=U.copy(source.bounds)}
    part.rows[#part.rows+1]=source;part.rows[#part.rows+1]=target
    local supplies,needs={},{}
    for i=1,spec.a do local y=y0+(i-1)*pitch
      local e=g:add(a.name,w/2,y+h/2,0,{recipe=spec.source.recipe,recipe_quality='normal'});source.machines[i]=e.entity_number
      local ins=arm(g,feed,-1,y+math.floor((h-1)/2),12,input,false);source.input_inserters[#source.input_inserters+1]=ins.entity_number
      supplies[i]=spec.source.output[spec.key]*sr
    end
    for j=1,spec.b do local y=y0+shift+(j-1)*pitch;local cy=y+math.floor((h-1)/2)
      local e=g:add(b.name,w+1+w/2,y+h/2,0,{recipe=spec.target.recipe,recipe_quality='normal'});target.machines[j]=e.entity_number
      local ins=arm(g,iron,2*w+1,cy,4,other,false);target.input_inserters[#target.input_inserters+1]=ins.entity_number
      local out=arm(g,take,w,cy,4,output,true);target.output_inserters[#target.output_inserters+1]=out.entity_number
      g:tile(equipment.underground.name,w-1,cy,12,{type='input'},output)
      g:tile(equipment.underground.name,-3,cy,12,{type='output'},output);g:tunnel('item',w-1,cy,-3,cy)
      for x=-4,collect+1,-1 do g:tile(equipment.belt.name,x,cy,12,nil,output)end
      part.underpasses=part.underpasses+1;needs[j]=spec.target.input[spec.key]*tr
    end
    for i=1,spec.a do for j=1,spec.b do
      local lo=math.max((i-1)*pitch,shift+(j-1)*pitch);local hi=math.min((i-1)*pitch+h-1,shift+(j-1)*pitch+h-1)
      local rate=math.min(supplies[i],needs[j])
      for y=lo,hi do if rate>eps then
        local selected=pick(spec.key,rate,true)or pool[#pool];local value=math.min(rate,I.direct_capacity(selected,c,spec.key))
        local e=arm(g,selected,w,y0+y,12,spec.key,false)
        source.output_inserters[#source.output_inserters+1]=e.entity_number;target.input_inserters[#target.input_inserters+1]=e.entity_number
        part.links[#part.links+1]={key=spec.key,source=source.machines[i],target=target.machines[j],inserter=e.entity_number,rate=value,stock=false}
        supplies[i]=supplies[i]-value;needs[j]=needs[j]-value;rate=math.min(supplies[i],needs[j])
      end end
    end end
    for _,v in ipairs(supplies)do assert(v<eps,'Direct bank left an unconnected supplier')end
    for _,v in ipairs(needs)do assert(v<eps,'Direct bank left an unconnected consumer')end
  end
  for _,v in ipairs({{input,copperx,false,spec.source.input[input]*spec.source.crafts},{other,ironx,false,spec.target.input[other]*spec.target.crafts},
    {output,collect,true,spec.target.output[output]*spec.target.crafts}})do
    local id='direct/'..v[1];g:reserve(v[2],-3,id)
    part.terminals[#part.terminals+1]={key=v[1],port={x=v[2],y=-3,d=v[3]and 0 or 2,plain=true,id=id},produce=v[3],rate=v[4]}
  end
  return part
end
function Cells.direct(c,s,spec,pool,equipment,order)
  local bank=direct_bank(c,s,spec,pool,equipment);if bank then return{bank}end
  local result={}
  local settings=U.copy(s);settings._legacy_dual=true
  for i=1,spec.copies do
    local source,target=U.copy(spec.source),U.copy(spec.target)
    source.count=spec.a;target.count=spec.b;source.crafts=source.crafts/spec.copies;target.crafts=target.crafts/spec.copies
    local part=Straight.build(c,settings,{nodes={source,target}},pool,{},equipment,order)
    for _,row in ipairs(part.rows)do row.direct_cell=true end
    part.local_routes={};part.direct_key=spec.key;part.underpasses=0;part.side_fluids=0
    result[#result+1]=rotate(part)
  end
  return result
end
return Cells
