-- hex/geometry.lua - Shared hex geometry constants and utilities
-- Consolidates flat-top hex constants and coordinate conversions
local M = {}

-- Flat-top hex geometry constants (measured from tile assets)
M.FLAT_TOP_DX = 188 -- Horizontal distance between hex centers (column stride)
M.FLAT_TOP_DY_FULL = 118 -- Vertical distance between row centers (row stride)
M.FLAT_TOP_DY_HALF = 60 -- Half-row offset for odd-q coordinate system

-- Export individual constants for backward compatibility
M.DX = M.FLAT_TOP_DX
M.DY_FULL = M.FLAT_TOP_DY_FULL
M.DY_HALF = M.FLAT_TOP_DY_HALF

-- Elevation rendering constants (shared with UI settings)
M.TILE_ELEVATION_PX = 48
M.TILE_CAP_BOTTOM_OFFSET = 42
M.TILE_CAP_TOP_OFFSET = 160
M.TILE_CAP_POLYGON = {
  { -66, -158 },
  { 64, -158 },
  { 120, -100 },
  { 64, -42 },
  { -66, -42 },
  { -122, -100 },
}

-- Validation helpers
function M.validate_offset(offset_x, offset_y)
  offset_x = offset_x or 0
  offset_y = offset_y or 0
  assert(type(offset_x) == "number", "offset_x must be a number")
  assert(type(offset_y) == "number", "offset_y must be a number")
  return offset_x, offset_y
end

function M.validate_coordinates(q, r)
  assert(type(q) == "number", "q must be a number")
  assert(type(r) == "number", "r must be a number")
  return q, r
end

-- Unified converter: axial to screen (flat-top)
-- Centralizes the conversion logic with consistent rounding
function M.axial_to_screen(q, r, offset_x, offset_y)
  offset_x, offset_y = M.validate_offset(offset_x, offset_y)
  q, r = M.validate_coordinates(q, r)

  local x = offset_x + q * M.FLAT_TOP_DX
  local y = offset_y + r * M.FLAT_TOP_DY_FULL + (q % 2) * M.FLAT_TOP_DY_HALF
  return x, y
end

-- Unified converter: screen to axial (flat-top)
-- Uses consistent rounding rules to minimize edge cases
function M.screen_to_axial(x, y, offset_x, offset_y)
  offset_x, offset_y = M.validate_offset(offset_x, offset_y)
  assert(type(x) == "number", "x must be a number")
  assert(type(y) == "number", "y must be a number")

  -- Calculate q with rounding (not floor)
  local q = math.floor((x - offset_x) / M.FLAT_TOP_DX + 0.5)

  -- Adjust y for odd-q offset before calculating r
  local y_adjusted = y - offset_y - (q % 2) * M.FLAT_TOP_DY_HALF
  local r = math.floor(y_adjusted / M.FLAT_TOP_DY_FULL + 0.5)

  return q, r
end

-- Helper to get hex center position (useful for distance calculations)
function M.get_hex_center(q, r, offset_x, offset_y) return M.axial_to_screen(q, r, offset_x, offset_y) end

-- Calculate squared distance between screen point and hex center
-- (useful for picking and collision detection)
function M.distance_squared(x, y, q, r, offset_x, offset_y)
  local cx, cy = M.get_hex_center(q, r, offset_x, offset_y)
  local dx = x - cx
  local dy = y - cy
  return dx * dx + dy * dy
end

function M.compute_surface_y(grid_y, elevation) return grid_y - (elevation or 0) * M.TILE_ELEVATION_PX end

function M.compute_anchor_y(grid_y, elevation) return M.compute_surface_y(grid_y, elevation) + M.TILE_CAP_BOTTOM_OFFSET end

function M.compute_anchor_position(q, r, offset_x, offset_y, elevation)
  local gx, gy = M.get_hex_center(q, r, offset_x, offset_y)
  return gx, M.compute_anchor_y(gy, elevation)
end

return M
