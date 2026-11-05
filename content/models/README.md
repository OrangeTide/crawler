# Models

Baked inputs for the polygon renderer. Each model is a Wavefront OBJ
(positions and UVs, triangulated) plus a binary PPM texture. The build
bakes these into CMSH lumps in the pak with the mesh baker, so the game
build needs only the Pascal toolchain, not the model tools.

The combat creature set is CREA1 through CREA13, one mesh per eldritch
creature, plus FLESH1 and FLESH2 from the meats and flesh pack. Each
monster in the table names its own mesh, so no two share a model.

These are converted offline from CC0 source packs (postdev.itch.io) with:

    assimp export SOURCE.glb NAME.obj -tri
    convert SOURCE_texture.png -resize 64x64\! -depth 8 NAME.ppm

For a texture embedded in a GLB, extract it first:

    assimp extract SOURCE.glb tmp
    convert tmp_img0.png -resize 128x128\! -depth 8 NAME.ppm

These OBJ sources keep their full detail. The baker runs a triangle
budget pass when it builds the pak, clustering vertices to bring any
heavy mesh down to the target ceiling for the PSX and DOS targets, so
the sources stay high resolution while the shipped lumps stay small.

The baker also reports each model's VRAM cost, its texture footprint in
an 8-bit page, since all textures share the one game palette and so one
CLUT on the PSX. The model registry carries that cost, and a cache can
sum the models an area needs and check them against MODEL_VRAM_BUDGET
to stay within what the console can hold at once.

The models are public domain (CC0); nothing here carries a license header.
