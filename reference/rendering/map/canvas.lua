-- rendering/map/canvas.lua - The painted overworld's static bake
--
-- Bakes the world once at manifest.SCALE px per world unit, at every profile, into chunk canvases of at most
-- BAKE.chunk px a side (the 800x600 world is 3200x2400: four; larger worlds add chunks), each with a BAKE.gutter of
-- its neighbours' pixels round it so filtering and mipmaps never show a seam, mipmapped so every zoom minifies
-- smoothly. Each chunk draws only the pieces that reach it, in order: the ground through the fringe shader in two
-- layers, lowest kind first (each tile solid in a band past its picked hex, the ground beneath its neighbours' edges;
-- then each over its picked hex only, fading to half on its edge, so a hex shows its own ground as the greater share
-- wherever picking names it and crossfades into its neighbours across the line), the faint hex grid on the lines
-- picking divides at, the road strips and hubs, then the doodads back to front. Fog, places and parties are drawn
-- live over it (game_states/map_state.lua).

local hex_grid = require("hex.grid")
local manifest = require("data.world.tiles.manifest")
local ui_settings = require("config.ui_settings")
local composition = require("rendering.map.composition")
local art = require("rendering.map.art")
local shaders = require("rendering.map.shaders")

local Canvas = {}

local BAKE = manifest.BAKE

-- The bake's chunk grid for a world of width x height world units, in chunks at most `chunk` px a side
local function chunk_plan(width, height, chunk)
  local scale = manifest.SCALE
  local pw, ph = math.ceil(width * scale), math.ceil(height * scale)
  local inner = chunk - 2 * BAKE.gutter
  local cols, rows = math.ceil(pw / inner), math.ceil(ph / inner)
  local cw, ch = math.ceil(pw / cols), math.ceil(ph / rows)
  local chunks = {}
  for j = 0, rows - 1 do
    for i = 0, cols - 1 do
      local x, y = i * cw, j * ch
      chunks[#chunks + 1] = { x = x, y = y, w = math.min(cw, pw - x), h = math.min(ch, ph - y) }
    end
  end
  return { scale = scale, width = width, height = height, pixel_width = pw, pixel_height = ph, chunks = chunks }
end

-- The lines a hex owns in the grid: its left side and upper edges along its picked region (hex.grid `region`), so
-- every shared edge is drawn once, where picking divides
local function grid_line(x, y, row)
  local r = hex_grid.region(row)
  local side_top, side_bottom = r.top - r.slope * r.half_w, r.bottom - r.slope * r.half_w
  return x - r.half_w, y + side_bottom, x - r.half_w, y - side_top, x, y - r.top, x + r.half_w, y - side_top
end

-- Whether world box (left, top, right, bottom) overlaps `area` (the same)
local function overlaps(area, left, top, right, bottom)
  return left < area[3] and right > area[1] and top < area[4] and bottom > area[2]
end

local function draw_ground(ground, fringe, layer)
  fringe:send("layer", layer)
  local inset = nil
  for _, job in ipairs(ground) do
    local wanted = manifest.PAINT.inset[job.kind] or 1
    if wanted ~= inset then
      inset = wanted
      fringe:send("inset", inset)
    end
    shaders.draw_fringed(art.image(job.file), job.x, job.y)
  end
end

-- Draw the pieces of `jobs` that reach `area` (world units: left, top, right, bottom)
local function draw_world(jobs, area)
  local graphics = love.graphics
  local ground = {}
  for _, job in ipairs(jobs.ground) do
    if overlaps(area, shaders.fringed_box(job.x, job.y)) then ground[#ground + 1] = job end
  end

  graphics.setColor(1, 1, 1, 1)
  local fringe = shaders.fringe()
  graphics.setShader(fringe)
  draw_ground(ground, fringe, shaders.UNDER)
  draw_ground(ground, fringe, shaders.GROUND)
  fringe:send("layer", shaders.OVERLAY)
  fringe:send("inset", 1)
  graphics.setShader()

  local ink = ui_settings.UI_COLORS.INK_900
  graphics.setColor(ink[1], ink[2], ink[3], manifest.PAINT.grid_alpha)
  graphics.setLineWidth(0.5)
  for _, job in ipairs(ground) do
    graphics.line(grid_line(job.x, job.y, job.row))
  end

  graphics.setColor(1, 1, 1, 1)
  for _, job in ipairs(jobs.roads) do
    for _, file in ipairs(job.files) do
      local b = art.box(file, "world_tile", nil, job.x, job.y)
      if overlaps(area, b.x, b.y, b.x + b.w, b.y + b.h) then art.place(file, "world_tile", nil, job.x, job.y) end
    end
  end
  for _, job in ipairs(jobs.doodads) do
    local b = art.box(job.file, "doodad", job.variant, job.x, job.y)
    if overlaps(area, b.x, b.y, b.x + b.w, b.y + b.h) then art.place(job.file, "doodad", job.variant, job.x, job.y) end
  end
end

-- What a world bakes, without drawing (composition.compose plus the bake plan); `chunk` as Canvas.render
function Canvas.build_jobs(world, chunk)
  local jobs = composition.compose(world)
  jobs.plan = chunk_plan(world.width, world.height, chunk or BAKE.chunk)
  return jobs
end

-- Bake `world` (a generated world: width, height, hexes, roads, towns, pois) in chunks at most `chunk` px a side
-- (BAKE.chunk; worldmap_tiles bakes a differently chunked copy to look for seams). Returns the bake { plan, chunks =
-- { canvas, quad, x, y, w, h } } and its jobs. Restores the caller's canvas and graphics state.
function Canvas.render(world, chunk)
  local graphics = love.graphics
  local jobs = Canvas.build_jobs(world, chunk)
  local plan = jobs.plan
  local s, g = plan.scale, BAKE.gutter
  local bake = { plan = plan, chunks = {} }
  local fringe = shaders.fringe()
  graphics.push("all")
  for _, c in ipairs(plan.chunks) do
    local canvas = graphics.newCanvas(c.w + 2 * g, c.h + 2 * g, { mipmaps = "manual", dpiscale = 1 })
    graphics.setCanvas(canvas)
    graphics.clear(0, 0, 0, 0)
    graphics.origin()
    graphics.translate(g - c.x, g - c.y)
    graphics.scale(s)
    fringe:send("noise_origin", { (c.x - g) / s, (c.y - g) / s })
    fringe:send("noise_scale", 1 / s)
    draw_world(jobs, { (c.x - g) / s, (c.y - g) / s, (c.x + c.w + g) / s, (c.y + c.h + g) / s })
    graphics.setCanvas()
    canvas:generateMipmaps()
    canvas:setFilter("linear", "linear")
    canvas:setMipmapFilter("linear")
    local quad = graphics.newQuad(g, g, c.w, c.h, canvas:getDimensions())
    bake.chunks[#bake.chunks + 1] = { canvas = canvas, quad = quad, x = c.x, y = c.y, w = c.w, h = c.h }
  end
  graphics.pop()
  return bake, jobs
end

-- Draw the bake in world units under the current transform; chunks wholly outside `bounds` (world units:
-- left, right, top, bottom) are skipped. The colour and shader are the caller's.
function Canvas.draw(bake, bounds)
  local graphics = love.graphics
  local s = bake.plan.scale
  graphics.setBlendMode("alpha", "premultiplied")
  for _, c in ipairs(bake.chunks) do
    local x, y, w, h = c.x / s, c.y / s, c.w / s, c.h / s
    if not bounds or (x < bounds.right and x + w > bounds.left and y < bounds.bottom and y + h > bounds.top) then
      graphics.draw(c.canvas, c.quad, x, y, 0, 1 / s, 1 / s)
    end
  end
  graphics.setBlendMode("alpha")
end

-- Texture memory the bake holds, in bytes (RGBA8 with a full mip chain)
function Canvas.bytes(bake)
  local total = 0
  for _, c in ipairs(bake.chunks) do
    local w, h = c.canvas:getDimensions()
    total = total + w * h * 4 * 4 / 3
  end
  return math.floor(total)
end

function Canvas.release(bake)
  for _, c in ipairs(bake and bake.chunks or {}) do
    c.canvas:release()
    c.quad:release()
  end
end

return Canvas
