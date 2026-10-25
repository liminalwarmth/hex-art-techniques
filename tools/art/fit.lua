-- tools/art/fit.lua - Template-driven normalization: measure a raw generation's own landmarks, map them
-- onto the family template (uniform scale + translation, never a stretch to fill a box), resample, clean
-- the alpha edge and check the result against the template landmarks. Icons, UI kit pieces and
-- illustrations have their own normalizers (whole-tile, slice atlas or fixed sprite, cover crop). An item's
-- `cut` ({ x, y, w, h } raw px) takes one piece of a generation that painted several.
local image = require("tools.art.image")
local templates = require("data.items.visual_templates")
local hex_geometry = require("hex.geometry")
local hex_grid = require("hex.grid")

local M = {}

local WORK = 4 -- detection grid: work pixels per export pixel (capped at the raw's own resolution)
local SOLID = 128 -- alpha that counts as part of the item when measuring
local MIN_ALPHA = 12 -- softer export pixels are haze, not art
local MIN_SPECK = 6 -- isolated islands smaller than this (export px) are removed
local OPAQUE = 250 -- export pixels this opaque anchor the colour of the soft edge around them
local HALO_LUM = 24 -- a soft-edge pixel this much brighter than every nearby opaque pixel is a halo
local KEY_HALO_SHARE = 0.002
local SPILL = 50 -- the key channels may exceed the others by this much in a keyed painting (olive grass); more is spill
local COARSE_POINTS, FINE_POINTS = 12000, 160000 -- silhouette search budgets (points per candidate)

local floor, ceil, max, min, abs, sqrt = math.floor, math.ceil, math.max, math.min, math.abs, math.sqrt

function M.sprite_path(family_name, sprite)
  return string.format("assets/units/%s/%s.png", templates.FAMILIES[family_name].folder, sprite)
end

-- Template geometry -------------------------------------------------------------------------------------

-- Polygon zones (export pixels) derived from the game's own hex geometry, so art and runtime share numbers
local SHAPES = {}

function SHAPES.battle_cap(t)
  local a, s, pts = t.landmarks.anchor, t.scale, {}
  for _, v in ipairs(hex_geometry.TILE_CAP_POLYGON) do
    pts[#pts + 1] = { a.x + v[1] * s, a.y + v[2] * s }
  end
  return pts
end

-- The cap's lower chain (vertices at or below its middle, in order), dropped by `steps` elevation steps
function SHAPES.battle_cliff(t)
  local cap = SHAPES.battle_cap(t)
  local top, bottom = math.huge, -math.huge
  for _, p in ipairs(cap) do
    top, bottom = min(top, p[2]), max(bottom, p[2])
  end
  local mid, n, start = (top + bottom) / 2, #cap, nil
  for i = 1, n do
    local prev = cap[(i - 2) % n + 1]
    if cap[i][2] >= mid and prev[2] < mid then start = i end
  end
  local chain = {}
  for k = 0, n - 1 do
    local p = cap[(start - 1 + k) % n + 1]
    if p[2] < mid then break end
    chain[#chain + 1] = p
  end
  local drop, pts = t.steps * hex_geometry.TILE_ELEVATION_PX * t.scale, {}
  for _, p in ipairs(chain) do
    pts[#pts + 1] = p
  end
  for i = #chain, 1, -1 do
    pts[#pts + 1] = { chain[i][1], chain[i][2] + drop }
  end
  return pts
end

function SHAPES.world_hex(t)
  local c, s, k = t.landmarks.centre, t.scale, hex_grid.CONSTANTS
  local hw, hh, tip = k.TILE_WIDTH * s / 2, k.TILE_HEIGHT * s / 2, (k.TILE_HEIGHT - k.VERTICAL_SPACING) * s
  return {
    { c.x, c.y - hh },
    { c.x + hw, c.y - hh + tip },
    { c.x + hw, c.y + hh - tip },
    { c.x, c.y + hh },
    { c.x - hw, c.y + hh - tip },
    { c.x - hw, c.y - hh + tip },
  }
end

-- A strip from the tile centre out through the middle of the edge at `bearing` (degrees, y down)
function SHAPES.world_half_edge(t, item)
  local c = t.landmarks.centre
  local a = math.rad(assert(item.bearing, "road and river items name the bearing of their edge"))
  local reach = hex_grid.CONSTANTS.TILE_WIDTH * t.scale / 2
  local dx, dy, hw = math.cos(a), math.sin(a), t.zone.half_width
  local ex, ey = c.x + dx * reach, c.y + dy * reach
  return {
    { c.x - dy * hw, c.y + dx * hw },
    { ex - dy * hw, ey + dx * hw },
    { ex + dy * hw, ey - dx * hw },
    { c.x + dy * hw, c.y - dx * hw },
  }
end

-- A twelve-sided disc of `radius` around the tile centre
function SHAPES.world_hub(t)
  local c, r, pts = t.landmarks.centre, t.zone.radius, {}
  for i = 0, 11 do
    local a = math.rad(i * 30)
    pts[#pts + 1] = { c.x + r * math.cos(a), c.y + r * math.sin(a) }
  end
  return pts
end

-- A convex polygon grown outward by d px (each edge moved out, corners at the moved edges' intersections)
local function grow_polygon(poly, d)
  local n, area = #poly, 0
  for i = 1, n do
    local p, q = poly[i], poly[i % n + 1]
    area = area + p[1] * q[2] - q[1] * p[2]
  end
  local side = area > 0 and 1 or -1 -- outward normal side for this winding (y down)
  local lines = {}
  for i = 1, n do
    local p, q = poly[i], poly[i % n + 1]
    local ex, ey = q[1] - p[1], q[2] - p[2]
    local len = sqrt(ex * ex + ey * ey)
    local nx, ny = side * ey / len, -side * ex / len
    lines[i] = { p[1] + nx * d, p[2] + ny * d, ex, ey }
  end
  local out = {}
  for i = 1, n do
    local a, b = lines[(i - 2) % n + 1], lines[i]
    local den = a[3] * b[4] - a[4] * b[3]
    local u = ((b[1] - a[1]) * b[4] - (b[2] - a[2]) * b[3]) / den
    out[i] = { a[1] + a[3] * u, a[2] + a[4] * u }
  end
  return out
end

-- The family template for an item: its family with the item's variant merged in, the size it is fitted to
-- and the zone resolved to concrete numbers
function M.template(item)
  local family = templates.FAMILIES[item.family] or error("unknown family " .. tostring(item.family))
  local t = {}
  for k, v in pairs(family) do
    t[k] = v
  end
  if family.variants then
    local variant = family.variants[item.variant]
    if not variant then
      local names = {}
      for name in pairs(family.variants) do
        names[#names + 1] = name
      end
      table.sort(names)
      error(string.format("%s item %s needs a variant (%s)", item.family, item.id, table.concat(names, ", ")))
    end
    for k, v in pairs(variant) do
      t[k] = v
    end
  end
  if family.fields then t.field = family.fields[item.id] end
  -- A generation painted on another key (or on none, `matte = false`) names it; a skill names its rim category
  -- and a status its badge cut
  if item.matte ~= nil then t.matte = item.matte or nil end
  -- A weapon whose head sits on one side of its haft (an axe's blade, a knife's edge) splits brightness by its
  -- steel, not its light: it names `light = false` and its light is judged on the sheet
  if item.light == false then t.light = false end
  if item.rim then t.rim_colour = t.rims[item.rim] or error(item.id .. " has no rim colour " .. item.rim) end
  t.badge = item.badge and t.badge or nil
  t.variants, t.fields, t.rims, t.name, t.scale = nil, nil, nil, item.family, t.scale or 1
  t.cut, t.hotspot = item.cut, item.hotspot -- the piece's rectangle on a generation that holds several
  if t.sizes then t.size = assert(t.sizes[item.size], item.family .. " item needs a size from the family sizes") end
  if t.fit.kind == "nine_slice" then
    local function sum(list)
      local n = 0
      for _, v in ipairs(list) do
        n = n + v
      end
      return n
    end
    t.canvas = { width = sum(t.cols), height = sum(t.rows) }
  end
  if t.zone.kind == "dome" and not t.zone.cx then
    local lm = t.landmarks
    t.zone = { kind = "dome", cx = lm.crown.x, top = lm.crown.y, bottom = lm.brow.y, half_width = t.half_width }
  elseif t.zone.kind == "polygon" then
    -- The guide shows the shape; ground is fitted to it grown by `seal`, so neighbours overlap with no seam
    t.guide_polygon = SHAPES[t.zone.shape](t, item)
    t.polygon = t.seal and grow_polygon(t.guide_polygon, t.seal) or t.guide_polygon
    if t.name == "world_tile" and t.zone.shape ~= "world_hex" then t.outline_hint = SHAPES.world_hex(t) end
  end
  -- Generations are square frames: the canvas sits centred in a frame of its longer side
  t.frame = max(t.canvas.width, t.canvas.height)
  t.off = { x = (t.frame - t.canvas.width) / 2, y = (t.frame - t.canvas.height) / 2 }
  return t
end

-- Image files a template's fit and checks read besides the raw (part of every output's fingerprint)
function M.image_inputs(t)
  if t.zone.kind == "silhouette" then return { t.zone.path } end
  return {}
end

-- Masks ------------------------------------------------------------------------------------------------

-- Binary mask {w, h, [i] = true} of alpha >= threshold
local function mask_of(img, threshold)
  local m = { w = img.w, h = img.h }
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      if image.alpha(img, x, y) >= threshold then m[y * img.w + x] = true end
    end
  end
  return m
end

-- Drop 8-connected islands smaller than min_size from a mask (or, with clear_img, zero them in the image)
local function remove_islands(m, min_size, clear_img)
  local seen = {}
  for start = 0, m.w * m.h - 1 do
    if m[start] and not seen[start] then
      local stack, island = { start }, {}
      seen[start] = true
      while #stack > 0 do
        local i = table.remove(stack)
        island[#island + 1] = i
        local x, y = i % m.w, floor(i / m.w)
        for dy = -1, 1 do
          for dx = -1, 1 do
            local nx, ny = x + dx, y + dy
            local j = ny * m.w + nx
            if nx >= 0 and ny >= 0 and nx < m.w and ny < m.h and m[j] and not seen[j] then
              seen[j] = true
              stack[#stack + 1] = j
            end
          end
        end
      end
      if #island < min_size then
        for _, i in ipairs(island) do
          m[i] = nil
          if clear_img then image.set(clear_img, i % m.w, floor(i / m.w), 0, 0, 0, 0) end
        end
      end
    end
  end
  return m
end

local function point_in_polygon(poly, x, y)
  local inside, j = false, #poly
  for i = 1, #poly do
    local xi, yi, xj, yj = poly[i][1], poly[i][2], poly[j][1], poly[j][2]
    if (yi > y) ~= (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi then inside = not inside end
    j = i
  end
  return inside
end

local function polygon_distance(poly, x, y)
  local best, j = math.huge, #poly
  for i = 1, #poly do
    local ax, ay, bx, by = poly[j][1], poly[j][2], poly[i][1], poly[i][2]
    local vx, vy = bx - ax, by - ay
    local u = max(0, min(1, ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)))
    local dx, dy = x - ax - u * vx, y - ay - u * vy
    best = min(best, sqrt(dx * dx + dy * dy))
    j = i
  end
  return best
end

-- Per-pixel coverage (0..1) of the template's zone sprite, bilinear from its own resolution
local function sprite_coverage(t)
  local zone = t.zone
  local ref = image.read(zone.path)
  local k = ref.w / t.canvas.width
  local cov = {}
  for y = 0, t.canvas.height - 1 do
    for x = 0, t.canvas.width - 1 do
      local sx, sy = (x + 0.5) * k - 0.5, (y + 0.5) * k - 0.5
      local x0, y0 = floor(sx), floor(sy)
      local fx, fy = sx - x0, sy - y0
      local function v(px, py) return image.alpha(ref, px, py) >= zone.threshold and 1 or 0 end
      cov[y * t.canvas.width + x] = (v(x0, y0) * (1 - fx) + v(x0 + 1, y0) * fx) * (1 - fy)
        + (v(x0, y0 + 1) * (1 - fx) + v(x0 + 1, y0 + 1) * fx) * fy
    end
  end
  return cov
end

-- The zone as a canvas-sized binary mask (silhouette sprite or polygon), or nil for other zone kinds
local function zone_mask(t)
  local w, h = t.canvas.width, t.canvas.height
  local m = { w = w, h = h }
  if t.zone.kind == "silhouette" then
    local cov = sprite_coverage(t)
    for i = 0, w * h - 1 do
      if cov[i] >= 0.5 then m[i] = true end
    end
  elseif t.polygon then
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        if point_in_polygon(t.polygon, x + 0.5, y + 0.5) then m[y * w + x] = true end
      end
    end
  else
    return nil
  end
  return m
end
M.zone_mask = zone_mask

-- Measurement ------------------------------------------------------------------------------------------

-- Remove the flat chroma key a generation was painted on (`green` #00FF00 or `magenta` #FF00FF): alpha from the
-- colour's excess of the key channels over the others, and the key's spill (any excess over `spill`) taken out
-- of the soft edge it leaves
local KEYS = {
  green = function(r, g, b) return g - max(r, b) end,
  magenta = function(r, g, b) return min(r, b) - g end,
}

local function key_matte(raw, matte, spill)
  local excess_of = KEYS[matte] or error("unknown matte " .. tostring(matte))
  local green, px = matte == "green", raw.px
  for i = 1, raw.w * raw.h * 4, 4 do
    local r, g, b = px[i], px[i + 1], px[i + 2]
    local excess = excess_of(r, g, b)
    if excess >= 200 then
      px[i], px[i + 1], px[i + 2], px[i + 3] = 0, 0, 0, 0
    elseif excess > spill then
      -- bring the key channels down until they exceed the others by at most `spill` (by nothing past 90)
      local d = excess > 90 and excess or excess - spill
      if green then
        px[i + 1] = g - d
      else
        px[i], px[i + 2] = r - d, b - d
      end
      if excess > 90 then px[i + 3] = floor(px[i + 3] * (200 - excess) / 110 + 0.5) end
    end
  end
  return raw
end

-- Points (canvas units, pixel centres) of the measured item: the raw alpha box-filtered onto the work grid
local function measure_points(raw, t)
  local s = t.frame
  local ww = min(s * WORK, raw.w)
  local f = raw.w / ww
  local work = image.resample(raw, ww, ww, function(x, y) return x * f, y * f end, max(1, floor(f + 0.5)))
  local g = ww / s
  local m = remove_islands(mask_of(work, SOLID), floor(g * g * MIN_SPECK))
  local pts = {}
  for i = 0, ww * ww - 1 do
    if m[i] then pts[#pts + 1] = { (i % ww + 0.5) / g - t.off.x, (floor(i / ww) + 0.5) / g - t.off.y } end
  end
  if #pts == 0 then error("raw image has no opaque pixels") end
  return pts, g
end

local function bounds(pts)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, p in ipairs(pts) do
    x0, y0, x1, y1 = min(x0, p[1]), min(y0, p[2]), max(x1, p[1]), max(y1, p[2])
  end
  return x0, y0, x1, y1
end

local function stride(list, budget)
  if #list <= budget then return list end
  local out, step = {}, ceil(#list / budget)
  for i = 1, #list, step do
    out[#out + 1] = list[i]
  end
  return out
end

-- Fits -------------------------------------------------------------------------------------------------
-- Each returns s, tx, ty for p = c + s * (q - c) + t, with q in canvas units and c the canvas centre

local fits = {}

function fits.dome(pts, t, g)
  local zone, fit = t.zone, t.fit
  local crown = math.huge
  for _, p in ipairs(pts) do
    crown = min(crown, p[2])
  end
  local height = zone.bottom - zone.top
  local depth_y = crown + fit.depth * height
  local row = (floor(depth_y * g) + 0.5) / g -- the work row holding depth_y
  local x0, x1 = math.huge, -math.huge
  for _, p in ipairs(pts) do
    if abs(p[2] - row) < 0.25 / g then
      x0, x1 = min(x0, p[1]), max(x1, p[1])
    end
  end
  local measured = x1 - x0 + 1 / g
  local dy = (1 - fit.depth) * height
  local target = 2 * zone.half_width * sqrt(1 - (dy / height) ^ 2)
  local s = target / measured
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local mid = (x0 + x1) / 2
  return s, zone.cx - (cx + s * (mid - cx)), zone.top - (cy + s * (crown - cy)), { scale_error = s - 1 }
end

function fits.rigid(pts, t, g)
  local sx, sy, y0, y1 = 0, 0, math.huge, -math.huge
  for _, p in ipairs(pts) do
    sx, sy = sx + p[1], sy + p[2]
    y0, y1 = min(y0, p[2]), max(y1, p[2])
  end
  local mx, my = sx / #pts, sy / #pts
  local s = t.size / (y1 - y0 + 1 / g)
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local grip = t.landmarks.grip
  return s, grip.x - (cx + s * (mx - cx)), grip.y - (cy + s * (my - cy)), {}
end

function fits.axis(pts, t, g)
  local lm = t.landmarks
  local a = math.rad(lm.angle_deg)
  local dx, dy = math.cos(a), math.sin(a)
  local nx, ny = -dy, dx
  local umin, umax = math.huge, -math.huge
  for _, p in ipairs(pts) do
    local u = p[1] * dx + p[2] * dy
    umin, umax = min(umin, u), max(umax, u)
  end
  local length = umax - umin + 1 / g
  local function haft_v(from, to)
    local sum, n = 0, 0
    for _, p in ipairs(pts) do
      local u = p[1] * dx + p[2] * dy
      if u >= umin + from * length and u < umin + to * length then
        sum, n = sum + p[1] * nx + p[2] * ny, n + 1
      end
    end
    return sum / max(1, n)
  end
  local v_grip = haft_v(0, 0.3)
  local angle_error = math.deg(math.atan((haft_v(0.15, 0.3) - haft_v(0, 0.15)) / (0.15 * length)))
  local s = t.size / length
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local cu, cv = cx * dx + cy * dy, cx * nx + cy * ny
  local bu, bv = lm.butt.x * dx + lm.butt.y * dy, lm.butt.x * nx + lm.butt.y * ny
  local tu = bu - (cu + s * (umin - cu))
  local tv = bv - (cv + s * (v_grip - cv))
  return s, tu * dx + tv * nx, tu * dy + tv * ny, { angle_error = angle_error }
end

-- Best overlap of the measured item with the zone mask over scale and translation
function fits.silhouette(pts, t, g, zm)
  local w, h = t.canvas.width, t.canvas.height
  local cx, cy = w / 2, h / 2
  local zone_area = 0
  for i = 0, w * h - 1 do
    if zm[i] then zone_area = zone_area + 1 end
  end
  -- Each point stands for s^2/density canvas px once placed, so overlap and areas are in canvas px
  local function iou(set, density, s, tx, ty)
    local inter = 0
    for _, p in ipairs(set) do
      local x = floor(cx + s * (p[1] - cx) + tx)
      local y = floor(cy + s * (p[2] - cy) + ty)
      if x >= 0 and y >= 0 and x < w and y < h and zm[y * w + x] then inter = inter + 1 end
    end
    inter = inter / density * s * s
    return inter / (zone_area + #set / density * s * s - inter)
  end
  -- Coarse search on one point per canvas px, fine search on every work point (both within a budget)
  local coarse, half = {}, floor(g / 2)
  for _, p in ipairs(pts) do
    local fx, fy = p[1] * g % g, p[2] * g % g
    if floor(fx) == half and floor(fy) == half then coarse[#coarse + 1] = p end
  end
  local coarse_set, fine_set = stride(coarse, COARSE_POINTS), stride(pts, FINE_POINTS)
  -- Points per canvas px: one in the coarse set, g^2 in the fine set, thinned by the budget stride
  local coarse_density = #coarse_set / #coarse
  local fine_density = #fine_set / #pts * g * g
  local search, max_err = t.fit.search or 12, t.fit.max_scale_error
  local step = search / 6
  local best = { -1 }
  for si = -6, 6 do
    local s = 1 + si * max_err / 6
    for ty = -search, search, step do
      for tx = -search, search, step do
        local score = iou(coarse_set, coarse_density, s, tx, ty)
        if score > best[1] then best = { score, s, tx, ty } end
      end
    end
  end
  local s0, tx0, ty0 = best[2], best[3], best[4]
  best = { -1 }
  for si = -2, 2 do
    local s = s0 + si * max_err / 24
    for ty = -step, step, step / 4 do
      for tx = -step, step, step / 4 do
        local score = iou(fine_set, fine_density, s, tx0 + tx, ty0 + ty)
        if score > best[1] then best = { score, s, tx0 + tx, ty0 + ty } end
      end
    end
  end
  return best[2], best[3], best[4], { scale_error = best[2] - 1 }
end

-- Bottom-centre on the base landmark, sized by painted height (or width); the base x is the middle of the
-- lowest part of the art (a trunk, feet, a pedestal's rim)
function fits.footprint(pts, t)
  local x0, y0, x1, y1 = bounds(pts)
  local measured = t.fit.measure == "width" and (x1 - x0) or (y1 - y0)
  local s = t.size / measured
  local sum, n = 0, 0
  for _, p in ipairs(pts) do
    if p[2] >= y1 - 0.12 * (y1 - y0) then
      sum, n = sum + p[1], n + 1
    end
  end
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local base = t.landmarks.base
  return s, base.x - (cx + s * (sum / n - cx)), base.y - (cy + s * (y1 - cy)), {}
end

-- A bow tip to tip, its stave (the outer run of the middle rows) on the grip, its middle on the grip line
function fits.bow(pts, t)
  local x0, y0, _, y1 = bounds(pts)
  local s = t.size / (y1 - y0)
  local mid, band = (y0 + y1) / 2, 0.03 * (y1 - y0)
  local outer = -math.huge
  for _, p in ipairs(pts) do
    if abs(p[2] - mid) <= band then outer = max(outer, p[1]) end
  end
  local sum, n = 0, 0
  for _, p in ipairs(pts) do
    if abs(p[2] - mid) <= band and p[1] >= outer - 0.04 * (y1 - y0) then
      sum, n = sum + p[1], n + 1
    end
  end
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local grip = t.landmarks.grip
  return s, grip.x - (cx + s * (sum / n - cx)), grip.y - (cy + s * (mid - cy)), { x0 = x0 }
end

-- The generation was painted on the template frame itself: no placement
function fits.frame() return 1, 0, 0, {} end

-- Measure the raw art and return its placement on the template canvas
function M.place(raw, t, zm)
  assert(raw.w == raw.h, "raw generations are square frames of the template canvas")
  local pts, g = measure_points(raw, t)
  local s, tx, ty, info = fits[t.fit.kind](pts, t, g, zm)
  info.scale, info.tx, info.ty = s, tx, ty
  return info
end

-- Map output pixel coordinates to raw pixel coordinates for a placement
local function inverse_for(raw, t, placement, out_to_canvas)
  local f = raw.w / t.frame
  local cx, cy = t.canvas.width / 2, t.canvas.height / 2
  local s, tx, ty = placement.scale, placement.tx, placement.ty
  return function(x, y)
    local px, py = out_to_canvas(x, y)
    return (cx + (px - cx - tx) / s + t.off.x) * f, (cy + (py - cy - ty) / s + t.off.y) * f
  end
end

-- Cleanup and checks -----------------------------------------------------------------------------------

local function lum(r, g, b) return 0.299 * r + 0.587 * g + 0.114 * b end

-- Pixels of the soft boundary band (alpha below full) that are either unsupported, with no opaque pixel
-- within two logical pixels, or brighter than every opaque pixel there: a matte fringe that reads as a halo.
local function halo_pixels(img, reach)
  local halo, soft = 0, 0
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      local r, g, b, a = image.get(img, x, y)
      if a > 0 and a < OPAQUE then
        soft = soft + 1
        local brightest
        for dy = -reach, reach do
          for dx = -reach, reach do
            local nr, ng, nb, na = image.get(img, x + dx, y + dy)
            if na >= OPAQUE then brightest = max(brightest or 0, lum(nr, ng, nb)) end
          end
        end
        if not brightest or lum(r, g, b) > brightest + HALO_LUM then halo = halo + 1 end
      end
    end
  end
  return halo, soft
end

-- The halo check: none at all, except that a chroma-keyed edge may keep strays up to KEY_HALO_SHARE of it
-- (or the template's `halo_share`, where light edges are the art: deckled paper, a hairline's tapered tips; an
-- icon's own `halo_share` where a hairline only goes soft at icon size: a bowstring)
local function halo_check(t, halo, soft, share)
  local allowed = t.matte and math.floor(soft * (share or t.halo_share or KEY_HALO_SHARE)) or 0
  return { name = "no light halo", ok = halo <= allowed, detail = string.format("%d of %d edge px", halo, soft) }
end

-- Alpha floor, speck removal and (unless the family has none) the darkened outer ring, `scale` px deep;
-- returns the halo and soft-edge pixel counts measured before the ring is darkened.
local function clean(img, t)
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      if image.alpha(img, x, y) < MIN_ALPHA then image.set(img, x, y, 0, 0, 0, 0) end
    end
  end
  image.quantize(img)
  remove_islands(mask_of(img, 1), MIN_SPECK * t.scale * t.scale, img)
  local halo, soft = halo_pixels(img, 2 * t.scale)
  if t.outline == false then return halo, soft end
  local ring, seen = {}, {}
  local function clear(x, y) return image.alpha(img, x, y) == 0 or seen[y * img.w + x] end
  for _ = 1, templates.STYLE.outline.width * t.scale do
    local layer = {}
    for y = 0, img.h - 1 do
      for x = 0, img.w - 1 do
        if image.alpha(img, x, y) > 0 and not seen[y * img.w + x] then
          if clear(x - 1, y) or clear(x + 1, y) or clear(x, y - 1) or clear(x, y + 1) then
            layer[#layer + 1] = { x, y }
          end
        end
      end
    end
    for _, p in ipairs(layer) do
      seen[p[2] * img.w + p[1]] = true
      ring[#ring + 1] = p
    end
  end
  local darken = templates.STYLE.outline.darken
  for _, p in ipairs(ring) do
    local r, g, b, a = image.get(img, p[1], p[2])
    image.set(img, p[1], p[2], r * darken, g * darken, b * darken, a)
  end
  image.quantize(img)
  return halo, soft
end

-- Fit art to its polygon: measure how much of the zone the art fills (`interior`, a scale's width in from
-- the edge) and how much lies beyond the fringe, then fade its edge outside the polygon to nothing at
-- `fringe` px. Returns fill and cut shares.
local function fit_to_polygon(img, t)
  local poly, fringe = t.polygon, t.fringe
  local w, h = img.w, img.h
  local total, cut, interior, filled = 0, 0, 0, 0
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local i = y * w + x
      local d = polygon_distance(poly, x + 0.5, y + 0.5)
      local inside = point_in_polygon(poly, x + 0.5, y + 0.5)
      local a = img.px[i * 4 + 4]
      total = total + a
      if inside and d > t.scale then
        interior = interior + 1
        if a >= OPAQUE then filled = filled + 1 end
      elseif not inside then
        local keep = max(0, 1 - d / fringe)
        cut = cut + a * (1 - keep)
        img.px[i * 4 + 4] = a * keep
      end
    end
  end
  image.quantize(img)
  return interior > 0 and filled / interior or 0, total > 0 and cut / total or 0
end

local function border_pixels(img)
  local n = 0
  for x = 0, img.w - 1 do
    if image.alpha(img, x, 0) > 0 then n = n + 1 end
    if image.alpha(img, x, img.h - 1) > 0 then n = n + 1 end
  end
  for y = 1, img.h - 2 do
    if image.alpha(img, 0, y) > 0 then n = n + 1 end
    if image.alpha(img, img.w - 1, y) > 0 then n = n + 1 end
  end
  return n
end

local function light_ratio(img)
  local x0, y0, x1, y1 = image.bbox(img, SOLID)
  local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
  local lit, lit_n, shade, shade_n = 0, 0, 0, 0
  for y = y0, y1 do
    for x = x0, x1 do
      local r, g, b, a = image.get(img, x, y)
      if a >= SOLID then
        if (x - cx) + (y - cy) < 0 then
          lit, lit_n = lit + lum(r, g, b), lit_n + 1
        else
          shade, shade_n = shade + lum(r, g, b), shade_n + 1
        end
      end
    end
  end
  return (lit / max(1, lit_n)) / max(1, shade / max(1, shade_n))
end

-- An icon subject's key light: the mean luminance just inside the edge that faces the upper left over the edge
-- that faces the lower right (3px in, past the darkened outline), so where the subject sits in its tile does not
-- matter. Each edge pixel faces away from its uncovered neighbours.
local function rim_light_ratio(img)
  local depth = 3
  local function solid(x, y) return image.alpha(img, x, y) >= SOLID end
  local lit, lit_n, shade, shade_n = 0, 0, 0, 0
  for y = 1, img.h - 2 do
    for x = 1, img.w - 2 do
      if solid(x, y) then
        local nx, ny = 0, 0
        for dy = -1, 1 do
          for dx = -1, 1 do
            if not solid(x + dx, y + dy) then
              nx, ny = nx + dx, ny + dy
            end
          end
        end
        local len = sqrt(nx * nx + ny * ny)
        local sx, sy = floor(x - nx / max(len, 1) * depth + 0.5), floor(y - ny / max(len, 1) * depth + 0.5)
        if len > 0 and solid(sx, sy) then
          local facing, l = -(nx + ny) / len, lum(image.get(img, sx, sy))
          if facing > 0.5 then
            lit, lit_n = lit + l, lit_n + 1
          elseif facing < -0.5 then
            shade, shade_n = shade + l, shade_n + 1
          end
        end
      end
    end
  end
  return (lit / max(1, lit_n)) / max(1, shade / max(1, shade_n))
end

local function in_ellipse(f, x, y) return ((x - f.x) / f.rx) ^ 2 + ((y - f.y) / f.ry) ^ 2 <= 1 end

-- Landmark checks on the export: each returns ok, detail
local function landmark_checks(img, t, placement, zm, extra)
  local checks = {}
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local kind, lm, k = t.fit.kind, t.landmarks, t.scale
  local function solid_at(name, p)
    local a = image.alpha(img, floor(p.x), floor(p.y))
    add(name, a >= SOLID, string.format("alpha %d", a))
  end
  local function size_check(measured)
    add("size", abs(measured - t.size) <= 2 * k, string.format("%d px (%d)", measured, t.size))
  end
  if kind == "dome" then
    local crown_a = image.alpha(img, lm.crown.x, lm.crown.y + 2 * k)
    add("crown covered", crown_a >= SOLID, string.format("alpha %d at crown+%d", crown_a, 2 * k))
    local err = abs(placement.scale_error)
    add("dome scale", err <= t.fit.max_scale_error, string.format("scale %.3f", placement.scale))
    local covered = 0
    local z = t.zone
    for x = z.cx - z.half_width + 4 * k, z.cx + z.half_width - 4 * k do
      if image.alpha(img, x, z.bottom - 2 * k) >= SOLID then covered = covered + 1 end
    end
    local need = 2 * z.half_width - 8 * k + 1
    add("rim covers brow", covered >= need * 0.9, string.format("%d/%d px", covered, need))
    if lm.jaw then solid_at("reaches jaw", { x = lm.crown.x, y = lm.jaw.y - 2 * k }) end
  elseif kind == "silhouette" then
    local inter, union, filled, zone_px = 0, 0, 0, 0
    for i = 0, img.w * img.h - 1 do
      local alpha = img.px[i * 4 + 4]
      if alpha >= SOLID and zm[i] then inter = inter + 1 end
      if alpha >= SOLID or zm[i] then union = union + 1 end
      if zm[i] then
        zone_px = zone_px + 1
        if alpha >= OPAQUE then filled = filled + 1 end
      end
    end
    local iou = inter / union
    add("zone overlap", iou >= t.fit.min_overlap, string.format("IoU %.3f", iou))
    add("scale", abs(placement.scale_error) <= t.fit.max_scale_error, string.format("%.3f", placement.scale))
    local fill = extra.fill or filled / zone_px
    if t.fit.min_fill then add("fills its zone", fill >= t.fit.min_fill, string.format("%.3f opaque", fill)) end
    if t.polygon then
      add(
        "stays in its hex",
        extra.cut <= t.fit.max_cut,
        string.format("%.3f cut beyond the %d px fringe", extra.cut, t.fringe)
      )
    end
  elseif kind == "rigid" then
    solid_at("grip on shield", lm.grip)
    local _, y0, _, y1 = image.bbox(img, SOLID)
    size_check(y1 - y0 + 1)
  elseif kind == "axis" then
    solid_at("grip on haft", lm.grip)
    if lm.grip_off then
      -- Both hands need one handle: from the main grip to `reach` past the off-hand grip the haft keeps the
      -- main grip's width, so a cross-guard, head or blade (all wider) cannot stand in for the second grip, and
      -- a gap or a handle ending early (narrower) cannot either
      local a = math.rad(lm.angle_deg)
      local dx, dy = math.cos(a), math.sin(a)
      local function width_at(u)
        local cx, cy = lm.grip.x + u * dx, lm.grip.y + u * dy
        local w = 0
        for _, side in ipairs({ 1, -1 }) do
          for v = side == 1 and 0 or 1, img.w do
            if image.alpha(img, floor(cx - side * v * dy), floor(cy + side * v * dx)) < SOLID then break end
            w = w + 1
          end
        end
        return w
      end
      local handle = t.fit.handle
      local grip_w = 0
      for u = -handle.reach, handle.reach do
        grip_w = grip_w + width_at(u)
      end
      grip_w = grip_w / (2 * handle.reach + 1)
      local span = sqrt((lm.grip_off.x - lm.grip.x) ^ 2 + (lm.grip_off.y - lm.grip.y) ^ 2) + handle.reach
      local widest, narrowest = 0, math.huge
      for u = 0, floor(span) do
        local w = width_at(u)
        widest, narrowest = max(widest, w), min(narrowest, w)
      end
      add(
        "one handle under both grips",
        grip_w > 0 and widest <= handle.max_flare * grip_w and narrowest >= grip_w / handle.max_flare,
        string.format("%d-%d px wide over %d px (grip %.1f px)", narrowest, widest, floor(span), grip_w)
      )
    end
    local err = placement.angle_error
    add("axis angle", abs(err) <= t.fit.max_angle_error, string.format("%.1f deg", err))
  elseif kind == "footprint" then
    local x0, y0, x1, y1 = image.bbox(img, SOLID)
    size_check(t.fit.measure == "width" and (x1 - x0 + 1) or (y1 - y0 + 1))
    if lm.emblem then solid_at("emblem plate", lm.emblem) end
    if t.field then
      local inside, on = 0, 0
      for y = 0, img.h - 1 do
        for x = 0, img.w - 1 do
          if in_ellipse(t.field, x + 0.5, y + 0.5) then
            inside = inside + 1
            if image.alpha(img, x, y) >= OPAQUE then on = on + 1 end
          end
        end
      end
      add("emblem field on the cloth", on / inside >= t.fit.min_field, string.format("%.3f", on / inside))
    end
  elseif kind == "bow" then
    solid_at("grip on stave", lm.grip)
    local _, y0, _, y1 = image.bbox(img, SOLID)
    size_check(y1 - y0 + 1)
    local string_x
    for x = 0, img.w - 1 do
      for y = lm.nock.y - 8 * k, lm.nock.y + 8 * k do
        if not string_x and image.alpha(img, x, y) >= 64 then string_x = x end
      end
    end
    local err = abs((string_x or 0) - lm.string.x)
    add("string", err <= t.fit.max_string_error, string.format("x %s (%d)", tostring(string_x), lm.string.x))
  elseif kind == "frame" then
    add("inside its layer", extra.inside >= t.fit.min_inside, string.format("%.3f of the paint", extra.inside))
    local _, painted = image.bbox(img, SOLID)
    add("visible", painted ~= nil, painted and "painted" or "nothing left inside the layer")
  end
  return checks
end

local function all_ok(checks)
  for _, check in ipairs(checks) do
    if not check.ok then return false end
  end
  return true
end

local function result(t, outputs, placement, checks)
  local bytes = 0
  for _, img in pairs(outputs) do
    bytes = bytes + img.w * img.h * 4
  end
  return {
    outputs = outputs,
    placement = placement,
    checks = checks,
    ok = all_ok(checks),
    dimensions = { width = outputs.asset.w, height = outputs.asset.h, scale = t.scale },
    texture_bytes = bytes,
  }
end

-- Icons: the whole frame (square ground), or the keyed subject or ground disc fitted inside the margin -----

-- The skill's category rim on the square tile's edge: an ink line, two pixels of its colour and another ink line
local function draw_rim(img, rim, colour)
  local size = img.w
  for i, c in ipairs({ rim.ink, colour, colour, rim.ink }) do
    local lo, hi = i - 1, size - i
    for p = lo, hi do
      for _, xy in ipairs({ { p, lo }, { p, hi }, { lo, p }, { hi, p } }) do
        image.set(img, xy[1], xy[2], c[1], c[2], c[3], 255)
      end
    end
  end
end

local function normalize_icon(raw, t)
  local size, margin = t.canvas.width, t.margin
  local checks = {}
  local asset
  if t.ground == "square" then
    checks[1] = { name = "square frame", ok = raw.w == raw.h, detail = raw.w .. "x" .. raw.h }
    local k = raw.w / size
    asset = image.resample(raw, size, size, function(x, y) return x * k, y * k end, ceil(k))
    image.quantize(asset)
    local clear = 0
    for i = 0, size * size - 1 do
      if asset.px[i * 4 + 4] < 255 then clear = clear + 1 end
    end
    checks[#checks + 1] = { name = "fills the tile", ok = clear == 0, detail = clear .. " see-through px" }
    if t.rim_colour then draw_rim(asset, t.rim, t.rim_colour) end
  else
    local x0, y0, x1, y1 = image.bbox(raw, SOLID)
    local k = (size - 2 * margin) / max(x1 - x0 + 1, y1 - y0 + 1)
    local ox, oy = (size - (x1 - x0 + 1) * k) / 2, (size - (y1 - y0 + 1) * k) / 2
    asset = image.resample(
      raw,
      size,
      size,
      function(x, y) return x0 + (x - ox) / k, y0 + (y - oy) / k end,
      max(1, ceil(1 / k))
    )
    if t.ground == "none" then
      checks[#checks + 1] = halo_check(t, clean(asset, t))
    else
      -- The ground is a circle of the inner square: antialiased edge, art outside it removed
      local r, c, inside, opaque = size / 2 - margin, size / 2, 0, 0
      for y = 0, size - 1 do
        for x = 0, size - 1 do
          local cover = 0
          for j = 0, 3 do
            for i = 0, 3 do
              local dx, dy = x + (i + 0.5) / 4 - c, y + (j + 0.5) / 4 - c
              if dx * dx + dy * dy <= r * r then cover = cover + 1 end
            end
          end
          local pr, pg, pb, pa = image.get(asset, x, y)
          image.set(asset, x, y, pr, pg, pb, pa * cover / 16)
          if (x + 0.5 - c) ^ 2 + (y + 0.5 - c) ^ 2 <= (r - 2) ^ 2 then
            inside = inside + 1
            if pa >= OPAQUE then opaque = opaque + 1 end
          end
        end
      end
      image.quantize(asset)
      local share = opaque / inside
      checks[#checks + 1] = {
        name = "ground fills its circle",
        ok = share >= t.fit.min_ground,
        detail = string.format("%.3f opaque", share),
      }
    end
  end
  -- A painted square ground has no subject edge to measure; its light is judged on the contact sheet
  if t.ground ~= "square" then
    local ratio = rim_light_ratio(asset)
    checks[#checks + 1] = { name = "lit from upper left", ok = ratio >= 1, detail = string.format("%.2fx", ratio) }
  end
  local outputs = { asset = asset }
  if t.badge then
    local k = size / t.badge
    outputs.badge =
      image.quantize(image.resample(asset, t.badge, t.badge, function(x, y) return x * k, y * k end, ceil(k)))
  end
  return result(t, outputs, { scale = size / raw.w }, checks)
end

-- UI kit -------------------------------------------------------------------------------------------------

-- An axis's segments in source px: { start, len, stretch }; even segments stretch unless the axis has one
local function segments(list)
  local out, at = {}, 0
  for i, len in ipairs(list) do
    out[i] = { start = at, len = len, stretch = #list > 1 and i % 2 == 0 }
    at = at + len
  end
  return out
end

-- Atlas rectangles of a sliced piece, row by row: { x, y, w, h, sx, sy, col, row } with sx, sy the slice's
-- source position, each ringed by `gutter` pixels extruded from its own edge so linear filtering never samples
-- a neighbour; then the atlas width and height
function M.slice_rects(t)
  local g, rects = t.gutter, {}
  local cols, rows = segments(t.cols), segments(t.rows)
  local y = g
  for r, row in ipairs(rows) do
    local x = g
    for c, col in ipairs(cols) do
      rects[#rects + 1] = { x = x, y = y, w = col.len, h = row.len, sx = col.start, sy = row.start, col = c, row = r }
      x = x + col.len + 2 * g
    end
    y = y + row.len + 2 * g
  end
  return rects, t.canvas.width + 2 * g * #cols, t.canvas.height + 2 * g * #rows
end

-- Where an axis's segments land when the piece is drawn `length` long: { at, len, lone } per segment.
-- Painted segments keep their size and stretch segments share the rest (tiled when drawn); a lone segment
-- spans it all (scaled).
function M.slice_spans(list, length)
  if #list == 1 then return { { at = 0, len = length, lone = true } } end
  local fixed, stretches = 0, 0
  for i, len in ipairs(list) do
    if i % 2 == 1 then
      fixed = fixed + len
    else
      stretches = stretches + 1
    end
  end
  local each = max(0, length - fixed) / stretches
  local spans, at = {}, 0
  for i, len in ipairs(list) do
    local next_at = at + (i % 2 == 1 and len or each)
    spans[i] = { at = floor(at + 0.5), len = floor(next_at + 0.5) - floor(at + 0.5) }
    at = next_at
  end
  return spans
end

-- A piece's visible rim in raw px: from each side's middle inwards to where a run of the frame's own
-- interior colour begins (averaged across a short band, so texture does not end it early); the mean of the
-- four sides
local function rim_width(raw, x0, y0, x1, y1)
  local cx, cy = floor((x0 + x1) / 2), floor((y0 + y1) / 2)
  local band, run = max(2, floor((y1 - y0) / 100)), max(4, floor((x1 - x0) / 50))
  local function lum_at(x, y, horizontal)
    local sum = 0
    for d = -band, band do
      local r, g, b = image.get(raw, horizontal and x or x + d, horizontal and y + d or y)
      sum = sum + lum(r, g, b)
    end
    return sum / (2 * band + 1)
  end
  local inner, n = 0, 0
  for dy = -band * 4, band * 4 do
    for dx = -band * 4, band * 4 do
      local r, g, b = image.get(raw, cx + dx, cy + dy)
      inner, n = inner + lum(r, g, b), n + 1
    end
  end
  inner = inner / n
  local function from(px, py, dx, dy, limit)
    local streak = 0
    for d = 0, limit do
      local x, y = px + dx * d, py + dy * d
      if abs(lum_at(x, y, dx ~= 0) - inner) < 12 then
        streak = streak + 1
        if streak >= run then return d - run + 1 end
      else
        streak = 0
      end
    end
    return limit
  end
  local hw, hh = cx - x0, cy - y0
  return (from(x0, cy, 1, 0, hw) + from(x1, cy, -1, 0, hw) + from(cx, y0, 0, 1, hh) + from(cx, y1, 0, -1, hh)) / 4
end

-- Where each source position along an axis reads in the fitted art (`length` long): painted segments come
-- from the art's ends (and a middle one from its proportional place); a stretch segment comes from the middle
-- of the art between them and is made to tile seamlessly: its start crossfaded with what follows its end when
-- the art is long enough, else blended with itself shifted by half (seamless at the wrap, softest in the
-- middle). Each entry is { a } or { a, b, w }: position a blended toward b by w.
local function axis_map(segs, length)
  local total = segs[#segs].start + segs[#segs].len
  local anchors = {}
  for i, s in ipairs(segs) do
    if not s.stretch then
      if i == 1 then
        anchors[i] = 0
      elseif i == #segs then
        anchors[i] = length - s.len
      else
        anchors[i] = floor((s.start + s.len / 2) / total * length - s.len / 2 + 0.5)
      end
    end
  end
  local map = {}
  for i, s in ipairs(segs) do
    if s.stretch then
      local g0 = anchors[i - 1] + segs[i - 1].len
      local gap = anchors[i + 1] - g0
      local overlap = max(0, min(floor(s.len / 2), gap - s.len))
      local c0 = g0 + floor((gap - s.len - overlap) / 2)
      local half = floor(s.len / 2)
      for o = 0, s.len - 1 do
        if overlap >= s.len / 4 then
          map[s.start + o] = o < overlap and { c0 + s.len + o, c0 + o, (o + 0.5) / overlap } or { c0 + o }
        else
          map[s.start + o] = { c0 + (o + half) % s.len, c0 + o, 1 - abs((2 * o + 1) / s.len - 1) }
        end
      end
    else
      for o = 0, s.len - 1 do
        map[s.start + o] = { anchors[i] + o }
      end
    end
  end
  return map
end

-- Mean RGBA difference between a stretch segment's end lines and its middle line, over the painted segments
-- across it (the rims): ornament leaking out of a corner or cap shows here
local function stretch_drift(img, t)
  local worst = 0
  local function fixed(segs)
    local list = {}
    for _, s in ipairs(segs) do
      if not s.stretch then
        for p = s.start, s.start + s.len - 1 do
          list[#list + 1] = p
        end
      end
    end
    return list
  end
  local function diff(ax, ay, bx, by)
    local r1, g1, b1, a1 = image.get(img, ax, ay)
    local r2, g2, b2, a2 = image.get(img, bx, by)
    return (abs(r1 - r2) + abs(g1 - g2) + abs(b1 - b2) + abs(a1 - a2)) / 4
  end
  for _, axis in ipairs({ { t.cols, t.rows, true }, { t.rows, t.cols, false } }) do
    local across = fixed(segments(axis[2]))
    for _, s in ipairs(segments(axis[1])) do
      if s.stretch then
        local m = s.start + floor(s.len / 2)
        for _, p in ipairs({ s.start, s.start + s.len - 1 }) do
          local sum = 0
          for _, q in ipairs(across) do
            sum = sum + (axis[3] and diff(p, q, m, q) or diff(q, p, q, m))
          end
          worst = max(worst, sum / max(1, #across))
        end
      end
    end
  end
  return worst
end

-- Even out a painting's broad lighting (the parchment's bright middle) so its slices meet without a step in
-- tone: each pixel's colour scaled by the piece's mean luminance over its neighbourhood's within `radius`,
-- counting only the art (alpha-weighted), so a feature narrower than the radius (a singed edge) keeps its tone
local function flatten_light(img, radius)
  local w, h = img.w, img.h
  local sl, sa = {}, {} -- summed-area tables of luminance x alpha and alpha, (w + 1) x (h + 1)
  for i = 0, (w + 1) * (h + 1) - 1 do
    sl[i], sa[i] = 0, 0
  end
  local total_l, total_a = 0, 0
  for y = 0, h - 1 do
    local row_l, row_a = 0, 0
    for x = 0, w - 1 do
      local r, g, b, a = image.get(img, x, y)
      local v = lum(r, g, b) * a
      row_l, row_a = row_l + v, row_a + a
      local i = (y + 1) * (w + 1) + x + 1
      sl[i], sa[i] = sl[i - w - 1] + row_l, sa[i - w - 1] + row_a
    end
    total_l, total_a = total_l + row_l, total_a + row_a
  end
  local mean = total_l / max(1, total_a)
  local function box(t, x0, y0, x1, y1)
    return t[y1 * (w + 1) + x1] - t[y0 * (w + 1) + x1] - t[y1 * (w + 1) + x0] + t[y0 * (w + 1) + x0]
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local r, g, b, a = image.get(img, x, y)
      if a > 0 then
        local x0, y0 = max(0, x - radius), max(0, y - radius)
        local x1, y1 = min(w, x + radius + 1), min(h, y + radius + 1)
        local gain = mean / max(1, box(sl, x0, y0, x1, y1) / max(1, box(sa, x0, y0, x1, y1)))
        image.set(img, x, y, min(255, r * gain), min(255, g * gain), min(255, b * gain), a)
      end
    end
  end
end

-- Sliced pieces: the art's box scaled so its rim lands on `border` (frames) or so it covers the source (an
-- axis with one segment fits exactly), then each source position read through `axis_map` and the slices cut
-- into the gutter atlas
local function normalize_sliced(raw, t)
  local W, H = t.canvas.width, t.canvas.height
  local x0, y0, x1, y1 = image.bbox(raw, SOLID)
  local bw, bh = x1 - x0 + 1, y1 - y0 + 1
  local checks = {}
  local function add(name, ok, detail) checks[#checks + 1] = { name = name, ok = ok, detail = detail } end
  local kx = #t.cols == 1 and W / bw or nil
  local ky = #t.rows == 1 and H / bh or nil
  local rim, k
  if t.border then
    rim = rim_width(raw, x0, y0, x1, y1)
    k = t.border / max(1, rim)
    local ok = rim > 0 and rim < min(bw, bh) / 4
    add("rim measured", ok, string.format("%d raw px to %d", floor(rim + 0.5), t.border))
  else
    k = kx or ky or max(W / bw, H / bh)
  end
  kx, ky = max(kx or k, W / bw), max(ky or k, H / bh)
  local aspect = kx / ky - 1
  add("aspect kept", abs(aspect) <= t.fit.max_aspect_error, string.format("%+.3f", aspect))
  local BW, BH = max(W, floor(bw * kx + 0.5)), max(H, floor(bh * ky + 0.5))
  local fitted = image.resample(
    raw,
    BW,
    BH,
    function(x, y) return x0 + x / kx, y0 + y / ky end,
    max(1, ceil(1 / min(kx, ky)))
  )
  if t.flatten then flatten_light(fitted, t.flatten) end
  local mx, my = axis_map(segments(t.cols), BW), axis_map(segments(t.rows), BH)
  local src = image.new(W, H)
  for y = 0, H - 1 do
    local ry = my[y]
    for x = 0, W - 1 do
      local rx = mx[x]
      local acc = { 0, 0, 0, 0 }
      for _, sx in ipairs({ { rx[1], rx[3] and 1 - rx[3] or 1 }, { rx[2], rx[3] or 0 } }) do
        for _, sy in ipairs({ { ry[1], ry[3] and 1 - ry[3] or 1 }, { ry[2], ry[3] or 0 } }) do
          local wgt = sx[2] * sy[2]
          if wgt > 0 then
            local r, g, b, a = image.get(fitted, sx[1], sy[1])
            acc[1], acc[2], acc[3], acc[4] = acc[1] + r * wgt, acc[2] + g * wgt, acc[3] + b * wgt, acc[4] + a * wgt
          end
        end
      end
      if t.grey then
        local v = lum(acc[1], acc[2], acc[3])
        acc[1], acc[2], acc[3] = v, v, v
      end
      image.set(src, x, y, acc[1], acc[2], acc[3], acc[4])
    end
  end
  image.quantize(src)
  local halo = halo_check(t, clean(src, t))
  local opaque = 0
  for i = 0, W * H - 1 do
    if src.px[i * 4 + 4] >= OPAQUE then opaque = opaque + 1 end
  end
  local min_solid = t.min_solid or t.fit.min_solid
  add("solid", opaque / (W * H) >= min_solid, string.format("%.3f opaque (min %.2f)", opaque / (W * H), min_solid))
  local drift = stretch_drift(src, t)
  add("segments stretch cleanly", drift <= t.fit.max_edge_drift, string.format("%.1f mean drift", drift))
  checks[#checks + 1] = halo
  local rects, aw, ah = M.slice_rects(t)
  local atlas, g = image.new(aw, ah), t.gutter
  for _, r in ipairs(rects) do
    for y = -g, r.h + g - 1 do
      for x = -g, r.w + g - 1 do
        local sx = r.sx + max(0, min(r.w - 1, x))
        local sy = r.sy + max(0, min(r.h - 1, y))
        image.set(atlas, r.x + x, r.y + y, image.get(src, sx, sy))
      end
    end
  end
  local placement = { scale = kx, scale_y = ky, rim = rim and floor(rim + 0.5) or nil }
  local out = result(t, { asset = atlas }, placement, checks)
  out.slices = rects
  return out
end

-- Fixed sprites: the art's box at one scale centred in the canvas (or against its top, or in its top-left
-- corner), or filling it
local function normalize_sprite(raw, t)
  local W, H, m = t.canvas.width, t.canvas.height, t.margin
  local x0, y0, x1, y1 = image.bbox(raw, SOLID)
  local bw, bh = x1 - x0 + 1, y1 - y0 + 1
  local kx, ky = (W - 2 * m) / bw, (H - 2 * m) / bh
  local checks = {}
  if t.fill then
    local aspect = kx / ky - 1
    checks[#checks + 1] = {
      name = "aspect kept",
      ok = abs(aspect) <= t.fit.max_aspect_error,
      detail = string.format("%+.3f", aspect),
    }
  else
    kx = min(kx, ky)
    ky = kx
  end
  local ox = t.align == "top_left" and m or (W - bw * kx) / 2
  local oy = t.align and m or (H - bh * ky) / 2
  local asset = image.resample(
    raw,
    W,
    H,
    function(x, y) return x0 + (x - ox) / kx, y0 + (y - oy) / ky end,
    max(1, ceil(1 / min(kx, ky)))
  )
  image.quantize(asset)
  checks[#checks + 1] = halo_check(t, clean(asset, t))
  if t.hollow then
    -- A frame drawn over its content: the painted window, flooded from the centre through the colours within
    -- `hollow` of the centre's, becomes see-through so a portrait drawn first shows inside it
    local cr, cg, cb = image.get(asset, floor(W / 2), floor(H / 2))
    local seen, stack, cleared = {}, { floor(H / 2) * W + floor(W / 2) }, 0
    while #stack > 0 do
      local i = table.remove(stack)
      local x, y = i % W, floor(i / W)
      if not seen[i] then
        seen[i] = true
        local r, g, b, a = image.get(asset, x, y)
        if a >= OPAQUE and max(abs(r - cr), abs(g - cg), abs(b - cb)) <= t.hollow then
          image.set(asset, x, y, 0, 0, 0, 0)
          cleared = cleared + 1
          if x > 0 then stack[#stack + 1] = i - 1 end
          if x < W - 1 then stack[#stack + 1] = i + 1 end
          if y > 0 then stack[#stack + 1] = i - W end
          if y < H - 1 then stack[#stack + 1] = i + W end
        end
      end
    end
    checks[#checks + 1] = {
      name = "window opened",
      ok = cleared / (W * H) >= 0.4,
      detail = string.format("%.3f of the canvas", cleared / (W * H)),
    }
  end
  if t.hotspot then
    local f = W / 32
    local hx, hy, reach, near = t.hotspot[1] * f, t.hotspot[2] * f, 2 * f, false
    for y = floor(hy - reach), ceil(hy + reach) do
      for x = floor(hx - reach), ceil(hx + reach) do
        if (x + 0.5 - hx) ^ 2 + (y + 0.5 - hy) ^ 2 <= reach * reach and image.alpha(asset, x, y) >= SOLID then
          near = true
        end
      end
    end
    checks[#checks + 1] = {
      name = "hotspot on the art",
      ok = near,
      detail = string.format("(%d, %d) at 32", t.hotspot[1], t.hotspot[2]),
    }
  end
  return result(t, { asset = asset }, { scale = kx, scale_y = ky }, checks)
end

-- Illustrations: cover-crop to the exact canvas (box filter down, bilinear up to `max_upscale`) ------------

local function box_blur(img, radius)
  local w, h = img.w, img.h
  local function pass(src, horizontal)
    local out = image.new(w, h)
    local len, other = horizontal and w or h, horizontal and h or w
    for o = 0, other - 1 do
      for ch = 1, 4 do
        local function at(i)
          i = max(0, min(len - 1, i))
          local x, y = horizontal and i or o, horizontal and o or i
          return src.px[(y * w + x) * 4 + ch]
        end
        local sum = 0
        for i = -radius, radius do
          sum = sum + at(i)
        end
        for i = 0, len - 1 do
          local x, y = horizontal and i or o, horizontal and o or i
          out.px[(y * w + x) * 4 + ch] = sum / (2 * radius + 1)
          sum = sum + at(i + radius + 1) - at(i - radius)
        end
      end
    end
    return out
  end
  for _ = 1, 3 do
    img = pass(pass(img, true), false)
  end
  return img
end

-- The blank cloth inside an illustration's emblem field: pixels whose chromaticity is near the median of the
-- field's inner half, so folds and shade stay in and a pole, rim or border across the cloth stays out. The mask
-- is the field's box (2rx x 2ry, its top-left at x - rx, y - ry); returns it and the share of the field it covers.
local CLOTH_NEAR, CLOTH_FAR, CLOTH_DARK = 0.05, 0.1, 48
local function cloth_mask(img, f)
  local left, top, w, h = f.x - f.rx, f.y - f.ry, 2 * f.rx, 2 * f.ry
  local function each(field, fn)
    for y = max(0, top), min(img.h, top + h) - 1 do
      for x = max(0, left), min(img.w, left + w) - 1 do
        if in_ellipse(field, x + 0.5, y + 0.5) then
          local r, g, b = image.get(img, x, y)
          local s = r + g + b
          fn(x, y, r / max(1, s), g / max(1, s), s)
        end
      end
    end
  end
  local rs, gs = {}, {}
  each({ x = f.x, y = f.y, rx = f.rx / 2, ry = f.ry / 2 }, function(_, _, r, g)
    rs[#rs + 1], gs[#gs + 1] = r, g
  end)
  if #rs == 0 then return image.new(w, h), 0 end
  table.sort(rs)
  table.sort(gs)
  local rr, gr = rs[ceil(#rs / 2)], gs[ceil(#gs / 2)]
  local mask, inside, on = image.new(w, h), 0, 0
  each(f, function(x, y, r, g, s)
    local d, a = abs(r - rr) + abs(g - gr), 255
    if s >= CLOTH_DARK and d > CLOTH_NEAR then
      a = d >= CLOTH_FAR and 0 or floor(255 * (CLOTH_FAR - d) / (CLOTH_FAR - CLOTH_NEAR) + 0.5)
    end
    image.set(mask, x - left, y - top, 255, 255, 255, a)
    inside, on = inside + 1, on + (a >= SOLID and 1 or 0)
  end)
  local whole = left >= 0 and top >= 0 and left + w <= img.w and top + h <= img.h
  return mask, whole and on / inside or 0
end

local function normalize_cover(raw, t)
  local w, h = t.canvas.width, t.canvas.height
  local cw, ch = raw.w, raw.h
  if cw / ch > w / h then
    cw = ch * w / h
  else
    ch = cw * h / w
  end
  local x0, y0, k = (raw.w - cw) / 2, (raw.h - ch) / 2, cw / w
  local asset
  if k >= 1 then
    asset = image.resample(raw, w, h, function(x, y) return x0 + x * k, y0 + y * k end, ceil(k))
  else
    asset = image.new(w, h)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local sx, sy = x0 + (x + 0.5) * k - 0.5, y0 + (y + 0.5) * k - 0.5
        local ix, iy = floor(sx), floor(sy)
        local fx, fy = sx - ix, sy - iy
        local px = {}
        for ch_i = 1, 4 do
          local function v(ax, ay)
            ax, ay = max(0, min(raw.w - 1, ax)), max(0, min(raw.h - 1, ay))
            return raw.px[(ay * raw.w + ax) * 4 + ch_i]
          end
          px[ch_i] = (v(ix, iy) * (1 - fx) + v(ix + 1, iy) * fx) * (1 - fy)
            + (v(ix, iy + 1) * (1 - fx) + v(ix + 1, iy + 1) * fx) * fy
        end
        image.set(asset, x, y, px[1], px[2], px[3], px[4])
      end
    end
  end
  image.quantize(asset)
  local clear = 0
  for i = 0, w * h - 1 do
    if asset.px[i * 4 + 4] < 255 then clear = clear + 1 end
  end
  local checks = {
    { name = "exact canvas", ok = asset.w == w and asset.h == h, detail = asset.w .. "x" .. asset.h },
    { name = "opaque", ok = clear == 0, detail = clear .. " see-through px" },
    {
      name = "magnification",
      ok = 1 / k <= t.fit.max_upscale,
      detail = string.format("%.3fx from %dx%d", 1 / k, raw.w, raw.h),
    },
  }
  local outputs = { asset = asset }
  if t.field then
    local share
    outputs.mask, share = cloth_mask(asset, t.field)
    checks[#checks + 1] = {
      name = "emblem field on the cloth",
      ok = share >= t.fit.min_field,
      detail = string.format("%.3f", share),
    }
  end
  if t.backdrop then
    local b = t.backdrop
    local bw, bh = w / b.divisor, h / b.divisor
    local small = image.resample(asset, bw, bh, function(x, y) return x * b.divisor, y * b.divisor end, b.divisor)
    local blurred = box_blur(small, b.radius)
    for i = 1, bw * bh * 4 do
      if i % 4 ~= 0 then blurred.px[i] = blurred.px[i] * b.darken end
    end
    outputs.backdrop = image.quantize(blurred)
  end
  return result(t, outputs, { scale = 1 / k }, checks)
end

-- Normalize ----------------------------------------------------------------------------------------------

-- The export canvas-size asset and the family's derived outputs (`icon`, `mask`, `backdrop`), each an image
-- The piece at rectangle `c` of a generation that holds several, and a check that no solid pixel lies on an
-- edge of the rectangle that is not also the generation's edge (the cut would clip the piece)
local function cut_piece(raw, c)
  local piece = image.new(c.w, c.h)
  for y = 0, c.h - 1 do
    for x = 0, c.w - 1 do
      image.set(piece, x, y, image.get(raw, c.x + x, c.y + y))
    end
  end
  return piece,
    function()
      local n = 0
      local function count(x, y)
        if image.alpha(piece, x, y) >= SOLID then n = n + 1 end
      end
      for y = 0, c.h - 1 do
        if c.x > 0 then count(0, y) end
        if c.x + c.w < raw.w then count(c.w - 1, y) end
      end
      for x = 0, c.w - 1 do
        if c.y > 0 then count(x, 0) end
        if c.y + c.h < raw.h then count(x, c.h - 1) end
      end
      return { name = "piece inside its cut", ok = n == 0, detail = n .. " solid px on the cut's edge" }
    end
end

local fit_raw

function M.normalize(raw, t)
  if not t.cut then return fit_raw(raw, t) end
  local piece, check = cut_piece(raw, t.cut)
  local out = fit_raw(piece, t)
  -- Only a keyed generation has ground to cut through; an opaque tile or disc is cut inside its own paint
  if t.matte then
    table.insert(out.checks, 1, check())
    out.ok = all_ok(out.checks)
  end
  return out
end

function fit_raw(raw, t)
  if t.matte then key_matte(raw, t.matte, t.spill or SPILL) end
  local kind = t.fit.kind
  if kind == "icon" then return normalize_icon(raw, t) end
  if kind == "nine_slice" then return normalize_sliced(raw, t) end
  if kind == "sprite" then return normalize_sprite(raw, t) end
  if kind == "cover" then return normalize_cover(raw, t) end
  local zm = zone_mask(t)
  local placement = M.place(raw, t, zm)
  local w, h = t.canvas.width, t.canvas.height
  local n = max(1, ceil(raw.w / t.frame / placement.scale))
  local asset = image.resample(raw, w, h, inverse_for(raw, t, placement, function(x, y) return x, y end), n)
  -- Halo and outline belong to the art's own edge; the hex fringe and layer mask then fade it softly
  local halo = halo_check(t, clean(asset, t))
  local extra = {}
  if t.polygon then
    extra.fill, extra.cut = fit_to_polygon(asset, t)
  end
  if kind == "frame" then
    -- Keep the paint inside the layer it marks
    local cov, total, inside = sprite_coverage(t), 0, 0
    for i = 0, w * h - 1 do
      local a = asset.px[i * 4 + 4]
      total, inside = total + a, inside + a * cov[i]
      asset.px[i * 4 + 4] = a * cov[i]
    end
    extra.inside = total > 0 and inside / total or 0
    image.quantize(asset)
  end
  local checks = landmark_checks(asset, t, placement, zm, extra)
  if not t.edge_ok then
    local border = border_pixels(asset)
    table.insert(checks, 1, { name = "not clipped", ok = border == 0, detail = border .. " border px" })
  end
  if t.light ~= false then
    local ratio = light_ratio(asset)
    checks[#checks + 1] = { name = "lit from upper left", ok = ratio >= 1, detail = string.format("%.2fx", ratio) }
  end

  local outputs = { asset = asset }
  if t.icon then
    local size, margin = t.icon.size, t.icon.margin
    local x0, y0, x1, y1 = image.bbox(asset, 1)
    local bw, bh = x1 - x0 + 1, y1 - y0 + 1
    local k = (size - 2 * margin) / max(bw, bh)
    local ox, oy = (size - bw * k) / 2, (size - bh * k) / 2
    local inverse = inverse_for(raw, t, placement, function(x, y) return x0 + (x - ox) / k, y0 + (y - oy) / k end)
    local icon = image.resample(raw, size, size, inverse, max(1, ceil(raw.w / t.frame / placement.scale / k)))
    -- Keep the icon inside the same footprint as the asset (no generator haze outside it)
    for y = 0, size - 1 do
      for x = 0, size - 1 do
        local cx, cy = floor(x0 + (x + 0.5 - ox) / k), floor(y0 + (y + 0.5 - oy) / k)
        if image.alpha(asset, cx, cy) == 0 then image.set(icon, x, y, 0, 0, 0, 0) end
      end
    end
    local halo_px, soft_px = clean(icon, t)
    local icon_halo = halo_check(t, halo_px, soft_px, t.icon.halo_share)
    halo.ok, halo.detail = halo.ok and icon_halo.ok, halo.detail .. ", icon " .. icon_halo.detail
    outputs.icon = icon
  end
  if t.field then
    local mask = image.new(w, h)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        if in_ellipse(t.field, x + 0.5, y + 0.5) then image.set(mask, x, y, 255, 255, 255, image.alpha(asset, x, y)) end
      end
    end
    outputs.mask = mask
  end
  table.insert(checks, t.edge_ok and 1 or 2, halo)
  return result(t, outputs, placement, checks)
end

-- Composition -------------------------------------------------------------------------------------------

-- An image box-filtered down by an integer factor (a source-scale asset at its logical size)
function M.downscale(img, factor)
  if factor == 1 then return img end
  return image.resample(
    img,
    floor(img.w / factor),
    floor(img.h / factor),
    function(x, y) return x * factor, y * factor end,
    factor
  )
end

-- Template body with the item composited at the family's logical size; `item_img` may be nil (the bare
-- guide body). Context sprites draw at their own logical size, whatever source scale they were painted at.
function M.compose(t, item_img)
  local lw, lh = t.canvas.width / t.scale, t.canvas.height / t.scale
  local out = image.new(lw, lh)
  local function place(entry)
    local g = templates.FAMILIES[entry.family]
    local glw = g.canvas.width / (g.scale or 1)
    local img = image.read(M.sprite_path(entry.family, entry.sprite))
    img = M.downscale(img, img.w / glw)
    if entry.family == "head" and t.mask and item_img then
      local mask = image.read("assets/units/masks/" .. t.mask .. ".png")
      mask = M.downscale(mask, mask.w / img.w)
      for i = 0, img.w * img.h - 1 do
        img.px[i * 4 + 4] = img.px[i * 4 + 4] * mask.px[i * 4 + 1] / 255
      end
    end
    local ox = g.origin.x - t.origin.x + (lw - img.w) / 2
    local oy = g.origin.y - t.origin.y + (lh - img.h) / 2
    image.over(out, img, floor(ox), floor(oy))
  end
  for _, entry in ipairs(t.context or {}) do
    if not entry.above then place(entry) end
  end
  if item_img then image.over(out, M.downscale(item_img, t.scale), 0, 0) end
  for _, entry in ipairs(t.context or {}) do
    if entry.above then place(entry) end
  end
  return out
end

return M
