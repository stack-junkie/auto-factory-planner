-- Two-phase primal simplex. Maximise c*x subject to A*x<=b, x>=0.
-- Artificial columns establish a feasible basis; Bland's rule breaks ties.
local S={}
local EPS=1e-9
function S.solve(A,b,c)
  local m,n=#b,#c
  if m==0 then return {} end
  local cols=n+m;local rows,basis,art={},{},{}
  for i=1,m do if b[i]<-EPS then cols=cols+1;art[cols]=true end end
  local ai=n+m
  for i=1,m do
    local r={};for j=1,cols+1 do r[j]=0 end
    local sign=b[i]<0 and -1 or 1
    for j=1,n do r[j]=sign*A[i][j] end
    r[n+i]=sign;r[cols+1]=math.abs(b[i]);basis[i]=n+i
    if sign<0 then ai=ai+1;r[ai]=1;basis[i]=ai end
    rows[i]=r
  end
  local objective
  local function canonical(cost)
    objective={};for j=1,cols do objective[j]=-(cost[j] or 0) end;objective[cols+1]=0
    for i,r in ipairs(rows) do
      local cb=cost[basis[i]] or 0
      for j=1,cols+1 do objective[j]=objective[j]+cb*r[j] end
    end
  end
  local function pivot(i,j)
    local r=rows[i];local v=r[j]
    for k=1,cols+1 do r[k]=r[k]/v end
    for h,q in ipairs(rows) do if h~=i then
      local z=q[j];if math.abs(z)>EPS then for k=1,cols+1 do q[k]=q[k]-z*r[k] end end
    end end
    local z=objective[j];for k=1,cols+1 do objective[k]=objective[k]-z*r[k] end
    basis[i]=j
  end
  local function optimise()
    for _=1,20000 do
      local col
      for j=1,cols do if not art[j] and objective[j]<-EPS then col=j;break end end
      if not col then return true end
      local row,ratio
      for i,r in ipairs(rows) do if r[col]>EPS then
        local v=r[cols+1]/r[col]
        if not row or v<ratio-EPS or (math.abs(v-ratio)<EPS and basis[i]<basis[row]) then row,ratio=i,v end
      end end
      if not row then return false,"unbounded" end
      pivot(row,col)
    end
    return false,"iterations"
  end
  -- Artificial variables may enter phase I, so explicitly permit them there.
  local artificial=art;local cost={};for j in pairs(artificial) do cost[j]=-1 end
  art={};canonical(cost)
  local ok,err=optimise();if not ok then return nil,err end
  if objective[cols+1]<-1e-6 then return nil,"infeasible" end
  art=artificial
  for i=#rows,1,-1 do if art[basis[i]] then
    local col;for j=1,cols do if not art[j] and math.abs(rows[i][j])>EPS then col=j;break end end
    if col then pivot(i,col) else table.remove(rows,i);table.remove(basis,i) end
  end end
  canonical(c);ok,err=optimise();if not ok then return nil,err end
  local x={};for j=1,n do x[j]=0 end
  for i,k in ipairs(basis) do if k<=n then x[k]=math.max(0,rows[i][cols+1]) end end
  return x
end
return S
