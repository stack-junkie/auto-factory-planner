local U=require("scripts.util")
local G=require("scripts.geometry")
local Progress=require("scripts.progress")
local Compression=require("scripts.compression")
local V={}
local function T(k,...) return {"afp."..k,...} end
function V.create(p,j)
  storage.afp_preview_serial=(storage.afp_preview_serial or 0)+1
  local name="afp-preview-"..script.mod_name.."-"..p.index.."-"..storage.afp_preview_serial
  j.surface=game.create_surface(name,{default_enable_all_autoplace_controls=false,autoplace_settings={entity={treat_missing_as_default=false},decorative={treat_missing_as_default=false}}})
  j.surface.always_day=true;j.surface.freeze_daytime=true
  j.drawn=0;j.view_event=0;j.marks={};j.port_marks={};j.sprites={};j.view={position={x=0,y=0},zoom=0.3,follow=true}
end
function V.remove(j)
  if j and j.surface and j.surface.valid then game.delete_surface(j.surface) end
end
function V.clear(j)
  j.controller_drawn=nil
  j.grid_reference_drawn=nil
  for _,list in ipairs({j.marks or {},j.port_marks or {},j.sprites or {}}) do for _,object in ipairs(list) do if object.valid then object.destroy() end end end
  if j.search_mark and j.search_mark.valid then j.search_mark.destroy() end
  if j.surface and j.surface.valid then j.surface.clear(true) end
  j.drawn=0;j.view_event=0;j.marks={};j.port_marks={};j.sprites={};j.search_mark=nil;j.wire_cursor=nil;j.boundary=nil;j.paving_drawn=nil
end
local function point(w,p) return Progress.point(w,{x=p.x+0.5,y=p.y+0.5}) end
local function wires(p,j)
  local entities=j.work.g.entities;local cursor=j.wire_cursor or {entity=1,wire=1};j.wire_cursor=cursor
  local count=0
  while cursor.entity<=#entities and count<120 do
    local list=entities[cursor.entity].wires or {};local wire=list[cursor.wire]
    if not wire then cursor.entity=cursor.entity+1;cursor.wire=1
    else
      local a,b=entities[wire[1]],entities[wire[3]]
      local red=wire[2]==defines.wire_connector_id.circuit_red or wire[2]==defines.wire_connector_id.combinator_input_red or wire[2]==defines.wire_connector_id.combinator_output_red
      local color=wire[2]==defines.wire_connector_id.pole_copper and {r=0.8,g=0.5,b=0.2} or red and {r=0.9,g=0.2,b=0.2} or {r=0.2,g=0.8,b=0.3}
      if wire[1]==wire[3] then j.sprites[#j.sprites+1]=rendering.draw_circle{color=color,width=1,radius=0.4,target=a.position,surface=j.surface,players={p.index}}
      else j.sprites[#j.sprites+1]=rendering.draw_line{color=color,width=1,from=a.position,to=b.position,surface=j.surface,players={p.index}} end
      cursor.wire=cursor.wire+1;count=count+1
    end
  end
  if cursor.entity>#entities and not j.boundary then
    local w=j.work;local g=w.g;local a=Progress.point(w,{x=g.minx,y=g.miny});local b=Progress.point(w,{x=g.maxx,y=g.maxy})
    j.boundary=rendering.draw_rectangle{color={r=0.6,g=0.7,b=0.75},width=1,filled=false,left_top={x=math.min(a.x,b.x),y=math.min(a.y,b.y)},
      right_bottom={x=math.max(a.x,b.x),y=math.max(a.y,b.y)},surface=j.surface,players={p.index}}
    j.sprites[#j.sprites+1]=j.boundary
    local hierarchy=w.plan.bus_hierarchy
    local grid=w.plan.city_blocks
    if grid then
      local bounds=grid.bounds;local color={r=.3,g=.65,b=1,a=.7}
      local function line(a,b)
        j.sprites[#j.sprites+1]=rendering.draw_line{color=color,width=2,from=Progress.point(w,a),to=Progress.point(w,b),surface=j.surface,players={p.index}}
      end
      for i=0,math.min(grid.columns,200)do local x=bounds.x0+i*grid.size;line({x=x,y=bounds.y0},{x=x,y=bounds.y1})end
      for i=0,math.min(grid.rows,200)do local y=bounds.y0+i*grid.size;line({x=bounds.x0,y=y},{x=bounds.x1,y=y})end
      local q=Progress.point(w,{x=bounds.x0,y=bounds.y0})
      local m=w.plan.compression or Compression.evaluate(w.plan,j.settings)
      j.sprites[#j.sprites+1]=rendering.draw_text{text=T('compression-result',grid.units,grid.columns,grid.rows,U.fmt(grid.perimeter),U.fmt(grid.area),#w.plan.entities,U.fmt(m and m.cost or 0),U.fmt(m and m.unit_cost or 0)),
        target={x=q.x,y=q.y-2},color=color,scale=1,surface=j.surface,players={p.index}}
    end
    if hierarchy and hierarchy.recipe.bounds and not grid then
      local function region(bounds,label,color,scale)
        local a=Progress.point(w,{x=bounds.x0,y=bounds.y0});local b=Progress.point(w,{x=bounds.x1+1,y=bounds.y1+1})
        j.sprites[#j.sprites+1]=rendering.draw_rectangle{color=color,width=1,filled=false,
          left_top={x=math.min(a.x,b.x),y=math.min(a.y,b.y)},right_bottom={x=math.max(a.x,b.x),y=math.max(a.y,b.y)},surface=j.surface,players={p.index}}
        j.sprites[#j.sprites+1]=rendering.draw_text{text=label,target={x=math.min(a.x,b.x),y=math.min(a.y,b.y)-1},
          color=color,scale=scale or 2,surface=j.surface,players={p.index}}
      end
      region(hierarchy.recipe.bounds,T('hierarchy-recipe',U.name(hierarchy.recipe.target)),{r=1,g=0.75,b=0.25})
      local a=Progress.point(w,hierarchy.main.interface.from);local b=Progress.point(w,hierarchy.main.interface.to)
      j.sprites[#j.sprites+1]=rendering.draw_text{text=T('hierarchy-external'),target={x=math.min(a.x,b.x),y=math.min(a.y,b.y)-2},
        color={r=0.35,g=0.75,b=1},scale=1.3,surface=j.surface,players={p.index}}
      for _,row in ipairs(hierarchy.lines) do
        local recipe=prototypes.recipe[row.recipe]
        region(row.bounds,T('hierarchy-line',recipe.localised_name),{r=0.4,g=1,b=0.5},1.2)
      end
    end
  end
  return cursor.entity>#entities
end
function V.focus(j,context)
  local w=j.work;if not w then return end
  local search=context or w.search or j.failure
  local viewport=j.viewport or {width=640,height=300}
  local scale=viewport.render_scale or 1
  if search and search.from and search.to then
    local a,b=point(w,search.from),point(w,search.to)
    j.view.position={x=(a.x+b.x)/2,y=(a.y+b.y)/2}
    j.view.zoom=math.min(0.8,viewport.width*scale/(32*math.max(20,math.abs(a.x-b.x)+12)),viewport.height*scale/(32*math.max(12,math.abs(a.y-b.y)+12)))
  elseif j.current then
    local event=j.current;local minx,miny,maxx,maxy=math.huge,math.huge,-math.huge,-math.huge
    for i=event.first,event.last do
      local q=w.g.entities[i].position;if not w.transformed then q=Progress.point(w,q) end
      minx=math.min(minx,q.x);maxx=math.max(maxx,q.x);miny=math.min(miny,q.y);maxy=math.max(maxy,q.y)
    end
    if minx<math.huge then
      j.view.position={x=(minx+maxx)/2,y=(miny+maxy)/2}
      j.view.zoom=math.min(0.7,viewport.width*scale/(32*math.max(15,maxx-minx+12)),viewport.height*scale/(32*math.max(12,maxy-miny+12)))
    end
  end
end
function V.fit(j)
  local w=j.work;if not w then return end
  local g=w.g;local a=Progress.point(w,{x=g.minx,y=g.miny});local b=Progress.point(w,{x=g.maxx,y=g.maxy})
  local viewport=j.viewport or {width=640,height=300}
  local scale=viewport.render_scale or 1
  j.view.position={x=(a.x+b.x)/2,y=(a.y+b.y)/2}
  -- GUI cameras apply their world zoom independently of the element's UI scaling.
  j.view.zoom=math.max(0.0001,math.min(1,viewport.width*scale/(32*math.max(20,math.abs(a.x-b.x)+16)),viewport.height*scale/(32*math.max(15,math.abs(a.y-b.y)+16))))
  j.view.follow=false;j.view.fit=true
end
function V.route_marks(p,j,failed,context)
  local w=j.work;local s=w and (context or w.search or j.failure);if not s then return end
  for _,m in ipairs(j.marks or {}) do if m.valid then m.destroy() end end;j.marks={}
  local color=failed and {r=1,g=0.2,b=0.15} or {r=0.3,g=0.9,b=1}
  local a,b=point(w,s.from),point(w,s.to)
  j.marks[#j.marks+1]=rendering.draw_line{color=color,width=2,from=a,to=b,surface=j.surface,players={p.index},dash_length=0.4,gap_length=0.3}
  for i,q in ipairs({a,b}) do
    j.marks[#j.marks+1]=rendering.draw_circle{color=color,radius=0.7,width=3,filled=false,target=q,surface=j.surface,players={p.index}}
    j.marks[#j.marks+1]=rendering.draw_text{text=T(i==1 and "route-from" or "route-to"),target={x=q.x,y=q.y-1},color=color,surface=j.surface,players={p.index},alignment="center"}
  end
  if j.view.follow then V.focus(j,s) end
end
function V.search_cursor(p,j)
  local search=j.work and j.work.search;if not search or not search.cursor then return end
  local q=point(j.work,search.cursor)
  if j.search_mark and j.search_mark.valid then j.search_mark.target=q
  else j.search_mark=rendering.draw_circle{color={r=1,g=0.8,b=0.1},radius=0.35,width=2,filled=true,target=q,surface=j.surface,players={p.index}} end
end
function V.draw(p,j,last,budget)
  local w=j.work;local g=w.g;local batch={}
  for i=j.drawn+1,math.min(last,j.drawn+(budget or 100)) do batch[#batch+1]=U.copy(g.entities[i]) end
  if not w.transformed then local temp=G.new();temp.entities=batch;temp:transform(w.turns,w.mirror) end
  local tiles={};local tile=prototypes.tile["lab-dark-1"] and "lab-dark-1" or "refined-concrete"
  for _,e in ipairs(batch) do
    local proto=prototypes.entity[e.name];local width,height=proto.tile_width,proto.tile_height
    if (e.direction or 0)%8==4 then width,height=height,width end
    local left,top=math.floor(e.position.x-width/2+1e-6),math.floor(e.position.y-height/2+1e-6)
    for x=left,left+width-1 do for y=top,top+height-1 do tiles[#tiles+1]={name=tile,position={x=x,y=y}} end end
  end
  if #tiles>0 then j.surface.set_tiles(tiles,false) end
  for _,e in ipairs(batch) do
    local ghost=j.surface.create_entity{name="entity-ghost",inner_name=e.name,position=e.position,direction=e.direction,mirror=e.mirror,force=p.force,
      create_build_effect_smoke=false,tags={afp_preview=true},type=e.type,recipe=e.recipe,recipe_quality=e.recipe_quality}
    if not ghost then error("Could not display preview entity: "..e.name) end
    if e.recipe then j.sprites[#j.sprites+1]=rendering.draw_sprite{sprite="recipe/"..e.recipe,target=e.position,surface=j.surface,players={p.index},x_scale=0.6,y_scale=0.6} end
  end
  j.drawn=j.drawn+#batch
  if #batch>0 then
    local a=Progress.point(w,{x=w.g.minx,y=w.g.miny});local b=Progress.point(w,{x=w.g.maxx,y=w.g.maxy})
    p.force.chart(j.surface,{{math.min(a.x,b.x)-8,math.min(a.y,b.y)-8},{math.max(a.x,b.x)+8,math.max(a.y,b.y)+8}})
  end
  if #j.port_marks==0 and j.current and j.current.stage=="ports" then
    for _,port in ipairs(w.plan.ports) do
      local q=port.position
      j.port_marks[#j.port_marks+1]=rendering.draw_text{text={"",T(port.kind)," #",port.index," ",U.icon(port.key)},target={x=q.x,y=q.y-1},surface=j.surface,
        color=port.kind=="in" and {r=0.4,g=1,b=0.5} or {r=0.4,g=0.8,b=1},alignment="center",players={p.index}}
    end
  end
  if j.drawn>=last and w.stage=="done" and last==#g.entities then
    if w.plan.controller_position and not j.controller_drawn then
      local slot=w.plan.controller_position;local offset=w.plan.project_offset
      j.sprites[#j.sprites+1]=rendering.draw_sprite{sprite='item/afp-controller',target={x=slot.x-offset.x,y=slot.y-offset.y},
        surface=j.surface,players={p.index},x_scale=.7,y_scale=.7}
      j.controller_drawn=true
    end
    if not j.grid_reference_drawn then
      for _,port in ipairs(w.plan.roboports or{})do if port.reference then
        j.surface.create_entity{name='entity-ghost',inner_name=w.plan.roboport_prototype,position=Progress.point(w,port.position),force=p.force,
          create_build_effect_smoke=false,tags={afp_preview=true}}
      end end
      j.grid_reference_drawn=true
    end
    if w.plan.tiles and not j.paving_drawn then
      local chunks={}
      for _,tile in ipairs(w.plan.tiles) do
        local key=math.floor(tile.position.x/32)..'/'..math.floor(tile.position.y/32)
        if not chunks[key] then chunks[key]=true;j.surface.request_to_generate_chunks(tile.position,0) end
      end
      j.surface.force_generate_chunk_requests()
      j.surface.set_tiles(w.plan.tiles,false);j.paving_drawn=true
      local a=Progress.point(w,{x=g.minx,y=g.miny});local b=Progress.point(w,{x=g.maxx,y=g.maxy})
      p.force.chart(j.surface,{{math.min(a.x,b.x)-2,math.min(a.y,b.y)-2},{math.max(a.x,b.x)+2,math.max(a.y,b.y)+2}})
    end
    return wires(p,j)
  end
  return j.drawn>=last
end
return V
