-- data/world/tiles/manifest.lua - The painted overworld (VA8): every piece of art the world map draws.
-- Paths only; each piece's canvas, anchor and source scale are its family's template (data/items/visual_templates.lua:
-- `world_tile`, `doodad`, `site`, `party`, `heraldry`). How a world picks among them is rendering/map/composition.lua;
-- the geometry contract and checks are in data/world/tiles/agents.md.

local TILES = "assets/worldmap/tiles/"
local ROADS = "assets/worldmap/roads/"
local DOODADS = "assets/worldmap/doodads/"
local SITES = "assets/worldmap/sites/"
local PARTIES = "assets/worldmap/parties/"

local function files(folder, ...)
  local list = {}
  for i, name in ipairs({ ... }) do
    list[i] = folder .. name .. ".png"
  end
  return list
end

return {
  -- Painted px per world unit: the bake's resolution, and the scale every piece is authored at
  SCALE = 4,
  -- The bake: chunk canvases at most `chunk` px a side with a `gutter` of neighbouring pixels round each
  BAKE = { chunk = 2048, gutter = 16 },

  -- Ground kinds, lowest priority first: where neighbours' soft edges meet, a higher kind's lies over a lower's (water
  -- < shore < marsh < meadow < farmland < forest floor < hills < mountain); no edge passes half strength beyond its own
  -- hex. Beach, forest floor, hills and mountain wait for the climates that use them (G06).
  GROUND_ORDER = {
    "deep",
    "shallow",
    "beach",
    "swamp",
    "meadow",
    "dark_grass",
    "farmland",
    "forest_floor",
    "hills",
    "mountain",
  },
  GROUND = {
    deep = files(TILES, "deep_01", "deep_02"),
    shallow = files(TILES, "shallow_01", "shallow_02"),
    beach = files(TILES, "beach_01", "beach_02"),
    swamp = files(TILES, "swamp_01", "swamp_02"),
    meadow = files(TILES, "meadow_01", "meadow_02", "meadow_03", "meadow_04"),
    dark_grass = files(TILES, "dark_grass_01", "dark_grass_02"),
    farmland = files(TILES, "farmland_01", "farmland_02"),
    forest_floor = files(TILES, "forest_floor_01", "forest_floor_02"),
    hills = files(TILES, "hills_01", "hills_02", "hills_03"),
    mountain = files(TILES, "mountain_01", "mountain_02", "mountain_03"),
  },
  -- The parchment an uncharted hex shows
  UNCHARTED = TILES .. "uncharted.png",

  -- The ground each climate paints, and where it varies: water beside land is shallow; meadow turns to dark grass
  -- where a broad noise field runs high, and to fields near a settlement
  CLIMATES = {
    ocean = { ground = "deep", shore = "shallow" },
    temperate = { ground = "meadow", lush = "dark_grass", fields = "farmland" },
    wetland = { ground = "swamp" },
  },
  PAINT = {
    lush_scale = 140, -- world units per dark-grass patch
    lush_above = 0.56, -- noise level above which meadow is dark grass
    fields_radius = 2, -- hexes from a settlement that may be farmed
    fields_share = 0.45,
    reeds_share = 0.55, -- marsh hexes with reeds
    copse_share = 0.07, -- open meadow hexes with a copse (until G06 adds forests)
    copse_clear = { settlement = 2, site = 1 }, -- no copse this many hexes from a place
    fringe = 0.42, -- a tile's soft edge spans up to this share of its half extents (the ground's centred on its edge)
    -- Kinds drawn from the middle of their art only: shallow water is painted as a little lake with sandy edges,
    -- which repeated along a shore reads as a string of beads
    inset = { shallow = 0.55 },
    grid_alpha = 0.1, -- the faint hex grid, INK_900 at this opacity
  },

  -- A road is a strip per edge it crosses (centre to that edge's midpoint) under the hub patch where strips meet
  ROADS = {
    N = ROADS .. "dirt_n.png",
    NE = ROADS .. "dirt_ne.png",
    SE = ROADS .. "dirt_se.png",
    S = ROADS .. "dirt_s.png",
    SW = ROADS .. "dirt_sw.png",
    NW = ROADS .. "dirt_nw.png",
    hub = ROADS .. "dirt_hub.png",
  },

  -- Objects stand bottom-centre this many world units below their hex's centre
  BASE_DROP = 4,
  DOODADS = {
    reeds = { variant = "reeds", files = files(DOODADS, "reeds_01", "reeds_02") },
    copse = { variant = "forest", files = files(DOODADS, "forest_04", "forest_06") },
  },

  -- Settlement miniatures by tier, sites by POI type (data/world/sites POI_TYPES)
  SETTLEMENTS = {
    village = files(SITES, "village_01", "village_02"),
    town = files(SITES, "town_01", "town_02"),
    city = files(SITES, "city_01", "city_02"),
  },
  SITES = {
    camp = SITES .. "bandit_camp.png",
    ruins = SITES .. "ruins.png",
    cave = SITES .. "cave.png",
    shrine = SITES .. "shrine.png",
    landmark = SITES .. "standing_stones.png",
  },

  -- Party figurines by faction (data/world/parties FACTIONS) and the company's standard-bearer (its flag blank until
  -- the company's heraldry is chosen, V14), drawn `size` times its authored size so a party reads above the places.
  -- Each stands on its allegiance's ground ring (VA1), `ring_w` x `ring_h` world units centred `ring_lift` above its
  -- base, its faction emblem `emblem` wide at its shoulder (all times `size`); below `floor_zoom` a figurine keeps
  -- its size on screen.
  PARTY = { size = 1.4, floor_zoom = 2, ring_w = 32, ring_h = 19, ring_lift = 2, emblem = 10 },
  PARTIES = {
    raiders = PARTIES .. "bandits.png",
    undead = PARTIES .. "restless_dead.png",
    beasts = PARTIES .. "wolves.png",
    caravan = PARTIES .. "caravan.png", -- neutral parties to come (E03 caravans, W07 patrols)
    militia = PARTIES .. "militia.png",
  },
  COMPANY = PARTIES .. "company.png",
  RINGS = {
    company = "assets/ui/kit/ring_company.png",
    hostile = "assets/ui/kit/ring_hostile.png",
    neutral = "assets/ui/kit/ring_neutral.png",
  },
}
