local G=require('scripts.geometry')
local S={}
local function less(a,b)
  for i=1,3 do if a[i]~=b[i]then return a[i]<b[i]end end
  return false
end
local function angle(a,b)
  if not a or not b or a==4 or b==4 then return 0 end
  local d=(a-b)%4;return math.min(d,4-d)
end
local function estimate(s,n)
  local dx,dy=s.to.x-n.x,s.to.y-n.y
  local length=math.abs(dx)+math.abs(dy)
  local h=dx~=0 and(dx>0 and 1 or 3)or nil
  local v=dy~=0 and(dy>0 and 2 or 0)or nil
  local turns=0
  if h and v then turns=math.min(angle(n.d,h)+1+angle(v,s.to.d),angle(n.d,v)+1+angle(h,s.to.d))
  elseif h or v then local d=h or v;turns=angle(n.d,d)+angle(d,s.to.d)end
  return {n.length+length,n.turns+turns,0}
end
local function key(n)return G.cell(n.x,n.y)..','..n.d..','..(n.forced and 1 or 0)end
local function restart(s,r)
  r.frames={{x=s.from.x,y=s.from.y,d=s.from.d or 4,forced=s.from.d~=nil and not s.from.turnable,length=0,turns=0,tunnels=0}}
  r.visiting={[G.cell(s.from.x,s.from.y)]=true};r.best={};r.next_bound=nil
end
-- Iterative deepening with recursive branch-and-bound. Frames are plain saved
-- data so a preview can pause, save and resume in the middle of recursion.
function S.advance(g,s,budget,free,fail)
  local r=s.recursive
  if not r then
    r={iterations=0};s.recursive=r;restart(s,r);r.bound=estimate(s,r.frames[1]);s.h=nil;s.best=nil
  end
  local remaining=budget
  local function cut(score)
    if not r.next_bound or less(score,r.next_bound)then r.next_bound=score end
  end
  local function options(n,depth)
    local result={}
    for d=0,3 do if(n.d==4 or d~=(n.d+2)%4)and(not n.forced or d==n.d)then
      local turning=n.d~=4 and d~=n.d
      if not(turning and s.turn_boundary and n.y<s.turn_boundary)then
        local function offer(length,tunnel)
          local x,y=n.x+G.dx[d+1]*length,n.y+G.dy[d+1]*length
          if x<s.minx or x>s.maxx or y<s.miny or y>s.maxy or r.visiting[G.cell(x,y)]then return end
          if not free(x,y)then return end
          local goal=x==s.to.x and y==s.to.y
          if goal and s.to.d and((d+2)%4==s.to.d or(s.strict_terminal and not s.to.turnable or tunnel)and d~=s.to.d)then return end
          if tunnel and(depth==1 or goal and s.to.plain or not g:tunnel_free('item',n.x,n.y,x,y))then return end
          local node={x=x,y=y,d=d,forced=tunnel,length=n.length+length,turns=n.turns+(turning and 1 or 0),
            tunnels=n.tunnels+(tunnel and 1 or 0),jump=tunnel,len=length}
          node.estimate=estimate(s,node)
          node.preference=turning and s.corridor and math.abs(n[s.corridor.axis]-s.corridor.value)or 0
          result[#result+1]=node
        end
        offer(1,false)
        if s.underground and not n.forced and(n.d==4 or d==n.d)then for length=2,s.maxspan do offer(length,true)end end
      end
    end end
    table.sort(result,function(a,b)
      if less(a.estimate,b.estimate)then return true end;if less(b.estimate,a.estimate)then return false end
      if a.preference~=b.preference then return a.preference<b.preference end
      if a.tunnels~=b.tunnels then return a.tunnels<b.tunnels end
      if a.d~=b.d then return a.d<b.d end
      return a.len<b.len
    end)
    return result
  end
  local function visit(depth)
    local n=r.frames[depth]
    if not n.entered then
      if remaining<=0 then return 'pause'end
      remaining=remaining-1;s.pops=s.pops+1;s.expanded=s.expanded+1
      if s.pops>s.limit then fail('limit')end
      local bound=n.estimate or estimate(s,n)
      if less(r.bound,bound)then cut(bound);return 'back'end
      local cost={n.length,n.turns,0};local id=key(n);local previous=r.best[id]
      if previous and not less(cost,previous)then return 'back'end
      r.best[id]=cost;s.cursor={x=n.x,y=n.y}
      if n.x==s.to.x and n.y==s.to.y and(not s.to.d or s.to.turnable or not s.strict_terminal and not n.forced or n.d==s.to.d)then
        local turns=n.turns+((not s.strict_terminal or s.to.turnable)and n.d~=s.to.d and angle(n.d,s.to.d)or 0)
        local score={n.length,turns,0}
        if less(r.bound,score)then cut(score);return 'back'end
        s.path={};for i=1,depth do local p=r.frames[i]
          s.path[i]={x=p.x,y=p.y,d=p.d,jump=p.jump,len=p.len}
        end
        s.route_cost={objects=n.length+1,turns=turns,underground_pairs=n.tunnels}
        s.search_direction='source-to-consumer';s.search_method='recursive-branch-and-bound'
        return 'done'
      end
      n.entered=true;n.options=options(n,depth);n.index=1
    end
    while n.index<=#n.options do
      local child=r.frames[depth+1]
      if not child then
        child=n.options[n.index]
        if r.visiting[G.cell(child.x,child.y)]then n.options[n.index]=false;n.index=n.index+1
        else r.frames[depth+1]=child;r.visiting[G.cell(child.x,child.y)]=true end
      end
      if r.frames[depth+1]then
        local status=visit(depth+1)
        if status~='back'then return status end
        r.visiting[G.cell(child.x,child.y)]=nil;r.frames[depth+1]=nil;n.options[n.index]=false;n.index=n.index+1
      end
    end
    return 'back'
  end
  while remaining>0 do
    local status=visit(1)
    if status=='done'then s.recursive=nil;return true end
    if status=='pause'then return false end
    if not r.next_bound then fail('blocked')end
    r.bound=r.next_bound;r.iterations=r.iterations+1;restart(s,r)
  end
  return false
end
return S
