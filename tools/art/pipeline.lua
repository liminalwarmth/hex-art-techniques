-- tools/art/pipeline.lua - Generated-art pipeline: template guide -> generation -> normalization -> contact
-- sheet -> promotion with provenance. Run from the repository root (usage at the bottom, or no arguments).
local image = require("tools.art.image")
local fit = require("tools.art.fit")

local quote, run, capture = image.quote, image.run, image.capture

local WORK_ROOT = "tmp/art"
local LEDGER = "tools/art/provenance.lua"
local GUIDE_SIZE = 1024
local EMBLEM_SAMPLE = "assets/icons/shields/heater_shield.png" -- stands in for a runtime emblem on sheets

-- Normalized outputs and the item field naming where each is promoted
local OUTPUT_FIELDS = { asset = "out", icon = "icon", mask = "mask", backdrop = "backdrop", badge = "badge" }
local OUTPUT_ORDER = { "asset", "icon", "mask", "backdrop", "badge" }

local function fail(msg)
  io.stderr:write("art: " .. msg .. "\n")
  os.exit(2)
end

local function load_batch(name)
  local ok, batch = pcall(require, "tools.art.batches." .. name)
  if not ok then fail("unknown batch '" .. tostring(name) .. "': " .. tostring(batch)) end
  batch.name = name
  batch.by_id = {}
  for _, item in ipairs(batch.items) do
    batch.by_id[item.id] = item
  end
  return batch
end

local function item_dir(batch, item) return string.format("%s/%s/%s", WORK_ROOT, batch.name, item.id) end

-- Deterministic Lua literal with sorted keys
local function serialize(value, indent)
  indent = indent or ""
  local t = type(value)
  if t == "string" then
    -- Double quotes as \034 so the literal keeps the house quote style (stylua-stable)
    return (string.format("%q", value):gsub('\\"', "\\034"))
  end
  if t == "number" then
    if value == math.floor(value) then return string.format("%d", value) end
    return string.format("%.4f", value)
  end
  if t == "boolean" then return tostring(value) end
  if t ~= "table" then error("cannot serialize " .. t) end
  local inner = indent .. "  "
  local parts = {}
  if #value > 0 then
    for _, v in ipairs(value) do
      parts[#parts + 1] = inner .. serialize(v, inner) .. ","
    end
  else
    local keys = {}
    for k in pairs(value) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local key = k:match("^[%a_][%w_]*$") and k or string.format("[%q]", k)
      parts[#parts + 1] = string.format("%s%s = %s,", inner, key, serialize(value[k], inner))
    end
  end
  if #parts == 0 then return "{}" end
  return "{\n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
end

local function write_file(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function load_table(path)
  local chunk = loadfile(path)
  return chunk and chunk() or nil
end

-- Guide ------------------------------------------------------------------------------------------------

-- Magenta guide strokes for a template's zone, in canvas pixels; `pt` and `len` map them onto the guide
local function zone_draw(t, pt, len)
  local zone, lm = t.zone, t.landmarks or {}
  local cmds = {}
  local function add(fmt, ...) cmds[#cmds + 1] = string.format(fmt, ...) end
  local function poly(points)
    local parts = {}
    for _, p in ipairs(points) do
      parts[#parts + 1] = pt(p[1], p[2])
    end
    add("polygon %s", table.concat(parts, " "))
  end
  if zone.kind == "dome" then
    local h = zone.bottom - zone.top
    add("ellipse %s %s,%s 180,360", pt(zone.cx, zone.bottom), len(zone.half_width), len(h))
    add("line %s %s", pt(zone.cx - zone.half_width, zone.bottom), pt(zone.cx + zone.half_width, zone.bottom))
    if lm.jaw then
      add("line %s %s", pt(zone.cx - zone.half_width / 2, lm.jaw.y), pt(zone.cx + zone.half_width / 2, lm.jaw.y))
    end
  elseif zone.kind == "ellipse" then
    local ry = t.size / 2
    add("ellipse %s %s,%s 0,360", pt(lm.grip.x, lm.grip.y), len(ry * zone.aspect), len(ry))
  elseif zone.kind == "band" then
    local a = math.rad(lm.angle_deg)
    local dx, dy, nx, ny = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
    local hw, bx, by = zone.width / 2, lm.butt.x, lm.butt.y
    local tx, ty = bx + dx * t.size, by + dy * t.size
    poly({
      { bx + nx * hw, by + ny * hw },
      { tx + nx * hw, ty + ny * hw },
      { tx - nx * hw, ty - ny * hw },
      {
        bx - nx * hw,
        by - ny * hw,
      },
    })
    for _, grip in ipairs({ lm.grip, lm.grip_off }) do
      add("circle %s %s", pt(grip.x, grip.y), pt(grip.x + 3 * t.scale, grip.y))
    end
  elseif zone.kind == "polygon" then
    poly(t.guide_polygon)
    if t.outline_hint then poly(t.outline_hint) end
  elseif zone.kind == "footprint" then
    local base, half = lm.base, t.size * zone.width / 2
    if t.fit.measure == "width" then half = t.size / 2 end
    poly({
      { base.x - half, base.y - t.size },
      { base.x + half, base.y - t.size },
      { base.x + half, base.y },
      { base.x - half, base.y },
    })
    add("line %s %s", pt(base.x, base.y - 6 * t.scale), pt(base.x, base.y + 6 * t.scale))
    if t.field then
      local f = t.field
      add("ellipse %s %s,%s 0,360", pt(f.x, f.y), len(f.rx), len(f.ry))
    end
  elseif zone.kind == "pedestal" then
    local base = lm.base
    add("ellipse %s %s,%s 0,360", pt(base.x, zone.cy), len(zone.rx), len(zone.ry))
    add("ellipse %s %s,%s 0,180", pt(base.x, zone.cy + zone.depth), len(zone.rx), len(zone.ry))
    add("line %s %s", pt(base.x - zone.rx, zone.cy), pt(base.x - zone.rx, zone.cy + zone.depth))
    add("line %s %s", pt(base.x + zone.rx, zone.cy), pt(base.x + zone.rx, zone.cy + zone.depth))
    add("circle %s %s", pt(lm.emblem.x, lm.emblem.y), pt(lm.emblem.x + 16, lm.emblem.y))
  elseif zone.kind == "bow" then
    local rx = lm.grip.x - lm.string.x
    add("ellipse %s %s,%s 270,90", pt(lm.string.x, lm.grip.y), len(rx), len(t.size / 2))
    add("line %s %s", pt(lm.string.x, lm.grip.y - t.size / 2), pt(lm.string.x, lm.grip.y + t.size / 2))
  elseif zone.kind == "nine" then
    local w, h = t.canvas.width, t.canvas.height
    local m = math.min(w, h) * 0.06
    poly({ { m, m }, { w - m, m }, { w - m, h - m }, { m, h - m } })
  end
  return cmds
end

local function write_guide(t, path)
  local k = GUIDE_SIZE / t.frame
  local function pt(x, y) return string.format("%.1f,%.1f", (x + t.off.x) * k, (y + t.off.y) * k) end
  local function len(v) return string.format("%.1f", v * k) end
  local background = t.matte == "green" and "'#00FF00'" or "none"
  local cmd = string.format("magick -size %dx%d xc:%s", GUIDE_SIZE, GUIDE_SIZE, background)
  local temps = {}
  if t.context then
    local body = path .. ".body.png"
    image.write(fit.compose(t, nil), body)
    temps[#temps + 1] = body
    local lk = k * t.scale
    cmd = cmd
      .. string.format(
        " \\( %s -filter Lanczos -resize %.3f%% \\) -geometry +%d+%d -composite",
        quote(body),
        lk * 100,
        math.floor(t.off.x * k),
        math.floor(t.off.y * k)
      )
  end
  if t.zone.kind == "silhouette" then
    local zm = fit.zone_mask(t)
    local w, h = t.canvas.width, t.canvas.height
    local edge = image.new(w, h)
    for y = 0, h - 1 do
      for x = 0, w - 1 do
        local function out(nx, ny) return nx < 0 or ny < 0 or nx >= w or ny >= h or not zm[ny * w + nx] end
        local d = t.scale -- a logical pixel wide, so the outline reads at every source scale
        if zm[y * w + x] and (out(x - d, y) or out(x + d, y) or out(x, y - d) or out(x, y + d)) then
          image.set(edge, x, y, 255, 0, 255, 255)
        end
      end
    end
    local edge_path = path .. ".edge.png"
    image.write(edge, edge_path)
    temps[#temps + 1] = edge_path
    cmd = cmd
      .. string.format(
        " \\( %s -filter point -resize %.3f%% \\) -geometry +%d+%d -composite",
        quote(edge_path),
        k * 100,
        math.floor(t.off.x * k),
        math.floor(t.off.y * k)
      )
  end
  local draws = zone_draw(t, pt, len)
  if #draws > 0 then
    cmd = cmd .. " -fill none -stroke '#ff00ff' -strokewidth 6"
    for _, d in ipairs(draws) do
      cmd = cmd .. " -draw " .. quote(d)
    end
  end
  run(cmd .. " PNG32:" .. quote(path))
  for _, p in ipairs(temps) do
    os.remove(p)
  end
end

-- Prompt -----------------------------------------------------------------------------------------------

local STYLE_TEXT = {
  unit = "Style: hand-painted fantasy mercenary game art, matching the style references in this directory: "
    .. "painted tabletop-miniature figures in three-quarter view, soft painterly shading with the key light from "
    .. "the upper left, a crisp dark outline, muted desaturated palette, worn and used medieval gear. Paint broad, "
    .. "readable shapes so the piece still reads when shrunk to a quarter of its size.",
  terrain = "Style: hand-painted battlefield terrain for a fantasy tactical game, matching the style references in "
    .. "this directory (the game's approved battle mockup): seen from the same high three-quarter view, muted "
    .. "natural colours (olive grass, umber soil, greige stone), soft painterly detail with LOW micro-contrast so "
    .. "painted figures standing on it stay the most readable thing on screen, key light from the upper left.",
  world = "Style: hand-painted fantasy overworld map art matching the style references in this directory (the "
    .. "game's approved overworld mockup): a painted miniature landscape seen from above at a slight angle, muted "
    .. "natural palette, key light from the upper left. Broad, readable shapes: it must still read when the whole "
    .. "hexagon is only 30 pixels wide.",
  ui = 'GAME AND STYLE: "Fantasy Warband", a premium indie tactical RPG about a medieval low-fantasy mercenary '
    .. 'company. Interface identity "The War Table": every UI piece is a physical object on a captain\'s war '
    .. "table: dark oiled oak with blackened iron corner brackets and brass rivets, umber leather, recessed inset "
    .. "wells, aged parchment, restrained brass trim, painted like the kit reference in this directory. One soft "
    .. "key light from the UPPER LEFT. Muted, warm palette: umber leather #1B1511 / #261D17, oak #4A3726, iron "
    .. "#555A5E, brass #A8823F / highlight #D9B565, parchment #EADBB8. No text, letters or numbers; shown "
    .. "straight-on, axis-aligned and symmetrical, with crisp clean edges.",
  icon = "Style: a hand-painted fantasy game icon in the house style of the icon sheet in this directory: one bold, "
    .. "simple subject, soft painterly shading with the key light from the upper left, rich but muted colours, no "
    .. "text, numbers, outer glow, fire or lightning backdrop. Broad, readable shapes: it must still read at 24 "
    .. "pixels.",
  illustration = "Style: rich hand-painted digital fantasy game illustration in exactly the style of the reference "
    .. "images in this directory: detailed but readable, crisp shapes with soft painterly rendering, "
    .. "tabletop-miniature charm, grounded low-fantasy. One clear key light from the UPPER LEFT. Muted, warm earthy "
    .. "palette with saturated colour only in small accents. Strong readable silhouettes and a clear focal point "
    .. "that still reads when the image is shown small.",
}

-- Per family: what the guide shows and what to paint (%s is the item's subject)
local TEMPLATE_TEXT = {
  helm = {
    noun = "helmet",
    remove = "head, face, hair",
    text = "template.png is a 1024x1024 canvas holding a character's bare head, facing right. The magenta dome "
      .. "outline marks the helmet's skull: its top is the crown and its flat bottom line is the rim at the "
      .. "brow. Paint ONE %s worn on this head. The helmet's skull must exactly fill the magenta dome; "
      .. "whatever hangs below the rim (brim, visor, cheek plates, mail) continues down from the bottom line "
      .. "as the design needs, and the whole helmet stays inside the canvas with a clear margin. Eye slits, "
      .. "breathing holes and the inside of the helmet are painted solid dark, never see-through.",
  },
  chest = {
    noun = "armour torso",
    remove = "head, hair, face",
    text = "template.png is a 1024x1024 canvas holding a mercenary's head, facing right; the magenta outline "
      .. "is the silhouette of his torso and shoulders below the head (a chest-and-shoulders bust, arms cut "
      .. "off at the upper arm). Paint ONE %s on this torso. The armour must exactly fill the magenta torso "
      .. "silhouette, with the collar at the top of the silhouette under the chin.",
  },
  shield = {
    noun = "shield",
    remove = "body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right, framed around his off "
      .. "hand. The magenta ellipse marks the shield he holds in front of his body. Paint ONE %s, its face "
      .. "turned to the viewer at a slight three-quarter angle, its outline filling the magenta ellipse "
      .. "(same centre, same height); its straps and hand are hidden behind it.",
  },
  weapon = {
    noun = "weapon",
    remove = "body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right. The magenta band "
      .. "marks a weapon held in his hand at the small magenta circle: the weapon lies inside the band, its "
      .. "haft end at the lower-left end of the band and its head at the upper-right end. Paint ONE %s lying "
      .. "along the band at exactly this angle and length, with no hand.",
  },
  weapon_2h = {
    noun = "weapon",
    remove = "body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right. The long magenta band "
      .. "marks a two-handed weapon held in both hands at the two small magenta circles: its butt at the "
      .. "lower-left end of the band and its tip at the upper-right end. Paint ONE %s lying along the band at "
      .. "exactly this angle and length, with no hands. Both circles sit on one long handle: the plain, narrow "
      .. "grip or haft runs from the butt end through BOTH circles and a little past the upper one, and any "
      .. "cross-guard, blade or head begins only beyond the upper circle.",
  },
  weapon_ranged = {
    noun = "bow",
    remove = "body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right. The magenta arc is the "
      .. "stave of a bow held upright in front of him (its middle at his hand, its tips at the ends of the arc) "
      .. "and the straight vertical magenta line is the bowstring, on the side toward his body. Paint ONE %s "
      .. "with its stave exactly on the arc and its taut string on the line; no arrow, no hand.",
  },
  head = {
    noun = "head",
    remove = "torso",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bare torso, facing right. The magenta dome "
      .. "marks the skull of his head: its top is the crown and its flat bottom line is the brow; the short "
      .. "magenta line lower down is the jaw. Paint ONE head of %s (head and neck only, three-quarter view facing "
      .. "right, hair kept close to the skull) whose skull fills the magenta dome exactly, brow on the dome's "
      .. "bottom line, chin on the jaw line, the neck ending where it meets the torso.",
  },
  quiver = {
    noun = "quiver",
    remove = "body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right. The magenta band marks "
      .. "a quiver slung diagonally across his back: its bottom at the lower-right end of the band and the "
      .. "fletched arrows at the upper-left end. Paint ONE %s lying along the band at exactly this angle and "
      .. "length; no strap, no body.",
  },
  pedestal = {
    noun = "display base",
    remove = "figure, body, head",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust. The magenta outline below him is a "
      .. "round display base for a painted miniature: a short drum seen from a high three-quarter view, its top "
      .. "face an ellipse. The small magenta circle on its front rim marks a small plain blank plaque where an "
      .. "emblem is added later. Paint ONE %s exactly filling the outline, with that plaque left plain and "
      .. "blank; no figure, no emblem, no text.",
  },
  beast = {
    noun = "beast",
    remove = "pedestal",
    text = "template.png is a 1024x1024 canvas holding a round display base for a painted miniature. The "
      .. "magenta box marks the beast standing on it: its feet on the bottom line of the box (the top of the "
      .. "base, around the small mark) and its back or head reaching the top of the box. Paint ONE %s in "
      .. "three-quarter view facing right, standing, filling the box's height.",
  },
  condition = {
    noun = "marks",
    remove = "body, head and everything else",
    text = "template.png is a 1024x1024 canvas holding a mercenary's bust facing right; the magenta outline "
      .. "is the layer the marks are painted on. Paint ONLY %s, entirely inside the magenta outline and following "
      .. "its form, as an overlay that sits on top of the figure.",
  },
  hex_cap = {
    noun = "ground",
    text = "template.png is a 1024x1024 canvas holding a magenta hexagon: the flat top face of one hexagonal "
      .. "battlefield tile seen from a high three-quarter view. Paint ONE patch of %s exactly filling the "
      .. "hexagon to its edges (a little soft, ragged grass or soil may spill over the outline), the top face "
      .. "only: no side, no cliff, no props, no figures.",
  },
  cliff_band = {
    noun = "cliff face",
    text = "template.png is a 1024x1024 canvas holding a magenta outline: the vertical face that drops below "
      .. "the three front edges of a raised hexagonal battlefield tile (seen from a high three-quarter view; "
      .. "the tile's top face, not shown, sits on its upper edge). Paint ONE %s exactly filling the outline, "
      .. "lit from the upper left, its top edge a clean lip and its bottom resting on the ground.",
  },
  prop = {
    noun = "prop",
    text = "template.png is a 1024x1024 canvas holding a magenta box: one battlefield prop standing on the "
      .. "ground, its base centred on the short magenta mark at the bottom and its top at the top of the box. "
      .. "Paint ONE %s filling the box's height, seen from the same high three-quarter view; no ground patch, "
      .. "no cast shadow.",
  },
  world_tile = {
    noun = "map tile",
    text = "template.png is a 1024x1024 canvas holding a magenta pointy-top hexagon: one overworld map tile "
      .. "seen from above. Paint %s exactly filling the hexagon to its edges, even and seamless so identical "
      .. "neighbours tile, nothing crossing the edges, no border.",
  },
  world_half_edge = {
    noun = "strip",
    text = "template.png is a 1024x1024 canvas holding a magenta strip that runs from the centre of a "
      .. "pointy-top overworld map hexagon (the larger magenta outline) out through the middle of one of its edges. "
      .. "Paint ONLY %s inside the strip, from the centre out to the edge, where it continues seamlessly into "
      .. "the next tile; do not paint the tile or any ground around it.",
  },
  world_hub = {
    noun = "patch",
    text = "template.png is a 1024x1024 canvas holding a small magenta circle at the centre of a pointy-top "
      .. "overworld map hexagon (the larger magenta outline): the spot where roads from several edges meet. Paint "
      .. "ONLY %s filling the circle, its rim soft and ragged so it blends into the roads around it; do not paint "
      .. "the tile, any road leading away or any ground around it.",
  },
  doodad = {
    noun = "map object",
    text = "template.png is a 1024x1024 canvas holding a magenta box: one object on a painted overworld map, "
      .. "its base centred on the short magenta mark and its top at the top of the box. Paint ONE %s filling "
      .. "the box's height, seen from above at a slight angle; no ground patch, no cast shadow.",
  },
  heraldry = {
    noun = "heraldry",
    text = "template.png is a 1024x1024 canvas holding a magenta box: its base centred on the short magenta "
      .. "mark and its top at the top of the box. Paint ONE %s filling the box's height. The magenta ellipse "
      .. "marks where an emblem is added later: keep that part of the cloth or wax plain, flat and BLANK (no "
      .. "emblem, pattern, letters or seams across it), lit evenly.",
  },
  ui_frame = {
    noun = "piece",
    text = "template.png marks with a magenta rectangle where the piece sits. Paint ONE %s filling the "
      .. "rectangle, its rim perfectly uniform along each side so the sides stretch and tile, identical "
      .. "mirror-symmetric corners or ends, and a plain, even interior.",
  },
}
TEMPLATE_TEXT.site, TEMPLATE_TEXT.party = TEMPLATE_TEXT.doodad, TEMPLATE_TEXT.doodad

local GREEN = "on a perfectly flat, uniform pure chroma green #00FF00 background everywhere outside it (no "
  .. "gradient, texture, vignette, cast shadow or glow onto the green); the painting itself contains no pure green"

local GROUND_TEXT = {
  square = "on a dark umber vignette square that fills the whole tile to its edges",
  disc = "on a round dark forged-iron disc with a thin bevelled rim, the disc centred and filling the frame, " .. GREEN,
  roundel = "on a round aged-parchment roundel with a thin dark rim, the roundel centred and filling the frame, "
    .. GREEN,
  none = "alone, centred and filling the frame, " .. GREEN,
}

local SAVE_RAW = "Save the generated image as raw.png in the current directory by copying it unchanged from "
  .. "wherever the tool writes it (usually ~/.codex/generated_images/). Do not edit, crop, resize, recentre or "
  .. "regenerate it, even if it looks imperfect: one generation only. Then print the final file path and "
  .. "pixel dimensions."

local HEADER = "Use your image generation tool (edit mode, with the images in this directory as inputs). The "
  .. "images are this game's own original art; never copy any other game."

local function build_prompt(t, item)
  local lines = { HEADER, "", STYLE_TEXT[t.style or "unit"], "" }
  local kind = t.fit.kind
  if kind == "square" or kind == "icon" or kind == "sprite" then
    lines[#lines + 1] = "Subject: " .. item.subject .. ", " .. GROUND_TEXT[t.ground or "square"] .. "."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Output: one square 1024x1024 image; no border, frame, text, letters or numbers."
  elseif kind == "cover" then
    lines[#lines + 1] = "Subject: " .. item.subject .. "."
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "Output: one full-bleed opaque landscape image of aspect %dx%d filling the canvas edge to edge: no frame, "
        .. "border, UI, text, letters, logo or signature.",
      t.canvas.width,
      t.canvas.height
    )
  else
    local key = t.name
    if key == "world_tile" and t.zone.shape ~= "world_hex" then key = t.zone.shape end
    local tt = TEMPLATE_TEXT[key]
    lines[#lines + 1] = "Template: " .. string.format(tt.text, item.subject)
    lines[#lines + 1] = ""
    local background = t.matte == "green" and GREEN or "on a fully transparent background"
    lines[#lines + 1] = string.format(
      "Output: an image of the SAME 1024x1024 framing that contains ONLY the %s, %s: remove %severy magenta "
        .. "guide. No text, no ground shadow, nothing else.",
      tt.noun,
      background,
      tt.remove and ("the " .. tt.remove .. " and ") or ""
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = SAVE_RAW
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end

-- Commands ---------------------------------------------------------------------------------------------

local function attempts(batch, item)
  local list = {}
  for n = 1, 99 do
    local dir = string.format("%s/gen_%d", item_dir(batch, item), n)
    if not image.exists(dir .. "/prompt.txt") then break end
    list[#list + 1] = { n = n, dir = dir, has_raw = image.exists(dir .. "/raw.png") }
  end
  return list
end

-- A style reference is a path, or { path, crop = "WxH+X+Y" } for a region of an in-repo mockup
local function write_style_ref(ref, dest)
  local path = type(ref) == "table" and ref.path or ref
  local crop = type(ref) == "table" and ref.crop and (" -crop " .. ref.crop .. " +repage") or ""
  run(string.format("magick %s%s -filter Lanczos -resize 1024x1024 PNG32:%s", quote(path), crop, quote(dest)))
  return { source = path, crop = type(ref) == "table" and ref.crop or nil, sha256 = image.sha256(path) }
end

local function prepare(batch, item)
  local t = fit.template(item)
  local n = #attempts(batch, item) + 1
  local dir = string.format("%s/gen_%d", item_dir(batch, item), n)
  run("mkdir -p " .. quote(dir))
  local kind = t.fit.kind
  if kind ~= "square" and kind ~= "icon" and kind ~= "sprite" and kind ~= "cover" then
    write_guide(t, dir .. "/template.png")
  end
  local refs = {}
  for i, ref in ipairs(t.style_refs) do
    refs[#refs + 1] = write_style_ref(ref, string.format("%s/style_ref_%d.png", dir, i))
  end
  local prompt = build_prompt(t, item)
  write_file(dir .. "/prompt.txt", prompt)
  return dir, prompt, refs, n
end

local function cmd_guide(batch, ids)
  for _, id in ipairs(ids) do
    local item = batch.by_id[id] or fail("no item " .. id)
    print((prepare(batch, item)))
  end
end

local function codex_version() return (capture("codex --version"):gsub("%s+$", "")) .. " built-in image generation" end

local function cmd_generate(batch, ids)
  for _, id in ipairs(ids) do
    local item = batch.by_id[id] or fail("no item " .. id)
    local dir, prompt, refs, n = prepare(batch, item)
    local log = dir .. "/codex.log"
    local started = os.date("!%Y-%m-%dT%H:%M:%SZ")
    os.execute(
      string.format(
        "codex exec --skip-git-repo-check -s workspace-write -C %s - < %s > %s 2>&1",
        quote(dir),
        quote(dir .. "/prompt.txt"),
        quote(log)
      )
    )
    local session = (read_file(log) or ""):match("session id: ([%w%-]+)")
    if not session then fail("no codex session in " .. log) end
    -- The first image the session generated is the raw, whatever the agent did with it afterwards
    local gen_dir = os.getenv("HOME") .. "/.codex/generated_images/" .. session
    local first = capture("ls -tr " .. quote(gen_dir) .. " 2>/dev/null | grep '\\.png$' | head -1"):gsub("%s+$", "")
    if first == "" then fail("codex session " .. session .. " generated no image (see " .. log .. ")") end
    run(string.format("cp %s %s", quote(gen_dir .. "/" .. first), quote(dir .. "/raw.png")))
    local record = {
      batch = batch.name,
      item = item.id,
      family = item.family,
      variant = item.variant,
      attempt = n,
      subject = item.subject,
      prompt = prompt,
      references = refs,
      template_sha256 = image.sha256(dir .. "/template.png"),
      generator = codex_version(),
      session = session,
      date = started,
      operator = batch.operator,
      raw_sha256 = image.sha256(dir .. "/raw.png"),
    }
    write_file(dir .. "/provenance.lua", "return " .. serialize(record) .. "\n")
    print(string.format("%s gen_%d raw %s", item.id, n, record.raw_sha256))
  end
end

-- Adopt a generation made outside the pipeline (`item.adopt = { dir, file }`, a prep work directory holding
-- the prompt, references, codex.log and the copied image) as the item's next attempt. The raw is the
-- session's first generated image, which must still exist and equal the copy: the record never trusts a copy.
local function cmd_adopt(batch, ids)
  for _, id in ipairs(ids) do
    local item = batch.by_id[id] or fail("no item " .. id)
    local src = item.adopt or fail(id .. " has no adopt source")
    local log = read_file(src.dir .. "/codex.log") or fail("no codex.log in " .. src.dir)
    local session = log:match("session id: ([%w%-]+)") or fail("no codex session in " .. src.dir)
    local copy = src.dir .. "/" .. src.file
    local gen_dir = os.getenv("HOME") .. "/.codex/generated_images/" .. session
    local first = capture("ls -tr " .. quote(gen_dir) .. " 2>/dev/null | grep '\\.png$' | head -1"):gsub("%s+$", "")
    if first == "" then fail("codex no longer has session " .. session .. "'s generated image; regenerate " .. id) end
    local raw_source = gen_dir .. "/" .. first
    if image.sha256(raw_source) ~= image.sha256(copy) then
      fail(copy .. " is not the session's first generated image " .. raw_source)
    end
    local n = #attempts(batch, item) + 1
    local dir = string.format("%s/gen_%d", item_dir(batch, item), n)
    run("mkdir -p " .. quote(dir))
    run(string.format("cp %s %s", quote(raw_source), quote(dir .. "/raw.png")))
    local prompt = read_file(src.dir .. "/prompt.txt") or fail("no prompt.txt in " .. src.dir)
    write_file(dir .. "/prompt.txt", prompt)
    local refs = {}
    for name in capture("ls " .. quote(src.dir) .. " | grep '\\.png$'"):gmatch("[^\n]+") do
      if name ~= src.file then
        refs[#refs + 1] = { source = src.dir .. "/" .. name, sha256 = image.sha256(src.dir .. "/" .. name) }
      end
    end
    local record = {
      batch = batch.name,
      item = item.id,
      family = item.family,
      variant = item.variant,
      attempt = n,
      subject = item.subject,
      prompt = prompt,
      references = refs,
      adopted_from = src.dir,
      generator = (log:match("(OpenAI Codex v[%w%.%-]+)") or "codex") .. " built-in image generation",
      session = session,
      date = capture("date -u -r " .. quote(copy) .. " +%Y-%m-%dT%H:%M:%SZ"):gsub("%s+$", ""),
      operator = batch.operator,
      raw_sha256 = image.sha256(dir .. "/raw.png"),
    }
    write_file(dir .. "/provenance.lua", "return " .. serialize(record) .. "\n")
    print(string.format("%s gen_%d adopted from %s raw %s", id, n, src.dir, record.raw_sha256))
  end
end

local function chosen_attempt(batch, item)
  local list = attempts(batch, item)
  local pick
  for _, a in ipairs(list) do
    if a.has_raw and (item.attempt == nil or item.attempt == a.n) then pick = a end
  end
  return pick
end

local function sha256_text(text)
  local path = os.tmpname()
  write_file(path, text)
  local sha = image.sha256(path)
  os.remove(path)
  return sha
end

-- Everything a normalized output depends on besides its raw: the family templates, the fitting code (and
-- the hex geometry it reads), the images the fit reads (silhouettes) and the item's batch entry
local function normalize_inputs_sha256(item)
  local parts = {}
  for _, module in ipairs({
    "data.items.visual_templates",
    "tools.art.fit",
    "tools.art.image",
    "hex.geometry",
    "hex.grid",
  }) do
    parts[#parts + 1] = image.sha256(assert(package.searchpath(module, package.path)))
  end
  for _, path in ipairs(fit.image_inputs(fit.template(item))) do
    parts[#parts + 1] = path .. " " .. assert(image.sha256(path), "missing fit input " .. path)
  end
  parts[#parts + 1] = serialize(item)
  return sha256_text(table.concat(parts, "\n"))
end

-- Why an item's normalized outputs do not belong to its chosen generation and current settings, or nil
local function stale_reason(item, qa, attempt)
  if qa.attempt ~= attempt.n then
    return string.format("was normalized from gen_%s but gen_%d is chosen", tostring(qa.attempt), attempt.n)
  elseif qa.raw_sha256 ~= image.sha256(attempt.dir .. "/raw.png") then
    return string.format("gen_%d raw.png is not the raw it was normalized from", attempt.n)
  elseif qa.inputs_sha256 ~= normalize_inputs_sha256(item) then
    return "was normalized with other templates, fitting code, fit images or batch settings"
  end
  return nil
end

local function cmd_normalize(batch, ids)
  local ok_all = true
  for _, id in ipairs(ids) do
    local item = batch.by_id[id] or fail("no item " .. id)
    local t = fit.template(item)
    local attempt = chosen_attempt(batch, item)
    if not attempt then fail(id .. " has no generated raw.png (run generate)") end
    local raw = image.read(attempt.dir .. "/raw.png")
    local result = fit.normalize(raw, t)
    local out = item_dir(batch, item) .. "/out"
    run("mkdir -p " .. quote(out))
    local outputs = {}
    for _, name in ipairs(OUTPUT_ORDER) do
      local img = result.outputs[name]
      if img then
        image.write(img, out .. "/" .. name .. ".png")
        outputs[name] = image.sha256(out .. "/" .. name .. ".png")
      end
    end
    local qa = {
      attempt = attempt.n,
      raw_sha256 = image.sha256(attempt.dir .. "/raw.png"),
      inputs_sha256 = normalize_inputs_sha256(item),
      ok = result.ok,
      checks = result.checks,
      placement = result.placement,
      dimensions = result.dimensions,
      texture_bytes = result.texture_bytes,
      slices = result.slices,
      outputs = outputs,
    }
    write_file(out .. "/qa.lua", "return " .. serialize(qa) .. "\n")
    local failed, hashes = {}, {}
    for _, check in ipairs(result.checks) do
      if not check.ok then failed[#failed + 1] = check.name .. " (" .. check.detail .. ")" end
    end
    for _, name in ipairs(OUTPUT_ORDER) do
      if outputs[name] then hashes[#hashes + 1] = name .. " " .. outputs[name]:sub(1, 16) end
    end
    print(
      string.format(
        "%-16s gen_%d %s scale %.3f  %s",
        id,
        attempt.n,
        result.ok and "PASS" or ("FAIL: " .. table.concat(failed, ", ")),
        result.placement.scale,
        table.concat(hashes, "  ")
      )
    )
    ok_all = ok_all and result.ok
  end
  return ok_all
end

-- Context sheet ----------------------------------------------------------------------------------------

-- A sliced piece's atlas drawn at w x h export px: painted segments as painted, stretch segments tiled,
-- a lone segment scaled
local function draw_sliced(atlas, t, slices, w, h)
  local out = image.new(w, h)
  local xs, ys = fit.slice_spans(t.cols, w), fit.slice_spans(t.rows, h)
  for _, r in ipairs(slices) do
    local sx, sy = xs[r.col], ys[r.row]
    local function source(p, span, len)
      if span.lone then return math.floor(p * len / span.len) end
      return p % len
    end
    for y = 0, sy.len - 1 do
      for x = 0, sx.len - 1 do
        local px, py = r.x + source(x, sx, r.w), r.y + source(y, sy, r.h)
        image.set(out, sx.at + x, sy.at + y, image.get(atlas, px, py))
      end
    end
  end
  return out
end

-- An emblem composited at a point (scaled to `size` px wide), optionally only where `mask` allows (a mask
-- whose top-left sits at (mx, my) on the image, the origin by default)
local function with_emblem(img, x, y, size, mask, mx, my)
  local emblem = image.read(EMBLEM_SAMPLE)
  local k = emblem.w / size
  local scaled = image.resample(
    emblem,
    size,
    size,
    function(px, py) return px * k, py * k end,
    math.max(1, math.ceil(k))
  )
  local ox, oy = math.floor(x - size / 2), math.floor(y - size / 2)
  if mask then
    for py = 0, size - 1 do
      for px = 0, size - 1 do
        local i = (py * size + px) * 4 + 4
        scaled.px[i] = scaled.px[i] * image.alpha(mask, ox + px - (mx or 0), oy + py - (my or 0)) / 255
      end
    end
  end
  return image.over(image.copy(img), scaled, ox, oy)
end

-- Labelled tiles ({ label, magick input }) showing one normalized item in its context
local function context_tiles(t, out, tiles)
  local asset = out .. "/asset.png"
  local kind = t.fit.kind
  local labels = {}
  local function add(label, spec) labels[#labels + 1] = { label, spec } end
  if kind == "square" or kind == "icon" then
    add("x2 (128)", asset)
    for _, size in ipairs({ 64, 48, 32, 24 }) do
      add(
        size .. " logical",
        string.format("%s -filter box -resize %dx%d -background '#1B1511' -flatten", asset, size, size)
      )
    end
  elseif kind == "nine_slice" then
    local atlas = image.read(asset)
    local qa = load_table(out .. "/qa.lua")
    local w, h = t.canvas.width, t.canvas.height
    add("atlas, " .. t.gutter .. "px gutters", asset .. " -filter box -resize '300x300>'")
    local sizes = { { w, h } }
    if #t.cols > 1 then sizes[#sizes + 1] = { 2 * w + 2 * t.cols[2], h } end
    if #t.rows > 1 then sizes[#sizes + 1] = { w, 2 * h + 2 * t.rows[2] } end
    for _, size in ipairs(sizes) do
      local path = string.format("%s/sliced_%dx%d.png", tiles, size[1], size[2])
      image.write(draw_sliced(atlas, t, qa.slices, size[1], size[2]), path)
      add(
        string.format("%dx%d logical", size[1] / t.scale, size[2] / t.scale),
        path .. string.format(" -filter box -resize %d%% -resize '600x600>'", 100 / t.scale)
      )
    end
  elseif kind == "sprite" then
    add(string.format("source %dx%d", t.canvas.width, t.canvas.height), asset .. " -filter point -resize '160x160<'")
    add("1x logical", string.format("%s -filter box -resize %d%%", asset, 100 / t.scale))
  elseif kind == "cover" then
    add("asset (640 wide)", asset .. " -filter box -resize 640x")
    if t.backdrop then add("backdrop (640 wide)", out .. "/backdrop.png -resize 640x") end
    if t.field then
      local f = t.field
      local mask = image.read(out .. "/mask.png")
      local img = with_emblem(image.read(asset), f.x, f.y, 2 * math.min(f.rx, f.ry), mask, f.x - f.rx, f.y - f.ry)
      image.write(img, tiles .. "/emblem.png")
      local x0, y0 = math.max(0, math.floor(f.x - 2 * f.rx)), math.max(0, math.floor(f.y - 1.5 * f.ry))
      add(
        "emblem through mask, 1x",
        string.format("%s/emblem.png -crop %dx%d+%d+%d +repage", tiles, 4 * f.rx, 3 * f.ry, x0, y0)
      )
    end
  elseif t.context or t.name == "beast" then
    local img = image.read(asset)
    if t.landmarks and t.landmarks.emblem then
      img = with_emblem(img, t.landmarks.emblem.x, t.landmarks.emblem.y, t.emblem_size)
    end
    local body = fit.compose(t, img)
    local zoom = math.max(1, math.floor(300 / body.w))
    image.write(body, tiles .. "/on_body.png")
    image.write(image.flip_x(body), tiles .. "/on_body_mirrored.png")
    add("source " .. img.w .. "px", asset .. " -filter box -resize 300x300")
    add("on body x" .. zoom, string.format("%s/on_body.png -filter point -resize %d%%", tiles, zoom * 100))
    add("mirrored x" .. zoom, string.format("%s/on_body_mirrored.png -filter point -resize %d%%", tiles, zoom * 100))
    add("1x logical", tiles .. "/on_body.png")
    add("0.5x box (mipmapped)", tiles .. "/on_body.png -filter box -resize 50%")
  else
    add("source " .. t.canvas.width .. "x" .. t.canvas.height, asset .. " -filter box -resize '300x300>'")
    add("1x logical", string.format("%s -filter box -resize %d%%", asset, 100 / t.scale))
    if t.field then
      local img = image.read(asset)
      local mask = image.read(out .. "/mask.png")
      local f = t.field
      image.write(with_emblem(img, f.x, f.y, math.floor(math.min(f.rx, f.ry) * 1.6), mask), tiles .. "/emblem.png")
      add("emblem through mask", tiles .. "/emblem.png -filter box -resize '300x300>'")
      add("emblem 1x logical", string.format("%s/emblem.png -filter box -resize %d%%", tiles, 100 / t.scale))
    end
  end
  if image.exists(out .. "/icon.png") then add("icon", out .. "/icon.png") end
  if t.badge then
    for _, size in ipairs({ 24, 20 }) do
      add(
        "badge " .. size .. " logical",
        string.format("%s/badge.png -filter box -resize %dx%d -background '#1B1511' -flatten", out, size, size)
      )
    end
  end
  return labels
end

local function montage_row(root, id, labels, title, tiles)
  local parts = {}
  for i, l in ipairs(labels) do
    local tile = string.format("%s/t%d.png", tiles, i)
    run(
      string.format(
        "magick %s -background '#3a3a3a' -gravity center -extent '%%[fx:max(w,170)]x%%[fx:max(h,170)]' "
          .. "-flatten -background '#202020' -gravity south -splice 0x18 -fill '#e0d0a0' -pointsize 12 "
          .. "-annotate +0+2 %s -bordercolor '#202020' -border 6 PNG32:%s",
        l[2],
        quote(l[1]),
        quote(tile)
      )
    )
    parts[#parts + 1] = quote(tile)
  end
  local row = string.format("%s/row_%s.png", root, id)
  run(string.format("magick %s -background '#202020' -gravity north +append %s", table.concat(parts, " "), quote(row)))
  local width = capture("magick identify -format '%w' " .. quote(row))
  run(
    string.format(
      "magick -background '#202020' -fill '#f0e0b0' -pointsize 13 -size %sx caption:%s %s -append %s",
      width,
      quote(title),
      quote(row),
      quote(row)
    )
  )
  return quote(row)
end

-- Promoted-or-normalized asset of a batch item for patch composition
local function patch_asset(batch, id)
  local item = batch.by_id[id] or fail("patch names unknown item " .. tostring(id))
  local path = item_dir(batch, item) .. "/out/asset.png"
  if not image.exists(path) then fail("patch item " .. id .. " is not normalized") end
  return item, fit.template(item), path
end

-- Layers composited onto one canvas grown to fit them, drawn in the order placed
local function layer_canvas()
  local layers, x0, y0, x1, y1 = {}, math.huge, math.huge, -math.huge, -math.huge
  local canvas = {}
  -- Draw `asset_path` (a template's canvas) with its `landmark` at (ax, ay); `flop` mirrors it about x
  function canvas.place(asset_path, t, ax, ay, landmark, flop)
    local lx = flop and (t.canvas.width - landmark.x) or landmark.x
    local left, top = math.floor(ax - lx + 0.5), math.floor(ay - landmark.y + 0.5)
    local input = flop and string.format("\\( %s -flop \\)", quote(asset_path)) or quote(asset_path)
    layers[#layers + 1] = { input = input, left = left, top = top }
    x0, y0 = math.min(x0, left), math.min(y0, top)
    x1, y1 = math.max(x1, left + t.canvas.width), math.max(y1, top + t.canvas.height)
  end
  function canvas.render(path)
    local parts = {}
    for _, l in ipairs(layers) do
      parts[#parts + 1] = string.format("%s -geometry %+d%+d -composite", l.input, l.left - x0, l.top - y0)
    end
    run(
      string.format(
        "magick -size %dx%d xc:'#202020' %s PNG32:%s",
        x1 - x0,
        y1 - y0,
        table.concat(parts, " "),
        quote(path)
      )
    )
  end
  return canvas
end

-- The battle patch: caps at their elevations on the flat-top battle grid, cliff bands (the hex's `cliff` or
-- the patch's: a band of n steps covers n levels, stacked from the ground up to each raised cap), and props on their
-- caps, drawn back to front at export scale
local function battle_patch(batch, spec, path)
  local geometry = require("hex.geometry")
  local canvas = layer_canvas()
  local function grid_y(h) return h.r * geometry.DY_FULL + (h.q % 2) * geometry.DY_HALF end
  local hexes = {}
  for _, h in ipairs(spec.hexes) do
    hexes[#hexes + 1] = h
  end
  table.sort(hexes, function(a, b) return grid_y(a) < grid_y(b) or (grid_y(a) == grid_y(b) and a.q < b.q) end)
  for _, h in ipairs(hexes) do
    local _, cap_t, cap_path = patch_asset(batch, h.cap or spec.cap)
    local k = cap_t.scale
    local gx, gy = h.q * geometry.DX * k, grid_y(h) * k
    local step = geometry.TILE_ELEVATION_PX * k
    if h.elevation > 0 then
      local _, cliff_t, cliff_path = patch_asset(batch, h.cliff or spec.cliff)
      for top = cliff_t.steps, h.elevation + cliff_t.steps - 1, cliff_t.steps do
        canvas.place(cliff_path, cliff_t, gx, gy - math.min(top, h.elevation) * step, cliff_t.landmarks.anchor)
      end
    end
    local anchor_y = gy - h.elevation * step
    canvas.place(cap_path, cap_t, gx, anchor_y, cap_t.landmarks.anchor)
    if h.prop then
      local _, prop_t, prop_path = patch_asset(batch, h.prop)
      local centre = (geometry.TILE_CAP_TOP_OFFSET + geometry.TILE_CAP_BOTTOM_OFFSET) / 2 * k
      canvas.place(prop_path, prop_t, gx + (h.dx or 0) * k, anchor_y - centre + 12 * k, prop_t.landmarks.base)
    end
  end
  canvas.render(path)
end

-- The world patch: ground tiles on the pointy-top odd-r grid, road and river strips (optionally mirrored),
-- then doodads and sites, then parties, each bottom-centre on its hex
local function world_patch(batch, spec, path)
  local grid = require("hex.grid").CONSTANTS
  local canvas = layer_canvas()
  local function centre(h, k)
    return (h.col * grid.HORIZONTAL_SPACING + (h.row % 2) * grid.ROW_OFFSET) * k, h.row * grid.VERTICAL_SPACING * k
  end
  local hexes = {}
  for _, h in ipairs(spec.hexes) do
    hexes[#hexes + 1] = h
  end
  table.sort(hexes, function(a, b) return a.row < b.row or (a.row == b.row and a.col < b.col) end)
  for _, pass in ipairs({ "tile", "overlays", "object", "party" }) do
    for _, h in ipairs(hexes) do
      local entries = pass == "overlays" and (h.overlays or {}) or { h[pass] and { id = h[pass] } }
      for _, e in ipairs(entries) do
        local _, t, asset_path = patch_asset(batch, e.id)
        local cx, cy = centre(h, t.scale)
        if t.landmarks.centre then
          canvas.place(asset_path, t, cx, cy, t.landmarks.centre, e.mirror)
        else
          canvas.place(asset_path, t, cx, cy + 4 * t.scale, t.landmarks.base)
        end
      end
    end
  end
  canvas.render(path)
end

local function cmd_sheet(batch, ids)
  local root = string.format("%s/%s", WORK_ROOT, batch.name)
  local rows = {}
  for _, id in ipairs(ids) do
    local item = batch.by_id[id]
    local t = fit.template(item)
    local out = item_dir(batch, item) .. "/out"
    local qa = load_table(out .. "/qa.lua")
    if qa then
      local attempt = chosen_attempt(batch, item)
      local stale = attempt and stale_reason(item, qa, attempt)
      if not attempt or stale then fail(id .. " " .. (stale or "has no generated raw.png") .. "; rerun normalize") end
      local tiles = out .. "/tiles"
      run("mkdir -p " .. quote(tiles))
      local summary = {}
      for _, check in ipairs(qa.checks) do
        summary[#summary + 1] = (check.ok and "ok " or "FAIL ") .. check.name .. ": " .. check.detail
      end
      local labels = context_tiles(t, out, tiles)
      local c = item.cut
      table.insert(labels, 1, {
        "raw (gen_" .. attempt.n .. (c and ", cut" or "") .. ")",
        string.format(
          "%s/raw.png%s -resize 300x300",
          quote(attempt.dir),
          c and string.format(" -crop %dx%d+%d+%d +repage", c.w, c.h, c.x, c.y) or ""
        ),
      })
      local title = string.format(
        "%s  [%s%s, %dx%d at %dx, %.1f KiB]  %s",
        id,
        item.family,
        item.variant and ("/" .. item.variant) or "",
        qa.dimensions.width,
        qa.dimensions.height,
        qa.dimensions.scale or 1,
        qa.texture_bytes / 1024,
        table.concat(summary, " | ")
      )
      rows[#rows + 1] = montage_row(root, id, labels, title, tiles)
    end
  end
  if #rows == 0 then fail("nothing normalized yet") end
  for name, spec in pairs(batch.patches or {}) do
    local path = string.format("%s/patch_%s.png", root, name)
    if name == "battle" then
      battle_patch(batch, spec, path)
    else
      world_patch(batch, spec, path)
    end
    local tiles = root .. "/patch_tiles"
    run("mkdir -p " .. quote(tiles))
    local labels = {
      { "export scale", path .. " -resize '1100x1100>'" },
      { "1x logical", string.format("%s -filter box -resize %d%%", path, name == "battle" and 50 or 25) },
    }
    if name == "world" then labels[#labels + 1] = { "2x logical", path .. " -filter box -resize 50%" } end
    rows[#rows + 1] = montage_row(root, "patch_" .. name, labels, spec.title, tiles)
  end
  local sheet = root .. "/contact_sheet.png"
  run(string.format("magick %s -background '#202020' -gravity west -append %s", table.concat(rows, " "), quote(sheet)))
  print(sheet)
end

-- Promotion --------------------------------------------------------------------------------------------

-- Check every item first, then copy: a refused promotion changes nothing in assets/ or the ledger
local function cmd_promote(batch, ids, replace)
  local ledger = load_table(LEDGER) or { assets = {}, items = {} }
  local copies, records, problems = {}, {}, {}
  for _, id in ipairs(ids) do
    local item = batch.by_id[id]
    local out = item_dir(batch, item) .. "/out"
    local qa = load_table(out .. "/qa.lua")
    local attempt = chosen_attempt(batch, item)
    local record = attempt and load_table(attempt.dir .. "/provenance.lua")
    local stale = qa and attempt and stale_reason(item, qa, attempt)
    if not attempt then
      problems[#problems + 1] = id .. " has no generated raw.png"
    elseif not qa then
      problems[#problems + 1] = id .. " is not normalized"
    elseif stale then
      problems[#problems + 1] = id .. " " .. stale .. "; rerun normalize"
    elseif not qa.ok then
      problems[#problems + 1] = id .. " failed its template checks (regenerate or fix the template, not the asset)"
    elseif not record or record.raw_sha256 ~= qa.raw_sha256 then
      problems[#problems + 1] = id .. " raw.png does not match its generation record"
    else
      for _, name in ipairs(OUTPUT_ORDER) do
        local dest, sha = item[OUTPUT_FIELDS[name]], qa.outputs[name]
        if sha and dest == nil then
          problems[#problems + 1] = string.format("%s has a %s output but no `%s` path", id, name, OUTPUT_FIELDS[name])
        elseif sha and dest then
          local src = out .. "/" .. name .. ".png"
          if image.sha256(src) ~= sha then
            problems[#problems + 1] = src .. " changed after its checks; rerun normalize"
          elseif image.exists(dest) and image.sha256(dest) ~= sha and not replace then
            problems[#problems + 1] = dest .. " exists and differs; curated assets are only overwritten with --replace"
          else
            copies[#copies + 1] = { src = src, dest = dest }
            ledger.assets[dest] = { item = batch.name .. "/" .. id, sha256 = sha }
          end
        end
      end
      record.attempt = attempt.n
      record.cut = item.cut
      record.normalize_inputs_sha256 = qa.inputs_sha256
      record.dimensions = qa.dimensions
      record.texture_bytes = qa.texture_bytes
      record.placement = qa.placement
      record.slices = qa.slices
      record.checks = {}
      for _, check in ipairs(qa.checks) do
        record.checks[#record.checks + 1] = check.name .. ": " .. check.detail
      end
      records[batch.name .. "/" .. id] = record
    end
  end
  if #problems > 0 then fail("nothing promoted:\n  " .. table.concat(problems, "\n  ")) end
  for _, o in ipairs(copies) do
    run("mkdir -p " .. quote(o.dest:match("^(.*)/[^/]+$")))
    run(string.format("cp %s %s", quote(o.src), quote(o.dest)))
  end
  for key, record in pairs(records) do
    ledger.items[key] = record
  end
  -- The ledger describes what ships: drop deleted assets and the records no shipped asset comes from any more
  local shipped = {}
  for path, entry in pairs(ledger.assets) do
    if image.exists(path) then
      shipped[entry.item] = true
    else
      ledger.assets[path] = nil
    end
  end
  for key in pairs(ledger.items) do
    if not shipped[key] then ledger.items[key] = nil end
  end
  write_file(
    LEDGER,
    "-- tools/art/provenance.lua - Provenance of every promoted generated asset (written by tools/art/pipeline.lua)\n"
      .. "return "
      .. serialize(ledger)
      .. "\n"
  )
  print(string.format("promoted %d files; ledger %s", #copies, LEDGER))
end

local USAGE = [[
usage: lua tools/art/pipeline.lua <command> <batch> [item ...] [--replace]
  guide      write template guide, style references and prompt for the next attempt (no generation)
  generate   guide + one Codex image generation per item into tmp/art/<batch>/<item>/gen_<n>/
  adopt      take an item's `adopt` prep generation (prompt, references, session) as its next attempt
  normalize  fit each item's chosen raw to its family template -> tmp/art/<batch>/<item>/out/
  sheet      context sheet of normalized items and the batch's patches -> tmp/art/<batch>/contact_sheet.png
  promote    copy passing items into assets/ and record provenance; refuses to overwrite a different
             existing file unless --replace is given
Items default to every item in the batch (tools/art/batches/<batch>.lua).]]

local function main(args)
  local command, batch_name = args[1], args[2]
  if not command or not batch_name then
    print(USAGE)
    os.exit(command and 2 or 0)
  end
  local batch = load_batch(batch_name)
  local ids, replace = {}, false
  for i = 3, #args do
    if args[i] == "--replace" then
      replace = true
    else
      ids[#ids + 1] = args[i]
    end
  end
  if #ids == 0 then
    for _, item in ipairs(batch.items) do
      if command ~= "adopt" or item.adopt then ids[#ids + 1] = item.id end
    end
  end
  if command == "guide" then
    cmd_guide(batch, ids)
  elseif command == "generate" then
    cmd_generate(batch, ids)
  elseif command == "adopt" then
    cmd_adopt(batch, ids)
  elseif command == "normalize" then
    if not cmd_normalize(batch, ids) then os.exit(1) end
  elseif command == "sheet" then
    cmd_sheet(batch, ids)
  elseif command == "promote" then
    cmd_promote(batch, ids, replace)
  else
    print(USAGE)
    os.exit(2)
  end
end

main(arg)
