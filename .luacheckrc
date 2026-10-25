std = "lua54"
max_line_length = 140
files["reference/**"] = { std = "lua51+love", max_line_length = false }
-- Recorded prompt subjects are deliberately kept as whole strings.
files["tools/art/batches/"] = { ignore = { "631" } }
