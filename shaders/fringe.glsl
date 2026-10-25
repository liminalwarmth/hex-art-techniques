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
