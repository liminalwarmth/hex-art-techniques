-- rendering/map/shaders.lua - The painted overworld's two shaders (impure: Love)
--
-- `fringe` draws a hex tile with a soft, brush-broken edge. The tile is drawn `QUAD` times its size about its centre;
-- its art is sampled inside the painted hex and mirrored across that hex's edge beyond it. Its coverage follows the
-- region picking gives the hex (hex.grid `region`, the row's parity read from the pixel's world position), by `layer`:
-- OVERLAY, opaque over that region and fading past it (the parchment); UNDER, solid only in a band just past it (the
-- ground its neighbours fade into); GROUND, over that region only, fading to exactly half on its edge, so a hex always
-- shows its own ground as the greater share and crossfades into its neighbours across the line picking divides at
-- (rendering/map/canvas.lua). The fades' reach is broken by noise on world position, so neighbouring chunks and frames
-- agree.
-- `sight` desaturates and dims what lies beyond the company's sight circle (explored but unseen ground).

local hex_grid = require("hex.grid")
local manifest = require("data.world.tiles.manifest")
local templates = require("data.items.visual_templates")

local M = {}

-- How much larger than its image a fringed tile is drawn (room for the fringe past the canvas margin)
M.QUAD = 1.36

-- The fringe shader's layers (see above)
M.OVERLAY, M.UNDER, M.GROUND = 0, 1, 2

local FRINGE = [[
uniform vec2 size;          // image size, source px
uniform vec2 centre;        // hex centre in the image, source px
uniform vec3 hex;           // the painted hex: half width, half height, tip height, source px
uniform vec4 region;        // the picked hex: half width, top, bottom below an even row and below an odd row, source px
uniform float slope;        // how far the picked hex's top and bottom edges fall per unit out from its middle
uniform float source_scale; // source px per world unit
uniform float row_pitch;    // world units from one row's centre to the next
uniform float quad;         // the scale the tile is drawn at about its centre
uniform float fringe;       // fringe reach, a share of the half extents
uniform float layer;        // 0 OVERLAY, 1 UNDER, 2 GROUND
uniform float inset;        // the share of the art (about its centre) spread over the hex: below 1 leaves a rim out
uniform vec2 noise_origin;  // world position of target pixel (0, 0)
uniform float noise_scale;  // world units per target pixel

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float top = mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x);
  float bottom = mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x);
  return mix(top, bottom, f.y);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  vec2 p = (tc * size - centre) * quad;
  vec2 a = abs(p);
  float m = max(a.x / hex.x, (a.y + a.x * hex.z / hex.x) / hex.y);
  vec2 q = m > 0.99 ? p * (max(1.98 - m, 0.5) / m) : p; // past the painted hex, its art mirrored across the edge
  // The art is opaque over its painted hex and the mirror samples inside it: only a minified mip level's footprint
  // reaches the transparent (black) margin, which must neither thin nor darken the ground
  vec4 t = Texel(tex, (centre + q * inset) / size);
  vec4 c = vec4(t.rgb / max(t.a, 1.0 / 255.0), 1.0);
  vec2 w = sc * noise_scale + noise_origin;
  float odd = mod(floor((w.y - p.y / source_scale) / row_pitch + 0.5), 2.0);
  float bottom = odd > 0.5 ? region.w : region.z;
  float n = max(a.x / region.x, max((a.x * slope - p.y) / region.y, (a.x * slope + p.y) / bottom));
  float broken = 0.65 * vnoise(w / 5.0) + 0.35 * vnoise(w / 1.7);
  float reach = fringe * (0.15 + 0.85 * broken);
  float keep;
  if (layer < 0.5) keep = 1.0 - smoothstep(1.0, 1.0 + reach, n);
  else if (layer < 1.5) keep = (n > 1.0 && n < 1.08 + 0.5 * fringe) ? 1.0 : 0.0;
  else keep = n <= 1.0 ? 1.0 - smoothstep(1.0 - 0.5 * reach, 1.0 + 0.5 * reach, n) : 0.0;
  c.a *= keep;
  return c * color;
}
]]

local SIGHT = [[
uniform vec2 sight_centre; // target px
uniform float sight_radius; // target px
uniform float sight_soft;   // target px
uniform float unseen_grey;  // how far beyond sight goes grey (0..1)
uniform float unseen_dim;   // and how much darker

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc) {
  vec4 c = Texel(tex, tc) * color;
  float t = smoothstep(sight_radius - sight_soft, sight_radius, distance(sc, sight_centre));
  float l = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  vec3 grey = mix(c.rgb, vec3(l), unseen_grey) * (1.0 - unseen_dim);
  c.rgb = mix(c.rgb, grey, t);
  return c;
}
]]

M.FRINGE = FRINGE -- the source, for tools that draw the same fringes another way (worldmap_tiles' hex IDs)

local fringe, sight

-- Send the world tile family's geometry to a shader built on FRINGE
function M.setup_fringe(shader)
  local t = templates.FAMILIES.world_tile
  local s, k = manifest.SCALE, hex_grid.CONSTANTS
  local even, odd = hex_grid.region(0), hex_grid.region(1)
  shader:send("size", { t.canvas.width, t.canvas.height })
  shader:send("centre", { t.landmarks.centre.x, t.landmarks.centre.y })
  -- The painted hex: the tessellating pointy-top hex of the world grid at its centres
  shader:send("hex", { k.TILE_WIDTH * s / 2, k.TILE_HEIGHT * s / 2, (k.TILE_HEIGHT - k.VERTICAL_SPACING) * s })
  shader:send("region", { even.half_w * s, even.top * s, even.bottom * s, odd.bottom * s })
  shader:send("slope", even.slope)
  shader:send("source_scale", s)
  shader:send("row_pitch", k.VERTICAL_SPACING)
  shader:send("quad", M.QUAD)
  shader:send("fringe", manifest.PAINT.fringe)
  shader:send("layer", M.OVERLAY)
  shader:send("inset", 1)
  return shader
end

-- The fringe shader set for the world tile family; the caller sends noise_origin and noise_scale for its target
function M.fringe()
  fringe = fringe or M.setup_fringe(love.graphics.newShader(FRINGE))
  return fringe
end

-- The world box (left, top, right, bottom) a fringed tile with its centre at (x, y) covers
function M.fringed_box(x, y)
  local t = templates.FAMILIES.world_tile
  local s, c = M.QUAD / manifest.SCALE, t.landmarks.centre
  return x - c.x * s, y - c.y * s, x + (t.canvas.width - c.x) * s, y + (t.canvas.height - c.y) * s
end

-- Draw a tile image with its centre at world point (x, y) through the fringe shader (already set)
function M.draw_fringed(image, x, y)
  local s = M.QUAD / manifest.SCALE
  local left, top = M.fringed_box(x, y)
  love.graphics.draw(image, left, top, 0, s, s)
end

-- The sight shader for this frame: the circle (target px) beyond which the world is explored but unseen
function M.sight(cx, cy, radius, soft)
  if not sight then
    sight = love.graphics.newShader(SIGHT)
    sight:send("unseen_grey", 0.7)
    sight:send("unseen_dim", 0.18)
  end
  sight:send("sight_centre", { cx, cy })
  sight:send("sight_radius", radius)
  sight:send("sight_soft", soft)
  return sight
end

return M
