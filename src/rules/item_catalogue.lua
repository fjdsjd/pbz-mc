-- Immutable lookup/pages built once, never rescanned on hover or redraw.
local M={page_size=20,columns=5,rows=4}
local definitions=require('content.items')
local source=require('content.catalogue_groups')
local groups,by_id,items,pages={},{},{},{}
for _,entry in ipairs(source.groups)do
 local group={id=entry.id,label=entry.label,skin=entry.skin,icon=entry.icon,entries={}}
 assert(not by_id[group.id],'duplicate-catalogue-category')
 groups[#groups+1]=group;by_id[group.id]=group
end
local function add(id,category,kind)
 local group=assert(by_id[category],'missing-catalogue-category')
 assert(definitions.get(id)and not items[id],'invalid-catalogue-content:'..id)
 group.entries[#group.entries+1]=id;items[id]={kind=kind,category=category,index=#group.entries}
end
for _,id in ipairs(require('content.blocks').catalogue())do add(id,source.block_category(id),'block')end
for _,id in ipairs(require('rules.equipment_catalogue').list())do
 add(id,require('content.armor').get(id)and'armor'or'equipment','equipment')
end
for _,id in ipairs(require('rules.supply_catalogue').list())do add(id,source.supply_category(id),'supply')end
for _,group in ipairs(groups)do
 group.pages=math.max(1,math.ceil(#group.entries/M.page_size));pages[group.id]={}
 for page=1,group.pages do
  local view={category=group.id,label=group.label,page=page,pages=group.pages,total=#group.entries,entries={}}
  for index=(page-1)*M.page_size+1,math.min(page*M.page_size,#group.entries)do
   view.entries[#view.entries+1]=group.entries[index]
  end
  pages[group.id][page]=view
 end
end
function M.categories()return groups end
function M.kind(id)return items[id]and items[id].kind end
function M.category(id)return items[id]and items[id].category end
function M.page(category,page)
 category=category or'construction';page=page or 1
 local group=assert(by_id[category],'unknown-catalogue-category:'..tostring(category))
 assert(type(page)=='number'and page%1==0,'invalid-catalogue-page')
 return pages[category][math.max(1,math.min(group.pages,page))]
end
function M.change(previous,request)
 local current=M.page(previous and previous.category,previous and previous.page)
 local remembered={};for id,page in pairs(previous and previous.remembered or{})do
  if by_id[id]then remembered[id]=M.page(id,page).page end
 end
 remembered[current.category]=current.page
 local view
 if request.kind=='catalogue_category'then view=M.page(request.category,remembered[request.category]or 1)
 elseif request.kind=='catalogue_page'then
  local steps=request.steps
  assert(type(steps)=='number'and steps%1==0 and math.abs(steps)<=273,'invalid-catalogue-page-step')
  view=M.page(current.category,current.page+steps)
 else error('unknown-catalogue-navigation')end
 remembered[view.category]=view.page
 local result={remembered=remembered};for key,value in pairs(view)do result[key]=value end
 return result
end
return M
