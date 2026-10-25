-- tools/art/image.lua - RGBA images for the art pipeline. ImageMagick (`magick`) only decodes and encodes;
-- every pixel decision is plain Lua arithmetic, so a rerun on the same inputs is byte-identical.
local M = {}

local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
M.quote = quote

local function run(cmd)
  local ok = os.execute(cmd)
  if ok ~= true and ok ~= 0 then error("command failed: " .. cmd) end
end
M.run = run

local function capture(cmd)
  local p = assert(io.popen(cmd, "r"))
  local out = p:read("*a")
  p:close()
  return out
end
M.capture = capture

function M.exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

function M.sha256(path)
  local out = capture("shasum -a 256 " .. quote(path) .. " 2>/dev/null")
  return out:match("^(%x+)")
end

-- A new transparent image: px is a flat 0-based-by-pixel array {r, g, b, a, ...} with 0..255 values
function M.new(w, h)
  local px = {}
  for i = 1, w * h * 4 do
    px[i] = 0
  end
  return { w = w, h = h, px = px }
end

function M.read(path)
  local dims = capture("magick identify -format '%w %h' " .. quote(path) .. "[0]")
  local w, h = dims:match("^(%d+) (%d+)")
  if not w then error("cannot read image " .. path) end
  w, h = tonumber(w), tonumber(h)
  local data = capture("magick " .. quote(path) .. "[0] -depth 8 RGBA:-")
  if #data ~= w * h * 4 then error(string.format("decoded %d bytes from %s, expected %d", #data, path, w * h * 4)) end
  local px = {}
  for i = 1, #data, 4096 do
    local chunk = { data:byte(i, math.min(i + 4095, #data)) }
    for j = 1, #chunk do
      px[i + j - 1] = chunk[j]
    end
  end
  return { w = w, h = h, px = px }
end

-- Encode as 8-bit RGBA PNG without timestamps or other metadata
function M.write(img, path)
  local parts = {}
  local px = img.px
  local floor = math.floor
  for i = 1, img.w * img.h * 4 do
    local v = floor(px[i] + 0.5)
    if v < 0 then
      v = 0
    elseif v > 255 then
      v = 255
    end
    parts[#parts + 1] = string.char(v)
  end
  local tmp = os.tmpname()
  local f = assert(io.open(tmp, "wb"))
  f:write(table.concat(parts))
  f:close()
  run(
    string.format(
      "magick -size %dx%d -depth 8 RGBA:%s -strip -define png:exclude-chunks=date,time PNG32:%s",
      img.w,
      img.h,
      quote(tmp),
      quote(path)
    )
  )
  os.remove(tmp)
end

function M.get(img, x, y)
  if x < 0 or y < 0 or x >= img.w or y >= img.h then return 0, 0, 0, 0 end
  local i = (y * img.w + x) * 4
  local px = img.px
  return px[i + 1], px[i + 2], px[i + 3], px[i + 4]
end

function M.set(img, x, y, r, g, b, a)
  local i = (y * img.w + x) * 4
  local px = img.px
  px[i + 1], px[i + 2], px[i + 3], px[i + 4] = r, g, b, a
end

function M.alpha(img, x, y)
  if x < 0 or y < 0 or x >= img.w or y >= img.h then return 0 end
  return img.px[(y * img.w + x) * 4 + 4]
end

function M.copy(img)
  local px = {}
  for i = 1, #img.px do
    px[i] = img.px[i]
  end
  return { w = img.w, h = img.h, px = px }
end

function M.flip_x(img)
  local out = M.new(img.w, img.h)
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      M.set(out, img.w - 1 - x, y, M.get(img, x, y))
    end
  end
  return out
end

-- Source-over composite of src onto dst with src's top-left at integer (ox, oy)
function M.over(dst, src, ox, oy, opacity)
  opacity = opacity or 1
  for y = 0, src.h - 1 do
    local dy = y + oy
    if dy >= 0 and dy < dst.h then
      for x = 0, src.w - 1 do
        local dx = x + ox
        if dx >= 0 and dx < dst.w then
          local r, g, b, a = M.get(src, x, y)
          a = a * opacity / 255
          if a > 0 then
            local dr, dg, db, da = M.get(dst, dx, dy)
            da = da / 255
            local oa = a + da * (1 - a)
            local function mix(s, d) return (s * a + d * da * (1 - a)) / oa end
            M.set(dst, dx, dy, mix(r, dr), mix(g, dg), mix(b, db), oa * 255)
          end
        end
      end
    end
  end
  return dst
end

-- Resample `src` into a w x h image through `inverse(x, y) -> sx, sy` (output to source coordinates).
-- Each output pixel averages an n x n grid of point samples (a box filter at the source density).
-- Alpha averages every sample; colour comes only from samples at least half opaque, so the generator's
-- matte colour in soft edges never reaches the export. A pixel covered only by translucent samples takes
-- the colour of its solid-coloured neighbours (a one-pixel soft edge); with none it is matte fringe and
-- is dropped.
function M.resample(src, w, h, inverse, n)
  local out = M.new(w, h)
  local opx = out.px
  local solid = {}
  local sw, sh, spx = src.w, src.h, src.px
  local floor = math.floor
  local inv_n = 1 / n
  local count = n * n
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local a_sum, r_sum, g_sum, b_sum, w_sum = 0, 0, 0, 0, 0
      for j = 0, n - 1 do
        for i = 0, n - 1 do
          local sx, sy = inverse(x + (i + 0.5) * inv_n, y + (j + 0.5) * inv_n)
          sx, sy = floor(sx), floor(sy)
          if sx >= 0 and sy >= 0 and sx < sw and sy < sh then
            local k = (sy * sw + sx) * 4
            local a = spx[k + 4]
            a_sum = a_sum + a
            if a >= 128 then
              r_sum = r_sum + spx[k + 1] * a
              g_sum = g_sum + spx[k + 2] * a
              b_sum = b_sum + spx[k + 3] * a
              w_sum = w_sum + a
            end
          end
        end
      end
      if w_sum > 0 then
        M.set(out, x, y, r_sum / w_sum, g_sum / w_sum, b_sum / w_sum, a_sum / count)
        solid[y * w + x] = true
      elseif a_sum > 0 then
        opx[(y * w + x) * 4 + 4] = a_sum / count
      end
    end
  end
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local o = (y * w + x) * 4
      if opx[o + 4] > 0 and not solid[y * w + x] then
        local r, g, b, wt = 0, 0, 0, 0
        for dy = -1, 1 do
          for dx = -1, 1 do
            local nx, ny = x + dx, y + dy
            if nx >= 0 and ny >= 0 and nx < w and ny < h and solid[ny * w + nx] then
              local k = (ny * w + nx) * 4
              local a = opx[k + 4]
              r, g, b, wt = r + opx[k + 1] * a, g + opx[k + 2] * a, b + opx[k + 3] * a, wt + a
            end
          end
        end
        if wt > 0 then
          M.set(out, x, y, r / wt, g / wt, b / wt, opx[o + 4])
        else
          opx[o + 4] = 0
        end
      end
    end
  end
  return out
end

-- Round every channel to an integer so later passes see exactly what will be encoded
function M.quantize(img)
  local floor = math.floor
  for i = 1, #img.px do
    local v = floor(img.px[i] + 0.5)
    img.px[i] = v < 0 and 0 or (v > 255 and 255 or v)
  end
  return img
end

-- Opaque-pixel bounding box (alpha >= threshold) as x0, y0, x1, y1 inclusive, or nil
function M.bbox(img, threshold)
  threshold = threshold or 1
  local x0, y0, x1, y1
  for y = 0, img.h - 1 do
    for x = 0, img.w - 1 do
      if M.alpha(img, x, y) >= threshold then
        x0 = (x0 and math.min(x0, x)) or x
        x1 = (x1 and math.max(x1, x)) or x
        y0 = y0 or y
        y1 = y
      end
    end
  end
  if not x0 then return nil end
  return x0, y0, x1, y1
end

return M
