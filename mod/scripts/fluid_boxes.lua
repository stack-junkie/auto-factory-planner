local F={}
-- Recipe indices are relative to the input/output lists, rather than the
-- machine's absolute fluidbox indices. Reserve explicit choices first.
function F.assign(prototype,ingredients,products)
  local pools={input={},output={}};local assignments,used={},{}
  for _,box in ipairs(prototype.fluidbox_prototypes)do
    for _,mode in ipairs({'input','output'})do if box.production_type==mode or box.production_type=='input-output'then pools[mode][#pools[mode]+1]=box end end
  end
  for _,explicit in ipairs({true,false})do
    for _,group in ipairs({{values=ingredients,mode='input'},{values=products,mode='output'}})do
      for _,value in ipairs(group.values)do if value.type=='fluid'and(value.fluidbox_index~=nil)==explicit then
        local selected
        for ordinal,box in ipairs(pools[group.mode])do
          if(not value.fluidbox_index or ordinal==value.fluidbox_index)and not used[box.index]and(not box.filter or box.filter.name==value.name)then selected=box;break end
        end
        if not selected then return nil end
        assignments[value]=selected.index;used[selected.index]=true
      end end
    end
  end
  return assignments
end
return F
