-- hex/grid.lua - The world map's one hex geometry: pointy-top hexes in odd-r offset rows
--
-- Centres, the whole-pixel position each tile is drawn at, which hex a point belongs to (the tile drawn on top
-- there), neighbours, distances and the hexes a straight line crosses. Contract: data/world/tiles/agents.md.

local M = {}

local CONSTANTS = {
  TILE_WIDTH = 30,
  TILE_HEIGHT = 34,
  -- Height of a tile's top (and bottom) point above its side corners: the slanted edges fall one row per two
  -- columns, so a tile is full width from 9.5 above its centre to 9.5 below
  TIP_HEIGHT = 7.5,
}
CONSTANTS.HORIZONTAL_SPACING = CONSTANTS.TILE_WIDTH
CONSTANTS.VERTICAL_SPACING = CONSTANTS.TILE_HEIGHT * 0.75
CONSTANTS.ROW_OFFSET = CONSTANTS.TILE_WIDTH * 0.5

M.CONSTANTS = CONSTANTS

local HALF_W = CONSTANTS.TILE_WIDTH / 2
local HALF_H = CONSTANTS.TILE_HEIGHT / 2
local TIP_SLOPE = CONSTANTS.TIP_HEIGHT / HALF_W

local function cache_key(a, b) return tostring(a) .. ":" .. tostring(b) end

local function clamp(value, min_value, max_value)
  if min_value and value < min_value then return min_value end
  if max_value and value > max_value then return max_value end
  return value
end

function M.hex_id(col, row) return string.format("%d:%d", col, row) end

function M.hex_index(col, row) return M.hex_id(col, row) end

local offset_to_axial_cache = {}
local axial_to_offset_cache = {}

local function offset_to_axial(col, row)
  local key = cache_key(col, row)
  local cached = offset_to_axial_cache[key]
  if cached then return cached[1], cached[2] end

  -- odd-r offset -> axial conversion
  local q = col - math.floor(row / 2) -- an integer under Lua 5.4 too, so axial steps name road edges
  local r = row
  offset_to_axial_cache[key] = { q, r }
  return q, r
end

local function axial_to_offset(q, r)
  local key = cache_key(q, r)
  local cached = axial_to_offset_cache[key]
  if cached then return cached[1], cached[2] end

  local col = q + math.floor(r / 2)
  local row = r
  axial_to_offset_cache[key] = { col, row }
  return col, row
end

function M.hex_to_world(col, row)
  local x = col * CONSTANTS.HORIZONTAL_SPACING
  local y = row * CONSTANTS.VERTICAL_SPACING
  if row % 2 ~= 0 then x = x + CONSTANTS.ROW_OFFSET end
  return x, y
end

-- Top-left pixel of a TILE_WIDTH x TILE_HEIGHT world-map sprite centred on (x, y). Odd rows sit on half pixels
-- (VERTICAL_SPACING is 25.5), and nearest-filtered pixel art drawn there duplicates and drops rows, so round.
function M.tile_origin(x, y) return math.floor(x - HALF_W + 0.5), math.floor(y - HALF_H + 0.5) end

-- Centre of a hex's tile as drawn: its centre rounded to tile_origin (odd rows half a pixel lower)
local function drawn_centre(col, row)
  local left, top = M.tile_origin(M.hex_to_world(col, row))
  return left + HALF_W, top + HALF_H
end

-- Whether (x, y) lies on the hex's tile: within its sides (left edge inclusive, so tiles of one row abut without
-- overlap) and under its slanted top and bottom edges
local function on_tile(col, row, x, y)
  local cx, cy = drawn_centre(col, row)
  local dx, dy = x - cx, y - cy
  return dx >= -HALF_W and dx < HALF_W and math.abs(dy) <= HALF_H - TIP_SLOPE * math.abs(dx)
end

M.on_tile = on_tile

-- The region world_to_hex gives a hex in `row`, about its drawn centre: its tile less the two tiles of the row below
-- that cover its lower edges. A convex hex `half_w` either side, reaching `top` above the centre and `bottom` below
-- it (the next row is 26 below an even row's drawn centre, 25 below an odd row's), both edges falling `slope` per
-- unit out from the middle. Every painted hex is drawn over exactly this region.
function M.region(row)
  local _, below = drawn_centre(0, row + 1)
  local _, here = drawn_centre(0, row)
  return {
    half_w = HALF_W,
    top = HALF_H,
    bottom = below - here - HALF_H + CONSTANTS.TIP_HEIGHT,
    slope = TIP_SLOPE,
  }
end

-- The hex a point belongs to: the one whose tile is drawn on top there. Tiles are drawn row by row, so where the
-- points of two rows overlap the lower row's tile covers the upper one's. Every point lies on a tile of its
-- nearest row band or the band below or above (rows step 25.5, tiles reach 17 above and below their centre).
local function owner(x, y)
  local band = math.floor((y + CONSTANTS.VERTICAL_SPACING / 2) / CONSTANTS.VERTICAL_SPACING)
  for row = band + 1, band - 1, -1 do
    local shift = (row % 2 ~= 0) and CONSTANTS.ROW_OFFSET or 0
    local col = math.floor((x - shift + HALF_W) / CONSTANTS.HORIZONTAL_SPACING)
    for c = col - 1, col + 1 do
      if on_tile(c, row, x, y) then return c, row end
    end
  end
  error(string.format("hex.grid: no tile covers (%s, %s)", tostring(x), tostring(y)))
end

-- opts may clamp the result to { min_col, max_col, min_row, max_row } (a world's hex_config)
function M.world_to_hex(wx, wy, opts)
  local col, row = owner(wx, wy)

  if opts then
    if opts.min_col or opts.max_col then col = clamp(col, opts.min_col, opts.max_col) end
    if opts.min_row or opts.max_row then row = clamp(row, opts.min_row, opts.max_row) end
  end

  return col, row, M.hex_id(col, row)
end

function M.offset_to_axial(col, row) return offset_to_axial(col, row) end

function M.axial_to_offset(q, r) return axial_to_offset(q, r) end

function M.offset_distance(col1, row1, col2, row2)
  local q1, r1 = offset_to_axial(col1, row1)
  local q2, r2 = offset_to_axial(col2, row2)
  return M.axial_distance(q1, r1, q2, r2)
end

function M.axial_distance(q1, r1, q2, r2)
  local x1, z1 = q1, r1
  local y1 = -x1 - z1
  local x2, z2 = q2, r2
  local y2 = -x2 - z2
  return math.max(math.abs(x1 - x2), math.abs(y1 - y2), math.abs(z1 - z2))
end

function M.hex_neighbors(col, row)
  local neighbors = {}
  local offsets_even = {
    { -1, -1 },
    { 0, -1 },
    { -1, 0 },
    { 1, 0 },
    { -1, 1 },
    { 0, 1 },
  }
  local offsets_odd = {
    { 0, -1 },
    { 1, -1 },
    { -1, 0 },
    { 1, 0 },
    { 0, 1 },
    { 1, 1 },
  }

  local offsets = (row % 2 ~= 0) and offsets_odd or offsets_even
  for _, delta in ipairs(offsets) do
    local neighbor_col = col + delta[1]
    local neighbor_row = row + delta[2]
    neighbors[#neighbors + 1] = {
      col = neighbor_col,
      row = neighbor_row,
      id = M.hex_id(neighbor_col, neighbor_row),
    }
  end

  return neighbors
end

-- The line two neighbouring hexes meet along, as (a, b, c): the first hex's side is a*x + b*y < c. Hexes of one
-- row meet halfway between their centres; across rows, along the lower tile's slanted upper edge facing the upper
-- hex, since the lower tile is drawn over the upper one.
local function boundary(col, row, ncol, nrow)
  local x, y = drawn_centre(col, row)
  local nx, ny = drawn_centre(ncol, nrow)
  if nrow == row then
    local toward = nx > x and 1 or -1
    return toward, 0, toward * (x + nx) / 2
  end
  local lower_x, lower_y, upper_x = nx, ny, x
  if nrow < row then
    lower_x, lower_y, upper_x = x, y, nx
  end
  local side = upper_x > lower_x and 1 or -1
  -- Upper side of the edge y = lower_y - HALF_H + side * TIP_SLOPE * (x - lower_x)
  local a, b, c = -side * TIP_SLOPE, 1, lower_y - HALF_H - side * TIP_SLOPE * lower_x
  if nrow < row then return -a, -b, -c end
  return a, b, c
end

-- Every hex the segment (x1, y1) -> (x2, y2) passes through, in order, as { col, row, enter, exit } where enter and
-- exit are fractions of the segment. A point belongs to the hex `world_to_hex` names (the tile drawn on top), so
-- each hex holds the stretch of the segment's line inside its six boundaries, and a boundary the segment runs along
-- is the hex's own when world_to_hex says so: one facing the row above, or the left neighbour. A clipped corner
-- counts however short; merely touching an edge or vertex (TOUCH_LENGTH or less, which is rounding) does not.
local TOUCH_LENGTH = 1e-9
function M.segment_hexes(x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  local length = math.sqrt(dx * dx + dy * dy)

  -- The stretch of the segment's line the hex holds, as fractions (from, to); empty (from > to) when the line runs
  -- along a boundary that is not the hex's. Such a boundary is judged from the start point alone, never a rounded
  -- point further along, so a line exactly on it is decided exactly.
  local function stretch(hex)
    local from, to = -math.huge, math.huge
    for _, neighbor in ipairs(M.hex_neighbors(hex.col, hex.row)) do
      local a, b, c = boundary(hex.col, hex.row, neighbor.col, neighbor.row)
      local toward, room = a * dx + b * dy, c - (a * x1 + b * y1)
      if toward > 0 then
        to = math.min(to, room / toward)
      elseif toward < 0 then
        from = math.max(from, room / toward)
      else
        local own = neighbor.row < hex.row or (neighbor.row == hex.row and neighbor.col < hex.col)
        if room < 0 or (room == 0 and not own) then return 1, 0 end
      end
    end
    return from, to
  end

  -- The hex among `hexes` that holds the segment from t on, and where it leaves it; nil at the segment's end
  local function next_cell(hexes, t)
    for _, hex in ipairs(hexes) do
      local from, to = stretch(hex)
      local exit = math.min(to, 1)
      if (from - t) * length <= TOUCH_LENGTH and (exit - t) * length > TOUCH_LENGTH then return hex, exit end
    end
  end

  -- The start point's own hex, or a neighbour when the segment leaves at once through that point's edge or vertex
  local start_col, start_row = owner(x1, y1)
  local candidates = M.hex_neighbors(start_col, start_row)
  table.insert(candidates, 1, { col = start_col, row = start_row })
  local cells = {}
  local hex, exit = next_cell(candidates, 0)
  local enter = 0
  while hex do
    cells[#cells + 1] = { col = hex.col, row = hex.row, enter = enter, exit = exit }
    enter = exit
    hex, exit = next_cell(M.hex_neighbors(hex.col, hex.row), enter)
  end
  if #cells == 0 then cells[1] = { col = start_col, row = start_row, enter = 0, exit = 1 } end
  return cells
end

return M
