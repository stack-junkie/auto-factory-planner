local U=require('scripts.util')
local G=require('scripts.geometry')
local F={}
-- Mix compatible ingredients once, then split that two-lane stream. Routing
-- each ingredient to every bank independently creates crossed mixer trees.
function F.build(g,plan,terminals,ports,equipment)
  if #ports~=2 then return end
  local feeds={};local allowed={}
  for _,t in ipairs(terminals)do if not t.produce then
    if not t.mixed or not t.vertical or #t.keys~=2 or t.port.d~=2 then return end
    feeds[#feeds+1]=t;allowed[t.port.id]=true
  end end
  if #feeds~=2 then return end
  table.sort(feeds,function(a,b)return a.port.x<b.port.x end)
  local left,right=feeds[1].port,feeds[2].port
  if right.x<=left.x then return end
  local keys=U.copy(feeds[1].keys);local rates={};local sources={}
  for _,p in ipairs(ports)do sources[p.key]=p end
  for _,t in ipairs(feeds)do
    if #t.keys~=2 then return end
    for _,key in ipairs(keys)do
      if not sources[key]or not t.rates[key]then return end
      rates[key]=(rates[key]or 0)+t.rates[key]
    end
  end
  for _,key in ipairs(keys)do
    if U.split(key)~='item'or rates[key]>equipment.belt.belt_speed*14400+1e-6
      or math.abs(rates[key]-sources[key].rate)>1e-6 then return end
  end
  local best
  local first_y=g.plot_front or math.min(left.y,right.y)-7
  for _,p in ipairs(ports)do if p.internal then first_y=math.max(first_y,p.local_position.y)end end
  for y=first_y,math.min(left.y,right.y)-3 do
    for x=left.x,right.x-1 do for inlet=0,1 do for swap=0,1 do
      local mix=x+inlet;local branch=y+2;local cells,occupied={},{};local clear=true
      local function tile(px,py,d,labels)
        local cell=G.cell(px,py);local old=g.reserved[cell]
        if occupied[cell]or old and not allowed[old]or not g:free(px,py,'item',labels,old)then clear=false;return end
        occupied[cell]=true;cells[#cells+1]={x=px,y=py,d=d,keys=labels}
      end
      local a,b=keys[1+swap],keys[2-swap]
      tile(mix-1,y,1,a);tile(mix+1,y,3,b)
      tile(mix,y,2,keys)
      for px=x,x+1 do
        local cell=G.cell(px,y+1);local old=g.reserved[cell]
        if occupied[cell]or old and not allowed[old]or not g:free(px,y+1,'item',keys,old)then clear=false end
        occupied[cell]=true
      end
      for px=x,left.x,-1 do tile(px,branch,px==left.x and 2 or 3,keys)end
      for py=branch+1,left.y do tile(left.x,py,2,keys)end
      for px=x+1,right.x do tile(px,branch,px==right.x and 2 or 1,keys)end
      for py=branch+1,right.y do tile(right.x,py,2,keys)end
      local inputs={
        [a]={x=mix-1,y=y,d=1,plain=true,id='paired-feed/'..a},
        [b]={x=mix+1,y=y,d=3,plain=true,id='paired-feed/'..b}}
      local distance,turns=0,0
      for key,p in pairs(inputs)do local source=sources[key].local_position
        distance=distance+math.abs(p.x-source.x)+math.abs(p.y-source.y)
        -- A side-loader needs an approach from outside the mixer. Penalize
        -- crossing past it and returning, before the external routes exist.
        local approach=p.x+(p.d==1 and-1 or 1)
        turns=turns+(source.x==approach and 1 or 3)
      end
      local bends=(x>left.x and 2 or 0)+(x+1<right.x and 2 or 0)
      local score=#cells+10+distance+2*(turns+bends)
      if clear and(not best or score<best.score)then
        best={cells=cells,x=x,y=y,mix=mix,inputs=inputs,score=score}
      end
    end end end
  end
  if not best then return end
  local first=#g.entities+1
  g:add(equipment.splitter.name,best.x+1,best.y+1.5,8,nil,keys)
  -- The router owns the two ingress cells; they must remain empty endpoints.
  for i=3,#best.cells do local p=best.cells[i];g:tile(equipment.belt.name,p.x,p.y,p.d*4,nil,p.keys)end
  for _,p in pairs(best.inputs)do g:reserve(p.x,p.y,p.id)end
  local handled={};for _,t in ipairs(feeds)do handled[t]=true end
  plan.paired_feeds=plan.paired_feeds or{}
  plan.paired_feeds[#plan.paired_feeds+1]={keys=keys,rates=rates,inputs=U.copy(best.inputs),
    mixer={x=best.mix,y=best.y},splitter={x=best.x+1,y=best.y+1.5},
    consumers={U.copy(left),U.copy(right)},first=first,last=#g.entities,monotone=true}
  return{handled=handled,inputs=best.inputs,rates=rates}
end
return F
