unit raster;

{** A small fixed-function polygon rasterizer, PSX style.

  Triangles are transformed into view space, projected, and filled with
  affine (not perspective correct) texture mapping, which is what gives
  the classic PlayStation texture warp. There is no depth buffer: whole
  triangles are sorted back to front and painted in order. The target is
  the shared 8-bit framebuffer, so a texel is already a palette index.

  The math is double precision for now. The hot path converts to fixed
  point later, the same way the raycaster did, once the look is settled. }

{$mode objfpc}{$H+}

interface

uses
  meshfmt;

type
  TMeshCam = record
    x, y, z: double;      { eye position in world space, Z up }
    yaw: double;          { heading, 0 looks along +X }
    pitch: double;        { look up and down }
  end;

{ Draw a mesh placed at (mx,my,mz), uniformly scaled, rotated myaw about
  Z. light is a 0..256 shade applied to every texel (256 is full bright,
  used for fog and simple lighting); 256 writes texels straight through. }
procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double);

implementation

uses
  gfx;

const
  NEAR  = 0.05;
  FOCAL = (FBW / 2) / 0.66;   { matches the raycaster field of view }

type
  TCorner = record
    sx, sy: double;    { screen position }
    u, v: double;      { texture coordinate }
    depth: double;     { view-space forward distance, for sorting }
  end;
  TTri = record
    c: array[0 .. 2] of TCorner;
    key: double;       { average depth, back to front }
  end;

var
  tris: array of TTri;
  ntris: longint;

{ Transform and project one world point; returns false if behind near. }
function Project(const cam: TMeshCam; wx, wy, wz: double; out c: TCorner): boolean;
var
  dx, dy, dz, fwd, side, up, depth, vup, cy, sy, cp, sp: double;
begin
  Project := false;
  dx := wx - cam.x; dy := wy - cam.y; dz := wz - cam.z;
  cy := cos(cam.yaw); sy := sin(cam.yaw);
  fwd := dx * cy + dy * sy;
  side := -dx * sy + dy * cy;
  up := dz;
  cp := cos(cam.pitch); sp := sin(cam.pitch);
  depth := fwd * cp + up * sp;
  vup := -fwd * sp + up * cp;
  if depth <= NEAR then exit;
  c.sx := (FBW / 2) + (side / depth) * FOCAL;
  c.sy := (FBH / 2) - (vup / depth) * FOCAL;
  c.depth := depth;
  Project := true;
end;

{ nearest-texel sample with wrap, V flipped from OBJ to image space }
function SampleTexel(const m: TMesh; u, v: double): byte;
var tx, ty: longint;
begin
  tx := round(u * m.texW);
  ty := round((1.0 - v) * m.texH);
  tx := ((tx mod m.texW) + m.texW) mod m.texW;
  ty := ((ty mod m.texH) + m.texH) mod m.texH;
  SampleTexel := m.tex[ty * m.texW + tx];
end;

{ Affine textured span fill of one screen triangle. }
procedure FillTri(const t: TTri; const m: TMesh; light: double);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x: longint;
  xa, ua, va, xb, ub, vb, tlong, tshort, tx, u, v: double;
  fy0, fy1, fy2: double;
  idx: byte;
  litI: longint;

  procedure Lerp(ay, by, ax, bx, au, bu, av, bv, yy: double; out ox, ou, ov: double);
  var tt: double;
  begin
    if by = ay then tt := 0 else tt := (yy - ay) / (by - ay);
    { clamp so a scanline rounded past an edge cannot extrapolate the
      vertex and fling the span across the screen }
    if tt < 0 then tt := 0 else if tt > 1 then tt := 1;
    ox := ax + (bx - ax) * tt;
    ou := au + (bu - au) * tt;
    ov := av + (bv - av) * tt;
  end;

begin
  p[0] := t.c[0]; p[1] := t.c[1]; p[2] := t.c[2];
  { sort by y ascending }
  if p[1].sy < p[0].sy then begin tmp := p[0]; p[0] := p[1]; p[1] := tmp; end;
  if p[2].sy < p[1].sy then begin tmp := p[1]; p[1] := p[2]; p[2] := tmp; end;
  if p[1].sy < p[0].sy then begin tmp := p[0]; p[0] := p[1]; p[1] := tmp; end;

  fy0 := p[0].sy; fy1 := p[1].sy; fy2 := p[2].sy;
  if fy2 - fy0 < 0.001 then exit;

  litI := round(light);

  iy0 := round(fy0); iy1 := round(fy2);
  if iy0 < 0 then iy0 := 0;
  if iy1 > FBH - 1 then iy1 := FBH - 1;

  for y := iy0 to iy1 do begin
    { long edge p0 -> p2 }
    Lerp(fy0, fy2, p[0].sx, p[2].sx, p[0].u, p[2].u, p[0].v, p[2].v, y, xa, ua, va);
    { active short edge }
    if y < fy1 then begin
      if fy1 - fy0 < 0.001 then continue;
      Lerp(fy0, fy1, p[0].sx, p[1].sx, p[0].u, p[1].u, p[0].v, p[1].v, y, xb, ub, vb);
    end else begin
      if fy2 - fy1 < 0.001 then continue;
      Lerp(fy1, fy2, p[1].sx, p[2].sx, p[1].u, p[2].u, p[1].v, p[2].v, y, xb, ub, vb);
    end;
    if xb < xa then begin
      tx := xa; xa := xb; xb := tx;
      tx := ua; ua := ub; ub := tx;
      tx := va; va := vb; vb := tx;
    end;
    ix0 := round(xa); ix1 := round(xb);
    if ix0 < 0 then ix0 := 0;
    if ix1 > FBW - 1 then ix1 := FBW - 1;
    for x := ix0 to ix1 do begin
      if xb - xa < 0.001 then tx := 0 else tx := (x - xa) / (xb - xa);
      if tx < 0 then tx := 0 else if tx > 1 then tx := 1;
      u := ua + (ub - ua) * tx;
      v := va + (vb - va) * tx;
      idx := SampleTexel(m, u, v);
      if litI >= 256 then
        FB[y * FBW + x] := idx
      else
        FB[y * FBW + x] := Quantize(Shade(Palette[idx], litI));
    end;
  end;
end;

procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double);
var
  i, k, base: longint;
  cmy, smy, lx, ly, wx, wy, wz: double;
  c: array[0 .. 2] of TCorner;
  ok: boolean;
  j, a: longint;
  keyA: double;
  tt: TTri;
  area, minsx, maxsx: double;
begin
  ntris := 0;
  SetLength(tris, Length(m.verts) div 3);
  cmy := cos(myaw); smy := sin(myaw);

  base := 0;
  while base + 2 < Length(m.verts) do begin
    ok := true;
    for k := 0 to 2 do begin
      lx := m.verts[base + k].x * cmy - m.verts[base + k].y * smy;
      ly := m.verts[base + k].x * smy + m.verts[base + k].y * cmy;
      wx := mx + scale * lx;
      wy := my + scale * ly;
      wz := mz + scale * m.verts[base + k].z;
      if not Project(cam, wx, wy, wz, c[k]) then begin ok := false; break; end;
      c[k].u := m.verts[base + k].u;
      c[k].v := m.verts[base + k].v;
    end;
    if ok then begin
      { skip a triangle that projects absurdly wide: a symptom of a
        vertex grazing the near plane, pending real near-plane clipping }
      minsx := c[0].sx; maxsx := c[0].sx;
      if c[1].sx < minsx then minsx := c[1].sx;
      if c[1].sx > maxsx then maxsx := c[1].sx;
      if c[2].sx < minsx then minsx := c[2].sx;
      if c[2].sx > maxsx then maxsx := c[2].sx;
      if maxsx - minsx > 4 * FBW then ok := false;
    end;
    if ok then begin
      { backface cull by the sign of the projected area }
      area := (c[1].sx - c[0].sx) * (c[2].sy - c[0].sy)
            - (c[2].sx - c[0].sx) * (c[1].sy - c[0].sy);
      if area > 0 then begin
        tris[ntris].c[0] := c[0]; tris[ntris].c[1] := c[1]; tris[ntris].c[2] := c[2];
        tris[ntris].key := (c[0].depth + c[1].depth + c[2].depth) / 3.0;
        inc(ntris);
      end;
    end;
    inc(base, 3);
  end;

  { painter's sort: farthest first (insertion sort, meshes are small) }
  for i := 1 to ntris - 1 do begin
    tt := tris[i]; keyA := tt.key; j := i - 1;
    while (j >= 0) and (tris[j].key < keyA) do begin
      tris[j + 1] := tris[j]; dec(j);
    end;
    tris[j + 1] := tt;
  end;

  for a := 0 to ntris - 1 do
    FillTri(tris[a], m, light);
end;

end.
