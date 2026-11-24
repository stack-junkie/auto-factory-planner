local U=require('scripts.util')
local G=require('scripts.geometry')
local I=require('scripts.inserters')
local R={}
-- Ordinary production unloads straight onto outward-facing collectors. Stock
-- chests and their slot limits are specific to mall, never transport buffers.
function R.add(g,c,machines,short,long,equipment,arm,line,lanes,pickups,forward_outputs,compact_fanout,deferred)
  local banks,protected,terminals={},{},{}
  local feed={};for _,lane in ipairs(lanes or{})do feed[lane.y]=true end
  local function options(m)
    local b=m.box
    for _,side in ipairs({-b.side,b.side})do local edge=side<0 and b.y or b.y+b.h-1
      for index=1,(#long>0 and 3 or 1)do local y=edge+side*(index+1);local clear=not feed[y];for fy in pairs(feed)do if y>fy-3 and y<fy+2 then clear=false end end
        if not compact_fanout then for _,other in ipairs(machines)do local a=other.box;if y>=a.y and y<a.y+a.h then clear=false end end end
        if clear then local ay=edge+side*math.max(1,index-1)
          for x=b.x,b.x+b.w-1 do if g:free(x,ay)and not pickups[G.cell(x,ay)]and g:free(x,y)then return side,edge,index end end
        end
      end
    end
    U.fail('item-ports',c.machines[m.node.machine].localised_name)
  end
  -- Opposite machine banks can drop onto the two lanes of the same belt.
  -- Group by the belt coordinate, retaining each inserter's approach side.
  for _,m in ipairs(machines)do if m.remaining>1e-6 then
    local side,edge,index=options(m);local id=tostring(edge+side*(index+1))
    banks[id]=banks[id]or{edge=edge,side=side,index=index,keys={}}
    local items=banks[id].keys;items[m.key]=items[m.key]or{};items[m.key][#items[m.key]+1]={machine=m,side=side,edge=edge,index=index}
  end end
  for _,id in ipairs(U.sorted(banks))do local bank=banks[id];local keys=U.sorted(bank.keys)
    -- Adjacent collectors for different items cannot both cross the packed
    -- recipe bus: their underground endpoints would occupy each other's tap.
    -- Keep such production groups independent during the grouping search.
    if #keys>1 then U.fail('item-ports',equipment.belt.localised_name)end
    for ordinal,key in ipairs(keys)do local index=bank.index+ordinal-1;if index>3 then U.fail('item-ports',equipment.belt.localised_name)end;local y=bank.edge+bank.side*(index+1);local first,last,rate=math.huge,0,0
      for _,entry in ipairs(bank.keys[key])do local m=entry.machine;local remaining=m.remaining;rate=rate+remaining
        local pool=entry.index==1 and short or long
        for offset=0,m.box.w-1 do if remaining>1e-6 then
          local x=m.box.x+offset;local ay=entry.edge+entry.side*math.max(1,entry.index-1)
          if g:free(x,ay)and not pickups[G.cell(x,ay)]and not protected[G.cell(x,ay)]and g:free(x,y)then
            local selected,capacity
            for _,p in ipairs(pool)do if I.capacity(p,c,key)>=remaining-1e-6 then selected=p;break end end
            selected=selected or pool[#pool]
            if selected then capacity=I.capacity(selected,c,key)
              local e=arm(selected,x,ay,entry.side<0 and 8 or 0,{key},true)
              m.row.output_inserters[#m.row.output_inserters+1]=e.entity_number;protected[G.cell(x,y)]=true
              remaining=remaining-capacity;first=math.min(first,x);last=math.max(last,x)
            end
          end
        end end
        if remaining>1e-6 then U.fail('item-ports',c.machines[m.node.machine].localised_name)end
      end
      local forward=forward_outputs and forward_outputs[key]
      local start=forward and first or-1
      if deferred and forward then
        for x=start,last do if not g:free(x,y)then U.fail('layout-ports')end end
      else last=line(g,equipment,y,start,last,key,forward and 4 or 12,protected)end
      local port={x=forward and last+1 or-2,y=y,d=forward and 1 or 3,plain=true,id='rate/export/'..id..'/'..key};g:reserve(port.x,port.y,port.id)
      if deferred and forward then deferred[#deferred+1]={key=key,x0=start,x1=last,y=y,d=1,rate=rate,port_id=port.id}end
      terminals[#terminals+1]={key=key,port=port,rate=rate,produce=true,forward=forward}
    end
  end
  return terminals
end
return R
