unit raster;

{** A small fixed-function polygon rasterizer, PSX style.

  Triangles are transformed into view space, projected, and filled with
  affine (not perspective correct) texture mapping, the classic PSX
  texture warp. A per-pixel depth buffer resolves occlusion, so faces may
  be drawn in any order. The target is the shared 8-bit framebuffer, so a
  texel is already a palette index.

  The math is double precision for now. The hot path converts to fixed
  point later, the same way the raycaster did, once the look is settled. }

{$mode objfpc}{$H+}

interface

uses
  meshfmt, gfx, pic;

type
  TMeshCam = record
    x, y, z: double;      { eye position in world space, Z up }
    yaw: double;          { heading, 0 looks along +X }
    pitch: double;        { look up and down, radians }
  end;

{ The screen point a view projects around. Defaults to the screen center;
  combat sets it per foe to place each model in its own slot. }
var
  RasterCX: double = FBW / 2;
  RasterCY: double = FBH / 2;

{ Clear the depth buffer; call once per frame before drawing. }
procedure RasterBeginFrame;

{ Draw a mesh placed at (mx,my,mz), uniformly scaled, rotated myaw about
  Z. light is a 0..256 shade (256 is full bright). }
procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double);

{ Draw one textured quad given four world-space corners (wound in order)
  and their texture coordinates. tex points at tw*th palette indices.
  The quad is not backface culled; the depth buffer sorts it. }
procedure DrawTexQuad(const cam: TMeshCam;
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double);

{ Draw a front-facing billboard: a camera-facing quad standing on the floor
  at world (wx,wy), wscale wide and hscale tall in tiles, textured with the
  ARGB image img. Transparent texels are skipped, so the key color shows the
  world behind, and the depth buffer occludes the sprite behind nearer walls
  and sprites. }
procedure DrawSpriteBillboard(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light: double);

implementation

const
  NEAR  = 0.05;
  FOCAL = (FBW / 2) / 0.66;   { matches the raycaster field of view }
  { PSX vertex snap: project to a coarse screen grid so vertices wobble the way
    the PlayStation's integer GTE output did. 1 snaps to whole pixels, 2 to
    half pixels. Shared world corners snap alike, so adjacent faces stay seamed.}
  VSNAP = 1.0;

type
  TCorner = record
    sx, sy: double;    { screen position }
    u, v: double;      { texture coordinate }
    iz: double;        { inverse view depth, for the z buffer }
  end;

var
  ZBuf: array[0 .. FBW * FBH - 1] of single;

procedure RasterBeginFrame;
var i: longint;
begin
  for i := 0 to FBW * FBH - 1 do ZBuf[i] := 0;   { 0 is infinitely far }
end;

{ Transform and project one world point; false if behind the near plane. }
function Project(const cam: TMeshCam; wx, wy, wz: double; out c: TCorner): boolean;
var
  dx, dy, dz, fwd, side, up, depth, vup, cyw, syw, cp, sp: double;
begin
  Project := false;
  dx := wx - cam.x; dy := wy - cam.y; dz := wz - cam.z;
  cyw := cos(cam.yaw); syw := sin(cam.yaw);
  fwd := dx * cyw + dy * syw;
  side := -dx * syw + dy * cyw;
  up := dz;
  cp := cos(cam.pitch); sp := sin(cam.pitch);
  depth := fwd * cp + up * sp;
  vup := -fwd * sp + up * cp;
  if depth <= NEAR then exit;
  c.sx := RasterCX + (side / depth) * FOCAL;
  c.sy := RasterCY - (vup / depth) * FOCAL;
  if VSNAP > 0 then begin
    c.sx := round(c.sx * VSNAP) / VSNAP;
    c.sy := round(c.sy * VSNAP) / VSNAP;
  end;
  c.iz := 1.0 / depth;
  Project := true;
end;

{ Affine textured, z-buffered span fill of one screen triangle. }
procedure FillTriTex(const t0, t1, t2: TCorner; tex: PByte; tw, th: longint; light: double);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x, fbo: longint;
  xa, ua, va, za, xb, ub, vb, zb, tx, u, v, z: double;
  fy0, fy1, fy2: double;
  litI, tsx, tsy: longint;
  idx: byte;

  procedure Edge(ay, by, ax, bx, au, bu, av, bv, az, bz, yy: double;
    out ox, ou, ov, oz: double);
  var tt: double;
  begin
    if by = ay then tt := 0 else tt := (yy - ay) / (by - ay);
    if tt < 0 then tt := 0 else if tt > 1 then tt := 1;
    ox := ax + (bx - ax) * tt;
    ou := au + (bu - au) * tt;
    ov := av + (bv - av) * tt;
    oz := az + (bz - az) * tt;
  end;

begin
  p[0] := t0; p[1] := t1; p[2] := t2;
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
    Edge(fy0, fy2, p[0].sx, p[2].sx, p[0].u, p[2].u, p[0].v, p[2].v,
      p[0].iz, p[2].iz, y, xa, ua, va, za);
    if y < fy1 then begin
      if fy1 - fy0 < 0.001 then continue;
      Edge(fy0, fy1, p[0].sx, p[1].sx, p[0].u, p[1].u, p[0].v, p[1].v,
        p[0].iz, p[1].iz, y, xb, ub, vb, zb);
    end else begin
      if fy2 - fy1 < 0.001 then continue;
      Edge(fy1, fy2, p[1].sx, p[2].sx, p[1].u, p[2].u, p[1].v, p[2].v,
        p[1].iz, p[2].iz, y, xb, ub, vb, zb);
    end;
    if xb < xa then begin
      tx := xa; xa := xb; xb := tx;
      tx := ua; ua := ub; ub := tx;
      tx := va; va := vb; vb := tx;
      tx := za; za := zb; zb := tx;
    end;
    ix0 := round(xa); ix1 := round(xb);
    if ix0 < 0 then ix0 := 0;
    if ix1 > FBW - 1 then ix1 := FBW - 1;
    fbo := y * FBW;
    for x := ix0 to ix1 do begin
      if xb - xa < 0.001 then tx := 0 else tx := (x - xa) / (xb - xa);
      if tx < 0 then tx := 0 else if tx > 1 then tx := 1;
      z := za + (zb - za) * tx;
      if z <= ZBuf[fbo + x] then continue;   { something nearer is here }
      u := ua + (ub - ua) * tx;
      v := va + (vb - va) * tx;
      tsx := round(u * tw); tsy := round((1.0 - v) * th);
      tsx := ((tsx mod tw) + tw) mod tw;
      tsy := ((tsy mod th) + th) mod th;
      idx := tex[tsy * tw + tsx];
      ZBuf[fbo + x] := z;
      if litI >= 256 then
        FB[fbo + x] := idx
      else
        FB[fbo + x] := DitherQuant(Shade(Palette[idx], litI), x, y);
    end;
  end;
end;

procedure DrawTexQuad(const cam: TMeshCam;
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double);
var
  c0, c1, c2, c3: TCorner;
begin
  if not Project(cam, x0, y0, z0, c0) then exit;
  if not Project(cam, x1, y1, z1, c1) then exit;
  if not Project(cam, x2, y2, z2, c2) then exit;
  if not Project(cam, x3, y3, z3, c3) then exit;
  c0.u := u0; c0.v := v0; c1.u := u1; c1.v := v1;
  c2.u := u2; c2.v := v2; c3.u := u3; c3.v := v3;
  FillTriTex(c0, c1, c2, tex, tw, th, light);
  FillTriTex(c0, c2, c3, tex, tw, th, light);
end;

{ Affine z-buffered span fill of one screen triangle from an ARGB image,
  skipping transparent texels. Mirrors FillTriTex but alpha tests and
  samples a 32-bit image rather than a palette page. }
procedure FillTriSpr(const t0, t1, t2: TCorner; pix: PLongWord; tw, th: longint; light: double);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x, fbo: longint;
  xa, ua, va, za, xb, ub, vb, zb, tx, u, v, z: double;
  fy0, fy1, fy2: double;
  litI, tsx, tsy: longint;
  src: TColor;

  procedure Edge(ay, by, ax, bx, au, bu, av, bv, az, bz, yy: double;
    out ox, ou, ov, oz: double);
  var tt: double;
  begin
    if by = ay then tt := 0 else tt := (yy - ay) / (by - ay);
    if tt < 0 then tt := 0 else if tt > 1 then tt := 1;
    ox := ax + (bx - ax) * tt;
    ou := au + (bu - au) * tt;
    ov := av + (bv - av) * tt;
    oz := az + (bz - az) * tt;
  end;

begin
  p[0] := t0; p[1] := t1; p[2] := t2;
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
    Edge(fy0, fy2, p[0].sx, p[2].sx, p[0].u, p[2].u, p[0].v, p[2].v,
      p[0].iz, p[2].iz, y, xa, ua, va, za);
    if y < fy1 then begin
      if fy1 - fy0 < 0.001 then continue;
      Edge(fy0, fy1, p[0].sx, p[1].sx, p[0].u, p[1].u, p[0].v, p[1].v,
        p[0].iz, p[1].iz, y, xb, ub, vb, zb);
    end else begin
      if fy2 - fy1 < 0.001 then continue;
      Edge(fy1, fy2, p[1].sx, p[2].sx, p[1].u, p[2].u, p[1].v, p[2].v,
        p[1].iz, p[2].iz, y, xb, ub, vb, zb);
    end;
    if xb < xa then begin
      tx := xa; xa := xb; xb := tx;
      tx := ua; ua := ub; ub := tx;
      tx := va; va := vb; vb := tx;
      tx := za; za := zb; zb := tx;
    end;
    ix0 := round(xa); ix1 := round(xb);
    if ix0 < 0 then ix0 := 0;
    if ix1 > FBW - 1 then ix1 := FBW - 1;
    fbo := y * FBW;
    for x := ix0 to ix1 do begin
      if xb - xa < 0.001 then tx := 0 else tx := (x - xa) / (xb - xa);
      if tx < 0 then tx := 0 else if tx > 1 then tx := 1;
      z := za + (zb - za) * tx;
      if z <= ZBuf[fbo + x] then continue;   { something nearer is here }
      u := ua + (ub - ua) * tx;
      v := va + (vb - va) * tx;
      tsx := round(u * tw); tsy := round((1.0 - v) * th);
      if tsx < 0 then tsx := 0 else if tsx > tw - 1 then tsx := tw - 1;
      if tsy < 0 then tsy := 0 else if tsy > th - 1 then tsy := th - 1;
      src := pix[tsy * tw + tsx];
      if (src shr 24) < 128 then continue;   { transparent texel }
      ZBuf[fbo + x] := z;
      if litI >= 256 then
        FB[fbo + x] := Quantize(src)
      else
        FB[fbo + x] := DitherQuant(Shade(src, litI), x, y);
    end;
  end;
end;

procedure DrawSpriteBillboard(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light: double);
var
  rx, ry, hw: double;
  c: array[0 .. 3] of TCorner;
  ok: boolean;
begin
  if Length(img.pix) = 0 then exit;
  { camera right vector in the world XY plane, so the quad faces the eye }
  rx := sin(cam.yaw); ry := -cos(cam.yaw);
  hw := wscale * 0.5;
  ok := Project(cam, wx - rx * hw, wy - ry * hw, 0,      c[0]);      { bottom left }
  ok := ok and Project(cam, wx + rx * hw, wy + ry * hw, 0,      c[1]);  { bottom right }
  ok := ok and Project(cam, wx + rx * hw, wy + ry * hw, hscale, c[2]);  { top right }
  ok := ok and Project(cam, wx - rx * hw, wy - ry * hw, hscale, c[3]);  { top left }
  if not ok then exit;
  c[0].u := 0; c[0].v := 0;
  c[1].u := 1; c[1].v := 0;
  c[2].u := 1; c[2].v := 1;
  c[3].u := 0; c[3].v := 1;
  FillTriSpr(c[0], c[1], c[2], @img.pix[0], img.w, img.h, light);
  FillTriSpr(c[0], c[2], c[3], @img.pix[0], img.w, img.h, light);
end;

procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double);
var
  base, k: longint;
  cmy, smy, lx, ly, wx, wy, wz, area: double;
  c: array[0 .. 2] of TCorner;
  ok: boolean;
begin
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
      area := (c[1].sx - c[0].sx) * (c[2].sy - c[0].sy)
            - (c[2].sx - c[0].sx) * (c[1].sy - c[0].sy);
      if area > 0 then
        FillTriTex(c[0], c[1], c[2], @m.tex[0], m.texW, m.texH, light);
    end;
    inc(base, 3);
  end;
end;

end.
