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
  meshfmt, gfx, pic, fixedpt;

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
  Z. light is a 0..256 shade (256 is full bright). An embedded-texture
  mesh draws from its own texture; a shared-texture mesh (texKind
  TEXKIND_SHARED) draws from the atlas passed in atlas/aw/ah, which the
  caller makes resident. Passing atlas=nil for a shared mesh skips it. }
procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double;
  atlas: PByte = nil; aw: longint = 0; ah: longint = 0;
  emis: PByte = nil; ew: longint = 0; eh: longint = 0);

{ As RenderMeshAt, but with an independent scale per local axis (sx along the
  mesh's own x, sy along y, sz along z), applied before the yaw rotation. Used
  to fit a fixed-size wall piece to a cell-edge run and a sector's height. }
procedure RenderMeshAt3(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, sx, sy, sz, myaw, light: double;
  atlas: PByte = nil; aw: longint = 0; ah: longint = 0;
  emis: PByte = nil; ew: longint = 0; eh: longint = 0);

{ Draw one textured quad given four world-space corners (wound in order)
  and their texture coordinates. tex points at tw*th palette indices.
  The quad is not backface culled; the depth buffer sorts it. An optional
  glow colour mixed in at glowW/256 tints an emissive tile's surface, the
  way the raycaster glows a light-well or brazier floor. }
procedure DrawTexQuad(const cam: TMeshCam;
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double;
  glow: TColor = 0; glowW: longint = 0);

{ Tint one cell's floor with an emissive glow: a flat decal over cell
  (tx,ty) at height z, mixing glow at glowW/256 over whatever is already
  drawn there and shaded by light. For a light tile (brazier, torch,
  biolume) on a kit-clad floor, whose merged native floor piece cannot
  carry a per-cell glow. It reads and tints the framebuffer, is z-tested so
  nearer walls and props occlude it, and leaves the depth buffer untouched
  so it never occludes anything itself. }
procedure DrawFloorGlow(const cam: TMeshCam; tx, ty: longint; z: double;
  glow: TColor; glowW: longint; light: double);

{ Draw a front-facing billboard: a camera-facing quad standing on the floor
  at world (wx,wy), wscale wide and hscale tall in tiles, textured with the
  ARGB image img. Transparent texels are skipped, so the key color shows the
  world behind, and the depth buffer occludes the sprite behind nearer walls
  and sprites. }
procedure DrawSpriteBillboard(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light: double; baseZ: double = 0);

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
  { the depth buffer holds inverse view depth in 16.16 fixed point, so the
    per-pixel span loops compare and store depth without the FPU the DOS and
    PS1 targets lack }
  ZBuf: array[0 .. FBW * FBH - 1] of TFix;

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

{ Affine textured, z-buffered span fill of one screen triangle. An optional
  emission texture (emis, ew by eh, sampled at the same uv as the diffuse) is
  added over the shaded texel, so an emissive surface glows regardless of the
  scene light: black emission texels add nothing, coloured ones glow. }
procedure FillTriTex(const t0, t1, t2: TCorner; tex: PByte; tw, th: longint;
  light: double; glow: TColor = 0; glowW: longint = 0;
  emis: PByte = nil; ew: longint = 0; eh: longint = 0);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x, fbo: longint;
  xa, ua, va, za, xb, ub, vb, zb, tx: double;
  spanw, du, dv, dz, tstart: double;
  uf, vf, zf, duf, dvf, dzf: TFix;
  fy0, fy1, fy2: double;
  litI, tsx, tsy, esx, esy: longint;
  idx: byte;
  glowS, c, ec: TColor;
  hasEmis: boolean;

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
  hasEmis := (emis <> nil) and (ew > 0) and (eh > 0);
  if glowW > 0 then glowS := Shade(glow, litI);   { tint, shaded like the tile }
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
    { set the span's fixed-point interpolants once, then step them per pixel
      with adds, so the inner loop needs no float for the FPU-less targets }
    spanw := xb - xa;
    if spanw < 0.001 then begin
      du := 0; dv := 0; dz := 0; tstart := 0;
    end else begin
      du := (ub - ua) / spanw; dv := (vb - va) / spanw; dz := (zb - za) / spanw;
      tstart := ix0 - xa;
    end;
    uf := FixF(ua + du * tstart); vf := FixF(va + dv * tstart); zf := FixF(za + dz * tstart);
    duf := FixF(du); dvf := FixF(dv); dzf := FixF(dz);
    for x := ix0 to ix1 do begin
      if zf > ZBuf[fbo + x] then begin   { nearer than what stands here }
        { +FONE biases the coordinate up by one whole texture before the shift,
          which a wrap leaves unchanged, so the shift always acts on a positive
          value and the lone mod wraps it into the page }
        tsx := (((int64(uf) + FONE) * tw + FHALF) shr FBITS) mod tw;
        tsy := (((int64(FONE - vf) + FONE) * th + FHALF) shr FBITS) mod th;
        idx := tex[tsy * tw + tsx];
        ZBuf[fbo + x] := zf;
        if (glowW > 0) or hasEmis then begin
          if litI >= 256 then c := Palette[idx] else c := Shade(Palette[idx], litI);
          if glowW > 0 then c := MixColor(c, glowS, glowW);
          if hasEmis then begin
            esx := (((int64(uf) + FONE) * ew + FHALF) shr FBITS) mod ew;
            esy := (((int64(FONE - vf) + FONE) * eh + FHALF) shr FBITS) mod eh;
            { the emission atlas holds the emitted colour; add it full-bright so
              the surface glows in those colours regardless of scene light, with
              black texels adding nothing }
            ec := Palette[emis[esy * ew + esx]];
            if (ec and $00FFFFFF) <> 0 then c := AddColor(c, ec);
          end;
          FB[fbo + x] := DitherQuant(c, x, y);
        end else if litI >= 256 then
          FB[fbo + x] := idx
        else
          FB[fbo + x] := DitherQuant(Shade(Palette[idx], litI), x, y);
      end;
      inc(uf, duf); inc(vf, dvf); inc(zf, dzf);
    end;
  end;
end;

procedure DrawTexQuad(const cam: TMeshCam;
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double;
  glow: TColor = 0; glowW: longint = 0);
var
  c0, c1, c2, c3: TCorner;
begin
  if not Project(cam, x0, y0, z0, c0) then exit;
  if not Project(cam, x1, y1, z1, c1) then exit;
  if not Project(cam, x2, y2, z2, c2) then exit;
  if not Project(cam, x3, y3, z3, c3) then exit;
  c0.u := u0; c0.v := v0; c1.u := u1; c1.v := v1;
  c2.u := u2; c2.v := v2; c3.u := u3; c3.v := v3;
  FillTriTex(c0, c1, c2, tex, tw, th, light, glow, glowW);
  FillTriTex(c0, c2, c3, tex, tw, th, light, glow, glowW);
end;

{ Span fill of one screen triangle that tints the framebuffer toward glowS
  at glowW/256, instead of drawing a texture. It interpolates only screen x
  and inverse depth, reads the pixel already there, mixes, and writes back.
  The depth test passes where the decal is at or nearer than what stands
  there, and the depth buffer is left unchanged. }
procedure FillTriGlow(const t0, t1, t2: TCorner; glowS: TColor; glowW: longint);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x, fbo: longint;
  xa, za, xb, zb, tx: double;
  spanw, dz, tstart: double;
  zf, dzf: TFix;
  fy0, fy1, fy2: double;
  c: TColor;

  procedure Edge(ay, by, ax, bx, az, bz, yy: double; out ox, oz: double);
  var tt: double;
  begin
    if by = ay then tt := 0 else tt := (yy - ay) / (by - ay);
    if tt < 0 then tt := 0 else if tt > 1 then tt := 1;
    ox := ax + (bx - ax) * tt;
    oz := az + (bz - az) * tt;
  end;

begin
  p[0] := t0; p[1] := t1; p[2] := t2;
  if p[1].sy < p[0].sy then begin tmp := p[0]; p[0] := p[1]; p[1] := tmp; end;
  if p[2].sy < p[1].sy then begin tmp := p[1]; p[1] := p[2]; p[2] := tmp; end;
  if p[1].sy < p[0].sy then begin tmp := p[0]; p[0] := p[1]; p[1] := tmp; end;

  fy0 := p[0].sy; fy1 := p[1].sy; fy2 := p[2].sy;
  if fy2 - fy0 < 0.001 then exit;
  if glowW <= 0 then exit;

  iy0 := round(fy0); iy1 := round(fy2);
  if iy0 < 0 then iy0 := 0;
  if iy1 > FBH - 1 then iy1 := FBH - 1;

  for y := iy0 to iy1 do begin
    Edge(fy0, fy2, p[0].sx, p[2].sx, p[0].iz, p[2].iz, y, xa, za);
    if y < fy1 then begin
      if fy1 - fy0 < 0.001 then continue;
      Edge(fy0, fy1, p[0].sx, p[1].sx, p[0].iz, p[1].iz, y, xb, zb);
    end else begin
      if fy2 - fy1 < 0.001 then continue;
      Edge(fy1, fy2, p[1].sx, p[2].sx, p[1].iz, p[2].iz, y, xb, zb);
    end;
    if xb < xa then begin
      tx := xa; xa := xb; xb := tx;
      tx := za; za := zb; zb := tx;
    end;
    ix0 := round(xa); ix1 := round(xb);
    if ix0 < 0 then ix0 := 0;
    if ix1 > FBW - 1 then ix1 := FBW - 1;
    fbo := y * FBW;
    spanw := xb - xa;
    if spanw < 0.001 then begin dz := 0; tstart := 0; end
    else begin dz := (zb - za) / spanw; tstart := ix0 - xa; end;
    zf := FixF(za + dz * tstart);
    dzf := FixF(dz);
    for x := ix0 to ix1 do begin
      if zf >= ZBuf[fbo + x] then begin   { on, or nearer than, the floor here }
        c := MixColor(Palette[FB[fbo + x]], glowS, glowW);
        FB[fbo + x] := DitherQuant(c, x, y);
      end;
      inc(zf, dzf);
    end;
  end;
end;

procedure DrawFloorGlow(const cam: TMeshCam; tx, ty: longint; z: double;
  glow: TColor; glowW: longint; light: double);
const
  { lift the decal a hair above the floor so it beats the kit floor mesh's
    own depth without reaching a wall riser, which is at least a half unit }
  GLOW_LIFT = 0.05;
var
  c0, c1, c2, c3: TCorner;
  zz: double;
  glowS: TColor;
begin
  if glowW <= 0 then exit;
  zz := z + GLOW_LIFT;
  if not Project(cam, tx, ty, zz, c0) then exit;
  if not Project(cam, tx + 1, ty, zz, c1) then exit;
  if not Project(cam, tx + 1, ty + 1, zz, c2) then exit;
  if not Project(cam, tx, ty + 1, zz, c3) then exit;
  glowS := Shade(glow, round(light));   { the glow dims with distance like the floor }
  FillTriGlow(c0, c1, c2, glowS, glowW);
  FillTriGlow(c0, c2, c3, glowS, glowW);
end;

{ Affine z-buffered span fill of one screen triangle from an ARGB image,
  skipping transparent texels. Mirrors FillTriTex but alpha tests and
  samples a 32-bit image rather than a palette page. }
procedure FillTriSpr(const t0, t1, t2: TCorner; pix: PLongWord; tw, th: longint; light: double);
var
  p: array[0 .. 2] of TCorner;
  tmp: TCorner;
  y, iy0, iy1, ix0, ix1, x, fbo: longint;
  xa, ua, va, za, xb, ub, vb, zb, tx: double;
  spanw, du, dv, dz, tstart: double;
  uf, vf, zf, duf, dvf, dzf, uu, vv: TFix;
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
    spanw := xb - xa;
    if spanw < 0.001 then begin
      du := 0; dv := 0; dz := 0; tstart := 0;
    end else begin
      du := (ub - ua) / spanw; dv := (vb - va) / spanw; dz := (zb - za) / spanw;
      tstart := ix0 - xa;
    end;
    uf := FixF(ua + du * tstart); vf := FixF(va + dv * tstart); zf := FixF(za + dz * tstart);
    duf := FixF(du); dvf := FixF(dv); dzf := FixF(dz);
    for x := ix0 to ix1 do begin
      if zf > ZBuf[fbo + x] then begin   { nearer than what stands here }
        { a sprite does not tile, so clamp the coordinate into [0,1] before the
          shift, which keeps it positive and holds the edge texel }
        uu := uf; if uu < 0 then uu := 0 else if uu > FONE then uu := FONE;
        vv := FONE - vf; if vv < 0 then vv := 0 else if vv > FONE then vv := FONE;
        tsx := (int64(uu) * tw + FHALF) shr FBITS;
        tsy := (int64(vv) * th + FHALF) shr FBITS;
        if tsx > tw - 1 then tsx := tw - 1;
        if tsy > th - 1 then tsy := th - 1;
        src := pix[tsy * tw + tsx];
        if (src shr 24) >= 128 then begin   { opaque texel: it shows and occludes }
          ZBuf[fbo + x] := zf;
          if litI >= 256 then
            FB[fbo + x] := Quantize(src)
          else
            FB[fbo + x] := DitherQuant(Shade(src, litI), x, y);
        end;
      end;
      inc(uf, duf); inc(vf, dvf); inc(zf, dzf);
    end;
  end;
end;

procedure DrawSpriteBillboard(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light: double; baseZ: double = 0);
const
  { A billboard shares the floor's depth buffer, and its base is coplanar with
    the floor of the tile it stands on, so at distance the floor wins the
    z-test and eats the sprite's lower body. Bias the sprite's depth toward the
    camera by part of a tile, less than one so a wall in front still occludes
    it, enough to win the fight with its own floor. The screen position and
    size stay as projected; only the z-buffer depth shifts. }
  DEPTH_BIAS = 0.45;
var
  rx, ry, hw, d: double;
  c: array[0 .. 3] of TCorner;
  k: longint;
  ok: boolean;
begin
  if Length(img.pix) = 0 then exit;
  { camera right vector in the world XY plane, so the quad faces the eye }
  rx := sin(cam.yaw); ry := -cos(cam.yaw);
  hw := wscale * 0.5;
  ok := Project(cam, wx - rx * hw, wy - ry * hw, baseZ,           c[0]);  { bottom left }
  ok := ok and Project(cam, wx + rx * hw, wy + ry * hw, baseZ,          c[1]);  { bottom right }
  ok := ok and Project(cam, wx + rx * hw, wy + ry * hw, baseZ + hscale, c[2]);  { top right }
  ok := ok and Project(cam, wx - rx * hw, wy - ry * hw, baseZ + hscale, c[3]);  { top left }
  if not ok then exit;
  { pull each corner's depth toward the camera for the z-test only }
  for k := 0 to 3 do begin
    d := 1.0 / c[k].iz - DEPTH_BIAS;
    if d < NEAR then d := NEAR;
    c[k].iz := 1.0 / d;
  end;
  c[0].u := 0; c[0].v := 0;
  c[1].u := 1; c[1].v := 0;
  c[2].u := 1; c[2].v := 1;
  c[3].u := 0; c[3].v := 1;
  FillTriSpr(c[0], c[1], c[2], @img.pix[0], img.w, img.h, light);
  FillTriSpr(c[0], c[2], c[3], @img.pix[0], img.w, img.h, light);
end;

procedure RenderMeshAt(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, scale, myaw, light: double;
  atlas: PByte = nil; aw: longint = 0; ah: longint = 0;
  emis: PByte = nil; ew: longint = 0; eh: longint = 0);
var
  base, k: longint;
  cmy, smy, lx, ly, wx, wy, wz, area: double;
  c: array[0 .. 2] of TCorner;
  ok: boolean;
  tex: PByte;
  tw, th: longint;
begin
  { choose the texture source: the mesh's own, or the shared atlas }
  if m.texKind = TEXKIND_SHARED then begin
    if (atlas = nil) or (aw <= 0) or (ah <= 0) then exit;
    tex := atlas; tw := aw; th := ah;
  end else begin
    if Length(m.tex) = 0 then exit;
    tex := @m.tex[0]; tw := m.texW; th := m.texH;
  end;
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
        FillTriTex(c[0], c[1], c[2], tex, tw, th, light, 0, 0, emis, ew, eh);
    end;
    inc(base, 3);
  end;
end;

procedure RenderMeshAt3(const m: TMesh; const cam: TMeshCam;
  mx, my, mz, sx, sy, sz, myaw, light: double;
  atlas: PByte = nil; aw: longint = 0; ah: longint = 0;
  emis: PByte = nil; ew: longint = 0; eh: longint = 0);
var
  base, k: longint;
  cmy, smy, px, py, lx, ly, wx, wy, wz, area: double;
  c: array[0 .. 2] of TCorner;
  ok: boolean;
  tex: PByte;
  tw, th: longint;
begin
  if m.texKind = TEXKIND_SHARED then begin
    if (atlas = nil) or (aw <= 0) or (ah <= 0) then exit;
    tex := atlas; tw := aw; th := ah;
  end else begin
    if Length(m.tex) = 0 then exit;
    tex := @m.tex[0]; tw := m.texW; th := m.texH;
  end;
  cmy := cos(myaw); smy := sin(myaw);
  base := 0;
  while base + 2 < Length(m.verts) do begin
    ok := true;
    for k := 0 to 2 do begin
      { scale in the mesh's own frame, then rotate about Z and place }
      px := m.verts[base + k].x * sx;
      py := m.verts[base + k].y * sy;
      lx := px * cmy - py * smy;
      ly := px * smy + py * cmy;
      wx := mx + lx;
      wy := my + ly;
      wz := mz + sz * m.verts[base + k].z;
      if not Project(cam, wx, wy, wz, c[k]) then begin ok := false; break; end;
      c[k].u := m.verts[base + k].u;
      c[k].v := m.verts[base + k].v;
    end;
    if ok then begin
      area := (c[1].sx - c[0].sx) * (c[2].sy - c[0].sy)
            - (c[2].sx - c[0].sx) * (c[1].sy - c[0].sy);
      if area > 0 then
        FillTriTex(c[0], c[1], c[2], tex, tw, th, light, 0, 0, emis, ew, eh);
    end;
    inc(base, 3);
  end;
end;

end.
