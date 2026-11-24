local G=require('scripts.geometry')
local P={}
function P.line(g,pipe,underground,x,y,nx,ny,key,keep)
  local dx=x==nx and 0 or(nx>x and 1 or-1);local dy=y==ny and 0 or(ny>y and 1 or-1)
  local length=math.abs(nx-x)+math.abs(ny-y);local span,base=0,0
  if underground then for _,box in pairs(underground.fluidbox_prototypes)do for _,connection in pairs(box.pipe_connections)do
    if connection.connection_type=='underground'then span=math.max(span,connection.max_underground_distance)
    elseif connection.connection_type=='normal'then base=(connection.direction or 0)/4 end
  end end end
  local d=dx>0 and 1 or dx<0 and 3 or dy>0 and 2 or 0
  local function fixed(i)
    if i==0 or i==length then return true end
    return keep and keep[G.cell(x+dx*i,y+dy*i)]
  end
  local i=0;local surface=false
  while i<=length do
    local last=i
    if not surface and not fixed(i)and span>=4 then
      while last<math.min(length,i+span)and not fixed(last+1)do last=last+1 end
    end
    if last-i>=4 and g:tunnel_free('fluid',x+dx*i,y+dy*i,x+dx*last,y+dy*last)then
      g:tile(underground.name,x+dx*i,y+dy*i,(((d+2)%4-base)%4)*4,nil,key)
      g:tile(underground.name,x+dx*last,y+dy*last,((d-base)%4)*4,nil,key)
      g:tunnel('fluid',x+dx*i,y+dy*i,x+dx*last,y+dy*last)
      i=last+1;surface=true
    else
      g:tile(pipe.name,x+dx*i,y+dy*i,0,nil,key);i=i+1;surface=false
    end
  end
end
return P
