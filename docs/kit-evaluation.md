# SigilsVault kit PS1-adaptability evaluation (0.26.0)

This is the go/no-go for theme G. It asks whether the SigilsVault CC0 modular
kits under `REF/sigilsvault.itch.io/` can be adapted to the project's PS1
target, and sets a per-tile polygon budget for the sector-map work that
follows. The findings come from measuring the kit meshes and textures and from
baking a kit piece through the real mesh pipeline, not from the vendor's
description.

## Verdict

GO for the Modular Dungeon kit. It adapts to the PS1 target through the
existing meshtools pipeline with light per-tile decimation, and its trim-sheet
texturing is already the PS1-friendly shape the game wants.

Conditional go for the Modular Cathedral kit. It is a step heavier and reads as
PS2-era. Use it selectively for hero and outdoor structures with decimation,
not as the everyday indoor tileset. Lower priority than the dungeon kit.

## Scope and method

- Kits: Modular Dungeon (91 mesh pieces plus 6 props) and Modular Cathedral (44
  pieces plus 4 props), GLB and FBX, 1-metre grid, trim-sheet textured.
- Mesh counts measured with `assimp info` over every GLB piece.
- Pipeline ingestion proven by baking `wall_large_01.glb` end to end: `assimp
  export ... -tri` to OBJ, the 256x256 trim sheet to a 64x64 game-palette PPM,
  then `mkmesh` to a `CMSH` lump, then `meshshot` to a framebuffer render.
- PS1 constraints used as the yardstick: 1 MB VRAM holding the framebuffers and
  the texture pages and CLUTs together, 256x256 texture pages, 8-bit paletted
  textures with a CLUT, no hardware depth buffer (ordering-table sort instead),
  affine (non-perspective-correct) texture mapping, and the 2 MB main RAM the
  roadmap already budgets against.

## License

Both kits are CC0 1.0 (public domain dedication) by Kevin Barany / SigilsVault,
per each kit's `LICENSE.txt`. Credit is appreciated but not required. This fits
the project's posture cleanly and carries no attribution obligation. No CREDITS
entry is added yet because no kit asset ships in `content/` at this step. The
courtesy entry lands when the first piece is baked into the game, per the
0.26.0 bake-a-room item.

## Polygon budget

Face counts per piece (triangulated):

| Kit | Pieces | Min | Mean | Max | Heaviest pieces |
|-----|-------:|----:|-----:|----:|-----------------|
| Dungeon | 91 | 12 | 135 | 584 | `door_arched_01` 584, `wall_large_03` 488, vault ceilings 300-458 |
| Cathedral | 44 | 20 | 345 | 1962 | `sanctum_upper_01` 1962, `tower_cap_02` 1016, `tower_cap_01` 964 |

Dungeon props: coffin 28, crate 108, pot 124, brazier 286.

Reading against the PS1. A first-person dungeon view shows on the order of a
dozen to two dozen pieces at once. At the dungeon kit's 135-face mean that is
roughly 1600 to 3200 triangles of geometry before sprites, which sits at the
upper edge of a practical PS1 per-frame budget. The structural pieces that
dominate a view (flat walls, floors, plain ceilings) run 12 to 144 faces and
need little or no reduction. The cost concentrates in a few hero pieces: the
vaulted ceilings (300 to 458), the arched door (584), and on the cathedral side
the towers and sanctum (900 to 1962). Those decimate or are used sparingly.

The existing pipeline already handles this. `mkmesh` runs `DecimateMesh` to a
triangle budget and `MESH_TRI_BUDGET` is 600, which is sized for a single
hero prop, not for a tile that repeats across a whole room. Theme G should add
a lower per-tile budget. Recommended targets:

- Structural tiles (walls, floors, plain ceilings): 128 triangles. Most are
  already under this; the rest decimate with no visible loss at dungeon scale.
- Hero tiles (vault ceilings, arches, stairs): 256 triangles, decimated.
- Props (barrel, crate, pot, coffin, brazier): 150 triangles, reusing the
  instanced-prop path that already draws the resident meshes.

With those caps a full dungeon view lands near 1500 to 2000 geometry triangles,
leaving headroom for the billboard sprites the game keeps.

## Texturing

The dungeon kit textures the entire set from one shared trim sheet, supplied at
256x256, 512x512, and 1024x1024, in a plain and a handpainted (mossy) variant.
This is the single most PS1-favourable property of the kit. The 256x256 trim
sheet at 8-bit is exactly one PS1 texture page, and the whole modular set draws
from it with no texture swaps. It maps directly onto the game's existing
one-resident-tileset model (`textures.SetTileset`): bake the trim sheet once as
a tileset, point every piece's UVs at it, and a whole room costs one texture.
The mossy sheet is a second tileset. This is the trim-sheet pipeline item that
0.26.0 already lists, and the kit ships ready for it.

The cathedral kit adds window diffuse and window emission maps. The emission
map pairs with the existing `world.LightGlow` and emissive-tile path, so
stained glass can glow without a new system.

## Palette fit

The dungeon trim sheet is near-greyscale stone. Baked to the game palette it
quantizes onto the grey ramp with no hue drift, which is the risk the
palette-cube constraint warns about. The baked `wall_large_01` renders as a
legible stone wall with its brick courses and the ornamental band intact. The
cathedral kit introduces warmer wood on the roofs and coloured stained glass,
which need palette care; the game's per-scene 256-colour palette support covers
that when those pieces are used.

## Pipeline ingestion

The meshtools pipeline ingests the kit with no new importer:

```
assimp export wall_large_01.glb wall.obj -tri        # 0.001 s, 92 tris
convert TrimSheet_256x256.png -resize 64x64! -depth 8 wall.ppm
mkmesh wall.cmsh wall.obj wall.ppm 600               # CMSH, 64x64 tex, 9636 bytes
meshshot wall.cmsh wall.png 35                        # renders in the game palette
```

GLB is the format to use: textures are embedded and the export is immediate.
FBX needs manual texture assignment and offers nothing the GLB path lacks. The
kits ship no collision meshes, which is correct for this project: collision
stays on the logical grid, decoupled from render geometry, as 0.27.0 plans.

## Grid, scale, and modularity

Pieces are authored on a 1-metre grid at real-world scale, which matches a
sector layout on a unit grid directly. The taxonomy is the one a sector format
needs: walls with left, right, half, and corner variants; floors with edge and
corner trims; vaulted and flat ceilings; pillars, stairs, and doors. A
half-thickness wall variant is included for stairway junctions to avoid vault
clipping. The sun-and-sigil motif on the trim sheet suits the game's theme.

## Gaps and risks

- Trim-sheet UVs are shared across pieces, so the bake must preserve each
  piece's UVs against the atlas rather than refit a per-piece texture. The
  current `mkmesh` takes one texture per mesh; theme G wires the shared tileset
  through instead. This is the planned pipeline change, not a blocker.
- The hero and cathedral pieces need the per-tile decimation above to fit a PS1
  frame. The decimator exists; the budgets are new tuning.
- A true PS1 backend sorts by an ordering table and has no depth buffer, while
  the current rasterizer uses a Z-buffer. That is a renderer-backend concern for
  the 0.31.0 seam, independent of the kit, but the per-tile budgets here feed it.
- Props overlap the existing billboard and instanced-prop approaches; pick per
  prop whether it reads better as a sprite or a mesh. Braziers and chandeliers
  pair with the light-glow system.

## Target poly budget (summary)

- Structural tile: 128 triangles.
- Hero tile: 256 triangles.
- Prop mesh: 150 triangles.
- Texture: one 256x256 8-bit trim sheet per tileset, one resident at a time.
- A full dungeon view: about 1500 to 2000 geometry triangles plus sprites.
