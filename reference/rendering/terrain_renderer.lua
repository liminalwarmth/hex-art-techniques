-- rendering/terrain_renderer.lua - The battlefield's painted ground (VA7) and the anchors things stand on (uses LÖVE)
--
-- Ground is drawn in two places (rendering/battle_drawlists.lua):
--   * the floor: every cap at ground level (level ground and water surfaces), whole painted images with their soft
--     fringes, in row order beneath everything else, then the hex grid over them. A fringe there only ever blends
--     into a neighbouring cap, never over a unit, a mark or a prop.
--   * the scene: ground that must hide what stands behind it, sorted with the units: a raised hex's cliff band and
--     cap, the near half of a water surface (over a wading unit's legs), and the upper half of a cap that borders
--     water to its north (over what of a wading unit sinks past the shore). These draw as meshes clipped to their hex,
--     so they carry no fringe; each redraws the grid along the edges it covers, and a raised cap catches a little more
--     light per level.
local M = {}
local ui_settings = require("config.ui_settings")
local geometry = require("hex.geometry")
local axial = require("hex.axial")
local balance = require("data.balance.battle")
local visual_templates = require("data.items.visual_templates")
local TERRAIN_TYPES = require("data.world.terrain")
local ENVIRONMENT_OBJECTS = require("data.world.environment")
local active_camera = nil

local CAP_ART = visual_templates.FAMILIES.hex_cap
local CLIFF_ART = visual_templates.FAMILIES.cliff_band
local PROP_ART = visual_templates.FAMILIES.prop
-- Caps and bands share the 2x anchor; one logical px is CAP_ART.scale source px
local ART_SCALE = CAP_ART.scale
local ANCHOR_X, ANCHOR_Y = CAP_ART.landmarks.anchor.x, CAP_ART.landmarks.anchor.y
-- How far a band's painted foot fades past the ground edge it stands on, in logical px
local BAND_FRINGE = (CLIFF_ART.seal + CLIFF_ART.fringe) / ART_SCALE
local CAP_CENTRE = (ui_settings.TILE_CAP_TOP_OFFSET + ui_settings.TILE_CAP_BOTTOM_OFFSET) * 0.5
-- Clutter (tufts, flowers) and scatter (pebbles, bones) share their base's margin above the canvas foot
local CLUTTER_BASE_MARGIN = PROP_ART.variants.clutter.canvas.height - PROP_ART.variants.clutter.landmarks.base.y

-- The cap polygon grown out to the midline between neighbours (relative to the tile anchor): a clipped cap meets its
-- neighbours with no gap, and the hex grid runs along it
local GRID = {}
do
  local cx, cy = -1, -100 -- the polygon's centre
  for i, v in ipairs(geometry.TILE_CAP_POLYGON) do
    local sx = v[1] > cx and 1 or (v[1] < cx and -1 or 0)
    local sy = v[2] > cy and 1 or (v[2] < cy and -1 or 0)
    GRID[i] = { v[1] + sx, v[2] + sy }
  end
end
-- Edges by index i (GRID[i] to GRID[i % 6 + 1]): 1 top, 2 upper right, 3 lower right, 4 bottom, 5 lower left,
-- 6 upper left. The hex across a lower edge, by column parity
local SOUTH_EDGES = {
  [3] = { even = { 1, 0 }, odd = { 1, 1 } },
  [4] = { even = { 0, 1 }, odd = { 0, 1 } },
  [5] = { even = { -1, 0 }, odd = { -1, 1 } },
}
local NORTH_NEIGHBOURS = {
  even = { { 0, -1 }, { 1, -1 }, { -1, -1 } },
  odd = { { 0, -1 }, { 1, 0 }, { -1, 0 } },
}

local function parity(q) return q % 2 == 0 and "even" or "odd" end

local function grid_xy(q, r, offset_x, offset_y) return axial.axial_to_screen_flat_top(q, r, offset_x, offset_y) end

function M.set_camera_transform(info) active_camera = info end

local function world_to_screen(x, y)
  if not active_camera then return x, y end
  local zoom = active_camera.zoom or 1
  local cx = (active_camera.screen_width or love.graphics.getWidth()) * 0.5
  local cy = (active_camera.screen_height or love.graphics.getHeight()) * 0.5
  local sx = (x - (active_camera.offset_x or 0)) * zoom + cx
  local sy = (y - (active_camera.offset_y or 0)) * zoom + cy
  return sx, sy
end

local function zoom() return active_camera and active_camera.zoom or 1 end

-- Whether a world rect meets the camera's view (always, without a camera): ground off screen is not drawn
local function on_screen(x0, y0, x1, y1)
  if not active_camera then return true end
  local z = active_camera.zoom or 1
  local half_w = (active_camera.screen_width or love.graphics.getWidth()) * 0.5 / z
  local half_h = (active_camera.screen_height or love.graphics.getHeight()) * 0.5 / z
  local cx, cy = active_camera.offset_x or 0, active_camera.offset_y or 0
  return x1 >= cx - half_w and x0 <= cx + half_w and y1 >= cy - half_h and y0 <= cy + half_h
end

local function image_on_screen(img, x, y, scale, ox, oy)
  local w, h = img:getWidth(), img:getHeight()
  return on_screen(x - ox * scale, y - oy * scale, x + (w - ox) * scale, y + (h - oy) * scale)
end

-- Calculate surface Y position for a given elevation
function M.get_surface_y(grid_y, elevation) return geometry.compute_surface_y(grid_y, elevation) end

-- Calculate anchor Y position for drawing
function M.get_anchor_y(grid_y, elevation) return geometry.compute_anchor_y(grid_y, elevation) end

-- Water is the one terrain a unit stands in rather than on: its bed lies a level down and its surface lies at ground
-- level, on the floor behind a wading unit, its near half drawn again over the unit's legs
function M.is_water(terrain_type) return M.get_terrain_elevation(terrain_type) < 0 end

-- The level of the cap a player sees and clicks on a hex (water's surface, not its bed)
function M.get_cap_elevation(terrain_type) return math.max(0, M.get_terrain_elevation(terrain_type)) end

-- Centre of a hex's visible cap: where highlights, footsteps and cost bubbles sit
function M.get_cap_center_y(terrain_type, q, r, offset_x, offset_y)
  local _, grid_y = grid_xy(q, r, offset_x, offset_y)
  return M.get_anchor_y(grid_y, M.get_cap_elevation(terrain_type)) - CAP_CENTRE
end

-- The painted art a terrain type draws with: its cap variants, then its cliff band (raised ground only). A type with
-- no art (lava, the +4 crag) returns an empty list.
function M.get_terrain_art_paths(terrain_type)
  local data = TERRAIN_TYPES[terrain_type]
  local paths = {}
  for _, cap in ipairs(data and data.caps or {}) do
    paths[#paths + 1] = "assets/terrain/caps/" .. cap .. ".png"
  end
  if data and data.cliff and data.height > 0 then
    paths[#paths + 1] = "assets/terrain/cliffs/" .. data.cliff .. "_" .. data.height .. ".png"
  end
  return paths
end

-- The cap variant a hex shows, fixed by its position
local function cap_path(data, q, r)
  local hash = (q * 73856093) + (r * 19349663)
  return "assets/terrain/caps/" .. data.caps[math.abs(hash) % #data.caps + 1] .. ".png"
end

-- Ground pieces for hex (q, r) as plain data (no images): a `floor` piece for ground-level caps, carrying the grid
-- edges it draws, and the scene's clipped pieces (see the header). `terrain_at(q, r)` gives a hex's terrain type,
-- nil off the board.
function M.collect_terrain_drawables(q, r, terrain_at, offset_x, offset_y)
  local terrain_type = terrain_at(q, r)
  local data = TERRAIN_TYPES[terrain_type]
  if not (data and data.caps) then return {} end

  local grid_x, grid_y = grid_xy(q, r, offset_x, offset_y)
  local height = data.height
  local level = math.max(0, height)
  local anchor_y = M.get_anchor_y(grid_y, level)
  local path = cap_path(data, q, r)
  local function piece(fields)
    fields.kind, fields.q, fields.r = "terrain", q, r
    fields.x, fields.y = grid_x, anchor_y
    fields.elevation = level
    fields.standing_elevation = fields.standing_elevation or level
    return fields
  end

  if height > 0 then
    return {
      piece({
        path = "assets/terrain/cliffs/" .. data.cliff .. "_" .. height .. ".png",
        shape = "band" .. height,
      }),
      piece({ path = path, shape = "cap", lift = height }),
    }
  end

  local p = parity(q)
  local edges = {}
  for i = 3, 5 do
    local step = SOUTH_EDGES[i][p]
    local across = terrain_at(q + step[1], r + step[2])
    if not (across and M.get_terrain_elevation(across) <= 0) then edges[#edges + 1] = i end
  end
  local out = { piece({ tier = "floor", path = path, south_edges = edges }) }
  -- A wading unit stands at the bed and sorts there, as do the pieces of its water drawn around it
  local standing = math.min(0, height)
  for _, step in ipairs(NORTH_NEIGHBOURS[p]) do
    local north = terrain_at(q + step[1], r + step[2])
    if north and M.is_water(north) then
      out[#out + 1] = piece({ path = path, shape = "cap_top", standing_elevation = standing })
      break
    end
  end
  if height < 0 then
    out[#out + 1] =
      piece({ path = path, shape = "cap", cap_half = "near", cap_anchor_y = anchor_y, standing_elevation = standing })
  end
  return out
end

-- The hex grid over the floor: one drawable over every floor piece
function M.collect_grid_drawable(floor_pieces) return { kind = "hex_grid", tier = "grid", pieces = floor_pieces } end

-- A prop stands on its cap a little below the centre, at its art's base landmark, and sorts by the ground it stands
-- on (its cell's row and level), however tall it is, so it hides what stands north of it and not what stands south
function M.collect_environment_drawable(object_id, terrain_type, q, r, offset_x, offset_y)
  local def = ENVIRONMENT_OBJECTS[object_id]
  if not def then return nil end
  local art = PROP_ART.variants[def.class]
  local grid_x, grid_y = grid_xy(q, r, offset_x, offset_y)
  return {
    kind = "environment_object",
    environment_id = object_id,
    cover_type = def.cover_type,
    img = nil,
    x = grid_x,
    y = M.get_cap_center_y(terrain_type, q, r, offset_x, offset_y) + ui_settings.ENVIRONMENT_BASE_OFFSET,
    ox = art.landmarks.base.x,
    oy = art.landmarks.base.y,
    q = q,
    r = r,
    screen_row = math.floor(grid_y),
    standing_elevation = M.get_cap_elevation(terrain_type),
    def = def,
    scale = 1 / PROP_ART.scale,
  }
end

-- The `slot`th clutter piece of a hex stands at its own place off the centre of the cap, clear of a unit's pedestal
-- and ground ring
function M.build_clutter_drawable(instance, terrain_type, q, r, offset_x, offset_y, slot)
  if not instance or not instance.sprite then return nil end
  local slots = ui_settings.CLUTTER_SLOTS
  local place = slots[((slot or 1) - 1) % #slots + 1]
  local grid_x, grid_y = grid_xy(q, r, offset_x, offset_y)
  return {
    kind = "environment_clutter",
    sprite = instance.sprite,
    img = nil,
    x = grid_x + place[1] + (instance.jitter_x or 0),
    y = M.get_cap_center_y(terrain_type, q, r, offset_x, offset_y) + place[2] + (instance.jitter_y or 0),
    q = q,
    r = r,
    screen_row = math.floor(grid_y),
    standing_elevation = M.get_cap_elevation(terrain_type),
    clutter_render_order = instance.render_order or 1,
    scale = 1 / PROP_ART.scale,
  }
end

-- Get character position data for a tile
function M.get_character_position(q, r, offset_x, offset_y, terrain_type)
  terrain_type = terrain_type or "ground_normal"
  local terrain_data = TERRAIN_TYPES[terrain_type] or TERRAIN_TYPES.ground_normal

  local grid_x, grid_y = grid_xy(q, r, offset_x, offset_y)
  local surface_y = M.get_surface_y(grid_y, terrain_data.height)
  local character_x = grid_x + ui_settings.UNIT_TILE_CENTER_OFFSET_X
  local character_y = surface_y - ui_settings.TILE_CAP_TOP_OFFSET + ui_settings.UNIT_TILE_CENTER_OFFSET_Y
  return character_x, character_y
end

function M.draw_environment_object(d)
  if not d or not d.img or not image_on_screen(d.img, d.x, d.y, d.scale, d.ox, d.oy) then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(d.img, d.x, d.y, 0, d.scale, d.scale, d.ox, d.oy)
end

function M.draw_clutter(d)
  if not d or not d.img then return end
  local w, h = d.img:getWidth(), d.img:getHeight()
  if not image_on_screen(d.img, d.x, d.y, d.scale, w * 0.5, h - CLUTTER_BASE_MARGIN) then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(d.img, d.x, d.y, 0, d.scale, d.scale, w * 0.5, h - CLUTTER_BASE_MARGIN)
end

-- Phase 3.2: Get terrain type category for movement cost calculations
function M.get_terrain_type(terrain_key)
  local terrain_data = TERRAIN_TYPES[terrain_key]
  if not terrain_data then return "grass" end
  return terrain_data.terrain_type or "grass"
end

-- Phase 3.2: Get elevation for a terrain tile
function M.get_terrain_elevation(terrain_key)
  local terrain_data = TERRAIN_TYPES[terrain_key]
  if not terrain_data then return 0 end
  return terrain_data.height or 0
end

-- Phase 3.2: Check if terrain is passable
function M.is_passable(terrain_key)
  local terrain_data = TERRAIN_TYPES[terrain_key]
  if not terrain_data then return true end
  return terrain_data.passable ~= false
end

-- Get terrain data for gameplay mechanics
function M.get_terrain_data(terrain_type) return TERRAIN_TYPES[terrain_type] end

function M.get_environment_objects() return ENVIRONMENT_OBJECTS end

function M.get_environment_asset_path(object_id)
  local def = ENVIRONMENT_OBJECTS[object_id]
  if not def or not def.sprite then return nil end
  return "assets/environment/" .. def.sprite
end

function M.get_clutter_asset_path(sprite)
  if not sprite then return nil end
  return "assets/environment/" .. sprite
end

-- Draw one half of a water cell's cap: `draw` runs clipped to the far half (behind a wading unit) or the near half
-- (over its legs) of the surface whose tile anchor is d.cap_anchor_y
function M.draw_cap_half(d, draw)
  local cap_top_y = d.cap_anchor_y - ui_settings.TILE_CAP_TOP_OFFSET
  local cap_bottom_y = d.cap_anchor_y - ui_settings.TILE_CAP_BOTTOM_OFFSET
  local mid_y = math.floor(cap_top_y + (cap_bottom_y - cap_top_y) / 2)
  local split_y = math.floor(math.min(cap_bottom_y - 1, math.max(cap_top_y + 1, mid_y + balance.WATER_SPLIT_Y_OFFSET)))
  local left, right = d.x - ui_settings.TILE_ANCHOR_X, d.x - ui_settings.TILE_ANCHOR_X + ui_settings.TILE_WIDTH
  local top, bottom = cap_top_y, split_y
  if d.cap_half == "near" then
    top, bottom = split_y, cap_bottom_y + 1
  end
  -- Whole screen pixels, so the two halves meet at the same row with no seam between them
  local sx1, sy1 = world_to_screen(left, top)
  local sx2, sy2 = world_to_screen(right, bottom)
  sx1, sy1, sx2, sy2 = math.floor(sx1 + 0.5), math.floor(sy1 + 0.5), math.floor(sx2 + 0.5), math.floor(sy2 + 0.5)
  love.graphics.setScissor(sx1, sy1, sx2 - sx1, sy2 - sy1)
  draw()
  love.graphics.setScissor()
end

-- Clipped pieces draw through a textured mesh of their shape (logical px about the anchor) per image and shape, and
-- redraw the grid along the cap edges they cover (OUTLINES, open polylines).
-- A cap bordering water to its north covers its whole upper half again: every edge it can share with that water
-- (the top, or a diagonal down to a side corner) and the strip below it, deeper than a wader sinks (one level)
local SHAPES = { cap = GRID, cap_top = { GRID[1], GRID[2], GRID[3], GRID[6] } }
local OUTLINES = {
  cap = { GRID[1], GRID[2], GRID[3], GRID[4], GRID[5], GRID[6], GRID[1] },
  cap_top = { GRID[6], GRID[1], GRID[2], GRID[3] },
}
for steps = 1, 3 do
  local drop = steps * geometry.TILE_ELEVATION_PX + BAND_FRINGE
  local left, right, bottom_left, bottom_right = GRID[6], GRID[3], GRID[5], GRID[4]
  SHAPES["band" .. steps] = {
    { left[1], left[2] },
    { right[1], right[2] },
    { right[1], right[2] + drop },
    { bottom_right[1], bottom_right[2] + drop },
    { bottom_left[1], bottom_left[2] + drop },
    { left[1], left[2] + drop },
  }
end

local meshes = setmetatable({}, { __mode = "k" })
local function mesh_for(img, shape)
  local by_shape = meshes[img]
  if not by_shape then
    by_shape = {}
    meshes[img] = by_shape
  end
  local mesh = by_shape[shape]
  if not mesh then
    local w, h = img:getWidth(), img:getHeight()
    local vertices = {}
    for i, v in ipairs(assert(SHAPES[shape], "no terrain shape " .. tostring(shape))) do
      vertices[i] = { v[1], v[2], (ANCHOR_X + v[1] * ART_SCALE) / w, (ANCHOR_Y + v[2] * ART_SCALE) / h }
    end
    mesh = love.graphics.newMesh(vertices, "fan", "static")
    mesh:setTexture(img)
    by_shape[shape] = mesh
  end
  return mesh
end

local function set_grid_line()
  local ink = ui_settings.UI_COLORS.INK_900
  love.graphics.setColor(ink[1], ink[2], ink[3], ui_settings.BATTLE_HEX_EDGE_ALPHA)
  love.graphics.setLineWidth(1 / zoom())
end

local function outline(points, x, y)
  local pts = {}
  for _, v in ipairs(points) do
    pts[#pts + 1] = x + v[1]
    pts[#pts + 1] = y + v[2]
  end
  set_grid_line()
  love.graphics.line(pts)
  love.graphics.setLineWidth(1)
end

-- One terrain piece: a floor cap whole; a clipped piece through its mesh, a raised cap then catching its level's
-- light, and the grid redrawn along the cap edges it covered
function M.draw_piece(d)
  if not d.img or not image_on_screen(d.img, d.x, d.y, 1 / ART_SCALE, ANCHOR_X, ANCHOR_Y) then return end
  love.graphics.setColor(1, 1, 1, 1)
  if d.tier == "floor" then
    love.graphics.draw(d.img, d.x, d.y, 0, 1 / ART_SCALE, 1 / ART_SCALE, ANCHOR_X, ANCHOR_Y)
    return
  end
  local mesh = mesh_for(d.img, d.shape)
  love.graphics.draw(mesh, d.x, d.y)
  if d.lift and d.lift > 0 then
    local light = ui_settings.BATTLE_ELEVATION_LIGHT * d.lift
    love.graphics.setBlendMode("add")
    love.graphics.setColor(light, light, light, 1)
    love.graphics.draw(mesh, d.x, d.y)
    love.graphics.setBlendMode("alpha")
  end
  if OUTLINES[d.shape] then outline(OUTLINES[d.shape], d.x, d.y) end
  love.graphics.setColor(1, 1, 1, 1)
end

-- The hex grid over the floor: each floor hex draws its upper edges, and a lower edge only where no floor hex lies
-- across it, so every edge is drawn once
function M.draw_grid(d)
  set_grid_line()
  local top_left, top_right, right, left = GRID[1], GRID[2], GRID[3], GRID[6]
  for _, p in ipairs(d.pieces) do
    local x, y = p.x, p.y
    if on_screen(x + left[1], y + top_left[2], x + right[1], y + GRID[4][2]) then
      love.graphics.line(
        x + left[1],
        y + left[2],
        x + top_left[1],
        y + top_left[2],
        x + top_right[1],
        y + top_right[2],
        x + right[1],
        y + right[2]
      )
      for _, i in ipairs(p.south_edges) do
        local a, b = GRID[i], GRID[i % 6 + 1]
        love.graphics.line(x + a[1], y + a[2], x + b[1], y + b[2])
      end
    end
  end
  love.graphics.setLineWidth(1)
  love.graphics.setColor(1, 1, 1, 1)
end

return M
