local U = {}
function U.sorted(t, compare)
  local a={}; for k in pairs(t) do a[#a+1]=k end
  table.sort(a,compare); return a
end
function U.key(t,n) return (t or "item")..":"..n end
function U.split(k)
  local t,n=k:match("^([^:]+):(.+)$");return t and t:gsub("@%d+$", ""),n
end
function U.base_key(k) local t,n=U.split(k);return U.key(t,n) end
function U.stream(k,section)
  if not section then return k end
  local t,n=U.split(k);return t.."@"..section..":"..n
end
function U.signal(k) local t,n=U.split(k); return {type=t,name=n,quality="normal"} end
function U.icon(k) local t,n=U.split(k); return "["..t.."="..n.."]" end
function U.name(k)
  local t,n=U.split(k); local p=t=="fluid" and prototypes.fluid[n] or prototypes.item[n]
  return p and p.localised_name or n
end
function U.fmt(n) return string.format("%.3f",n):gsub("0+$",""):gsub("%.$","") end
function U.copy(v)
  if type(v)~="table" then return v end
  local t={};for k,x in pairs(v) do t[k]=U.copy(x) end;return t
end
function U.fail(k,...) error({"afp-error."..k,...},0) end
function U.add(t,k,n) t[k]=(t[k] or 0)+n end
function U.fingerprint(v)
  if type(v)~="table" then return type(v)..":"..tostring(v) end
  local values={};for _,k in ipairs(U.sorted(v,function(a,b)return tostring(a)<tostring(b) end)) do values[#values+1]=U.fingerprint(k).."="..U.fingerprint(v[k]) end
  return "{"..table.concat(values,";").."}"
end
local function infrastructure(s)
  local value=U.copy(s.infrastructure or{})
  value.belt=nil;value.underground=nil;value.splitter=nil
  return value
end
function U.layout_signature(s)
  return U.fingerprint{growth_direction=s.growth_direction,direction=s.direction or 2,side=s.side or 1,infrastructure=infrastructure(s),thresholds=s.thresholds or {},
    input_rows=s.input_rows or 'auto',input_order=s.input_order,layout_search=s.layout_search,mode=s.mode or 'rate',targets=s.targets,max_width=s.max_width,paving=s.paving,
    roboports=s.roboports or false,snap_grid=s.snap_grid or false,compression_weights=s.compression_weights,grid_anchor=s.grid_anchor,_project=s._project,manual_ports=s.manual_ports,port_origin=s.port_origin}
end
function U.factory_signature(s)
  local infrastructure=infrastructure(s);infrastructure.roboport=nil
  return U.fingerprint{mode=s.mode or'rate',target=s.target,rate=s.rate,targets=s.targets,decisions=s.decisions or{},conversions=s.conversions or{},byproduct_exports=s.byproduct_exports or{},
    growth_direction=s.growth_direction,direction=s.direction or 2,side=s.side or 1,infrastructure=infrastructure,thresholds=s.thresholds or{},max_width=s.max_width,input_rows=s.input_rows or'auto',input_order=s.input_order,layout_search=s.layout_search,compression_weights=s.compression_weights,manual_ports=s.manual_ports,port_origin=s.port_origin}
end
function U.rotate(x,y,turns)
  for _=1,turns%4 do x,y=-y,x end;return x,y
end
function U.expected(p)
  local probability=(p.independent_probability or p.probability or 1)
  if p.shared_probability then probability=probability*(p.shared_probability.max-p.shared_probability.min) end
  return ((p.amount or ((p.amount_min+p.amount_max)/2))+(p.extra_count_fraction or 0))*probability,probability
end
return U
