# Artwork and license scope

The MIT license covers the source code, shaders, documentation and prompt text in this repository.

The PNG artwork, original raw generation, style-reference images and screenshots are shared for reference and study. They are excluded from the MIT license; no additional artwork reuse license is granted here. Contact the repository owner if you need permission to redistribute or use the artwork in another project.

The terrain images were generated with Codex's built-in image-generation tool, guided by the game's original mockups, then processed by the included normalization code. The recorded generator does not name an underlying image model. Provenance JSON files identify the prompt, chosen attempt, original raw hash, exported asset hash, dimensions and production checks. A recorded check documents the production run; it is not a claim that every new generation will pass.

The repository is a curated educational export of Fantasy Warband's terrain workflow. The exported art bytes and core pipeline implementations are preserved; terrain templates are limited to the five included families, style-reference paths are mapped to included crops, and batch IDs are based on public asset filenames. Session identifiers and operator metadata are omitted. Original game runtime modules under `reference/` are provided for integration study.
