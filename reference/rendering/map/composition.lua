-- rendering/map/composition.lua - What the painted overworld draws where (pure, no Love)
--
-- From a generated world: each cell's ground (its climate's kind, varied by shore, a broad lushness field and the
-- fields round settlements), in draw order (ground priority, then row, then column, so where neighbours' soft edges
-- meet a higher kind's lies over a lower's); each road hex's strips and hub; and the doodads (reeds in the marsh, a few
-- copses on open meadow), back to front. Every choice is a function of the world and the hex, so every bake of a
-- world is the same picture. Art is data/world/tiles/manifest.lua; drawing is rendering/map/canvas.lua.

local hex_grid = require("hex.grid")
local noise = require("world.noise")
local manifest = require("data.world.tiles.manifest")

local M = {}

local PRIORITY = {}
for i, kind in ipairs(manifest.GROUND_ORDER) do
  PRIORITY[kind] = i
end

local P = manifest.PAINT
local OPPOSITE = { N = "S", S = "N", NE = "SW", SW = "NE", SE = "NW", NW = "SE" }
local PRIME = 2147483647

-- A deterministic value in [0, 1) for a hex and a purpose (`salt`): a seeded MINSTD mix of the coordinates, kept
-- below 2^53 at every step so LuaJIT and Lua 5.4 agree
local function roll(col, row, salt, seed)
  local x = ((col + 4096) * 7919 + (row + 4096) * 104729 + salt * 1299709 + (seed or 0) % 1000003) % PRIME
  for _ = 1, 3 do
    x = x * 48271 % PRIME
  end
  return x / PRIME
end
M.roll = roll

local function pick(list, value) return list[math.floor(value * #list) + 1] end

-- The centre a hex's art is drawn on: hex_grid's drawn centre (odd rows half a world unit low), so picking and the
-- painted hex share one centre
function M.drawn_centre(x, y)
  local left, top = hex_grid.tile_origin(x, y)
  return left + hex_grid.CONSTANTS.TILE_WIDTH / 2, top + hex_grid.CONSTANTS.TILE_HEIGHT / 2
end

local function near(hex, places, radius)
  for _, place in ipairs(places) do
    if hex_grid.offset_distance(hex.col, hex.row, place.col, place.row) <= radius then return true end
  end
  return false
end

local function places_of(world, list)
  local found = {}
  for _, place in ipairs(list or {}) do
    local hex = world.hexes[place.hex_id]
    if hex then found[#found + 1] = hex end
  end
  return found
end

local function is_water(hex) return hex.climate == "ocean" end

-- Whether a hex lies on the shore: water beside land, or land beside water
local function on_shore(world, hex)
  local water = is_water(hex)
  for _, n in ipairs(hex_grid.hex_neighbors(hex.col, hex.row)) do
    local other = world.hexes[n.id]
    if other and is_water(other) ~= water then return true end
  end
  return false
end

-- The ground kind a hex paints (manifest CLIMATES and PAINT)
local function ground_kind(world, hex, settlements)
  local rule = manifest.CLIMATES[hex.climate] or error("no painted ground for climate " .. tostring(hex.climate))
  if rule.shore and on_shore(world, hex) then return rule.shore end
  if
    rule.fields
    and near(hex, settlements, P.fields_radius)
    and roll(hex.col, hex.row, 3, world.seed) < P.fields_share
  then
    return rule.fields
  end
  if
    rule.lush
    and noise.perlin_2d(hex.center.x, hex.center.y, P.lush_scale, 2, 0.5, (world.seed or 0) + 4111) > P.lush_above
  then
    return rule.lush
  end
  return rule.ground
end

local function sorted_ids(map)
  local ids = {}
  for id in pairs(map or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

local function by_row(a, b)
  if a.row ~= b.row then return a.row < b.row end
  return a.col < b.col
end

-- The doodad a hex carries, if any: reeds on marsh, a copse on open meadow clear of roads and places
local function doodad(world, hex, kind, clear)
  local set
  if kind == "swamp" and roll(hex.col, hex.row, 5, world.seed) < P.reeds_share then
    set = manifest.DOODADS.reeds
  elseif
    (kind == "meadow" or kind == "dark_grass")
    and not clear[hex.id]
    and roll(hex.col, hex.row, 7, world.seed) < P.copse_share
  then
    set = manifest.DOODADS.copse
  end
  if not set then return nil end
  return { variant = set.variant, file = pick(set.files, roll(hex.col, hex.row, 11, world.seed)) }
end

-- { ground, roads, doodads }: ground jobs { hex_id, col, row, x, y, kind, priority, file } in draw order; road jobs
-- { hex_id, col, row, x, y, files } (strips by edge, then the hub); doodad jobs { hex_id, col, row, x, y, variant,
-- file } back to front. x, y are each hex's drawn centre in world units.
function M.compose(world)
  local hexes = world.hexes or {}
  local roads = (world.roads or {}).tiles or {}
  local settlements, sites = places_of(world, world.towns), places_of(world, world.pois)

  -- Copses keep clear of roads and of places
  local clear = {}
  for id in pairs(roads) do
    clear[id] = true
  end
  for id, hex in pairs(hexes) do
    if near(hex, settlements, P.copse_clear.settlement) or near(hex, sites, P.copse_clear.site) then
      clear[id] = true
    end
  end

  local ground, doodads = {}, {}
  for _, id in ipairs(sorted_ids(hexes)) do
    local hex = hexes[id]
    local x, y = M.drawn_centre(hex.center.x, hex.center.y)
    local kind = ground_kind(world, hex, settlements)
    ground[#ground + 1] = {
      hex_id = id,
      col = hex.col,
      row = hex.row,
      x = x,
      y = y,
      kind = kind,
      priority = PRIORITY[kind],
      file = pick(manifest.GROUND[kind], roll(hex.col, hex.row, 1, world.seed)),
    }
    local object = doodad(world, hex, kind, clear)
    if object then
      object.hex_id, object.col, object.row, object.x, object.y = id, hex.col, hex.row, x, y + manifest.BASE_DROP
      doodads[#doodads + 1] = object
    end
  end
  table.sort(ground, function(a, b)
    if a.priority ~= b.priority then return a.priority < b.priority end
    return by_row(a, b)
  end)
  table.sort(doodads, by_row)

  local road_jobs = {}
  for _, id in ipairs(sorted_ids(roads)) do
    local tile, hex = roads[id], hexes[id]
    local edges, files = tile.overlay_edges or {}, {}
    for _, edge in ipairs(edges) do
      files[#files + 1] = manifest.ROADS[edge] or error("no road strip for edge " .. tostring(edge))
    end
    if #files > 0 then
      -- A road running straight through needs no hub; an end, a bend or a junction does
      if not (#edges == 2 and OPPOSITE[edges[1]] == edges[2]) then files[#files + 1] = manifest.ROADS.hub end
      local x, y = M.drawn_centre(tile.center.x, tile.center.y)
      road_jobs[#road_jobs + 1] = { hex_id = id, col = hex.col, row = hex.row, x = x, y = y, files = files }
    end
  end
  table.sort(road_jobs, by_row)

  return { ground = ground, roads = road_jobs, doodads = doodads }
end

-- The art a settlement of `tier` (village, town, city) draws: one of its tier's miniatures, by its hex
function M.settlement_art(tier, col, row, seed)
  local list = manifest.SETTLEMENTS[tier] or error("no settlement art for tier " .. tostring(tier))
  return pick(list, roll(col, row, 13, seed))
end

return M
