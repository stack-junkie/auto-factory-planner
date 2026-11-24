local U=require('scripts.util')
local Grid=require('scripts.grid')
local P={width=2,road_width=4}
function P.grid_roads(s)return s.snap_grid==true end
function P.options(c)
  local result={}
  for name,item in pairs(prototypes.item) do
    local place=item.place_as_tile_result
    if c.available[U.key('item',name)] and place and place.result.can_be_part_of_blueprint
      and place.result.walking_speed_modifier>1 and not place.invert then result[#result+1]=item end
  end
  table.sort(result,function(a,b) return a.order==b.order and a.name<b.name or a.order<b.order end)
  return result
end
function P.validate(c,s)
  if s.paving or P.grid_roads(s)then return P.material(c,s)end
end
function P.material(c,s)
  local options=P.options(c);local fallback
  for _,item in ipairs(options)do
    if item.name==s.paving then return item end
    if not fallback or item.name=='stone-brick'then fallback=item end
  end
  if not s.paving and fallback then return fallback end
  U.fail('paving-unavailable',s.paving or 'stone-brick')
end
function P.maximum(s)
  local width=s.max_width
  if s.roboports or s.snap_grid then local span=s._roboport_span or Grid.width(s);if span then width=math.min(width or span,span)end end
  return width
end
function P.limit(s)
  local width=P.maximum(s)
  if not width then return end
  local limit=width-P.margin(s)*2
  if limit<=0 then U.fail('width',P.width*2+1,width) end
  return limit
end
function P.margin(s)
  if s._legacy_clearance and not s.paving then return 0 end
  if s.snap_grid then
    for key,value in pairs(s)do if type(key)=='string'and key:match('^_legacy_')and value then return P.width end end
    return P.width+1
  end
  return P.width
end
function P.axis(s)
  return not s._mall_compact_axes and not s._legacy_orientation and not s._legacy_layout and(s.mode=='mall'or not s._legacy_rate)and'y'or'x'
end
function P.span(s,g)
  return P.axis(s)=='y' and g.maxy-g.miny or g.maxx-g.minx
end
function P.add(g,s,plan,turns,mirror)
  local margin=P.margin(s)
  local b={x0=g.minx-margin,y0=g.miny-margin,x1=g.maxx+margin,y1=g.maxy+margin}
  plan.clearance=margin;plan.production_bounds={x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy}
  plan.local_bounds=b
  g.minx,g.miny,g.maxx,g.maxy=b.x0,b.y0,b.x1,b.y1
  if P.grid_roads(s)then plan.tiles=nil;return end
  if not s.paving then return end
  local tile=prototypes.item[s.paving].place_as_tile_result.result.name
  local tiles={}
  local function add(x,y)
    local cx,cy=x+0.5,y+0.5
    if mirror then cy=-cy end
    cx,cy=U.rotate(cx,cy,turns)
    tiles[#tiles+1]={name=tile,position={x=math.floor(cx),y=math.floor(cy)}}
  end
  for x=b.x0,b.x1-1 do for y=b.y0,b.y1-1 do
    if x<b.x0+P.width or x>=b.x1-P.width or y<b.y0+P.width or y>=b.y1-P.width then add(x,y) end
  end end
  plan.tiles=tiles
end
function P.add_grid_roads(c,g,s,plan,turns,mirror)
  local ports=plan.roboports and #plan.roboports>0 and plan.roboports or plan.grid_ports
  if not P.grid_roads(s)or not ports or #ports==0 then return end
  local material=plan.paving_material and prototypes.item[plan.paving_material]or P.material(c,s)
  local tile=material.place_as_tile_result.result.name
  local body=plan.production_bounds;local margin=P.margin(s)
  local b={x0=math.floor(body.x0-margin),y0=math.floor(body.y0-margin),x1=math.ceil(body.x1+margin),y1=math.ceil(body.y1+margin)}
  local xs,ys={},{};local half=P.road_width/2
  for _,port in ipairs(ports)do local p=port.position
    local x,y=math.floor(p.x-half),math.floor(p.y-half)
    xs[x]=true;ys[y]=true
    b.x0=math.min(b.x0,x);b.x1=math.max(b.x1,x+P.road_width)
    b.y0=math.min(b.y0,y);b.y1=math.max(b.y1,y+P.road_width)
  end
  if plan.city_blocks then
    -- Adjacent units of one factory form a compound plot. Keep the roads
    -- on its perimeter; an internal measuring line must not pave over rows.
    local frame=plan.city_blocks.bounds
    xs={[math.floor(frame.x0-half)]=true,[math.floor(frame.x1-half)]=true}
    ys={[math.floor(frame.y0-half)]=true,[math.floor(frame.y1-half)]=true}
  end
  local tiles,seen={},{}
  local function add(x,y)
    local key=x..'/'..y;if seen[key]then return end;seen[key]=true
    local wx,wy=U.rotate(x+.5,mirror and -y-.5 or y+.5,turns)
    tiles[#tiles+1]={name=tile,position={x=math.floor(wx),y=math.floor(wy)}}
  end
  local columns,rows=U.sorted(xs),U.sorted(ys)
  for _,left in ipairs(columns)do for x=left,left+P.road_width-1 do for y=b.y0,b.y1-1 do add(x,y)end end end
  for _,top in ipairs(rows)do for y=top,top+P.road_width-1 do for x=b.x0,b.x1-1 do add(x,y)end end end
  for _,port in ipairs(ports)do local p=port.position
    for x=math.floor(p.x-half),math.floor(p.x+half-1)do for y=math.floor(p.y-half),math.floor(p.y+half-1)do add(x,y)end end
  end
  plan.tiles=tiles;plan.paving_grid={width=P.road_width,columns=columns,rows=rows,bounds=b,material=material.name}
  g.minx=math.min(g.minx,b.x0);g.miny=math.min(g.miny,b.y0);g.maxx=math.max(g.maxx,b.x1);g.maxy=math.max(g.maxy,b.y1)
end
local function key(p) return math.floor(p.x)..'/'..math.floor(p.y) end
local function valid(e) return e and e.valid end
local function at(surface,p,type)
  return surface.find_entities_filtered{position={p.x+0.5,p.y+0.5},radius=0.1,type=type}[1]
end
-- Existing paving is shared terrain: never adopt or replace it.
function P.conflicts(project,tiles)
  local surface=project.anchor.surface;local areas={}
  for _,tile in ipairs(tiles or {}) do
    local ghost=at(surface,tile.position,'tile-ghost');local record=(project.paving_tiles or {})[key(tile.position)]
    local own=record and valid(record.ghost) and record.ghost==ghost
    if ghost and not own then areas[#areas+1]={{tile.position.x,tile.position.y},{tile.position.x+1,tile.position.y+1}} end
  end
  return areas
end
function P.observe(project)
  local surface=project.anchor.surface
  for k,record in pairs(project.paving_tiles or {}) do
    local name=surface.get_tile(record.position).name
    if valid(record.ghost) then
      if name~=record.before then record.ghost=nil;project.paving_tiles[k]=nil end
    elseif not record.built then
      if name==record.name then record.built=true else project.paving_tiles[k]=nil end
    elseif name~=record.name then project.paving_tiles[k]=nil end
  end
end
function P.retire(project,player_index,desired)
  P.observe(project)
  local surface=project.anchor.surface;local retiring={};local wanted={};local kept={}
  for _,tile in ipairs(desired or {}) do wanted[key(tile.position)]=tile.name end
  local queued=project.paving_retiring or {}
  for k,record in pairs(queued) do
    if valid(record.proxy) then
      if wanted[k]==record.name and surface.get_tile(record.position).name==record.name then
        record.proxy.cancel_deconstruction(project.anchor.force);record.proxy=nil;kept[k]=record;queued[k]=nil
      else retiring[#retiring+1]=record.proxy end
    else queued[k]=nil end
  end
  for k,record in pairs(project.paving_tiles or {}) do
    if wanted[k]==record.name then kept[k]=record
    else
    if valid(record.ghost) then record.ghost.destroy()
    elseif record.built and surface.get_tile(record.position).name==record.name then
      local p=record.position
      local proxy=at(surface,p,'deconstructible-tile-proxy') or surface.create_entity{
        name='deconstructible-tile-proxy',position={p.x+0.5,p.y+0.5},force=project.anchor.force}
      if not proxy or (not proxy.order_deconstruction(project.anchor.force,player_index) and not proxy.to_be_deconstructed(project.anchor.force)) then
        U.fail('project-deconstruction',{'tile-name.'..record.name})
      end
      retiring[#retiring+1]=proxy;record.proxy=proxy;queued[k]=record
    end
    end
  end
  project.paving_tiles=kept;project.paving_retiring=queued
  return retiring
end
function P.build(project,tiles)
  local surface=project.anchor.surface;local records={}
  for _,tile in ipairs(tiles or {}) do
    local previous=(project.paving_tiles or {})[key(tile.position)]
    if previous and previous.name==tile.name then records[key(tile.position)]=previous
    else
    local old=surface.get_tile(tile.position);local items=old.prototype.items_to_place_this
    if not items or #items==0 then
      local ghost=surface.create_entity{name='tile-ghost',inner_name=tile.name,
        position={tile.position.x+0.5,tile.position.y+0.5},force=project.anchor.force,create_build_effect_smoke=false}
      if ghost then records[key(tile.position)]={position=U.copy(tile.position),name=tile.name,before=old.name,ghost=ghost} end
    end
    end
  end
  project.paving_tiles=records
end
-- A manual replacement/removal releases the tile; it is no longer ours to demolish.
function P.changed(event)
  for _,project in pairs(storage.afp_projects or {}) do if valid(project.anchor) and project.anchor.surface.index==event.surface_index then
    for _,tile in ipairs(event.tiles) do
      local k=key(tile.position);local record=(project.paving_tiles or {})[k]
      if record then
        if not record.built and not valid(record.ghost) and project.anchor.surface.get_tile(tile.position).name==record.name then record.built=true
        else project.paving_tiles[k]=nil end
      end
    end
  end end
end
return P
