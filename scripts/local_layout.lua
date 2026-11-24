local U=require('scripts.util')
local G=require('scripts.geometry')
local C=require('scripts.catalogue')
local I=require('scripts.inserters')
local Straight=require('scripts.straight_cells')
local Shared=require('scripts.shared_rows')
local Fluid=require('scripts.fluid_cells')
local Intake=require('scripts.intake')
local Inputs=require('scripts.inputs')
local Displays=require('scripts.input_displays')
local Power=require('scripts.power')
local Paving=require('scripts.paving')
local Branch=require('scripts.branch_cells')
local Outputs=require('scripts.output_ports')
local ManualPorts=require('scripts.manual_ports')
local Grid=require('scripts.grid')
local Roboports=require('scripts.roboports')
local ItemExport=require('scripts.item_export')
local Frame=require('scripts.production_frame')
local Arrangement=require('scripts.arrangement')
local BankRoutes=require('scripts.bank_routes')
local PairedFeeds=require('scripts.paired_feeds')
local SharedOutputs=require('scripts.shared_outputs')
local Central=require('scripts.central_spine')
local N={}
local function point(x,y,d,id)return{x=x,y=y,d=d,plain=true,id=id}end
local function position(p,turns,mirror)
  local x,y=U.rotate(p.x+.5,mirror and -p.y-.5 or p.y+.5,turns);return{x=x,y=y}
end
local function arms(c,s)
  local result={};local override=s.infrastructure and s.infrastructure.inserter
  for _,p in ipairs(C.options(c,'inserter',function(v)return v.get_inserter_rotation_speed('normal')end))do
    if I.supported(p)and math.floor(-p.inserter_pickup_position[2]+.5)==1 and math.floor(p.inserter_drop_position[2]+.5)==1 and(not override or override==p.name)then result[#result+1]=p end
  end
  if #result==0 then U.fail('missing-infrastructure','inserter')end;return result
end
local function intersect(a,b,gap)
  return a.x0<b.x1+gap and b.x0<a.x1+gap and a.y0<b.y1+gap and b.y0<a.y1+gap
end
function N.begin(c,s,plan,equipment,turns,mirror)
  Frame.prepare(s,plan,turns,mirror)
  local g=G.new();g.isolate_items=true;g.item_ports={};g.debug_layout=s._debug_layout
  local spaced=s._shape_rows=='spaced'
  local gap_x,gap_y=spaced and 14 or 8,spaced and 7 or 3
  local events,connections,parts,groups={},{},{},{}
  local order=Intake.order(s,plan);local pool=arms(c,s);local byid,used={},{}
  local balanced_items={};local cheapest=C.options(c,'transport-belt',function(p)return p.belt_speed end)[1]
  for key,flow in pairs(plan.flows)do if U.split(key)=='item'and flow.internal_export and(flow.supply or 0)>cheapest.belt_speed*14400 then balanced_items[key]=true end end
  for _,n in ipairs(plan.nodes)do if n.direct_fanout then Arrangement.order(plan);break end end
  for _,n in ipairs(plan.nodes)do byid[n.id]=n end
  local function fluid_dependencies(n,group)
    if used[n.id]then return end
    used[n.id]=true;group.nodes[#group.nodes+1]=n
    for _,other in ipairs(plan.nodes)do if not used[other.id]and Fluid.has_fluid({nodes={other}})then
      local connected=false
      for key in pairs(n.input)do if other.output[key]and(U.split(key)=='fluid'or balanced_items[key])then connected=true end end
      for key in pairs(n.output)do if other.input[key]and(U.split(key)=='fluid'or balanced_items[key])then connected=true end end
      if connected then fluid_dependencies(other,group)end
    end end
  end
  for _,n in ipairs(plan.nodes)do if not used[n.id]then
    local group={nodes={},touching=true}
    if Fluid.has_fluid({nodes={n}})then fluid_dependencies(n,group)
    else group.nodes[1]=n;used[n.id]=true end
    local target=n.direct_target and byid[n.direct_target]
    if target and not used[target.id]then group.nodes[#group.nodes+1]=target;group.grouped=true;group.compact_fanout=n.direct_fanout;used[target.id]=true end
    groups[#groups+1]=group
  end end
  -- A recipe is not a compression unit: its physical banks are. Build each
  -- bank separately so a trial can move it and rebuild all external routes.
  local has_central=false
  if s._central_spine then for _,group in ipairs(groups)do if #group.nodes==1 then local n=group.nodes[1]
    for _,target in ipairs(plan.targets)do if n.output[target.key]and Central.spec(c,s,n,equipment.belt)then group.central_spine=true;has_central=true end end
  end end end
  local recipe_banks=not has_central and plan.compression_search and plan.single_recipe and plan.fixed_production and s.growth_direction
    and not Fluid.has_fluid({nodes=plan.nodes}) and #groups==1 and #groups[1].nodes==1
  if recipe_banks then
    local node=groups[1].nodes[1];local machine=c.machines[node.machine]
    local maximum=math.max(1,math.floor(((Paving.limit(s)or 46)-12)/machine.tile_width))
    local banks=s.input_rows=='single'and 1 or math.max(math.ceil(node.count/maximum),node.count>1 and 2 or 1)
    local remaining=node.count;local split={}
    for i=1,banks do
      local n=U.copy(node);n.count=math.ceil(remaining/(banks-i+1));n.crafts=node.crafts*n.count/node.count;remaining=remaining-n.count
      split[#split+1]={nodes={n},touching=true,split=true,bank_index=i,recipe_bank=true}
    end
    groups=split
  end
  local compact_items=plan.rate_search and s.growth_direction and plan.fixed_production and (#groups>1 or recipe_banks)and(Paving.limit(s)or 46)>=34 and not Fluid.has_fluid({nodes=plan.nodes})
  if compact_items and not spaced then gap_x,gap_y=2,2 end
  local finals={};for _,target in ipairs(plan.targets)do finals[target.key]=true end
  local function pairable(node)
    if #U.sorted(node.input)~=2 or #U.sorted(node.output)~=1 then return false end
    local capacity=equipment.belt.belt_speed*14400
    for _,side in ipairs({node.input,node.output})do for _,amount in pairs(side)do if amount*node.crafts>capacity+1e-6 then return false end end end
    for key in pairs(node.input)do local sources=0
      for _,p in ipairs(plan.ports)do if p.kind=='in'and p.key==key then sources=sources+1 end end
      for _,n in ipairs(plan.nodes)do if n.output[key]then sources=sources+1 end end
      if sources~=1 then return false end
    end
    return true
  end
  local independent_banks={}
  if compact_items then
    local folded={}
    for _,group in ipairs(groups)do
      local node=group.nodes[1];local final=false
      for key in pairs(node.output)do if finals[key]then final=true end end
      -- Bound final banks and also try shorter intermediate banks when
      -- the search requests them, preserving each recipe's total capacity.
      local compact_bank=not final and s._intermediate_bank or(s.snap_grid and s._shape_rows=='double'and 14 or 28)
      local threshold=compact_bank==14 and 14 or 24
      if not group.central_spine and not group.recipe_bank and #group.nodes==1 and final and #plan.targets==1 and s.input_rows~='single'
        and node.count>=2 and node.count<=28 and pairable(node)then
        local remaining=node.count
        for i=1,2 do local n=U.copy(node);n.count=math.ceil(remaining/(3-i));n.crafts=node.crafts*n.count/node.count;remaining=remaining-n.count
          folded[#folded+1]={nodes={n},touching=true,split=true,bank_index=i,recipe_bank=true}
        end
      elseif not group.central_spine and not group.recipe_bank and #group.nodes==1 and(final or s._intermediate_bank)and node.count>threshold then
        local banks=math.max(2,math.ceil(node.count/compact_bank));local remaining=node.count
        for i=1,banks do
          local n=U.copy(node);n.count=math.ceil(remaining/(banks-i+1));n.crafts=node.crafts*n.count/node.count;remaining=remaining-n.count
          folded[#folded+1]={nodes={n},touching=true,split=true,bank_index=i}
        end
      else folded[#folded+1]=group end
    end
    groups=folded
    if s._intermediate_bank then
      -- Allocate each upstream bank from its downstream bank's demand.
      -- Equal machine counts can have spare capacity, but must not leave
      -- the declared material flow split 50/50 when consumers are unequal.
      local banks={}
      for _,group in ipairs(groups)do if group.split then local id=group.nodes[1].id
        banks[id]=banks[id]or{};banks[id][#banks[id]+1]=group
      end end
      for _=1,#groups do local changed=false
        for _,sources in pairs(banks)do
          local node=sources[1].nodes[1];local key=U.sorted(node.output)[1]
          if not finals[key]then
            independent_banks[key]=nil
            local sinks={};local total,supply=0,0
            for _,group in ipairs(groups)do for _,n in ipairs(group.nodes)do if n.input[key]then
              sinks[#sinks+1]=n;total=total+n.crafts*n.input[key]
            end end end
            for _,group in ipairs(sources)do supply=supply+group.nodes[1].crafts*node.output[key]end
            if #sinks==#sources and math.abs(total-supply)<1e-6 then
              local valid=true
              for i,group in ipairs(sources)do local n=group.nodes[1]
                if sinks[i].crafts*sinks[i].input[key]>n.count*60*n.speed/n.energy*n.output[key]+1e-6 then valid=false;break end
              end
              if valid then independent_banks[key]=true;for i,group in ipairs(sources)do local n=group.nodes[1];local crafts=sinks[i].crafts*sinks[i].input[key]/n.output[key]
                if math.abs(n.crafts-crafts)>1e-8 then changed=true;n.crafts=crafts end
              end end
            end
          end
        end
        if not changed then break end
      end
    end
  end
  local config=U.copy(s);config.input_rows=compact_items and(s.input_rows or 'auto')or(s.input_rows=='double'and'double'or'single')
  if s.snap_grid and not compact_items and(not s.input_rows or s.input_rows=='auto')then
    config.input_rows=s._shape_rows=='spaced'and'single'or s._shape_rows or'auto'
  end
  config._shared_input_banks=compact_items
  config._balanced_items=balanced_items
  if s.growth_direction then
    config._forward_outputs={}
    for key,flow in pairs(plan.flows)do if U.split(key)=='item'and(flow.internal or 0)>0 and not flow.internal_export then config._forward_outputs[key]=true end end
    if compact_items then for key in pairs(finals)do config._forward_outputs[key]=true end end
  end
  local cell_limit=Paving.limit(s);config._cell_width=cell_limit and math.max(3,cell_limit-10)
  local shared_outputs=false;local pairs_by_node={}
  for _,group in ipairs(groups)do if group.recipe_bank then local id=group.nodes[1].id
    pairs_by_node[id]=pairs_by_node[id]or{};pairs_by_node[id][#pairs_by_node[id]+1]=group
  end end
  if compact_items then for id,list in pairs(pairs_by_node)do if #list==2 and pairable(byid[id])then
    shared_outputs=true;for _,group in ipairs(list)do group.common_output=true end
  end end end
  plan.branch_rows=not has_central and plan.single_recipe and plan.full_belt_collectors or false
  if plan.full_belt_collectors and #plan.nodes==1 then
    local n=plan.nodes[1];local key=U.sorted(n.output)[1]
    if #U.sorted(n.input)>1 and U.split(key)=='item'and n.output[key]*n.crafts>equipment.belt.belt_speed*14400+1e-6 then config.input_rows='double' end
  end
  local area,longest=0,0
  for _,group in ipairs(groups)do
    local final=false;for _,node in ipairs(group.nodes)do for key in pairs(node.output)do if finals[key]then final=true end end end
    local transverse=compact_items and not final and not group.compact_fanout
    if has_central and(s._central_transverse==false or s._central_transverse=='corner')then transverse=false end
    if transverse then
      local span=6;for _,node in ipairs(group.nodes)do span=math.max(span,6+node.count*c.machines[node.machine].tile_width)end
      if span>(Paving.limit(s)or 46)-12 then transverse=false end
    end
    local cell_config=config
    if transverse then cell_config=U.copy(config);cell_config._forward_outputs=nil;cell_config.input_rows='single' end
    if compact_items and(final or group.split)and #group.nodes==1 and group.nodes[1].count>=4 and s.input_rows~='single'then
      cell_config=U.copy(config);cell_config.input_rows='double'
    end
    if group.recipe_bank then cell_config=U.copy(config);cell_config.input_rows='single';cell_config._defer_outputs=group.common_output end
    local part
    if has_central and s._central_transverse=='corner'and not final then part=Central.root(c,cell_config,group,equipment)end
    if not part then
      if group.central_spine then cell_config=U.copy(config);cell_config._spine_swap=s._spine_swap;part=Central.build(c,cell_config,group,equipment)
      elseif Fluid.has_fluid(group)then part=Fluid.build(c,cell_config,group,pool,equipment,order)
      else part=Shared.build(c,cell_config,group,pool,equipment)or Straight.build(c,cell_config,group,pool,{},equipment,order)end
    end
    if not transverse and(plan.branch_rows or s.growth_direction and not Fluid.has_fluid(group)and not group.compact_fanout)then Branch.align(part)end
    if group.common_output and group.bank_index==2 then SharedOutputs.face_inward(part)end
    part.mixed_count=0;for _,t in ipairs(part.terminals)do if t.mixed then part.mixed_count=part.mixed_count+1 end end
    local bounds={x0=part.g.minx,y0=part.g.miny,x1=part.g.maxx,y1=part.g.maxy};local mixed=0
    for _,line in ipairs(part.collectors or{})do
      bounds.x0=math.min(bounds.x0,line.x);bounds.x1=math.max(bounds.x1,line.x+1)
      bounds.y0=math.min(bounds.y0,line.y0);bounds.y1=math.max(bounds.y1,line.y1+1)
    end
    for _,t in ipairs(part.terminals)do
      if t.forward then bounds.x1=math.max(bounds.x1,t.port.x+1);bounds.y1=math.max(bounds.y1,t.port.y+1)end
      if t.mixed and group.recipe_bank then
        -- Include the side-loading sockets and their entry cells, without
        -- retaining the old empty routing bay around the entire bank.
        bounds.x0=math.min(bounds.x0,t.port.x-2);bounds.x1=math.max(bounds.x1,t.port.x+3)
      elseif t.mixed then
        if part.branch_rows then
          local y=t.port.y-2-mixed*4
          bounds.y0=math.min(bounds.y0,y);bounds.x0=math.min(bounds.x0,t.port.x-4);bounds.x1=math.max(bounds.x1,t.port.x+5)
        else
          local x=t.port.x-2-mixed*4
          bounds.x0=math.min(bounds.x0,x);bounds.y0=math.min(bounds.y0,t.port.y-4);bounds.y1=math.max(bounds.y1,t.port.y+5)
        end
        mixed=mixed+1
      elseif not t.mixed then
        local x=t.port.x
        if not t.produce and not t.fluid and part.mixed_count>0 then
          if part.branch_rows then bounds.y0=math.min(bounds.y0,t.port.y-2-4*part.mixed_count)
          else x=x-2-4*part.mixed_count end
        end
        local approach=(group.recipe_bank or group.compact_fanout and part.mixed_count==0 or compact_items and part.branch_rows)and 0 or 3
        bounds.x0=math.min(bounds.x0,x-approach)
      end
    end
    part.bounds=bounds
    part.group=group;part.width=bounds.x1-bounds.x0;part.height=bounds.y1-bounds.y0
    parts[#parts+1]=part;area=area+part.width*(part.height+3);longest=math.max(longest,part.width)
  end
  if s._shape_rows=='single'or spaced then table.sort(parts,function(a,b)
    local aa,ba=a.width*a.height,b.width*b.height
    if aa~=ba then return aa>ba end
    if a.group.nodes[1].id~=b.group.nodes[1].id then return a.group.nodes[1].id<b.group.nodes[1].id end
    return(a.group.bank_index or 0)<(b.group.bank_index or 0)
  end)end
  local predecessors={}
  if s.growth_direction or plan.fixed_production then
    local producers={};for _,part in ipairs(parts)do for _,node in ipairs(part.group.nodes)do for key in pairs(node.output)do
      producers[key]=producers[key]or{};producers[key][#producers[key]+1]=part
    end end end
    for _,part in ipairs(parts)do
      local seen={};predecessors[part]={}
      for _,node in ipairs(part.group.nodes)do for key in pairs(node.input)do for _,source in ipairs(producers[key]or{})do
        if source~=part and not seen[source]then predecessors[part][#predecessors[part]+1]=source;seen[source]=true end
      end end end
    end
    local ordered,visited={},{}
    local function visit(part)
      if visited[part]then return end
      visited[part]=true
      for _,source in ipairs(predecessors[part])do visit(source)end
      ordered[#ordered+1]=part
    end
    for _,part in ipairs(parts)do visit(part)end
    parts=ordered
  end
  local width=math.max(longest,math.ceil(math.sqrt(area)*((compact_items or s._shape_rows=='double')and 1.1 or 1.7)))
  local packed_width
  if s._shape_rows=='single'then width=math.max(longest,math.min(220,area/12))end
  if plan.branch_rows and #parts>1 then
    local span=0;for _,part in ipairs(parts)do span=span+part.width end
    local strip=Paving.limit(s)
    if strip and Paving.axis(s)=='x'and span+gap_x*(#parts-1)>strip then
      gap_x=math.max(2,math.min(gap_x,math.floor((strip-span)/(#parts-1))))
    end
    packed_width=span+gap_x*(#parts-1)
    width=math.max(width,packed_width)
  end
  local limit=Paving.limit(s)
  if limit and Paving.axis(s)=='x'then width=math.min(width,limit)end
  if compact_items and limit then width=limit-(s.snap_grid and 0 or 2)end
  local input_ports,output_ports={},{}
  for _,p in ipairs(plan.ports)do local list=p.kind=='in'and input_ports or output_ports;list[#list+1]=p end
  local routing_width=0;local merge_clearance={}
  if compact_items then
    local counts={}
    local function count(key,produce)
      counts[key]=counts[key]or{0,0};local i=produce and 1 or 2;counts[key][i]=counts[key][i]+1
    end
    local paired_counts={}
    for _,part in ipairs(parts)do for _,t in ipairs(part.terminals)do for _,key in ipairs(t.keys or{t.key})do
      local id=part.group.common_output and(part.group.nodes[1].id..'/'..tostring(t.produce)..'/'..key)
      if not id or not paired_counts[id]then count(key,t.produce);if id then paired_counts[id]=true end end
    end end end
    for _,p in ipairs(input_ports)do count(p.key,true)end
    for _,p in ipairs(output_ports)do count(p.key,false)end
    -- A many-to-many stream needs both a merge and a fork between the
    -- producer and consumer banks. Keep room for that junction before
    -- placing the downstream machines, rather than enclosing its sockets.
    for key,v in pairs(counts)do if v[1]>1 and v[2]>1 then merge_clearance[key]=independent_banks[key]and 6 or(v[1]+v[2]-3)*3+7 end end
    for _,part in ipairs(parts)do if part.group.common_output then for key in pairs(part.group.nodes[1].input)do
      for _,node in ipairs(plan.nodes)do if node.output[key]then merge_clearance[key]=math.max(merge_clearance[key]or 0,6)end end
    end end end
    for _,v in pairs(counts)do if v[1]==1 and v[2]>1 or v[1]>1 and v[2]==1 then routing_width=routing_width+6 end end
    -- Forks at successive dependency levels reuse the same routing strip.
    routing_width=recipe_banks and 0 or math.min(routing_width,10)
  end
  for i,p in ipairs(output_ports)do
    p.index=#input_ports+i;p.local_position={x=2*(#input_ports+i-1),y=-4};p.position=position(p.local_position,turns,mirror)
  end
  if plan.branch_rows and #parts==1 and not recipe_banks then
    for _,t in ipairs(parts[1].terminals)do if t.produce then
      plan.intake_header_offset=t.port.x-parts[1].bounds.x0-2*#input_ports;break
    end end
  end
  if plan.branch_rows and #parts>1 then
    local context=s._project
    if context and context.intake_header_offset~=nil then plan.intake_header_offset=context.intake_header_offset
    elseif s.snap_grid and limit and packed_width>=limit and not(context and context.offset)then
      -- A full strip still needs one tile beside its first socket for the
      -- input display. Put the header inside the strip instead of widening it.
      plan.intake_header_offset=1
    end
  end
  Intake.prepare(s,plan,input_ports,order,turns,mirror)
  if plan.branch_rows then
    local front=math.huge;for _,p in ipairs(input_ports)do front=math.min(front,p.local_position.y)end
    if front<math.huge then g.plot_front=front;g.plot_front_body=front+Paving.margin(s);g.miny=g.plot_front_body;plan.intake_front=front end
  end
  plan.ports={};for _,list in ipairs({input_ports,output_ports})do for _,p in ipairs(list)do plan.ports[#plan.ports+1]=p end end
  plan.recipe_bus_order=U.copy(order);plan.production_rows={};plan.production_groups={};plan.mall_buffers={};plan.mall_links={};plan.cell_links={};plan.bank_links={};plan.lane_balancers={};plan.feed_corridors={};plan.feed_branches={}
  local boxes,terminals,placed,export_columns,part_boxes,collectors={},{},{},{},{},{}
  local first_y=-1;local fluid_plan=Fluid.has_fluid({nodes=plan.nodes})
  local fork_bay=plan.branch_rows and #input_ports==1 and #plan.nodes==1 and #U.sorted(plan.nodes[1].input)==1 and config.input_rows=='double'
  local fork_clearance=8
  if plan.fixed_production then
    fork_bay=plan.branch_rows
    if fork_bay then for _,part in ipairs(parts)do
      local counts={}
      for _,t in ipairs(part.terminals)do if not t.produce then
        if t.fluid or t.mixed then fork_bay=false;break end
        counts[t.key]=(counts[t.key]or 0)+1
        fork_clearance=math.max(fork_clearance,8+part.bounds.y0-t.port.y)
      end end
      local keys=U.sorted(counts)
      if #keys~=1 or counts[keys[1]]~=2 then fork_bay=false end
    end end
  end
  local direct_clearance=0;local pickups={}
  if plan.branch_rows then for _,part in ipairs(parts)do for _,t in ipairs(part.terminals)do if not t.produce then
    if t.fluid or t.mixed then direct_clearance=nil
    else
      pickups[t.key]=(pickups[t.key]or 0)+1
      if direct_clearance then direct_clearance=math.max(direct_clearance,part.bounds.y0-t.port.y)end
    end
  end end end end
  for _,count in pairs(pickups)do if count>1 then direct_clearance=nil end end
  first_y=-math.huge;for _,p in ipairs(input_ports)do first_y=math.max(first_y,p.local_position.y+(fork_bay and 8 or plan.branch_rows and 16 or plan.single_recipe and not fluid_plan and 1 or 5))end
  if first_y==-math.huge then first_y=0 end
  local first_x=0
  if #input_ports>0 then first_x=input_ports[1].local_position.x-(plan.intake_header_offset or 0)end
  if not plan.fixed_production and fluid_plan and Paving.grid_roads(s)and Paving.axis(s)=='x'and(plan.project_offset or s._project and s._project.offset)then
    -- Keep the denser body inside the same road interval as its persisted
    -- sockets. A wider manifold must not push machines onto the far road and
    -- force power relays to detour outside the factory strip.
    local step=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
    local approach=2
    if longest<=step-Paving.road_width-approach then width=math.min(width,step-Paving.road_width-approach)end
    local cell=math.floor((first_x-phase.x)/step);local target,distance,line
    for index=cell-1,cell+1 do
      local left=phase.x+index*step+Paving.road_width/2+approach
      local right=phase.x+(index+1)*step-Paving.road_width/2-width
      if left<=right then
        local candidate=math.max(left,math.min(right,first_x));local d=math.abs(candidate-first_x)
        if not distance or d<distance then target,distance,line=candidate,d,phase.x+index*step end
      end
    end
    first_x=target or first_x
    if line then plan.grid_strip={axis='x',line=line}end
  end
  if not plan.fixed_production and s.roboports and s.snap_grid and plan.branch_rows and Paving.axis(s)=='x'and not(s._project and s._project.offset)then
    -- Keep a new production strip between grid rows. Explicit world sockets
    -- are applied later and stay fixed while the interior uses the free strip.
    local origin=s._project and s._project.origin or s.port_origin or{x=.5,y=.5}
    plan.project_offset=plan.project_offset or Inputs.offset(origin,s,{x0=-3,y0=-4},plan.orientation)
    local step,prototype=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
    local cell=math.floor((first_x-phase.x)/step);local target,distance
    for index=cell-1,cell+1 do
      local left=phase.x+index*step+prototype.tile_width/2
      local right=phase.x+(index+1)*step-prototype.tile_width/2-width
      if left<=right then local candidate=math.max(left,math.min(right,first_x));local d=math.abs(candidate-first_x)
        if not distance or d<distance then target,distance=candidate,d end
      end
    end
    target=target or first_x
    local delta=target-first_x
    if delta~=0 then
      first_x=target;g.minx=target;g.maxx=target
      for _,p in ipairs(input_ports)do p.local_position.x=p.local_position.x+delta;p.position=position(p.local_position,turns,mirror)end
      if plan.power_base then plan.power_base.x=plan.power_base.x+delta end
    end
  end
  if not plan.fixed_production and plan.branch_rows and s._project and s._project.offset then
    -- Retired entrances stay in the world. Keep the outgoing collector clear
    -- of their columns when a replacement recipe or orientation moves the body.
    local offset=plan.project_offset or s._project.offset;local blocked={}
    for _,pin in ipairs(plan.project_inputs or{})do if not pin.active then
      local x,y=U.rotate(pin.position.x-offset.x,pin.position.y-offset.y,(4-turns)%4)
      blocked[math.floor(x+1e-6)]=true
    end end
    for attempt=1,#(plan.project_inputs or{})+1 do
      local collision=false
      for _,t in ipairs(parts[1].terminals)do if t.produce and blocked[first_x+t.port.x-parts[1].bounds.x0]then collision=true end end
      if not collision then break end;first_x=first_x+2
    end
  end
  if s.snap_grid and plan.branch_rows and Paving.axis(s)=='x'then
    -- The first header/display clearance belongs to the strip even when no
    -- entity occupies it yet. Keep power placement identical on recalculation.
    g.minx=first_x;g.maxx=first_x
  end
  if not plan.fixed_production and Paving.grid_roads(s)and plan.branch_rows and next(s.manual_ports or{})then
    -- Keep the complete entrance bay on the inside of the leading grid road.
    -- Only the approaches to selected world sockets may cross that boundary.
    local origin=s._project and s._project.origin or s.port_origin or{x=.5,y=.5}
    plan.project_offset=plan.project_offset or Inputs.offset(origin,s,{x0=-3,y0=-4},plan.orientation)
    local step=Grid.size(c,s);local phase=Grid.phase(s,plan,turns,mirror)
    local bay=9
    local line=phase.y+math.floor((first_y-bay-phase.y)/step)*step
    plan.grid_front={line=line,value=line+Paving.road_width/2}
    first_y=math.max(first_y,plan.grid_front.value+bay+3)
  end
  if not plan.fixed_production and plan.grid_strip then
    local span=Grid.size(c,s)
    g.plot_strip={axis=plan.grid_strip.axis,min=plan.grid_strip.line+Paving.road_width/2,max=plan.grid_strip.line+span-Paving.road_width/2}
    if not plan.grid_front then
      local phase=Grid.phase(s,plan,turns,mirror);local front=math.huge
      for _,port in ipairs(input_ports)do front=math.min(front,port.local_position.y)end
      if front<math.huge then
        local line=phase.y+math.floor((front-Paving.road_width/2-phase.y)/span)*span
        plan.grid_front={axis='y',line=line,value=line+Paving.road_width/2}
      end
    end
    if plan.grid_front then g.plot_front=plan.grid_front.value end
  end
  if plan.fixed_production then
    local bay=fork_bay and fork_clearance or plan.branch_rows and(direct_clearance or(recipe_banks and 8 or 16))or plan.single_recipe and not fluid_plan and 1 or 5
    -- One ordinary root feed has no splitter or mixer to house in a bay.
    if compact_items and not plan.branch_rows and not fluid_plan and #input_ports<=2 then
      local direct=true;local feeds=0
      for _,t in ipairs(parts[1].terminals)do if not t.produce then
        feeds=feeds+1
        if t.mixed or t.fluid or not t.key then direct=false end
      end end
      if direct and feeds==1 then bay=0 end
    end
    if #parts==1 and parts[1].group.compact_fanout then bay=0 end
    local front,available
    first_x,first_y,front,available=Frame.place(c,s,plan,fluid_plan,bay)
    if available then width=math.min(width,available)end
    for i,p in ipairs(input_ports)do
      p.local_position={x=first_x+(plan.intake_header_offset or 0)+2*(i-1),y=front-2}
      p.position=position(p.local_position,turns,mirror);p.pinned_direction=2
    end
    plan.power_base={x=first_x-1,y=front+1}
    g.plot_front=front;g.plot_front_body=front;g.miny=front;g.maxy=front;g.minx=first_x;g.maxx=first_x
    if (fluid_plan or recipe_banks or shared_outputs or has_central)and plan.grid_strip then
      g.plot_strip={axis='x',min=plan.grid_strip.line+3,max=plan.grid_strip.line+Grid.size(c,s)-3}
    end
    if compact_items then first_x=first_x+routing_width;width=math.max(longest,width-routing_width)end
  end
  plan.production_start=first_y
  plan.compression_blocks={}
  plan.compression_limits={x0=first_x-routing_width,x1=first_x+width,y0=first_y}
  for i,part in ipairs(parts)do part.compression_id=i end
  for pi,part in ipairs(parts)do
    local start=first_y
    for _,source in ipairs(predecessors[part]or{})do local b=part_boxes[source];if b then
      local gap=gap_y
      for _,node in ipairs(part.group.nodes)do for key in pairs(node.input)do for _,producer in ipairs(source.group.nodes)do
        if producer.output[key]then gap=math.max(gap,merge_clearance[key]or 0)end
      end end end
      start=math.max(start,b.y1+gap)
    end end
    -- Keep enough horizontal space for the next bank of this recipe.
    -- Centring the first bank can otherwise force its sibling into a new row.
    local shelf_span=part.width
    if s._intermediate_bank and part.group.split then
      local id=part.group.nodes[1].id;local first=true
      for _,other in ipairs(parts)do if other~=part and other.group.split and other.group.nodes[1].id==id then
        if part_boxes[other]then first=false;break end
        if shelf_span+gap_x+other.width<=width then shelf_span=shelf_span+gap_x+other.width end
      end end
      if not first then shelf_span=part.width end
    end
    local xs,ys={[first_x]=true},{[start]=true}
    for _,b in ipairs(boxes)do xs[b.x0]=true;xs[b.x1+gap_x]=true;ys[b.y0]=true;ys[b.y1+gap_y]=true end
    if part.group.common_output and #(part.collectors or{})==1 then local line=part.collectors[1]
      for _,b in ipairs(boxes)do if b.output_key==line.key then xs[b.output_x-line.x+part.bounds.x0]=true end end
    end
    local best;local override=s._compression_positions and s._compression_positions[pi]
    for _,x in ipairs(U.sorted(xs))do for _,y in ipairs(U.sorted(ys))do
      local box=SharedOutputs.mark({x0=x,y0=y,x1=x+part.width,y1=y+part.height},part);local clear=not override and x+shelf_span<=first_x+width and y>=start
      for _,b in ipairs(boxes)do if intersect(box,b,2)and not SharedOutputs.overlap(box,b)then clear=false;break end end
      if clear and plan.branch_rows then
        for _,out in ipairs(export_columns)do if out.x>=box.x0 and out.x<box.x1 and box.y0<=out.y
          and not(box.output_x==out.x and box.output_key==out.key)then clear=false;break end end
        for _,t in ipairs(part.terminals)do if t.produce then
          local ox,oy=x+t.port.x-part.bounds.x0,y+t.port.y-part.bounds.y0
          for _,b in ipairs(boxes)do if ox>=b.x0 and ox<b.x1 and b.y0<=oy
            and not(b.output_x==ox and b.output_key==t.key)then clear=false;break end end
        end end
      end
      if clear then
        local right,bottom=box.x1,box.y1;for _,b in ipairs(boxes)do right=math.max(right,b.x1);bottom=math.max(bottom,b.y1)end
        local score=(right-first_x)*(bottom-first_y)*.12
        if compact_items then score=score+(bottom-first_y)*20 end
        if fluid_plan and Paving.grid_roads(s)and s._shape_rows=='double'then score=score+(bottom-first_y)*20 end
        if s._shape_rows=='single'then score=score+(bottom-first_y)*3
        elseif s._shape_rows=='auto'then score=score+math.abs((right-first_x)-(bottom-first_y)*1.3)end
        for _,t in ipairs(part.terminals)do for _,key in ipairs(t.keys or{t.key})do
          local px=x+t.port.x-part.bounds.x0;local py=y+t.port.y-part.bounds.y0
          for _,old in ipairs(placed[key]or{})do if old.produce~=t.produce then score=score+math.abs(old.port.x-px)+math.abs(old.port.y-py)end end
        end end
        if not best or score<best.score then best={box=box,score=score}end
      end
    end end
    if override then
      local box=SharedOutputs.mark({x0=override.x,y0=override.y,x1=override.x+part.width,y1=override.y+part.height},part)
      local limits=plan.compression_limits
      if box.x0<limits.x0 or box.x1>limits.x1 or box.y0<limits.y0 then U.fail('layout-ports')end
      for _,old in ipairs(boxes)do if intersect(box,old,0)and not SharedOutputs.overlap(box,old)then U.fail('layout-ports')end end
      for _,source in ipairs(predecessors[part]or{})do if box.y0<part_boxes[source].y1 then U.fail('layout-ports')end end
      best={box=box}
    end
    if not best then U.fail('width',part.width+Paving.margin(s)*2,Paving.maximum(s) or width)end
    local box=SharedOutputs.mark(best.box,part);boxes[#boxes+1]=box;part_boxes[part]=box
    local dependencies={};for _,source in ipairs(predecessors[part]or{})do dependencies[#dependencies+1]=source.compression_id end
    plan.compression_blocks[#plan.compression_blocks+1]={id=pi,x0=box.x0,y0=box.y0,x1=box.x1,y1=box.y1,predecessors=dependencies,output_x=box.output_x,output_key=box.output_key}
    local dx,dy=box.x0-part.bounds.x0,box.y0-part.bounds.y0;local offset=#g.entities;local first=offset+1
    if plan.branch_rows then for _,t in ipairs(part.terminals)do if t.produce then export_columns[#export_columns+1]={x=t.port.x+dx,y=t.port.y+dy,key=t.key}end end end
    for _,e in ipairs(part.g.entities)do local extra=U.copy(e);extra.position=nil;extra.entity_number=nil;g:add(e.name,e.position.x+dx,e.position.y+dy,e.direction,extra)end
    for cell,id in pairs(part.g.reserved)do local x,y=cell:match('^(-?%d+),(-?%d+)$');x,y=tonumber(x)+dx,tonumber(y)+dy
      local old=g.reserved[G.cell(x,y)]
      local shared=part.group.common_output and x==box.output_x and old and id:match('^rate/export/')and old:match('^%d+/rate/export/')
      if not shared then g:reserve(x,y,pi..'/'..id,part.g.fluid_ports[cell])end
    end
    for _,t in ipairs(part.g.tunnels)do if t.horizontal then g:tunnel(t.kind,t.lo+dx,t.y+dy,t.hi+dx,t.y+dy)else g:tunnel(t.kind,t.x+dx,t.lo+dy,t.x+dx,t.hi+dy)end end
    local row_start=#plan.production_rows+1
    for _,original in ipairs(part.rows)do local row=U.copy(original)
      if part.group.recipe_bank or s._intermediate_bank and part.group.split then
        for _,node in ipairs(part.group.nodes)do if node.id==row.node then row.crafts_per_machine=node.crafts/node.count end end
      end
      for _,list in ipairs({row.machines,row.input_inserters,row.output_inserters})do for i,id in ipairs(list)do list[i]=id+offset end end
      row.bounds={x0=row.bounds.x0+dx,y0=row.bounds.y0+dy,x1=row.bounds.x1+dx,y1=row.bounds.y1+dy}
      if row.output_collector then local tap=row.output_collector.tap;tap.x=tap.x+dx;tap.y=tap.y+dy end
      plan.production_rows[#plan.production_rows+1]=row
    end
    for _,link in ipairs(part.links or{})do local copy=U.copy(link);for _,field in ipairs({'source','target','inserter'})do if copy[field]then copy[field]=copy[field]+offset end end;plan.mall_links[#plan.mall_links+1]=copy end
    for _,link in ipairs(part.cell_links or{})do local copy=U.copy(link);for _,field in ipairs({'source','target','output','inserter','first','last'})do if copy[field]then copy[field]=copy[field]+offset end end;plan.cell_links[#plan.cell_links+1]=copy end
    for _,line in ipairs(part.corridors or{})do local copy=U.copy(line)
      if copy.vertical then copy.x=copy.x+dx;copy.y0=copy.y0+dy;copy.y1=copy.y1+dy
      else copy.x0=copy.x0+dx;copy.x1=copy.x1+dx;copy.y=copy.y+dy end
      plan.feed_corridors[#plan.feed_corridors+1]=copy
    end
    for _,line in ipairs(part.collectors or{})do collectors[#collectors+1]={key=line.key,x=line.x+dx,y0=line.y0+dy,y1=line.y1+dy,
      rate=line.rate,port_id=pi..'/'..line.port_id}end
    local recipes={};for _,n in ipairs(part.group.nodes)do recipes[n.recipe]=true end
    plan.production_groups[#plan.production_groups+1]={recipes=U.sorted(recipes),rows={first=row_start,last=#plan.production_rows},direct=true}
    if part.central_spine then local line=U.copy(part.central_spine)
      line.x=line.x+dx;line.y0=line.y0+dy;line.y1=line.y1+dy;line.feed_x=line.feed_x+dx
      plan.central_spines=plan.central_spines or{};plan.central_spines[#plan.central_spines+1]=line
      plan.shared_collectors=plan.shared_collectors or{};plan.shared_collectors[#plan.shared_collectors+1]=U.copy(line)
    end
    if part.central_export then
      plan.central_exports=plan.central_exports or{}
      plan.central_exports[#plan.central_exports+1]={input=part.central_export.input+offset,key=part.central_export.key,port_id=pi..'/central/out'}
    end
    for _,original in ipairs(part.terminals)do local t=U.copy(original);t.port.x=t.port.x+dx;t.port.y=t.port.y+dy;t.port.id=pi..'/'..t.port.id;t.cell=pi;t.mixed_count=part.mixed_count;t.vertical=part.branch_rows
      terminals[#terminals+1]=t;for _,key in ipairs(t.keys or{t.key})do placed[key]=placed[key]or{};placed[key][#placed[key]+1]=t end
    end
    events[#events+1]={stage='machines',first=first,last=#g.entities}
  end
  Central.connect(c,g,plan,terminals)
  if #collectors>0 then
    local first=#g.entities+1;terminals=SharedOutputs.add(g,plan,collectors,terminals,equipment.belt)
    events[#events+1]={stage='machines',first=first,last=#g.entities}
  end
  local networks={}
  local function terminal(key,p,produce,rate,cell)
    networks[key]=networks[key]or{sources={},sinks={}};local list=produce and networks[key].sources or networks[key].sinks
    list[#list+1]={port=p,rate=rate,cell=cell}
  end
  local prefixes,obstacles,mixed_index={},{},{}
  local paired
  if shared_outputs then
    local banks={};for _,t in ipairs(terminals)do if not t.produce and parts[t.cell]and parts[t.cell].group.common_output then banks[#banks+1]=t end end
    if #banks==2 and banks[1].mixed then
      local sources={};local counts={}
      for _,p in ipairs(input_ports)do sources[p.key]=p;counts[p.key]=(counts[p.key]or 0)+1 end
      for _,t in ipairs(terminals)do if t.produce then
        sources[t.key]={key=t.key,rate=t.rate,local_position=t.port,pinned_direction=t.port.d,internal=true};counts[t.key]=(counts[t.key]or 0)+1
      end end
      local inputs={};for _,key in ipairs(banks[1].keys)do if counts[key]==1 then inputs[#inputs+1]=sources[key]end end
      paired=PairedFeeds.build(g,plan,banks,inputs,equipment)
      if #inputs==2 and not paired then U.fail('layout-ports')end
    end
  end
  if paired then for key,p in pairs(paired.inputs)do terminal(key,p,false,paired.rates[key])end end
  for _,t in ipairs(terminals)do
    if paired and paired.handled[t]then
      -- These original two-lane terminals already have a shared feed tree.
    elseif t.mixed then
      local index=mixed_index[t.cell]or 0;mixed_index[t.cell]=index+1
      local x,y=t.vertical and t.port.y-2-index*4 or t.port.x-2-index*4,t.vertical and t.port.x or t.port.y
      prefixes[#prefixes+1]={x0=x,x1=t.vertical and t.port.y or t.port.x,y=y,keys=t.keys,vertical=t.vertical}
      for j,key in ipairs(t.keys)do local p
        if t.vertical then p=point(y+(j==1 and-1 or 1),x,j==1 and 1 or 3,t.port.id..'/'..j)
        else p=point(x,y+(j==1 and-1 or 1),j==1 and 2 or 0,t.port.id..'/'..j)end
        obstacles[G.cell(p.x,p.y)]=true;terminal(key,p,false,t.rates[key],t.cell)
      end
    elseif not t.produce and not t.fluid and t.mixed_count>0 then
      local p=U.copy(t.port)
      if t.vertical then p.y=p.y-2-4*t.mixed_count;prefixes[#prefixes+1]={x0=p.y+1,x1=t.port.y,y=p.x,keys={t.key},vertical=true}
      else p.x=p.x-2-4*t.mixed_count;prefixes[#prefixes+1]={x0=p.x+1,x1=t.port.x,y=p.y,keys={t.key}}end
      terminal(t.key,p,false,t.rate,t.cell)
    else
      if compact_items and t.produce and not t.fluid then t.port.turnable=true end
      terminal(t.key,t.port,t.produce,t.rate,t.cell)
    end
  end
  -- Side-loading one lane must not occupy the neighbouring ingredient belt.
  -- Stagger the mixers and bridge only those exact crossing cells.
  for _,line in ipairs(prefixes)do local x=line.x0
    local function cell(v)return line.vertical and G.cell(line.y,v)or G.cell(v,line.y)end
    local function tile(name,v,kind)return g:tile(name,line.vertical and line.y or v,line.vertical and v or line.y,line.vertical and 8 or 4,kind and{type=kind}or nil,line.keys)end
    while x<=line.x1 do
      if obstacles[cell(x+1)]and x<line.x1 then
        local last=x+2;while obstacles[cell(last)]do last=last+1 end
        if last>line.x1 or last-x>equipment.underground.max_underground_distance then U.fail('layout-ports')end
        tile(equipment.underground.name,x,'input');tile(equipment.underground.name,last,'output')
        if line.vertical then g:tunnel('item',line.y,x,line.y,last)else g:tunnel('item',x,line.y,last,line.y)end;x=last+1
      else tile(equipment.belt.name,x);x=x+1 end
    end
  end
  if plan.fixed_production then
    local bounds={x0=math.huge,y0=math.huge,x1=-math.huge,y1=-math.huge}
    for _,b in ipairs(boxes)do bounds.x0=math.min(bounds.x0,b.x0);bounds.y0=math.min(bounds.y0,b.y0);bounds.x1=math.max(bounds.x1,b.x1);bounds.y1=math.max(bounds.y1,b.y1)end
    plan.fixed_production_bounds=bounds
  end
  ManualPorts.prepare(g,s,plan,equipment,turns,mirror)
  for _,p in ipairs(input_ports)do terminal(p.key,point(p.local_position.x,p.local_position.y,p.pinned_direction or 2,'user/'..p.id),true,p.rate)end
  for _,p in ipairs(output_ports)do
    local network=networks[p.key]
    if network and #network.sources==1 and #network.sinks==0 then
      local source=network.sources[1].port;p.local_position={x=source.x,y=source.y};p.position=position(p.local_position,turns,mirror);p.display_direction=((source.d or 3)+2)%4
      local marker=g.occupied[G.cell(source.x,source.y)]
      if U.split(p.key)~='fluid'or not marker then
        g:tile(U.split(p.key)=='fluid'and equipment.pipe.name or equipment.belt.name,source.x,source.y,U.split(p.key)=='fluid'and 0 or source.d*4,nil,p.key)
      elseif marker.fluid~=p.key then U.fail('layout-ports')end
      network.direct=true
    elseif network then
      -- A final product leaves at its local merge, without a return belt
      -- across every other production block to the external input header.
      network.export=p
    else U.fail('port',U.name(p.key))end
  end
  Inputs.inactive(g,s,plan);Inputs.protect(g,s,plan)
  Roboports.reserve(c,s,g,plan,turns,mirror)
  Displays.reserve(c,s,g,plan)
  -- A merge has not selected its outlet yet. Reserving its provisional
  -- origin can cut through a bank when the primary cell is at negative Y.
  local ready={ports={},branch_rows=plan.branch_rows}
  for _,p in ipairs(plan.ports)do
    local network=networks[p.key]
    if not network or network.export~=p then ready.ports[#ready.ports+1]=p end
  end
  Outputs.reserve(g,ready)
  for _,key in ipairs(U.sorted(networks))do local net=networks[key];if not net.direct then Intake.fork(g,plan,key,net,equipment)end end
  -- Protect every terminal before locating any shared junction. A later
  -- network must not occupy the only way out of an earlier cell.
  for key,net in pairs(networks)do if not net.direct then
    for _,side in ipairs({{net.sources,true},{net.sinks,false}})do for _,t in ipairs(side[1])do
      local p=t.port;local d=side[2]and(p.d or 3)or((p.d or 1)+2)%4
      if U.split(key)=='item'then g.item_ports[G.cell(p.x,p.y)]=key end
      for step=0,compact_items and 1 or 2 do local x,y=p.x+G.dx[d+1]*step,p.y+G.dy[d+1]*step;local cell=G.cell(x,y)
        if not g.occupied[cell]and not g.reserved[cell]then g:reserve(x,y,p.id or key)end
      end
    end end
  end end
  local function claim(p,d,id)
    -- A cell builder can protect a longer approach than this route needs.
    -- Transfer the entire socket reservation, including its unused tail,
    -- so a connection does not detour around its own reserved cells.
    if p.id then for cell,owner in pairs(g.reserved)do if owner==p.id then g.reserved[cell]=id end end end
    for step=0,compact_items and 1 or 3 do local x,y=p.x+G.dx[d+1]*step,p.y+G.dy[d+1]*step;local cell=G.cell(x,y)
      if not g.occupied[cell]then
        local old=g.reserved[cell]
        if not old or old==p.id or old:match('^belt%-end/')then g.reserved[cell]=id end
      end
    end
  end
  local function route(key,a,b,fluid)
    if not fluid and a.id and a.id:match('^user/in/')then b.turnable=true end
    local id='local/'..(#connections+1);claim(a,a.d or 3,id);claim(b,((b.d or 1)+2)%4,id)
    if not fluid then g.item_ports[G.cell(a.x,a.y)]=key;g.item_ports[G.cell(b.x,b.y)]=key end
    connections[#connections+1]={key=key,from=U.copy(a),to=U.copy(b),id=id,direct_route=true,local_route=fluid,network=key}
    return connections[#connections]
  end
  local junction_boxes={}
  local function site(w,h,list,key)
    local cx,cy,n=0,0,0
    for _,side in ipairs({list.sources,list.sinks})do for _,t in ipairs(side)do cx=cx+t.port.x;cy=cy+t.port.y;n=n+1 end end
    cx=math.floor(cx/n);cy=math.floor(cy/n-h/2)
    local upstream=compact_items and #list.sources==1 and #list.sinks>1
    local downstream=compact_items and #list.sources>1 and #list.sinks==0 and list.export
    if upstream then
      -- Split before the first consumer instead of feeding past it and
      -- returning from a junction placed at the centre of the whole factory.
      table.sort(list.sinks,function(a,b)return a.port.y==b.port.y and a.port.x<b.port.x or a.port.y<b.port.y end)
      cx=cx-(list._junction_flip and 3 or 1)
      cy=list._junction_top or(list.sinks[1].port.y-h+4)
    elseif downstream then
      table.sort(list.sources,function(a,b)return a.port.y==b.port.y and a.port.x<b.port.x or a.port.y<b.port.y end)
      cx=cx-1;cy=list.sources[#list.sources].port.y
    end
    local best
    local x0,x1=math.min(g.minx-12,cx-12),math.max(g.maxx+8,cx+12)
    local y0,y1=math.min(g.miny-6,cy-6),math.max(g.maxy+8,cy+12)
    for x=x0,x1 do for y=y0,y1 do
      local before=(g.maxx-g.minx)*(g.maxy-g.miny)
      local after=(math.max(g.maxx,x+w)-math.min(g.minx,x))*(math.max(g.maxy,y+h)-math.min(g.miny,y))
      local score=math.abs(cx-x)+math.abs(cy-y)+math.max(0,after-before)*.015
      if(not upstream or y>=list.sources[1].port.y and y<=cy)and(not downstream or y>=cy)and(not best or score<best.score)then local clear=true
        local body={x0=x,y0=y,x1=x+math.min(w,3),y1=y+h}
        if not compact_items then for _,block in ipairs(boxes)do if intersect(body,block,1)then clear=false;break end end end
        for _,old in ipairs(junction_boxes)do if intersect(body,old,compact_items and 1 or 2)then clear=false;break end end
        if clear then for px=x,x+w-1 do for py=y,y+h-1 do if not g:free(px,py,U.split(key),key)then clear=false;break end end;if not clear then break end end end
        if clear and compact_items then
          local entry=x+(list._junction_flip and 3 or 0)
          clear=g:free(entry,y-1,'item',key,list.sources[1].port.id)
          if clear then clear=g:free(entry,y+h,'item',key)end
          local outside=x+(list._junction_flip and-1 or 4)
          for i,offset in ipairs(list._junction_offsets or{})do if clear then
            local merge=i<#list.sources
            clear=g:free(outside,y+offset+(merge and-1 or 1),'item',key,merge and list.sources[i+1].port.id or nil)
          end end
        end
        if clear and list.export and U.split(key)=='item'and plan.branch_rows then
          for py=y+h,g.maxy+2 do if g.occupied[G.cell(x,py)]then clear=false;break end end
        end
        if clear then best={x=x,y=y,score=score}end
      end
    end end
    if not best then U.fail('layout-ports')end
    return best.x,best.y
  end
  local function export_line(key,net)
    if not compact_items or not net.export or #net.sinks~=0 or #net.sources<2 or net.export.rate>equipment.belt.belt_speed*14400 then return false end
    local left,right,last,seen=math.huge,-math.huge,-math.huge,{}
    for _,source in ipairs(net.sources)do local p=source.port
      if p.d~=2 or seen[p.x]then return false end;seen[p.x]=true
      left=math.min(left,p.x);right=math.max(right,p.x);last=math.max(last,p.y)
    end
    local y=last+2
    for x=left-1,right do if not g:free(x,y,'item',key)then return false end end
    for _,source in ipairs(net.sources)do local p=source.port
      for py=p.y,y-1 do if not g:free(p.x,py,'item',key,p.id)then return false end end
    end
    -- A single lane can carry this entire export. Feed a straight collector
    -- at the ends of the banks instead of returning to a splitter tree.
    for x=left-1,right do g:tile(equipment.belt.name,x,y,12,nil,key)end
    for _,source in ipairs(net.sources)do local p=source.port
      route(key,p,point(p.x,y-1,2,'export-line/'..key))
      local connection=connections[#connections];connection.vertical_route=true
      for py=p.y,y-1 do g.reserved[G.cell(p.x,py)]=connection.id end
    end
    local p=net.export;p.local_position={x=left-1,y=y}
    if recipe_banks then
      -- Let the merged product leave in the growth direction. Returning it
      -- to the transverse edge would put its extension on the side road.
      g.occupied[G.cell(left-1,y)].entity.direction=8;p.display_direction=0
    else p.display_direction=1 end
    p.position=position(p.local_position,turns,mirror)
    return true
  end
  for _,key in ipairs(U.sorted(networks))do local net=networks[key];local m,n=#net.sources,#net.sinks+(net.export and 1 or 0)
    if not net.direct then
      if m==0 or n==0 then U.fail('port',U.name(key))end
      if U.split(key)=='fluid'then
        if m==1 and n==1 then route(key,net.sources[1].port,net.sinks[1].port,true)
        else local x,y=site(1,1,net,key);g:tile(equipment.pipe.name,x,y,0,nil,key)
          for _,list in ipairs({net.sources,net.sinks})do for _,t in ipairs(list)do route(key,t.port,point(x,y,0),true)end end
          if net.export then local p=net.export;p.local_position={x=x,y=y};p.position=position(p.local_position,turns,mirror);p.display_direction=2 end
        end
      elseif m==1 and n==1 then route(key,net.sources[1].port,net.sinks[1].port)
      elseif independent_banks[key]then
        if not BankRoutes.add(g,equipment,key,net,parts,route,plan)then U.fail('layout-ports')end
      elseif export_line(key,net)then
      else
        local input,branch=ItemExport.add(c,s,g,plan,equipment,key,net,turns,mirror)
        if input then
          route(key,net.sources[1].port,input)
          route(key,branch,net.sinks[1].port)
        else
        local stages=m+n-2;local levels
        if compact_items and m==1 and not net.export then
          table.sort(net.sinks,function(a,b)return a.port.y==b.port.y and a.port.x<b.port.x or a.port.y<b.port.y end)
          levels={};levels[stages]=math.min(net.sinks[n].port.y-2,net.sinks[n-1].port.y-1)
          for i=stages-1,1,-1 do levels[i]=math.min(net.sinks[i].port.y-1,levels[i+1]-2)end
          net._junction_top=levels[1]-1
          net._junction_flip=net.sinks[1].port.x<net.sources[1].port.x
        end
        local pitch=compact_items and(m>1 and 3 or 2)or 4
        local height=levels and levels[stages]-levels[1]+4 or compact_items and(stages-1)*pitch+4 or stages*pitch+5
        if compact_items then net._junction_offsets={};for i=1,stages do net._junction_offsets[i]=1+(levels and levels[i]-levels[1]or(i-1)*pitch)end end
        local x,top=site(compact_items and 4 or 7,height,net,key);local y0=top+(compact_items and 1 or 3)
        local flip=net._junction_flip
        local function col(i)return x+(flip and 3-i or i)end
        local ys={};for i=1,stages do ys[i]=y0+(levels and levels[i]-levels[1]or(i-1)*pitch)end
        local last=ys[stages]
        local bottom=last+(compact_items and 3 or 6)
        junction_boxes[#junction_boxes+1]={x0=x,y0=top,x1=x+3,y1=bottom}
        local id='junction/'..key
        -- Keep the unused splitter sockets isolated, but leave the space
        -- beside branch ends open so a route can turn out of the junction.
        for i=0,2 do for py=top,bottom-1 do g:reserve(col(i),py,id)end end
        local splits={};for _,y in ipairs(ys)do splits[y]=true end
        for y=y0,last+1 do if not splits[y]then g:tile(equipment.belt.name,col(0),y,8,nil,key)end end
        local branches={}
        for i=1,stages do local y=ys[i]
          g:add(equipment.splitter.name,x+(flip and 3 or 1),y+.5,8,nil,key)
          local merge=i<m;local by=y+(merge and-1 or 1)
          g:tile(equipment.belt.name,col(1),by,merge and 8 or flip and 12 or 4,nil,key);g:tile(equipment.belt.name,col(2),by,merge and(flip and 4 or 12)or(flip and 12 or 4),nil,key)
          local branch=point(col(3),by,merge and(flip and 1 or 3)or(flip and 3 or 1),id)
          if compact_items and not merge then branch.turnable=true end
          branches[#branches+1]=branch
        end
        route(key,net.sources[1].port,point(col(0),y0-1,2,id))
        for i=2,m do route(key,net.sources[i].port,branches[i-1])end
        for i=1,n-1 do route(key,branches[m-1+i],net.sinks[i].port)end
        if net.export then
          local p=net.export;p.local_position={x=col(0),y=last+2};p.position=position(p.local_position,turns,mirror);p.display_direction=0
          g:tile(equipment.belt.name,col(0),last+2,8,nil,key)
        else local tail=point(col(0),last+2,2,id);if compact_items then tail.turnable=true end;route(key,tail,net.sinks[n].port)end
        end
      end
    end
  end
  Outputs.reserve(g,plan)
  table.sort(connections,function(a,b)
    local af,bf=U.split(a.key)=='fluid',U.split(b.key)=='fluid';if af~=bf then return af end
    local ad=math.abs(a.from.x-a.to.x)+math.abs(a.from.y-a.to.y);local bd=math.abs(b.from.x-b.to.x)+math.abs(b.from.y-b.to.y)
    return ad==bd and a.id<b.id or(s._shape_rows=='auto'and ad>bd or s._shape_rows~='auto'and ad<bd)
  end)
  -- A tiny direct-feed cell has ample supply sites after routing. Placing its
  -- poles first can block a short underground exit beside the fixed inputs.
  local pole
  if not compact_items and not(#parts==1 and parts[1].group.compact_fanout)then pole=Power.add(c,s,g,plan)end
  events[#events+1]={stage='recipe-bus',first=#g.entities+1,last=#g.entities,detail='local connections'}
  plan.layout_revision=38;plan.layout_stats={compact=true,folded_items=compact_items or nil,intermediate_bank=s._intermediate_bank,local_network=true,rate_local=true,mall_groups=#parts,production_rows=#plan.production_rows,direct_links=#plan.mall_links,
    closed_buses=0,straight_buses=0,recipe_bus_taps=#connections,main_bus_taps=0,external_interfaces=#plan.ports,hierarchy_levels=3,generated_main_bus_entities=0}
  local front=input_ports[1]and input_ports[1].local_position or{x=0,y=-4}
  local back=input_ports[#input_ports]and input_ports[#input_ports].local_position or front
  plan.bus_hierarchy={levels=3,generated_levels=1,main={id='main',external=true,built=false,entities={},lanes={},direction=s.growth_direction and((turns+1)%4)*4 or((s.direction or 2)-1)*4,interface={from=U.copy(front),to=U.copy(back)}},
    recipe={id='recipe',target=plan.target,bounds={x0=g.minx,y0=g.miny,x1=g.maxx,y1=g.maxy},lanes={}},lines=plan.production_rows,interfaces={}}
  for _,p in ipairs(plan.ports)do plan.bus_hierarchy.interfaces[#plan.bus_hierarchy.interfaces+1]={key=p.key,kind=p.kind,port=p.id,position=U.copy(p.local_position),from=p.kind=='in'and'main'or'recipe',to=p.kind=='in'and'recipe'or'main'}end
  if s._debug_layout then helpers.write_file('local-layout.json',helpers.table_to_json({entities=g.entities,reserved=g.reserved,connections=connections,boxes=boxes,networks=networks}),false)end
  local work={g=g,events=events,plan=plan,connections=connections,special={},buses={},turns=turns,mirror=mirror,power=pole and pole.name,
    equipment={belt=equipment.belt.name,underground=equipment.underground.name,splitter=equipment.splitter.name,pipe=equipment.pipe and equipment.pipe.name,pipeug=equipment.pipeug and equipment.pipeug.name},
    connection_index=1,special_index=1,stage='routes',route_bounds={x0=g.minx-8,y0=g.miny-8,x1=g.maxx+8,y1=g.maxy+8}}
  work.route_base={entities=U.copy(g.entities),reserved=U.copy(g.reserved),fluid_ports=U.copy(g.fluid_ports),tunnels=U.copy(g.tunnels),item_ports=U.copy(g.item_ports),debug_layout=g.debug_layout,plot_front=g.plot_front,plot_front_body=g.plot_front_body,plot_strip=U.copy(g.plot_strip),bounds={g.minx,g.miny,g.maxx,g.maxy}}
  work.base_event_count=#events;work.route_retries=0;work.route_priorities={}
  work.retry_limit=equipment.underground.max_underground_distance<=5 and 4 or 10
  return work
end
-- Rip up routed connections when a branch becomes enclosed. Give that
-- constrained connection priority, then rebuild the other paths around it.
-- The production blocks, fixed entrances and junctions never move here.
function N.retry(work)
  if not work.route_base or work.route_retries>=(work.retry_limit or 10)or work.connection_index==1 then return false end
  local connection=work.connections[work.connection_index]
  if not connection then return false end
  local signature=connection.id
  if(work.route_priorities[signature]or 0)>=2 then return false end
  work.route_priorities[signature]=(work.route_priorities[signature]or 0)+1
  table.remove(work.connections,work.connection_index);table.insert(work.connections,1,connection)
  local base=work.route_base;local g=G.new();g.isolate_items=true;g.item_ports=U.copy(base.item_ports);g.debug_layout=base.debug_layout
  if base.bounds then g.minx,g.miny,g.maxx,g.maxy=table.unpack(base.bounds)end
  g.plot_strip=U.copy(base.plot_strip)
  g.plot_front=base.plot_front;g.plot_front_body=base.plot_front_body
  for _,e in ipairs(base.entities)do local extra=U.copy(e);extra.entity_number=nil;extra.position=nil;g:add(e.name,e.position.x,e.position.y,e.direction,extra)end
  g.reserved=U.copy(base.reserved);g.fluid_ports=U.copy(base.fluid_ports);g.tunnels=U.copy(base.tunnels)
  work.g=g;work.connection_index=1;work.search=nil;work.route_first=nil;work.route_retries=work.route_retries+1;work.restarted=true
  work.plan.layout_stats.route_retries=work.route_retries
  for i=#work.events,work.base_event_count+1,-1 do work.events[i]=nil end
  return true
end
return N
