-- Terrain-only export of the original shared art contracts.
-- Canvas, landmark, size, seal and fringe values are export pixels.
-- scale is export pixels per logical game pixel. Style references use local crops.
return {
  FAMILIES = {
    cliff_band = {
      edge_ok = true,
      fit = {
        kind = "silhouette",
        max_cut = 0.06,
        max_scale_error = 0.15,
        min_fill = 0.95,
        min_overlap = 0.8,
        search = 32,
      },
      folder = "terrain",
      fringe = 16,
      landmarks = {
        anchor = {
          x = 256,
          y = 444,
        },
      },
      light = false,
      matte = "green",
      outline = false,
      scale = 2,
      seal = 8,
      style = "terrain",
      style_refs = {
        "references/cliff_band_1.png",
      },
      variants = {
        step1 = {
          canvas = {
            height = 512,
            width = 512,
          },
          steps = 1,
        },
        step2 = {
          canvas = {
            height = 608,
            width = 512,
          },
          steps = 2,
        },
        step3 = {
          canvas = {
            height = 704,
            width = 512,
          },
          steps = 3,
        },
      },
      zone = {
        kind = "polygon",
        shape = "battle_cliff",
      },
    },
    doodad = {
      fit = {
        kind = "footprint",
        measure = "height",
      },
      folder = "worldmap",
      matte = "green",
      scale = 4,
      style = "world",
      style_refs = {
        "references/doodad_1.png",
      },
      variants = {
        forest = {
          canvas = {
            height = 160,
            width = 160,
          },
          landmarks = {
            base = {
              x = 80,
              y = 148,
            },
          },
          size = 120,
        },
        hill = {
          canvas = {
            height = 128,
            width = 160,
          },
          landmarks = {
            base = {
              x = 80,
              y = 116,
            },
          },
          size = 72,
        },
        peak = {
          canvas = {
            height = 224,
            width = 256,
          },
          landmarks = {
            base = {
              x = 128,
              y = 212,
            },
          },
          size = 180,
        },
        reeds = {
          canvas = {
            height = 96,
            width = 128,
          },
          landmarks = {
            base = {
              x = 64,
              y = 88,
            },
          },
          size = 56,
        },
      },
      zone = {
        kind = "footprint",
        width = 0.85,
      },
    },
    hex_cap = {
      canvas = {
        height = 512,
        width = 512,
      },
      edge_ok = true,
      fit = {
        kind = "silhouette",
        max_cut = 0.04,
        max_scale_error = 0.15,
        min_fill = 0.98,
        min_overlap = 0.85,
        search = 32,
      },
      folder = "terrain",
      fringe = 16,
      landmarks = {
        anchor = {
          x = 256,
          y = 444,
        },
      },
      light = false,
      matte = "green",
      outline = false,
      scale = 2,
      seal = 8,
      style = "terrain",
      style_refs = {
        "references/hex_cap_1.png",
      },
      zone = {
        kind = "polygon",
        shape = "battle_cap",
      },
    },
    prop = {
      fit = {
        kind = "footprint",
        measure = "height",
      },
      folder = "environment",
      matte = "green",
      scale = 2,
      style = "terrain",
      style_refs = {
        "references/prop_1.png",
      },
      variants = {
        bush = {
          canvas = {
            height = 288,
            width = 288,
          },
          landmarks = {
            base = {
              x = 144,
              y = 272,
            },
          },
          size = 224,
        },
        cart = {
          canvas = {
            height = 320,
            width = 512,
          },
          landmarks = {
            base = {
              x = 256,
              y = 304,
            },
          },
          size = 176,
          zone = {
            kind = "footprint",
            width = 2.2,
          },
        },
        clutter = {
          canvas = {
            height = 160,
            width = 224,
          },
          landmarks = {
            base = {
              x = 112,
              y = 148,
            },
          },
          size = 104,
          zone = {
            kind = "footprint",
            width = 1.4,
          },
        },
        fence = {
          canvas = {
            height = 192,
            width = 512,
          },
          landmarks = {
            base = {
              x = 256,
              y = 176,
            },
          },
          size = 96,
          zone = {
            kind = "footprint",
            width = 4,
          },
        },
        low = {
          canvas = {
            height = 224,
            width = 288,
          },
          landmarks = {
            base = {
              x = 144,
              y = 208,
            },
          },
          size = 128,
          zone = {
            kind = "footprint",
            width = 1.6,
          },
        },
        rock = {
          canvas = {
            height = 288,
            width = 288,
          },
          landmarks = {
            base = {
              x = 144,
              y = 272,
            },
          },
          size = 224,
        },
        scatter = {
          canvas = {
            height = 128,
            width = 288,
          },
          landmarks = {
            base = {
              x = 144,
              y = 116,
            },
          },
          size = 40,
          zone = {
            kind = "footprint",
            width = 4,
          },
        },
        standing = {
          canvas = {
            height = 416,
            width = 288,
          },
          landmarks = {
            base = {
              x = 144,
              y = 400,
            },
          },
          size = 352,
          zone = {
            kind = "footprint",
            width = 0.5,
          },
        },
        tent = {
          canvas = {
            height = 416,
            width = 512,
          },
          landmarks = {
            base = {
              x = 256,
              y = 400,
            },
          },
          size = 320,
          zone = {
            kind = "footprint",
            width = 1.2,
          },
        },
        tree = {
          canvas = {
            height = 704,
            width = 640,
          },
          landmarks = {
            base = {
              x = 320,
              y = 688,
            },
          },
          size = 600,
        },
      },
      zone = {
        kind = "footprint",
        width = 0.8,
      },
    },
    world_tile = {
      canvas = {
        height = 152,
        width = 136,
      },
      edge_ok = true,
      folder = "worldmap",
      fringe = 6,
      landmarks = {
        centre = {
          x = 68,
          y = 76,
        },
      },
      light = false,
      matte = "green",
      outline = false,
      scale = 4,
      style = "world",
      style_refs = {
        "references/world_tile_1.png",
      },
      variants = {
        ground = {
          fit = {
            kind = "silhouette",
            max_cut = 0.05,
            max_scale_error = 0.15,
            min_fill = 0.98,
            min_overlap = 0.85,
            search = 10,
          },
          seal = 2,
          zone = {
            kind = "polygon",
            shape = "world_hex",
          },
        },
        hub = {
          fit = {
            kind = "silhouette",
            max_cut = 0.15,
            max_scale_error = 0.25,
            min_fill = 0.5,
            min_overlap = 0.5,
            search = 8,
          },
          zone = {
            kind = "polygon",
            radius = 14,
            shape = "world_hub",
          },
        },
        river = {
          fit = {
            kind = "silhouette",
            max_cut = 0.15,
            max_scale_error = 0.25,
            min_fill = 0.5,
            min_overlap = 0.5,
            search = 8,
          },
          zone = {
            half_width = 16,
            kind = "polygon",
            shape = "world_half_edge",
          },
        },
        road = {
          fit = {
            kind = "silhouette",
            max_cut = 0.15,
            max_scale_error = 0.25,
            min_fill = 0.5,
            min_overlap = 0.5,
            search = 8,
          },
          zone = {
            half_width = 12,
            kind = "polygon",
            shape = "world_half_edge",
          },
        },
      },
    },
  },
  FRAME = {
    height = 150,
    width = 150,
  },
  STYLE = {
    light = "upper_left",
    mirror = "flip_x",
    outline = {
      darken = 0.55,
      width = 1,
    },
  },
}
