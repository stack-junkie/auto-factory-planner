local U=require('scripts.util')
local R=require('scripts.router')
local I=require('scripts.inserters')
local Links={}
function Links.add(g,c,group,machines,short,equipment,arm)
  local result={}
  local function capacity(key,rate)
    for _,p in ipairs(short)do if I.capacity(p,c,key)>=rate-1e-6 then return p end end
    return short[#short]
  end
  for _,key in ipairs(U.sorted(group.local_keys or{}))do
    for _,source in ipairs(machines)do if source.key==key and source.remaining>1e-6 then
      local chest=source.chest or source.export_chest or source.rate_cell and source.entity
      if chest then for _,target in ipairs(machines)do
        local rate=math.min(source.remaining,target.need[key]or 0)
        while rate>1e-6 do
          local selected=capacity(key,rate);local amount=math.min(rate,I.capacity(selected,c,key))
          local x,y=math.floor(chest.position.x),math.floor(chest.position.y)
          local output
          local upper=target.dual and target.box.side>0
          local edges=upper and {{0,-1,8},{1,0,12},{-1,0,4}} or {{0,1,0},{1,0,12},{-1,0,4}}
          for _,v in ipairs(edges)do
            if source.rate_cell then
              local b=source.box
              for offset=0,(v[1]==0 and b.w or b.h)-1 do
                local ax=v[1]>0 and b.x+b.w or v[1]<0 and b.x-1 or b.x+offset
                local ay=v[2]>0 and b.y+b.h or v[2]<0 and b.y-1 or b.y+offset
                local bx,by=ax+v[1],ay+v[2]
                -- The first belt must leave straight away from the machine.
                -- An earlier local transfer can leave the drop cell free
                -- while blocking that mandatory next step.
                if not output and g:free(ax,ay)and g:free(bx,by)and g:free(bx+v[1],by+v[2])
                  and(upper and by<target.box.y or not upper and by>=target.box.y)then output={x=ax,y=ay,bx=bx,by=by,d=v[3]}end
              end
              if output then break end
            else
            local ax,ay=x+v[1],y+v[2];local bx,by=ax+v[1],ay+v[2]
            if g:free(ax,ay)and g:free(bx,by)and(upper and by<target.box.y or not upper and by>=target.box.y)then output={x=ax,y=ay,bx=bx,by=by,d=v[3]};break end
            end
          end
          local input;local b=target.box
          for offset=0,b.w-1 do local ax,ay=b.x+offset,upper and b.y-1 or b.y+b.h;local by=upper and ay-1 or ay+1
            if g:free(ax,ay)and g:free(ax,by)then input={x=ax,y=ay,bx=ax,by=by};break end
          end
          if not output or not input then U.fail('item-ports',c.machines[target.node.machine].localised_name)end
          local take=arm(selected,output.x,output.y,output.d,{key},true)
          local feed=arm(selected,input.x,input.y,upper and 0 or 8,{key},false)
          local direction=output.bx<=input.bx and 1 or 3
          local from={x=output.bx,y=output.by,d=source.rate_cell and(output.d/4+2)%4 or direction,plain=true}
          local to={x=input.bx,y=input.by,d=direction,plain=true}
          local search=R.begin(from,to,'item',key,equipment.belt,equipment.underground,'cell/'..#result)
          search.minx=math.min(from.x,to.x)-2;search.maxx=math.max(from.x,to.x)+2
          search.miny=math.min(from.y,to.y)-(upper and 3 or 0);search.maxy=math.max(from.y,to.y)+(upper and 0 or 3);search.limit=4000
          while not R.advance(g,search,4096)do end
          local first=#g.entities+1;R.build(g,search)
          source.row.output_inserters[#source.row.output_inserters+1]=take.entity_number
          target.row.input_inserters[#target.row.input_inserters+1]=feed.entity_number
          source.remaining=source.remaining-amount;target.need[key]=target.need[key]-amount
          result[#result+1]={key=key,source=chest.entity_number,target=target.entity.entity_number,output=take.entity_number,
            inserter=feed.entity_number,first=first,last=#g.entities,rate=amount}
          rate=math.min(source.remaining,target.need[key]or 0)
        end
      end end
    end end
    for _,m in ipairs(machines)do if(m.need[key]or 0)>1e-6 then U.fail('item-ports',c.machines[m.node.machine].localised_name)end end
  end
  return result
end
return Links
