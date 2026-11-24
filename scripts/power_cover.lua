local Cover={}
local function overlap(a,b)return a.x<b.x+b.w and b.x<a.x+a.w and a.y<b.y+b.h and b.y<a.y+a.h end
function Cover.refine(selected,free,existing)
  local counts={}
  local function add(candidate,delta)
    for _,user in ipairs(candidate.users)do counts[user]=(counts[user]or 0)+delta end
  end
  for _,candidate in ipairs(selected)do add(candidate,1)end
  local function prune()
    for i=#selected,1,-1 do local candidate=selected[i];local needed=false
      for _,user in ipairs(candidate.users)do if counts[user]==1 then needed=true;break end end
      if not needed then add(candidate,-1);table.remove(selected,i)end
    end
  end
  prune()
  -- Deletion alone gets stuck when two nearby poles each have a private
  -- consumer. Move their shared replacement before numbering or wiring poles.
  local changed=true
  local members={}
  local function covers(candidate,user)
    if not members[candidate]then local set={};for _,u in ipairs(candidate.users)do set[u]=true end;members[candidate]=set end
    return members[candidate][user]
  end
  while changed do
    changed=false
    -- Every retained pole has a private consumer. A possible replacement must
    -- cover both private consumers, so only these local pairs need inspection.
    local owners,pairs,seen_pairs={},{},{}
    for i,a in ipairs(selected)do local witness
      for _,user in ipairs(a.users)do if counts[user]==1 and(not witness or #user.candidates<#witness.candidates)then witness=user end end
      for _,candidate in ipairs(witness.candidates)do
        local list=owners[candidate]or{};owners[candidate]=list
        for _,j in ipairs(list)do local key=j..'/'..i
          if not seen_pairs[key]then seen_pairs[key]=true;pairs[#pairs+1]={i=j,j=i}end
        end
        list[#list+1]=i
      end
    end
    table.sort(pairs,function(a,b)return a.i==b.i and a.j<b.j or a.i<b.i end)
    for _,pair in ipairs(pairs)do local i,j=pair.i,pair.j;local a,b=selected[i],selected[j]
        local required,seen,seed={},{},nil
        for _,candidate in ipairs({a,b})do for _,user in ipairs(candidate.users)do
          if not seen[user]then
            seen[user]=true
            local supplied=0
            for _,owner in ipairs({a,b})do if covers(owner,user)then supplied=supplied+1 end end
            if counts[user]==supplied then
              required[#required+1]=user
              if not seed or #user.candidates<#seed.candidates then seed=user end
            end
          end
        end end
        local best
        for _,candidate in ipairs(seed and seed.candidates or{})do
          local valid=true
          for _,user in ipairs(required)do if not covers(candidate,user)then valid=false;break end end
          if valid and free(candidate.x,candidate.y,candidate.prototype)then
            for k,other in ipairs(selected)do if k~=i and k~=j and overlap(candidate,other)then valid=false;break end end
            if valid and(not best or #candidate.users>#best.users or #candidate.users==#best.users and candidate.tie<best.tie)then best=candidate end
          end
        end
        if best then
          add(a,-1);add(b,-1);add(best,1)
          selected[i]=best;table.remove(selected,j);prune();changed=true;break
        end
    end
  end
  -- Equal-count moves can avoid a relay between two supply poles that are
  -- only just outside wire reach. Keep full coverage and decrease a symmetric
  -- wire score so neighbouring poles cannot chase each other in a cycle.
  local function connection(a,b)
    local ax,ay=a.position and a.position.x or a.x+a.w/2,a.position and a.position.y or a.y+a.h/2
    local bx,by=b.position and b.position.x or b.x+b.w/2,b.position and b.position.y or b.y+b.h/2
    local ap=a.prototype or prototypes.entity[a.name];local bp=b.prototype or prototypes.entity[b.name]
    local reach=math.min(ap.get_max_wire_distance('normal'),bp.get_max_wire_distance('normal'))
    local d=(ax-bx)^2+(ay-by)^2
    return math.max(0,math.ceil((math.sqrt(d)-1e-6)/reach)-1)*1000+d/(d+1)
  end
  local function score(candidate,index)
    local value=0
    for j,other in ipairs(selected)do if j~=index then value=value+connection(candidate,other)end end
    for _,other in ipairs(existing or{})do value=value+connection(candidate,other)end
    return value
  end
  changed=true
  while changed do
    changed=false
    for i,old in ipairs(selected)do
      local required,seed={},nil
      for _,user in ipairs(old.users)do if counts[user]==1 then
        required[#required+1]=user
        if not seed or #user.candidates<#seed.candidates then seed=user end
      end end
      local best,best_score=old,score(old,i)
      for _,candidate in ipairs(seed.candidates)do
        local valid=true
        for _,user in ipairs(required)do if not covers(candidate,user)then valid=false;break end end
        if valid and free(candidate.x,candidate.y,candidate.prototype)then
          for j,other in ipairs(selected)do if j~=i and overlap(candidate,other)then valid=false;break end end
          if valid then local value=score(candidate,i)
            if value<best_score-1e-9 then best,best_score=candidate,value end
          end
        end
      end
      if best~=old then add(old,-1);add(best,1);selected[i]=best;prune();changed=true;break end
    end
  end
  return selected
end
return Cover
