local Projects=require('scripts.projects')
local Catalogue=require('scripts.catalogue')
local Model=require('scripts.model')
local Layout=require('scripts.layout')
local Paving=require('scripts.paving')
local U=require('scripts.util')
local function init() storage.afp=storage.afp or {};Projects.init() end
local UI=require("scripts.gui")
script.on_init(init)
script.on_configuration_changed(function()
  init()
  for _,s in pairs(storage.afp)do if s.snap_grid then s.roboports=true end end
  for _,player in pairs(game.players) do if player.gui.screen.afp then UI.open(player) end end
end)
script.on_event(defines.events.on_tick,function(e) Projects.tick(e);UI.tick(e) end)
script.on_event({defines.events.on_built_entity,defines.events.on_robot_built_entity,defines.events.script_raised_built,defines.events.script_raised_revive},Projects.built)
script.on_event({defines.events.on_player_mined_entity,defines.events.on_robot_mined_entity,defines.events.on_entity_died,defines.events.script_raised_destroy},Projects.removed)
script.on_event({defines.events.on_player_built_tile,defines.events.on_robot_built_tile,defines.events.on_player_mined_tile,
  defines.events.on_robot_mined_tile,defines.events.script_raised_set_tiles},Paving.changed)
script.on_event(defines.events.on_gui_opened,function(e)
  if e.entity and e.entity.valid and e.entity.name=='afp-controller' then
    local player=game.get_player(e.player_index)
    if player.force==e.entity.force then UI.open_project(player,Projects.get(e.entity)) else player.print({'afp-error.project-force'}) end
  end
end)
script.on_event("afp-open",function(e) UI.open(game.get_player(e.player_index)) end)
script.on_event(defines.events.on_lua_shortcut,function(e) if e.prototype_name=="afp-open" then UI.open(game.get_player(e.player_index)) end end)
script.on_event(defines.events.on_gui_click,UI.click)
script.on_event(defines.events.on_player_selected_area,UI.port_selected)
script.on_event(defines.events.on_player_alt_selected_area,UI.port_selected)
script.on_event('afp-port-rotate',UI.port_rotate)
script.on_event(defines.events.on_player_cursor_stack_changed,UI.port_cursor_changed)
script.on_event({defines.events.on_research_finished,defines.events.on_research_reversed},UI.research_changed)
script.on_event({defines.events.on_gui_selection_state_changed,defines.events.on_gui_elem_changed,defines.events.on_gui_text_changed,defines.events.on_gui_checked_state_changed},UI.changed)
script.on_event(defines.events.on_gui_selected_tab_changed,UI.tab_changed)
script.on_event(defines.events.on_string_translated,UI.translated)
script.on_event(defines.events.on_player_locale_changed,UI.locale_changed)
script.on_event(defines.events.on_gui_closed,function(e)
  if e.element and e.element.valid and e.element.name=="afp" then e.element.destroy() end
end)
script.on_event(defines.events.on_entity_settings_pasted,UI.paste_settings)
script.on_event(defines.events.on_player_removed,function(e) UI.remove(e.player_index) end)
commands.add_command("afp",{"afp.command"},function(e) if e.player_index then UI.open(game.get_player(e.player_index)) end end)
local function project_snapshot(id)
  local project=storage.afp_projects and storage.afp_projects[id]
  if not project then return nil end
  return {id=id,anchor=project.anchor,revision=project.revision,members=project.members,retiring=project.retiring,
    status=project.status,error=project.error,pending=project.pending,area=project.area,buffers=project.buffers,config=project.config,
    paving_tiles=project.paving_tiles,pending_tiles=project.pending_tiles,inputs=project.inputs,changes=project.changes,offset=project.offset,
    layout_revision=project.layout_revision,recipe_bus_order=project.recipe_bus_order,intake_revision=project.intake_revision,
    copied_settings=project.copied_settings,settings_revision=project.settings_revision,demolishing=project.demolishing}
end
local function project_plan(id,settings)
  local project=storage.afp_projects[id]
  if not project or not project.anchor.valid then error({'afp-error.project-missing'},0) end
  local catalogue=Catalogue.build(project.anchor.force)
  local input=U.copy(settings);input._project=Projects.context(id)
  local plan=Model.calculate(catalogue,input)
  return Layout.generate(catalogue,input,plan)
end
remote.add_interface('auto_factory_planner',{
  register_controller=function(anchor)return Projects.get(anchor).id end,
  get_project=project_snapshot,
  plan_project=project_plan,
  preview_project=function(id,settings) return Projects.preview(id,settings,project_plan(id,settings)) end,
  apply_project=function(id,settings,revision)
    Projects.apply(id,settings,project_plan(id,settings),nil,revision)
    return project_snapshot(id)
  end,
  demolish_project=function(id,revision)Projects.demolish(id,nil,revision);return project_snapshot(id)end
})
if script.active_mods['afp-project-tests'] then require('__afp-project-tests__/bridge').setup(UI) end

if script.active_mods['afp-integration']then require('__afp-integration__/bridge').setup()end
