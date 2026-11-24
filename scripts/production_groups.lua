local U=require('scripts.util')
local Paving=require('scripts.paving')
local Groups={}
function Groups.enabled(s)
  return not(s._legacy_groups or s._legacy_branches or s._legacy_intake or s._legacy_straight or s._legacy_cells or s._legacy_rows or s._legacy_bus or s._legacy_orientation or s._legacy_layout)
end
function Groups.plan(s,plan,seeds,build)
  local consumers={}
  for _,n in ipairs(plan.nodes)do for key in pairs(n.input)do
    consumers[key]=consumers[key]or{};consumers[key][n.id]=true
  end end
  local function describe(nodes,parts)
    local group={nodes={},parts=parts,keys={},local_keys={},grouped=true};local inside,outputs={},{}
    for _,n in ipairs(nodes)do group.nodes[#group.nodes+1]=n;inside[n.id]=true;group.local_supply=group.local_supply or n.local_supply
      for key in pairs(n.input)do group.keys[key]=true end
      for key in pairs(n.output)do outputs[key]=true end
    end
    table.sort(group.nodes,function(a,b)return a.id<b.id end)
    group.inputs={};group.count=0
    for _,n in ipairs(nodes)do group.count=group.count+n.count end
    for key in pairs(group.keys)do if not outputs[key]then group.inputs[key]=true end end
    for key in pairs(outputs)do if consumers[key]then
      local all=true;for id in pairs(consumers[key])do if not inside[id]then all=false;break end end
      if all and not(plan.direct_keys and plan.direct_keys[key])then group.local_keys[key]=true end
    end end
    return group
  end
  local groups,parts={},{}
  for i,seed in ipairs(seeds)do
    local group=describe(seed.nodes,{seed});local ok,part=pcall(build,group,true)
    if not ok then
      -- A base cell can retain its established bus connection if its local
      -- route is obstructed. Speculative merged cells must fit completely.
      group.local_keys={};ok,part=pcall(build,group,true)
    end
    if not ok then local names={};for _,n in ipairs(group.nodes)do names[#names+1]=n.recipe end;log('AFP GROUP FAILED '..table.concat(names,',')..' '..serpent.line(part));error(part,0)end
    groups[i]=group;parts[i]=part
  end
  local function acyclic(candidate,a,b)
    local owner,producer,edges={},{},{}
    for id,g in pairs(groups)do if id~=b then
      local chosen=id==a and candidate or g
      for _,n in ipairs(chosen.nodes)do owner[n.id]=id;for key in pairs(n.output)do producer[key]=id end end
    end end
    for _,n in ipairs(plan.nodes)do for key in pairs(n.input)do local source=producer[key];local target=owner[n.id]
      if source and source~=target then edges[source]=edges[source]or{};edges[source][target]=true end
    end end
    local active,done={},{}
    local function visit(id)
      if active[id]then return false end;if done[id]then return true end;active[id]=true
      for nextid in pairs(edges[id]or{})do if not visit(nextid)then return false end end
      active[id]=nil;done[id]=true;return true
    end
    for id in pairs(groups)do if id~=b and not visit(id)then return false end end;return true
  end
  local function cost(part)
    local g=part.g;local feeds=0
    for _,t in ipairs(part.terminals)do feeds=feeds+#(t.keys or{t.key})end
    return #g.entities+(g.maxx-g.minx)*(g.maxy-g.miny)*0.12+feeds*18
  end
  local width=Paving.limit(s);local budget=width and width-16 or math.huge
  while true do
    local best;local ids=U.sorted(groups)
    for ai,a in ipairs(ids)do for bi=ai+1,#ids do local b=ids[bi]
      if not parts[a].shared_row and not parts[b].shared_row then
        local nodes={};for _,g in ipairs({groups[a],groups[b]})do for _,n in ipairs(g.nodes)do nodes[#nodes+1]=n end end
        local candidate=describe(nodes,{groups[a],groups[b]});local shared,connected=0,false
        for key in pairs(groups[a].inputs)do if groups[b].inputs[key]then shared=shared+1 end end
        for _,pair in ipairs({{groups[a],groups[b]},{groups[b],groups[a]}})do
          for _,n in ipairs(pair[1].nodes)do for key in pairs(n.output)do if pair[2].keys[key]then connected=true end end end
        end
        if candidate.count<=(plan.rate_search and 40 or 10) and #nodes<=(plan.rate_search and 5 or 10) and #U.sorted(candidate.inputs)<=5 and(shared>0 or connected)and acyclic(candidate,a,b)then
          local ok,part=pcall(build,candidate,true)
          if ok and part.g.maxx-part.g.minx<=budget then
            local gain=cost(parts[a])+cost(parts[b])-cost(part)
            if gain>0.01 and(not best or gain>best.gain+1e-6)then best={a=a,b=b,group=candidate,part=part,gain=gain}end
          end
        end
      end
    end end
    if not best then break end
    groups[best.a]=best.group;parts[best.a]=best.part;groups[best.b]=nil;parts[best.b]=nil
  end
  local producer,owner,done,ordered,placed={},{},{},{},{}
  for id,g in pairs(groups)do for _,n in ipairs(g.nodes)do owner[n.id]=id;for key in pairs(n.output)do producer[key]=id end end end
  local function visit(id)
    if done[id]then return end;done[id]=true
    for _,key in ipairs(U.sorted(groups[id].inputs))do local source=producer[key];if source and source~=id then visit(source)end end
    ordered[#ordered+1]=groups[id];placed[#placed+1]=build(groups[id])
  end
  for _,id in ipairs(U.sorted(groups))do visit(id)end
  return ordered,placed
end
return Groups
