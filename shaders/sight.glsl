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
