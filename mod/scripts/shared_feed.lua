local U=require('scripts.util')
local F={}
local function cost(part)
  local g=part.g
  return #g.entities+(g.maxx-g.minx)*(g.maxy-g.miny)*0.12
end
-- Keep direct-feed dependency components together. Only independent components
-- may be moved to the other side of the common feed strip.
function F.choose(c,s,group,baseline,positions,build)
  if s.input_rows=='single' or s._legacy_dual or not group.grouped and s.mode=='mall'or #group.nodes<2 and(s.mode=='mall'or group.nodes[1].count<2)then return baseline end
  if s.mode=='mall'then for _,t in ipairs(baseline.terminals)do if t.produce then return baseline end end end
  local components,seen={},{}
  local function connected(a,b)
    for key in pairs(a.output)do if b.input[key]then return true end end
    for key in pairs(b.output)do if a.input[key]then return true end end
  end
  local function visit(n,list)
    if seen[n.id]then return end;seen[n.id]=true;list[#list+1]=n
    for _,other in ipairs(group.nodes)do if connected(n,other)then visit(other,list)end end
  end
  for _,n in ipairs(group.nodes)do if not seen[n.id]then
    local nodes={};visit(n,nodes)
    local p=positions(c,{nodes=nodes,grouped=true});local width=0
    for _,v in ipairs(p)do
      if v.y~=0 or v.side~=-1 then return baseline end
      width=math.max(width,v.x+c.machines[v.node.machine].tile_width)
    end
    if s.mode~='mall'and #nodes==1 and #p>1 then
      local half=math.ceil(#p/2)
      for start=1,#p,half do local list={};local origin=p[start].x;local extent=0
        for i=start,math.min(#p,start+half-1)do local v=p[i];list[#list+1]={node=v.node,x=v.x-origin,y=0,side=-1};extent=math.max(extent,v.x-origin+c.machines[v.node.machine].tile_width)end
        components[#components+1]={positions=list,width=extent}
      end
    else components[#components+1]={positions=p,width=width}end
  end end
  if #components<2 then return baseline end
  local raw={}
  for _,t in ipairs(baseline.terminals)do if not t.produce then for _,key in ipairs(t.keys or{t.key})do
    raw[key]=(raw[key]or 0)+(t.rates and t.rates[key]or t.rate)
  end end end
  local bestmask,bestwidth,bestdiff
  for mask=1,2^#components-2,2 do
    local widths={-1,-1}
    for i,part in ipairs(components)do local bank=math.floor(mask/2^(i-1))%2+1;widths[bank]=widths[bank]+part.width+1 end
    local width,diff=math.max(widths[1],widths[2]),math.abs(widths[1]-widths[2])
    if not bestwidth or width<bestwidth or width==bestwidth and diff<bestdiff then bestmask,bestwidth,bestdiff=mask,width,diff end
  end
  local best
  for swap=0,1 do
    local placement,x={}, {0,0}
    for i,part in ipairs(components)do
      local bank=(math.floor(bestmask/2^(i-1))%2+swap)%2+1
      for _,v in ipairs(part.positions)do placement[#placement+1]={node=v.node,x=x[bank]+v.x,bank=bank}end
      x[bank]=x[bank]+part.width+1
    end
    local ok,result=pcall(build,{positions=placement,dual=true,raw=raw,collector=not s._shared_input_banks and s.mode~='mall'and #group.nodes==1})
    if not ok and type(result)~='table'then error(result,0)end
    if ok and(not best or cost(result)<cost(best))then best=result end
  end
  if best and(s.input_rows=='double' or cost(best)<cost(baseline)-0.01)then return best end
  return baseline
end
return F
