local U=require("scripts.util")
local P={}
function P.event(w,stage,first,detail,from,to)
  local event={stage=stage,first=first,last=#w.g.entities,detail=detail,from=from and U.copy(from),to=to and U.copy(to)}
  w.events[#w.events+1]=event
  return event
end
function P.point(w,p)
  local x,y=p.x,p.y;if w.mirror then y=-y end
  x,y=U.rotate(x,y,w.turns);return {x=x,y=y}
end
return P
