local U=require('scripts.util')
local C=require('scripts.compression')
local Outputs=require('scripts.shared_outputs')
local S={}
function S.begin(base,settings,plan)
  local positions={}
  for _,b in ipairs(plan.compression_blocks or{})do positions[b.id]={x=b.x0,y=b.y0}end
  return{base=U.copy(base),settings=U.copy(settings),best=U.copy(plan),positions=positions,initial_positions=U.copy(positions),tried={},stopped={},
    done=#positions<2 or not plan.compression_limits,history={},attempts=0,accepted=0,initial_price=plan.compression.unit_cost}
end
local function feasible(state,positions)
  local limits=state.best.compression_limits;local boxes={}
  for _,b in ipairs(state.best.compression_blocks)do local p=positions[b.id]
    local q={x0=p.x,y0=p.y,x1=p.x+b.x1-b.x0,y1=p.y+b.y1-b.y0,
      output_x=b.output_x and b.output_x+p.x-b.x0,output_key=b.output_key};boxes[b.id]=q
    if q.x0<limits.x0 or q.x1>limits.x1 or q.y0<limits.y0 then return false end
    for _,old in pairs(boxes)do if old~=q and q.x0<old.x1 and old.x0<q.x1 and q.y0<old.y1 and old.y0<q.y1
      and not Outputs.overlap(q,old)then return false end end
  end
  for _,b in ipairs(state.best.compression_blocks)do for _,id in ipairs(b.predecessors)do
    if boxes[b.id].y0<boxes[id].y1 then return false end
  end end
  return true
end
function S.next(state)
  if state.done then return end
  local blocks=state.best.compression_blocks;local moves={}
  for _,axis in ipairs({'y','x'})do
    local cuts={};for _,b in ipairs(blocks)do cuts[b[axis..'0']]=true end
    for _,cut in ipairs(U.sorted(cuts))do
      local ids={};for _,b in ipairs(blocks)do if b[axis..'0']>=cut then ids[#ids+1]=b.id end end
      if #ids>0 and #ids<#blocks then moves[#moves+1]={axis=axis,ids=ids,signature=axis..'/'..table.concat(ids,',')}end
    end
  end
  for _,move in ipairs(moves)do
    if not state.tried[move.signature]and not state.stopped[move.signature]then
      state.tried[move.signature]=true
      local positions=U.copy(state.positions)
      for _,id in ipairs(move.ids)do positions[id][move.axis]=positions[id][move.axis]-1 end
      if feasible(state,positions)then
        state.attempts=state.attempts+1;state.active=move;move.positions=positions
        local settings=U.copy(state.settings);settings._compression_positions=positions
        return settings
      end
    end
  end
  state.done=true
end
function S.observe(state,plan,failure)
  local before=state.best.compression;local after=plan and plan.compression
  local accepted=after and after.unit_cost<=before.unit_cost and C.score(plan)[1]<=C.score(state.best)[1]
  local reason=not after and'invalid'or after.unit_cost>before.unit_cost and'price-increase'or not accepted and'score-increase'or'accepted'
  state.history[#state.history+1]={attempt=state.attempts,axis=state.active.axis,delta=-1,blocks=U.copy(state.active.ids),
    before=before.unit_cost,after=after and after.unit_cost,accepted=accepted or false,reason=reason,error=failure}
  if accepted then
    state.best=U.copy(plan);state.positions=state.active.positions;state.accepted=state.accepted+1;state.tried={}
  elseif reason=='price-increase'then state.stopped[state.active.signature]=true end
  state.active=nil;state.trial=nil;state.trial_settings=nil
end
function S.finish(state)
  state.best.compression.refinement={attempts=state.attempts,accepted=state.accepted,initial_price=state.initial_price,
    final_price=state.best.compression.unit_cost,history=U.copy(state.history),initial_positions=U.copy(state.initial_positions),
    final_positions=U.copy(state.positions),choice={rows=state.settings._shape_rows,intermediate_bank=state.settings._intermediate_bank,
      central_spine=state.settings._central_spine,central_transverse=state.settings._central_transverse,spine_swap=state.settings._spine_swap,
      infrastructure=U.copy(state.settings.infrastructure)},converged=true}
  return state.best
end
return S
