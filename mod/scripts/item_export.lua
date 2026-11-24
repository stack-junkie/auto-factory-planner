local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local E={}
-- Split the incoming lane, then side-load the two halves onto opposite sides.
-- A nearby priority tap supplies the small internal consumer before export.
local cells={{0,5,0},{0,3,3},{-1,3,0},{-1,2,0},{-1,1,1},
  {1,3,0},{1,2,0},{1,1,3},{0,1,0},{0,0,0},{0,-2,0},{1,-2,1},{2,-2,1}}
function E.collector(g,equipment,key,port)
  local d=port.d;local rx,ry=U.rotate(0,6,d);local x,y=port.x-rx,port.y-ry
  local function at(a,b)local px,py=U.rotate(a,b,d);return x+px,y+py end
  g:tile(equipment.belt.name,port.x,port.y,d*4,nil,key)
  for _,v in ipairs(cells)do if v[2]>=0 then local px,py=at(v[1],v[2]);g:tile(equipment.belt.name,px,py,((v[3]+d)%4)*4,nil,key)end end
  local px,py=at(.5,4);g:add(equipment.splitter.name,px+.5,py+.5,d*4,nil,key)
  px,py=at(0,-1)
  local result={x=px,y=py,d=d,plain=true,id=port.id..'/balanced',balanced=true}
  g:reserve(px,py,result.id)
  return result
end
function E.add(c,s,g,plan,equipment,key,net,turns,mirror)
  if not net.export or #net.sources~=1 or #net.sinks~=1 then return end
  local cheapest=C.options(c,'transport-belt',function(p)return p.belt_speed end)[1]
  if net.export.rate<=cheapest.belt_speed*14400 and not net.sources[1].port.balanced then return end
  local pin=s.manual_ports and s.manual_ports['out/'..key..'/'..(net.export.section or 1)]
  if not pin or not plan.project_offset then return end
  local tx,ty=U.rotate(pin.position.x-plan.project_offset.x,pin.position.y-plan.project_offset.y,(4-turns)%4)
  if mirror then ty=-ty end;tx,ty=math.floor(tx),math.floor(ty)
  local source,sink=net.sources[1].port,net.sinks[1].port
  local compact=source.balanced
  local ymin,ymax=compact and-1 or-2,compact and 1 or 5
  local xmin=compact and 0 or-1
  local input_y,output_y=compact and 2 or 6,compact and-1 or-2
  local template=compact and{{0,1,0},{0,-1,0},{1,-1,1},{2,-1,1}}or cells
  local approaches={{0,input_y},{0,input_y+1},{3,output_y},{4,output_y},{5,output_y},{0,output_y-1},{0,output_y-2}}
  local function at(x,y,d,px,py,hand)local a,b=U.rotate(px*(hand or 1),py,d);return x+a,y+b end
  local best
  for d=0,3 do for _,hand in ipairs({1,-1})do
    for x=g.minx-6,g.maxx+6 do for y=g.miny-8,g.maxy+4 do
      local ix,iy=at(x,y,d,0,input_y,hand);local ox,oy=at(x,y,d,0,output_y,hand);local bx,by=at(x,y,d,2,output_y,hand)
      local score=2*(math.abs(ix-source.x)+math.abs(iy-source.y)+math.abs(ox-tx)+math.abs(oy-ty))
        +.1*(math.abs(bx-sink.x)+math.abs(by-sink.y))
      local branch_distance=math.abs(bx-sink.x)+math.abs(by-sink.y)
      local dx,dy=ix-source.x,iy-source.y;local face=source.d or d
      local inline=d==face and dx*G.dy[face+1]-dy*G.dx[face+1]==0 and dx*G.dx[face+1]+dy*G.dy[face+1]>=0
      local length=compact and(score-.1*branch_distance)/2 or score
      local bends=compact and not inline and 1 or 0
      if not best or length<best.length-1e-6 or math.abs(length-best.length)<1e-6
        and(bends<best.bends or bends==best.bends and branch_distance<best.branch_distance)then
        local clear=true
        for a=xmin,2 do for b=ymin,ymax do local px,py=at(x,y,d,a,b,hand)
          if not g:free(px,py,'item',key)then clear=false;break end
        end;if not clear then break end end
        if clear then for _,v in ipairs(approaches)do local px,py=at(x,y,d,v[1],v[2],hand)
          if not g:free(px,py,'item',key)then clear=false;break end
        end end
        if clear then best={x=x,y=y,d=d,hand=hand,length=length,bends=bends,branch_distance=branch_distance}end
      end
    end end
  end end
  if not best then return end
  local x,y,d,hand=best.x,best.y,best.d,best.hand;local id='balanced-export/'..key
  for a=xmin,2 do for b=ymin,ymax do local px,py=at(x,y,d,a,b,hand);g:reserve(px,py,id)end end
  for _,v in ipairs(approaches)do local px,py=at(x,y,d,v[1],v[2],hand);g:reserve(px,py,id)end
  local made={}
  for _,v in ipairs(template)do local px,py=at(x,y,d,v[1],v[2],hand);made[#made+1]=g:tile(equipment.belt.name,px,py,((v[3]*hand+d)%4)*4,nil,key)end
  for _,v in ipairs(compact and{{1,.5}}or{{1,4.5},{1,-.5}})do local px,py=at(x,y,d,v[1]-.5,v[2]-.5,hand)
    made[#made+1]=g:add(equipment.splitter.name,px+.5,py+.5,d*4,(compact or v[2]<0)and{output_priority=hand==1 and'right'or'left'}or nil,key)
  end
  local function point(a,b,face)local px,py=at(x,y,d,a,b,hand);return{x=px,y=py,d=(face*hand+d)%4,plain=true,id=id}end
  local input,output,branch=point(0,input_y,0),point(0,output_y,0),point(2,output_y,1)
  net.export.local_position={x=output.x,y=output.y}
  local wx,wy=U.rotate(output.x+.5,mirror and-output.y-.5 or output.y+.5,turns)
  net.export.position={x=wx,y=wy};net.export.display_direction=(output.d+2)%4;net.export.balanced_export=true
  plan.lane_balancers[#plan.lane_balancers+1]={key=key,position={x=x,y=y},direction=d,hand=hand,input=input,output=output,branch=branch}
  local ug=C.pick(c,'underground-belt',nil,function(p)return p.belt_speed*14400>=net.export.rate*.6 end,function(p)return p.belt_speed end)
  plan.balanced_underground=plan.balanced_underground or{};plan.balanced_underground[key]=ug.name
  return point(0,input_y,0),point(3,output_y,1)
end
return E
