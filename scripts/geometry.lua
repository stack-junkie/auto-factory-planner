local U=require("scripts.util")
local G={};G.__index=G
script.register_metatable("afp-geometry",G)
G.dx={0,1,0,-1};G.dy={-1,0,1,0}
function G.new() return setmetatable({entities={},occupied={},reserved={},fluid_ports={},tunnels={},electric={},minx=0,miny=0,maxx=0,maxy=0},G) end
function G.cell(x,y) return x..","..y end
local function transport(e)
  local kind=prototypes.entity[e.name].type
  return kind=='transport-belt'or kind=='splitter'or kind=='underground-belt'and e.type=='output'
end
local function items(key)
  local result={}
  for _,value in ipairs(type(key)=='table'and key or{key})do if type(value)=='string'and U.split(value)=='item'then result[U.base_key(value)]=true end end
  return result
end
local function accepts(source,destination)
  for key in pairs(source or{})do if not(destination and destination[key])then return false end end
  return true
end
function G:reserve(x,y,id,fluid)
  local k=G.cell(x,y)
  if self.reserved[k] and self.reserved[k]~=id then
    log('AFP reservation overlap '..k..' '..self.reserved[k]..' / '..id)
    U.fail("layout-ports")
  end
  self.reserved[k]=id;if fluid then self.fluid_ports[k]=fluid end
end
function G:free(x,y,kind,key,allow,bridge)
  if self.plot_strip and allow~='roboport-grid'then
    local v=self.plot_strip.axis=='x'and x or y
    if v<self.plot_strip.min or v>=self.plot_strip.max then return false end
  end
  if self.plot_front and y<self.plot_front then return false end
  local k=G.cell(x,y)
  if self.occupied[k] or (self.reserved[k] and self.reserved[k]~=allow) then return false end
  if kind=="fluid" then
    for i=1,4 do
      local q=self.occupied[G.cell(x+G.dx[i],y+G.dy[i])]
      if q and q.fluid and q.fluid~=key and q.entity.entity_number~=bridge then return false end
      local reserved=self.fluid_ports[G.cell(x+G.dx[i],y+G.dy[i])]
      if reserved and reserved~=key then return false end
    end
  elseif kind=='item'and self.isolate_items then
    local wanted=items(key)
    for d=0,3 do local neighbor=self.occupied[G.cell(x-G.dx[d+1],y-G.dy[d+1])]
      if neighbor and neighbor.items and transport(neighbor.entity)and(neighbor.entity.direction or 0)/4==d and not accepts(neighbor.items,wanted)then return false end
    end
  end;return true
end
function G:add(name,x,y,d,extra,key)
  if #self.entities>=30000 then U.fail("too-large") end
  local p=prototypes.entity[name];if not p then U.fail("infrastructure",name) end
  local w,h=p.tile_width,p.tile_height;if (d or 0)%8==4 then w,h=h,w end
  local left,top=math.floor(x-w/2+1e-6),math.floor(y-h/2+1e-6)
  if self.plot_strip and not(extra and extra.tags and extra.tags.afp_roboport)then
    local lo=self.plot_strip.axis=='x'and left or top
    local hi=lo+(self.plot_strip.axis=='x'and w or h)
    if lo<self.plot_strip.min or hi>self.plot_strip.max then U.fail('layout-ports')end
  end
  if self.plot_front and top<self.plot_front then U.fail('layout-ports')end
  for a=left,left+w-1 do for b=top,top+h-1 do
    if self.occupied[G.cell(a,b)] then
      if self.debug_layout then helpers.write_file('geometry-overlap.json',helpers.table_to_json{pending={name=name,x=x,y=y,direction=d,key=key},existing=self.occupied[G.cell(a,b)].entity,entities=self.entities,reserved=self.reserved},false)end
      U.fail("layout-overlap",name,a,b)
    end
  end end
  local e={entity_number=#self.entities+1,name=name,position={x=x,y=y},direction=d or 0,quality="normal"}
  for k,v in pairs(extra or {}) do e[k]=v end
  if extra and extra.recipe then e.tags=e.tags or {};e.tags.afp_process=extra.recipe end
  if key then
    local keys={}
    if type(key)=='string' then keys[U.base_key(key)]=true
    else for _,entry in ipairs(key) do keys[U.base_key(type(entry)=='table' and entry.key or entry)]=true end end
    e.tags=e.tags or {};e.tags.afp_stream=table.concat(U.sorted(keys),'|')
    if type(key)=='string'and U.split(key)=='fluid'then e.tags.afp_network=key end
  end
  self.entities[#self.entities+1]=e
  local labels={};for value in((e.tags and e.tags.afp_stream)or''):gmatch('[^|]+')do labels[#labels+1]=value end
  local item_keys=items(labels)
  local fluid=type(key)=='string'and U.split(key)=='fluid'and key or e.tags and e.tags.afp_network
  if not fluid and #labels==1 and U.split(labels[1])=='fluid'then fluid=labels[1]end
  local marker={entity=e,fluid=fluid,items=next(item_keys)and item_keys or nil}
  for a=left,left+w-1 do for b=top,top+h-1 do self.occupied[G.cell(a,b)]=marker end end
  self.minx=math.min(self.minx,left);self.miny=math.min(self.miny,top);self.maxx=math.max(self.maxx,left+w);self.maxy=math.max(self.maxy,top+h)
  if self.plot_front_body then self.miny=self.plot_front_body end
  if p.type=="inserter" or p.type=="pump" or p.type=="decider-combinator" or p.type=='roboport'or p.crafting_categories then self.electric[#self.electric+1]=e end
  return e
end
function G:tile(name,x,y,d,extra,key) return self:add(name,x+0.5,y+0.5,d,extra,key) end
function G:wire(a,ac,b,bc)
  a.wires=a.wires or {};a.wires[#a.wires+1]={a.entity_number,ac,b.entity_number,bc}
end
function G:tunnel_free(kind,x,y,nx,ny)
  local horizontal=y==ny
  for _,t in ipairs(self.tunnels) do if t.kind==kind and t.horizontal==horizontal then
    if horizontal and t.y==y and math.max(math.min(x,nx),t.lo)<=math.min(math.max(x,nx),t.hi) then return false end
    if not horizontal and t.x==x and math.max(math.min(y,ny),t.lo)<=math.min(math.max(y,ny),t.hi) then return false end
  end end;return true
end
function G:tunnel(kind,x,y,nx,ny)
  self.tunnels[#self.tunnels+1]={kind=kind,x=x,y=y,horizontal=y==ny,lo=math.min(y==ny and x or y,y==ny and nx or ny),hi=math.max(y==ny and x or y,y==ny and nx or ny)}
end
function G:protect_item_ends()
  for cell,marker in pairs(self.occupied)do if marker.items and transport(marker.entity)then
    local x,y=cell:match('^(-?%d+),(-?%d+)$');local d=(marker.entity.direction or 0)/4
    local target=G.cell(tonumber(x)+G.dx[d+1],tonumber(y)+G.dy[d+1])
    if not self.occupied[target]and not self.reserved[target]then self.reserved[target]='belt-end/'..marker.entity.entity_number end
  end end
end
function G:item_edges_valid()
  for cell,marker in pairs(self.occupied)do if marker.items and transport(marker.entity)then
    local x,y=cell:match('^(-?%d+),(-?%d+)$');local d=(marker.entity.direction or 0)/4
    local other=self.occupied[G.cell(tonumber(x)+G.dx[d+1],tonumber(y)+G.dy[d+1])]
    if other and other.entity~=marker.entity and other.items and prototypes.entity[other.entity.name].type~='inserter'
      and(other.entity.direction or 0)~=((marker.entity.direction or 0)+8)%16 and not accepts(marker.items,other.items)then
      log('AFP ITEM NETWORK CONTACT '..cell..' '..marker.entity.name..' -> '..other.entity.name)
      return false
    end
  end end
  return true
end
function G:transform(turns,mirror)
  for _,e in ipairs(self.entities) do
    local proto=prototypes.entity[e.name];local olddirection=e.direction or 0
    local x,y=e.position.x,e.position.y
    if mirror then y=-y end
    x,y=U.rotate(x,y,turns);e.position={x=x,y=y}
    local d=e.direction or 0;if mirror then d=(8-d)%16 end;e.direction=(d+turns*4)%16
    if mirror then
      for _,p in ipairs({"input_priority","output_priority"}) do
        if e[p]=="left" then e[p]="right" elseif e[p]=="right" then e[p]="left" end
      end
      if proto.use_mirroring then e.mirror=not e.mirror
      elseif #proto.fluidbox_prototypes>0 then
        -- Non-mirrorable symmetric entities (notably tanks) can require a
        -- different rotation to preserve their reflected pipe connections.
        local function ports(direction,reflect)
          local result={}
          for _,fb in pairs(proto.fluidbox_prototypes) do for _,conn in pairs(fb.pipe_connections) do
            local pos=conn.positions[direction/4+1];local face=((conn.direction or 0)+direction)%16
            local px,py=pos.x,pos.y
            if reflect then py=-py;face=(8-face)%16 end
            result[#result+1]=fb.index..":"..conn.connection_type..":"..(conn.flow_direction or "input-output")..":"..face..":"..math.floor(px*2+0.5)..":"..math.floor(py*2+0.5)
          end end
          table.sort(result);return table.concat(result,";")
        end
        local expected=ports(olddirection,true)
        for candidate=0,12,4 do if ports(candidate,false)==expected then e.direction=(candidate+turns*4)%16;break end end
      end
    end
  end
end
return G
