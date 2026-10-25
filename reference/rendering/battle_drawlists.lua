-- rendering.battle_drawlists - The battle scene's one drawlist and its tactical depth model
--
-- Everything on the battlefield stands on a ground cell and draws in the order of, field by field:
--   1. row: its cell's grid y on the flat ground plane (screen_row). What stands further south draws later at any
--      height, so northern terrain never covers a unit and higher southern terrain may.
--   2. elevation: the level of the cap it stands on (standing_elevation). Within a row higher ground draws later.
--      Water is stood in: the pieces of its surface drawn in the scene sort at the bed, -1, with the units wading
--      there.
--   3. band: what it is on that cap (BAND below): a cap, its clutter, its marks, a prop, an actor, then the actor's
--      bars.
--   4. column: its cell's q, a fixed order between cells that share a row.
--   5. actor: the unit it belongs to, so one character's body, weapon, shield and bars never interleave with
--      another's.
--   6. part: its order inside the band (an actor's equipment layer, a clutter sprite's render order).
-- Ties keep build order. A moving unit sorts with the cell its step chooses (rendering.battle_animation_pipeline).
-- Beneath all of it lies the floor (`tier`): the ground-level caps with their soft fringes, by the same key, then the
-- hex grid over them (rendering.terrain_renderer), so a fringe never covers a unit, a mark or a prop.
-- Projectiles fly above the whole ground scene; the HUD, tooltips and modal overlays draw after the scene
-- (rendering.battle_phases.ui).

local axial = require("hex.axial")
local ui_settings = require("config.ui_settings")
local terrain = require("rendering.terrain_renderer")
local battle_units = require("rendering.battle_units")
local battle_unit_bars = require("ui.battle_unit_bars")
local sprites = require("rendering.sprites")
local assets = require("rendering.assets")
local battle_overlays = require("rendering.battle_overlays")
local battle_move_overlay = require("rendering.battle_move_overlay")

local ARROW_ASSET_PATH = require("data.items.visuals").ARROW.image

local M = {}

M.BAND = {
  terrain = 0, -- a raised cell's cliff band and cap, or a cap's upper half over a wading unit north of it
  clutter = 1, -- grass and stones, landed arrows
  highlight = 2, -- hover, move-band and ZoC marks on the cap, and the ground rings, over the clutter
  path = 3, -- footsteps and the AP cost of a move preview
  prop = 4, -- trees, rocks and other standing objects
  actor = 5, -- a unit with its equipment, or a dying unit
  water_near = 6, -- near half of a water surface, over a wading unit's legs
  over_water = 7, -- the near half of marks on water, which lie on its surface
  status = 8, -- a unit's HP and armor bars and the morale and status marks beside them
}
local BAND = M.BAND

local KIND_BAND = {
  terrain = BAND.terrain,
  hex_grid = BAND.terrain,
  hex_mark = BAND.highlight,
  ground_ring = BAND.highlight,
  environment_clutter = BAND.clutter,
  fallen_arrow = BAND.clutter,
  footstep = BAND.path,
  ap_bubble = BAND.path,
  environment_object = BAND.prop,
  unit = BAND.actor,
  unit_layered = BAND.actor,
  weapon_sprite = BAND.actor,
  death_sprite = BAND.actor,
  unit_hp_bar = BAND.status,
  unit_armor_bar = BAND.status,
  unit_marks = BAND.status,
}

-- Each field below the row has a fixed range; the key packs them into one integer, exact in a double for any
-- row a battlefield can have
local ELEVATION_MIN, ELEVATION_SLOTS = -2, 8
local BAND_SLOTS = 10
local COLUMN_MIN, COLUMN_SLOTS = -32, 64
local ACTOR_SLOTS = 256 -- unit indices 1..255; 0 is no actor
local PART_SLOTS = 128 -- an equipment layer times ten (sprites.LAYERS, up to 10; attachments add a tenth)
-- The floor and its grid sort below the scene, each in a span of its own (keys stay exact in a double)
local TIER_SPAN = 2 ^ 46
local TIER_BASE = { floor = -2 * TIER_SPAN, grid = -TIER_SPAN }

local function field(name, value, min, slots)
  local index = value - min
  if index < 0 or index >= slots or index % 1 ~= 0 then
    error(string.format("depth %s %s outside [%d, %d)", name, tostring(value), min, min + slots), 3)
  end
  return index
end

local function part_of(drawable, kind, band)
  if band == BAND.actor then
    return math.floor((kind == "weapon_sprite" and drawable.layer or sprites.LAYERS.BASE) * 10 + 0.5)
  elseif kind == "environment_clutter" then
    return drawable.clutter_render_order or 1
  elseif kind == "ap_bubble" then
    return 1
  end
  return 0
end

-- The near-surface copy of a mark on water sorts after the surface's near half, in its original band order
local function near_copy_band(drawable) return drawable.cap_half == "near" and drawable.kind ~= "terrain" end

function M.assign_z(drawable)
  local kind = drawable.kind
  local band = KIND_BAND[kind]
  if not band then error("no depth band for drawable kind " .. tostring(kind), 2) end
  local part = part_of(drawable, kind, band)
  if kind == "terrain" and drawable.cap_half then
    band = BAND.water_near
  elseif near_copy_band(drawable) then
    band, part = BAND.over_water, band
  end
  local actor = (band == BAND.actor or band == BAND.status) and drawable.unit_index or 0
  local key = (drawable.screen_row or 0) * ELEVATION_SLOTS
    + field("elevation", drawable.standing_elevation or 0, ELEVATION_MIN, ELEVATION_SLOTS)
  key = key * BAND_SLOTS + band
  key = key * COLUMN_SLOTS + field("column", drawable.column or drawable.q or 0, COLUMN_MIN, COLUMN_SLOTS)
  key = key * ACTOR_SLOTS + field("actor", actor, 0, ACTOR_SLOTS)
  key = key * PART_SLOTS + field("part", part, 0, PART_SLOTS)
  if math.abs(key) >= TIER_SPAN then error("depth row " .. tostring(drawable.screen_row) .. " out of range", 2) end
  drawable.z_index = key + (TIER_BASE[drawable.tier] or 0)
end

-- Sort by depth, keeping build order between equal keys
local function sort_by_depth(list)
  for i = 1, #list do
    list[i].depth_seq = i
  end
  table.sort(list, function(a, b)
    if a.z_index ~= b.z_index then return a.z_index < b.z_index end
    return a.depth_seq < b.depth_seq
  end)
end

-- A mark (highlight, footstep, cost, a wader's ring) sits at the centre of its cell's visible cap. On a water cell that
-- cap is the surface: the mark's far half draws behind a wading unit, its near half over the surface in front of him.
local CAP_CENTER_ABOVE_ANCHOR = (ui_settings.TILE_CAP_TOP_OFFSET + ui_settings.TILE_CAP_BOTTOM_OFFSET) * 0.5

local function add_mark(list, mark, on_water)
  list[#list + 1] = mark
  if not on_water then return end
  local near = {}
  for k, v in pairs(mark) do
    near[k] = v
  end
  mark.cap_half, near.cap_half = "far", "near"
  mark.cap_anchor_y = mark.y + CAP_CENTER_ABOVE_ANCHOR
  near.cap_anchor_y = mark.cap_anchor_y
  list[#list + 1] = near
end

-- The board: every hex of the odd-q rectangle the battlefield generator fills
function M.board_bounds(balance)
  return {
    q_min = balance.BATTLE_MAP_Q_MIN,
    q_max = balance.BATTLE_MAP_Q_MAX,
    r_min = balance.BATTLE_MAP_R_MIN,
    r_max = balance.BATTLE_MAP_R_MAX,
  }
end

local function insert_terrain(drawlist, args)
  local balance = args.balance
  local bounds = M.board_bounds(balance)
  local get_terrain = args.get_terrain_at_hex
  local terrain_images = args.terrain_images or {}
  local function terrain_at(q, r)
    if q < bounds.q_min or q > bounds.q_max or r < bounds.r_min or r > bounds.r_max then return nil end
    return get_terrain and get_terrain(q, r) or "ground_normal"
  end

  local floor = {}
  for q = bounds.q_min, bounds.q_max do
    for r = bounds.r_min, bounds.r_max do
      local pieces =
        terrain.collect_terrain_drawables(q, r, terrain_at, balance.BATTLE_OFFSET_X, balance.BATTLE_OFFSET_Y)
      local _, screen_y = axial.axial_to_screen_flat_top(q, r, balance.BATTLE_OFFSET_X, balance.BATTLE_OFFSET_Y)
      for i = 1, #pieces do
        local piece = pieces[i]
        piece.img = terrain_images[piece.path]
        piece.screen_row = math.floor(screen_y)
        drawlist[#drawlist + 1] = piece
        if piece.tier == "floor" then floor[#floor + 1] = piece end
      end
    end
  end
  drawlist[#drawlist + 1] = terrain.collect_grid_drawable(floor)
end

local function insert_environment(drawlist, args)
  local environment_map = args.environment_map or {}
  local environment_images = args.environment_images or {}
  local balance = args.balance
  for _, entry in pairs(environment_map) do
    local drawable = terrain.collect_environment_drawable(
      entry.id,
      entry.terrain,
      entry.q,
      entry.r,
      balance.BATTLE_OFFSET_X,
      balance.BATTLE_OFFSET_Y
    )
    if drawable then
      drawable.img = environment_images[entry.id]
      drawlist[#drawlist + 1] = drawable
    end
  end
end

local function insert_clutter(drawlist, args)
  local clutter_map = args.clutter_map or {}
  local clutter_images = args.clutter_images or {}
  local balance = args.balance
  for key, instances in pairs(clutter_map) do
    local q, r = key:match("(-?%d+):(-?%d+)")
    if q and r then
      q, r = tonumber(q), tonumber(r)
      local terrain_key = args.terrain_map and args.terrain_map[key]
      for slot, inst in ipairs(instances) do
        local drawable = terrain.build_clutter_drawable(
          inst,
          terrain_key,
          q,
          r,
          balance.BATTLE_OFFSET_X,
          balance.BATTLE_OFFSET_Y,
          slot
        )
        if drawable then
          drawable.img = clutter_images[inst.sprite]
          drawlist[#drawlist + 1] = drawable
        end
      end
    end
  end
end

function M.build_static_scene(args)
  local drawlist = {}
  insert_terrain(drawlist, args)
  insert_environment(drawlist, args)
  insert_clutter(drawlist, args)
  return drawlist
end

local function add_unit_elements(drawlist, args, result)
  local unit_result = battle_units.build({
    units = args.units,
    anim_state = args.anim_state,
    selected_unit = args.selected_unit,
    get_animated_position = args.get_animated_position,
    get_terrain_at_hex = args.get_terrain_at_hex,
    unit_is_visible = args.unit_is_visible,
    ui_settings = args.ui_settings,
    balance = args.balance,
  })

  for _, entry in ipairs(unit_result.drawables or {}) do
    if entry.kind == "unit_layered" and entry.unit_index == args.highlight_unit then entry.highlight = true end
    drawlist[#drawlist + 1] = entry
  end
  for _, ring in
    ipairs(battle_overlays.build_ground_rings({
      frames = unit_result.unit_frames,
      current = not args.moving_unit and args.turn_order and args.turn_order[args.current_turn_idx] or nil,
      targets = args.targets,
      highlight = args.highlight_unit,
    }))
  do
    add_mark(drawlist, ring, ring.on_water)
  end

  if unit_result.unit_frames then
    for _, frame in ipairs(unit_result.unit_frames) do
      local bars = battle_unit_bars.build_entries({
        unit = frame.unit,
        unit_index = frame.unit_index,
        grid_x = frame.grid_x,
        char_y = frame.char_y,
        column = frame.column,
        sort_elev = frame.sort_elev,
        screen_row = frame.screen_row,
        anim_state = args.anim_state,
        now = args.now or 0,
        ui_settings = args.ui_settings,
      })
      for _, bar in ipairs(bars) do
        drawlist[#drawlist + 1] = bar
      end
    end
  end

  result.unit_result = unit_result
end

-- A dying unit falls as one figure in the gear it fought in: body, helmet (still masked), armour, weapon and shield
-- tilt, bounce and fade together and leave nothing behind (rendering.effects_renderer.draw_death_sprite)
local function add_death_animations(drawlist, args)
  local anim_state = args.anim_state
  if not anim_state or not anim_state.death_anims then return end

  local units = args.units or {}
  for unit_id in pairs(anim_state.death_anims) do
    local u = units[unit_id]
    if u then
      local body, gear = nil, {}
      for _, d in
        ipairs(battle_units.figure({
          units = units,
          anim_state = anim_state,
          get_terrain_at_hex = args.get_terrain_at_hex,
          ui_settings = args.ui_settings,
          balance = args.balance,
        }, unit_id))
      do
        if d.kind == "unit_layered" then
          body = d
        elseif d.kind == "weapon_sprite" and not d.aim_arrow then
          gear[#gear + 1] = d
        end
      end
      if body then
        drawlist[#drawlist + 1] = {
          kind = "death_sprite",
          layers = body.layers,
          gear = gear,
          x = body.x,
          y = body.y,
          mirror = body.mirror_x,
          unit_index = unit_id,
          team = u.team,
          helm_layer_index = body.helm_layer_index,
          has_masked_helm = body.has_masked_helm,
          q = u.q,
          r = u.r,
          column = body.column,
          screen_row = body.screen_row,
          standing_elevation = body.standing_elevation,
        }
      end
    end
  end
end

local function add_overlays(drawlist, list, args)
  for _, o in ipairs(list) do
    add_mark(drawlist, o, terrain.is_water(args.get_terrain_at_hex(o.q, o.r)))
  end
end

local function add_hover_overlays(drawlist, args)
  if args.moving_unit then return end

  if args.hover_hex then
    add_overlays(
      drawlist,
      battle_overlays.build_hover_overlay({
        hover_q = args.hover_hex.q,
        hover_r = args.hover_hex.r,
        offset_x = args.balance.BATTLE_OFFSET_X,
        offset_y = args.balance.BATTLE_OFFSET_Y,
        get_terrain_at_hex = args.get_terrain_at_hex,
      }),
      args
    )
  end

  local phase = args.current_phase or "select"
  if phase == "end_turn" then return end
  if not args.battle_ctrl or not args.battle_ctrl.reachable then return end

  local viewer_team
  if args.selected_unit and args.units[args.selected_unit] then
    viewer_team = args.units[args.selected_unit].team
  else
    local cur_id = args.turn_order[args.current_turn_idx]
    viewer_team = cur_id and args.units[cur_id] and args.units[cur_id].team or "player"
  end

  if viewer_team == "player" then
    add_overlays(
      drawlist,
      battle_overlays.build_zoc_overlays({
        units = args.units,
        viewer_team = viewer_team,
        offset_x = args.balance.BATTLE_OFFSET_X,
        offset_y = args.balance.BATTLE_OFFSET_Y,
        get_terrain_at_hex = args.get_terrain_at_hex,
        is_playable_hex = args.is_playable_hex,
      }),
      args
    )
  end

  -- Pointing at a unit shows its full-turn reach; otherwise the active unit's move bands
  local over_unit = false
  for _, u in ipairs(args.units) do
    if args.hover_hex and args.unit_is_visible(u) and u.q == args.hover_hex.q and u.r == args.hover_hex.r then
      over_unit = true
    end
  end
  -- An armed area skill's sweep over the hexes it would strike (the controller's own preview)
  if args.area then
    add_overlays(
      drawlist,
      battle_overlays.build_area_marks({
        hexes = args.area,
        offset_x = args.balance.BATTLE_OFFSET_X,
        offset_y = args.balance.BATTLE_OFFSET_Y,
        get_terrain_at_hex = args.get_terrain_at_hex,
      }),
      args
    )
  end
  if not over_unit and args.move_bands then
    add_overlays(
      drawlist,
      battle_overlays.build_move_bands({
        bands = args.move_bands,
        offset_x = args.balance.BATTLE_OFFSET_X,
        offset_y = args.balance.BATTLE_OFFSET_Y,
        get_terrain_at_hex = args.get_terrain_at_hex,
      }),
      args
    )
  end

  local overlays = battle_move_overlay.build_hover_move_overlays({
    hover_hex = args.hover_hex,
    units = args.units,
    unit_is_visible = args.unit_is_visible,
    offset_x = args.balance.BATTLE_OFFSET_X,
    offset_y = args.balance.BATTLE_OFFSET_Y,
    get_terrain_at_hex = args.get_terrain_at_hex,
    get_reachable = function(unit_id)
      if not args.battle_ctrl or not args.battle_ctrl.reachable then return {} end
      local board = {
        units = args.units,
        turn_order = args.turn_order,
        current_turn_idx = args.current_turn_idx,
        get_terrain = args.get_terrain_at_hex,
        get_terrain_elevation = function(q, r) return terrain.get_terrain_elevation(args.get_terrain_at_hex(q, r)) end,
        is_passable = args.is_hex_passable,
      }
      return args.battle_ctrl.reachable(board, unit_id, { use_max_ap = true })
    end,
  })
  add_overlays(drawlist, overlays, args)
end

function M.build_scene_layers(args)
  local drawlist = M.build_static_scene(args)
  local result = { drawlist = drawlist }

  add_unit_elements(drawlist, args, result)
  add_death_animations(drawlist, args)
  add_hover_overlays(drawlist, args)

  for _, d in ipairs(drawlist) do
    M.assign_z(d)
  end
  sort_by_depth(drawlist)
  if args.draw_metrics then args.draw_metrics.sorts_drawlist = (args.draw_metrics.sorts_drawlist or 0) + 1 end

  return result
end

-- `frame_buffer` reuses memory between frames; callers must clear `cached_drawlist`
-- whenever scene_dirty is raised so overlays and unit state refresh.
-- `cached_drawlist` should be rebuilt after terrain/unit mutations; frame assembly
-- only sorts in the preview marks and landed arrows, then adds projectiles above the ground.
function M.build_frame_drawlist(args)
  local frame_drawlist = args.frame_buffer or {}
  local cached_drawlist = args.cached_drawlist or {}
  local anim_state = args.anim_state or {}
  local draw_metrics = args.draw_metrics or {}
  local get_terrain_at_hex = args.get_terrain_at_hex or function() return "ground_normal" end

  for i = #frame_drawlist, 1, -1 do
    frame_drawlist[i] = nil
  end
  for i = 1, #cached_drawlist do
    frame_drawlist[i] = cached_drawlist[i]
  end
  if not draw_metrics.frame_drawlist_ref then draw_metrics.frame_drawlist_ref = frame_drawlist end

  local arrow_img = args.arrow_img
  if arrow_img == nil then arrow_img = assets.get(ARROW_ASSET_PATH) end

  local ground_marks = {}
  for _, item in ipairs(args.preview_transients or {}) do
    add_mark(ground_marks, item, terrain.is_water(get_terrain_at_hex(item.q, item.r)))
  end
  -- A missile's own image (a thrown weapon's) or the arrow
  local function missile_img(image) return image and assets.get(image) or arrow_img end
  for _, fallen in ipairs(anim_state.fallen_arrows or {}) do
    local img = missile_img(fallen.image)
    if img then
      ground_marks[#ground_marks + 1] = {
        kind = "fallen_arrow",
        img = img,
        x = fallen.x,
        y = fallen.y,
        rotation = fallen.rotation or 0,
        scale = fallen.scale or 1,
        screen_row = fallen.screen_row or 0,
        standing_elevation = fallen.standing_elevation or 0,
      }
    end
  end
  if #ground_marks > 0 then
    for _, item in ipairs(ground_marks) do
      M.assign_z(item)
      frame_drawlist[#frame_drawlist + 1] = item
    end
    sort_by_depth(frame_drawlist)
    draw_metrics.sorts_frame = (draw_metrics.sorts_frame or 0) + 1
  end

  -- Arrows in flight pass over the whole scene, nearer (southern) ones last
  local first_projectile = #frame_drawlist + 1
  for _, proj in ipairs(anim_state.projectiles or {}) do
    local img = missile_img(proj.image)
    local item = {
      kind = "projectile_arrow",
      img = img,
      x = proj.x or proj.start_x,
      y = proj.y or proj.start_y,
      rotation = proj.rotation or 0,
      scale = proj.scale or 1,
      screen_row = proj.screen_row or 0,
    }
    if not img then
      item.fallback = true
      item.fallback_length = ui_settings.RANGED_PROJECTILE_FALLBACK_LENGTH
      item.fallback_width = ui_settings.RANGED_PROJECTILE_FALLBACK_WIDTH
    end
    local i = #frame_drawlist
    while i >= first_projectile and frame_drawlist[i].screen_row > item.screen_row do
      frame_drawlist[i + 1] = frame_drawlist[i]
      i = i - 1
    end
    frame_drawlist[i + 1] = item
  end

  return frame_drawlist
end

return M
