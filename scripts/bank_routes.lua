local G=require('scripts.geometry')
local B={}
-- Match independent producer banks to consumer banks before introducing a
-- shared merge-and-fork tree. Each local collector feeds opposite belt lanes.
function B.add(g,equipment,key,net,parts,route,plan)
  if net.export or #net.sources<2 or #net.sinks<2 then return false end
  local groups={}
  for _,source in ipairs(net.sources)do
    local cell=source.cell;local part=cell and parts[cell]
    if not part or not part.group.split or #part.group.nodes~=1 or source.port.d~=2 then return false end
    groups[cell]=groups[cell]or{cell=cell,sources={},capacity=0,supply=0}
    groups[cell].sources[#groups[cell].sources+1]=source
    groups[cell].supply=groups[cell].supply+source.rate
  end
  local banks={}
  for _,bank in pairs(groups)do
    if #bank.sources~=2 then return false end
    local node=parts[bank.cell].group.nodes[1]
    bank.capacity=(node.output[key]or 0)*node.count*60*node.speed/node.energy
    bank.left,bank.right=math.huge,-math.huge;bank.y=-math.huge
    for _,source in ipairs(bank.sources)do local p=source.port
      bank.left=math.min(bank.left,p.x);bank.right=math.max(bank.right,p.x);bank.y=math.max(bank.y,p.y+2)
    end
    banks[#banks+1]=bank
  end
  if #banks~=#net.sinks or #banks>6 then return false end
  table.sort(banks,function(a,b)return a.left<b.left end)
  local best,bestcost;local assigned,used={},{}
  local function match(i,cost)
    if i>#banks then
      if not bestcost or cost<bestcost then bestcost=cost;best={};for j,v in ipairs(assigned)do best[j]=v end end
      return
    end
    local bank=banks[i]
    for j,sink in ipairs(net.sinks)do local p=sink.port;local part=sink.cell and parts[sink.cell]
      if not used[j]and part and part.group.split and p.d==2 and sink.rate<=math.min(bank.capacity,bank.supply)+1e-6
        and p.x>bank.left and p.x<bank.right and p.y>bank.y+1 then
        local distance=0;for _,source in ipairs(bank.sources)do distance=distance+math.abs(source.port.x-p.x)+math.abs(source.port.y-p.y)end
        if not bestcost or cost+distance<=bestcost then used[j]=true;assigned[i]=sink;match(i+1,cost+distance);used[j]=nil end
      end
    end
  end
  match(1,0);if not best then return false end
  local claimed={}
  local function free(x,y,allow)
    local cell=G.cell(x,y)
    if claimed[cell]or not g:free(x,y,'item',key,allow)then return false end
    claimed[cell]=true;return true
  end
  for i,bank in ipairs(banks)do local sink=best[i];local p=sink.port
    for x=bank.left,bank.right do if not free(x,bank.y)then return false end end
    for _,source in ipairs(bank.sources)do local a=source.port
      for y=a.y,bank.y-1 do if not free(a.x,y,a.id)then return false end end
    end
    for y=bank.y+1,p.y do if not free(p.x,y,p.id)then return false end end
  end
  plan.bank_links=plan.bank_links or{}
  for i,bank in ipairs(banks)do local sink=best[i];local p=sink.port
    for x=bank.left,bank.right do g:tile(equipment.belt.name,x,bank.y,x<p.x and 4 or x>p.x and 12 or 8,nil,key)end
    for _,source in ipairs(bank.sources)do local a=source.port
      route(key,a,{x=a.x,y=bank.y-1,d=2,plain=true,id='bank-collector/'..key..'/'..bank.cell})
    end
    local link=route(key,{x=p.x,y=bank.y+1,d=2,plain=true,id='bank-feed/'..key..'/'..bank.cell},p)
    link.vertical_route=true
    for y=bank.y+1,p.y do g.reserved[G.cell(p.x,y)]=link.id end
    plan.bank_links[#plan.bank_links+1]={key=key,source_cell=bank.cell,target_cell=sink.cell,capacity=bank.capacity,demand=sink.rate,
      collector={x0=bank.left,x1=bank.right,y=bank.y},feed={x=p.x,y0=bank.y+1,y1=p.y}}
  end
  return true
end
return B
