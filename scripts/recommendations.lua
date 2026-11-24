local U=require('scripts.util')
local R={}
local kinds={['assembling-machine']=true,furnace=true,['mining-drill']=true,['solar-panel']=true,
  ['electric-pole']=true,container=true,['logistic-container']=true,['transport-belt']=true,
  ['underground-belt']=true,splitter=true,inserter=true,pipe=true,['pipe-to-ground']=true,
  ['storage-tank']=true,pump=true,roboport=true,wall=true,gate=true,locomotive=true,
  ['cargo-wagon']=true,['fluid-wagon']=true,['artillery-wagon']=true,['train-stop']=true,
  ['rail-signal']=true,['rail-chain-signal']=true,['rail-ramp']=true,['rail-support']=true}
function R.recommended(item)
  if item.hidden or item.name=='afp-controller' then return false end
  if item.type=='ammo' or item.type=='rail-planner' or item.type=='repair-tool' then return true end
  local entity=item.place_result
  return entity and (kinds[entity.type] or entity.type:find('turret',1,true)~=nil) or false
end
function R.items(s)
  local names={}
  for name,item in pairs(prototypes.item) do if R.recommended(item) then names[name]=true end end
  for _,target in ipairs(s.targets or {}) do local kind,name=U.split(target.key or '')
    if kind=='item' and prototypes.item[name] then names[name]=true end
  end
  return U.sorted(names,function(a,b)
    local x,y=(s.ui_names and s.ui_names[a] or a),(s.ui_names and s.ui_names[b] or b)
    return x==y and a<b or x<y
  end)
end
function R.normalise(text)
  text=string.lower(text or '')
  text=text:gsub('Ё','е'):gsub('ё','е')
  for upper,lower in pairs({['А']='а',['Б']='б',['В']='в',['Г']='г',['Д']='д',['Е']='е',['Ж']='ж',['З']='з',
    ['И']='и',['Й']='й',['К']='к',['Л']='л',['М']='м',['Н']='н',['О']='о',['П']='п',['Р']='р',['С']='с',
    ['Т']='т',['У']='у',['Ф']='ф',['Х']='х',['Ц']='ц',['Ч']='ч',['Ш']='ш',['Щ']='щ',['Ъ']='ъ',['Ы']='ы',['Ь']='ь',['Э']='э',['Ю']='ю',['Я']='я'}) do text=text:gsub(upper,lower) end
  return text
end
function R.matches(name,translated,query)
  local haystack=R.normalise(name..' '..(translated or ''))
  for word in R.normalise(query):gmatch('%S+') do if not haystack:find(word,1,true) then return false end end
  return true
end
return R
