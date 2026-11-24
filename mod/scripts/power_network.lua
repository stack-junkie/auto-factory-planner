local U=require('scripts.util')
local N={}
local copper=defines.wire_connector_id.pole_copper
local function distance(a,b)return(a.position.x-b.position.x)^2+(a.position.y-b.position.y)^2 end
local function reach(p)return prototypes.entity[p.name].get_max_wire_distance('normal')end
-- Build a short spanning network, joining existing connected components before
-- considering relays. Entity insertion order must not determine wire routes.
function N.connect(g,poles,models,free,place,detour)
  if #poles==0 then return end
  poles[1].tags=poles[1].tags or{};poles[1].tags.afp_power=true
  local parent,degrees,by_id={},{},{}
  for _,p in ipairs(poles)do local id=p.entity_number;parent[id]=id;by_id[id]=p end
  local function root(id)
    local r=id;while parent[r]~=r do r=parent[r]end
    while parent[id]~=id do local next_id=parent[id];parent[id]=r;id=next_id end
    return r
  end
  local groups=#poles
  local function join(a,b)
    local x,y=root(a.entity_number),root(b.entity_number)
    if x~=y then parent[y]=x;groups=groups-1 end
  end
  for _,e in ipairs(g.entities)do for _,w in ipairs(e.wires or{})do
    if w[2]==copper and w[4]==copper and by_id[w[1]]and by_id[w[3]]then
      degrees[w[1]]=(degrees[w[1]]or 0)+1;degrees[w[3]]=(degrees[w[3]]or 0)+1
      join(by_id[w[1]],by_id[w[3]])
    end
  end end
  local function wire(a,b)
    g:wire(a,copper,b,copper);degrees[a.entity_number]=(degrees[a.entity_number]or 0)+1
    degrees[b.entity_number]=(degrees[b.entity_number]or 0)+1;join(a,b)
  end
  local function edge(a,b)
    if a.entity_number<b.entity_number then a,b=b,a end
    local d=distance(a,b);local best,chosen
    for _,model in ipairs(models)do
      local span=model.get_max_wire_distance('normal');local first,last=math.min(span,reach(a)),math.min(span,reach(b))
      local relays=d<=math.min(reach(a),reach(b))^2+1e-6 and 0
        or math.max(1,math.ceil((math.sqrt(d)-first-last-1e-6)/span)+1)
      if not best or relays<best then best=relays;chosen=model end
    end
    return{a=a,b=b,d=d,relays=best,model=chosen}
  end
  local function order(a,b)
    if a.relays~=b.relays then return a.relays<b.relays end
    if a.d~=b.d then return a.d<b.d end
    if a.a.entity_number~=b.a.entity_number then return a.a.entity_number<b.a.entity_number end
    return a.b.entity_number<b.b.entity_number
  end
  -- Keep only each pole's nearest outgoing edge. Lazy refresh after component
  -- merges gives the same global edge order without a quadratic edge table.
  local heap,slots={},{}
  local function less(a,b)
    if order(a.edge,b.edge)then return true end
    if order(b.edge,a.edge)then return false end
    return a.source.entity_number<b.source.entity_number
  end
  local function set(i,node)heap[i]=node;slots[node.source.entity_number]=i end
  local function update(source,candidate)
    local i=slots[source.entity_number]or(#heap+1)
    local node={source=source,edge=candidate};set(i,node)
    while i>1 do local p=math.floor(i/2);if not less(node,heap[p])then break end;set(i,heap[p]);i=p;set(i,node)end
    while i*2<=#heap do local child=i*2
      if child+1<=#heap and less(heap[child+1],heap[child])then child=child+1 end
      if not less(heap[child],node)then break end
      set(i,heap[child]);i=child;set(i,node)
    end
  end
  local function pop()
    local first=heap[1];local last=table.remove(heap);slots[first.source.entity_number]=nil
    if #heap>0 then
      local i=1;set(i,last)
      while i*2<=#heap do local child=i*2
        if child+1<=#heap and less(heap[child+1],heap[child])then child=child+1 end
        if not less(heap[child],last)then break end
        set(i,heap[child]);i=child;set(i,last)
      end
    end
    return first
  end
  local function eligible(a,b)
    return root(a.entity_number)~=root(b.entity_number)
      and(degrees[a.entity_number]or 0)<4 and(degrees[b.entity_number]or 0)<4
  end
  local function refresh(source)
    if(degrees[source.entity_number]or 0)>=4 then return end
    local best
    for _,p in ipairs(poles)do if eligible(source,p)then local e=edge(source,p)
      if not best or order(e,best)then best=e end
    end end
    if best then update(source,best)end
  end
  for _,p in ipairs(poles)do refresh(p)end
  while groups>1 do
    local chosen,source
    while #heap>0 do local node=pop();local e=node.edge
      if eligible(e.a,e.b)then chosen=e;source=node.source;break else refresh(node.source)end
    end
    if not chosen then U.fail('power')end
    local a,b=chosen.a,chosen.b;local d=chosen.d;local added={}
    local model=chosen.model;local span=model.get_max_wire_distance('normal');local pw,ph=model.tile_width,model.tile_height
    while d>math.min(reach(a),reach(b))^2+1e-6 do
      local next_p,next_d;local r=math.min(span,reach(a))
      for dx=-math.floor(r),math.floor(r)do for dy=-math.floor(r),math.floor(r)do
        local x,y=math.floor(a.position.x-pw/2)+dx,math.floor(a.position.y-ph/2)+dy
        local pos={position={x=x+pw/2,y=y+ph/2}}
        local step=distance(a,pos);local remaining=distance(pos,b)
        if step>0 and step<=r*r+1e-6 and remaining<d-.1 and(not next_d or remaining<next_d)and free(x,y,model)then
          next_p={x=x,y=y};next_d=remaining
        end
      end end
      if not next_p then
        local connected={}
        for _,p in ipairs(poles)do if root(p.entity_number)==root(a.entity_number)then connected[#connected+1]=p end end
        local start,path=detour(connected,degrees,b)
        if not start then U.fail('power')end
        a=start
        for _,point in ipairs(path)do
          local q=place(point.x,point.y);parent[q.entity_number]=q.entity_number;groups=groups+1
          added[#added+1]=q;wire(a,q);a=q
        end
        d=distance(a,b);break
      end
      local q=place(next_p.x,next_p.y,nil,model);parent[q.entity_number]=q.entity_number;groups=groups+1
      added[#added+1]=q;wire(a,q);a=q;d=next_d
    end
    wire(a,b)
    for _,q in ipairs(added)do poles[#poles+1]=q end
    refresh(source)
    for _,q in ipairs(added)do
      refresh(q)
      for _,p in ipairs(poles)do if eligible(p,q)then local e=edge(p,q);local i=slots[p.entity_number]
        if not i or order(e,heap[i].edge)then update(p,e)end
      end end
    end
  end
end
return N
