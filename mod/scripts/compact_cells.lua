local U=require('scripts.util')
local G=require('scripts.geometry')
local I=require('scripts.inserters')
local Mall=require('scripts.mall')
local C={}
local function choose(pool,c,key,rate,direct)
  local capacity=direct and I.direct_capacity or I.capacity
  for _,p in ipairs(pool)do if capacity(p,c,key)>=rate-1e-6 then return p end end
end
function C.build(c,s,group,pool,targets,belt)
  if s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout or #group.nodes~=3 then return end
  local consumer,sources
  for _,n in ipairs(group.nodes)do if n.count==1 then
    local list={}
    for _,source in ipairs(group.nodes)do if source~=n and source.count==1 and source.local_supply and #U.sorted(source.input)==1 then
      local key=U.sorted(source.output)[1];if n.input[key]then list[#list+1]=source end
    end end
    if #list==2 then consumer,sources=n,list;break end
  end end
  if not consumer then return end
  local p=c.machines[consumer.machine];local a,b=c.machines[sources[1].machine],c.machines[sources[2].machine]
  if a.tile_width~=b.tile_width then return end
  local local_keys={};for _,source in ipairs(sources)do local_keys[U.sorted(source.output)[1]]=true end
  local extra={};for _,key in ipairs(U.sorted(consumer.input))do if not local_keys[key]then extra[#extra+1]=key end end
  if #extra>p.tile_width then return end
  local g=G.new();local rows,links,stocks,terminals={},{},{},{}
  local function machine(n,x,y)
    local proto=c.machines[n.machine]
    local e=g:add(proto.name,x+proto.tile_width/2,y+proto.tile_height/2,0,{recipe=n.recipe,recipe_quality='normal'})
    local row={node=n.id,recipe=n.recipe,count=1,machines={e.entity_number},input_inserters={},output_inserters={},mall_cell=true,compact_cell=true,
      bounds={x0=x-2,y0=y-2,x1=x+proto.tile_width+2,y1=y+proto.tile_height+2}}
    rows[#rows+1]=row;return e,row
  end
  local function arm(proto,x,y,d,key,output)
    local _,name=U.split(key)
    return g:tile(proto.name,x,y,d,output and proto.filter_count>0 and{use_filters=true,filters={{index=1,name=name,quality='normal',comparator='='}}}or{use_filters=false},key)
  end
  local function terminal(key,x,y,d,rate,produce,id)
    local dx,dy=G.dx[d+1],G.dy[d+1]
    for n=0,2 do g:reserve(x+(produce and dx or -dx)*n,y+(produce and dy or -dy)*n,id)end
    terminals[#terminals+1]={key=key,port={x=x,y=y,d=d,plain=true,id=id},produce=produce,rate=rate}
  end
  local sink,sink_row=machine(consumer,0,0)
  local raw,feed_y={},{};local right=p.tile_width+1
  for i,source in ipairs(sources)do
    local proto=c.machines[source.machine];local y=i==1 and(1-proto.tile_height)or(p.tile_height-1)
    local key=U.sorted(source.output)[1];local input=U.sorted(source.input)[1]
    local out_rate=source.output[key]*source.crafts;local in_rate=source.input[input]*source.crafts
    local out=choose(pool,c,key,out_rate,true);local take=choose(pool,c,input,in_rate)
    if not out or not take or in_rate>belt.belt_speed*14400+1e-6 then return end
    local object,row=machine(source,right,y)
    local iy=i==1 and 0 or p.tile_height-1
    local direct=arm(out,p.tile_width,iy,4,key,false)
    row.output_inserters[#row.output_inserters+1]=direct.entity_number;sink_row.input_inserters[#sink_row.input_inserters+1]=direct.entity_number
    links[#links+1]={key=key,source=object.entity_number,target=sink.entity_number,inserter=direct.entity_number,rate=out_rate,stock=false}
    local fy=y+math.floor((proto.tile_height-1)/2)
    local feed=arm(take,right+proto.tile_width,fy,4,input,false);row.input_inserters[#row.input_inserters+1]=feed.entity_number
    raw[input]=(raw[input]or 0)+in_rate;feed_y[#feed_y+1]=fy
  end
  local keys=U.sorted(raw);local fx=right+a.tile_width+1;local top=math.min(table.unpack(feed_y));local bottom=p.tile_height+b.tile_height
  for y=top,bottom+1 do g:tile(belt.name,fx,y,0,nil,keys)end
  if #keys==1 then terminal(keys[1],fx,bottom+2,0,raw[keys[1]],false,'compact/raw/1')
  else
    for i,key in ipairs(keys)do local side=i==1 and -1 or 1
      g:tile(belt.name,fx+side,bottom,side<0 and 4 or 12,nil,key)
      terminal(key,fx+2*side,bottom,side<0 and 1 or 3,raw[key],false,'compact/raw/'..i)
    end
  end
  for i,key in ipairs(extra)do
    local rate=consumer.input[key]*consumer.crafts;local selected=choose(pool,c,key,rate);if not selected then return end
    local x=math.floor((i-1)*(p.tile_width-1)/math.max(1,#extra-1));if #extra==1 then x=math.floor((p.tile_width-1)/2)end
    local feed=arm(selected,x,p.tile_height,8,key,false);sink_row.input_inserters[#sink_row.input_inserters+1]=feed.entity_number
    g:tile(belt.name,x,p.tile_height+1,0,nil,key)
    terminal(key,x,p.tile_height+2,0,rate,false,'compact/extra/'..i)
  end
  local key=U.sorted(consumer.output)[1];local rate=consumer.output[key]*consumer.crafts
  local selected=choose(pool,c,key,rate);if not selected then return end
  local y=math.floor((p.tile_height-1)/2);local output=arm(selected,-1,y,4,key,true);sink_row.output_inserters[1]=output.entity_number
  local target=targets[U.base_key(key)]
  if target then
    local chest=Mall.chest(c,s,target.stacks)
    local box=g:tile(chest.name,-2,y,0,{bar=target.stacks,tags={afp_mall={key=U.base_key(key),stacks=target.stacks}}},key)
    stocks[1]={key=U.base_key(key),stock=target.stock,stacks=target.stacks,chest=box.entity_number,inserter=output.entity_number}
  else
    g:tile(belt.name,-2,y,12,nil,key);terminal(key,-3,y,3,rate,true,'compact/out')
  end
  return {g=g,rows=rows,stocks=stocks,links=links,terminals=terminals,compact_cell=true}
end
return C
