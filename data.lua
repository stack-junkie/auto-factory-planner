local controller=table.deepcopy(data.raw['constant-combinator']['constant-combinator'])
controller.name='afp-controller'
controller.minable={mining_time=0.2,result='afp-controller'}
controller.placeable_by={item='afp-controller',count=1}
controller.localised_name={'entity-name.afp-controller'}
controller.localised_description={'entity-description.afp-controller'}
local controller_art='__auto-factory-planner__/graphics/entity/factory-controller.png'
local controller_sprite={filename=controller_art,width=1254,height=1254,scale=48/1254,shift={0,-0.125}}
controller.icon=controller_art
controller.icon_size=1254
controller.sprites={north=controller_sprite,east=controller_sprite,south=controller_sprite,west=controller_sprite}
controller.activity_led_sprites=nil
controller.water_reflection=nil
data:extend({
  {type='selection-tool',name='afp-grid-anchor',icon='__base__/graphics/icons/roboport.png',icon_size=64,
    flags={'not-stackable','spawnable'},subgroup='tool',order='z[afp-grid-anchor]',stack_size=1,
    select={border_color={r=1,g=.6,b=0},cursor_box_type='copy',mode={'entity-with-health','same-force'},entity_type_filters={'roboport'}},
    alt_select={border_color={r=1,g=.6,b=0},cursor_box_type='copy',mode={'entity-with-health','same-force'},entity_type_filters={'roboport'}}},
  {type='recipe',name='afp-grid-anchor',enabled=true,energy_required=.5,
    ingredients={{type='item',name='iron-plate',amount=1},{type='item',name='electronic-circuit',amount=1}},
    results={{type='item',name='afp-grid-anchor',amount=1}}},
  {type='selection-tool',name='afp-port',icon='__base__/graphics/icons/transport-belt.png',icon_size=64,
    flags={'only-in-cursor','not-stackable','spawnable'},stack_size=1,
    select={border_color={r=0,g=1,b=1},cursor_box_type='copy',mode={'any-tile'}},
    alt_select={border_color={r=1,g=.5,b=0},cursor_box_type='copy',mode={'any-tile'}}},
  {type='custom-input',name='afp-port-rotate',key_sequence='',linked_game_control='rotate',consuming='none'},
  controller,
  {type='item',name='afp-controller',icon=controller_art,icon_size=1254,
    subgroup='circuit-network',order='z[afp-controller]',place_result='afp-controller',stack_size=50},
  {type='recipe',name='afp-controller',enabled=true,energy_required=0.5,
    ingredients={{type='item',name='iron-plate',amount=5},{type='item',name='copper-plate',amount=2}},
    results={{type='item',name='afp-controller',amount=1}}},
  {type="custom-input", name="afp-open", key_sequence="CONTROL + SHIFT + F", consuming="none"},
  {type="shortcut", name="afp-open", action="lua", associated_control_input="afp-open",
    icon="__base__/graphics/icons/blueprint.png", icon_size=64, small_icon="__base__/graphics/icons/blueprint.png", small_icon_size=64}
})

-- Compact production rows use the game's own frame and slot artwork.
data.raw['gui-style'].default.afp_chain_row={type='frame_style',parent='inside_shallow_frame',padding=4,vertical_flow_style={type='vertical_flow_style',vertical_spacing=4}}
