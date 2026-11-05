program meshshot;

{** Render a baked mesh to a PPM, headless, to check the rasterizer.

  Usage: meshshot <in.cmsh> <out.ppm> [yawDegrees]

  Frames the model from its bounding box, rotates it for a three-quarter
  view, and writes the framebuffer out as a binary PPM. }

{$mode objfpc}{$H+}

uses
  sysutils, classes, pak, gfx, meshfmt, raster;

var
  m: TMesh;
  blob: TByteArray;
  fs: TFileStream;
  i, len: longint;
  cam: TMeshCam;
  minx, miny, minz, maxx, maxy, maxz, cx, cy, cz, radius, d: double;
  yaw: double;
  outppm: array of byte;
  c: TColor;
  hdr: string;
begin
  if ParamCount < 2 then begin
    writeln(StdErr, 'usage: meshshot <in.cmsh> <out.ppm> [yawDeg]');
    halt(2);
  end;
  InitGfx;

  fs := TFileStream.Create(ParamStr(1), fmOpenRead);
  try
    len := fs.Size; SetLength(blob, len);
    if len > 0 then fs.ReadBuffer(blob[0], len);
  finally
    fs.Free;
  end;
  if not DecodeMesh(blob, m) then begin
    writeln(StdErr, 'meshshot: bad mesh ', ParamStr(1)); halt(1);
  end;

  { bounds }
  minx := 1e30; miny := 1e30; minz := 1e30;
  maxx := -1e30; maxy := -1e30; maxz := -1e30;
  for i := 0 to High(m.verts) do begin
    if m.verts[i].x < minx then minx := m.verts[i].x;
    if m.verts[i].y < miny then miny := m.verts[i].y;
    if m.verts[i].z < minz then minz := m.verts[i].z;
    if m.verts[i].x > maxx then maxx := m.verts[i].x;
    if m.verts[i].y > maxy then maxy := m.verts[i].y;
    if m.verts[i].z > maxz then maxz := m.verts[i].z;
  end;
  cx := (minx + maxx) / 2; cy := (miny + maxy) / 2; cz := (minz + maxz) / 2;
  radius := maxx - minx;
  if maxy - miny > radius then radius := maxy - miny;
  if maxz - minz > radius then radius := maxz - minz;
  if radius < 0.001 then radius := 1;

  yaw := 0.6;
  if ParamCount >= 3 then yaw := StrToFloatDef(ParamStr(3), 34) * Pi / 180;

  { the baker already centers the model on its base at z=0 }
  d := radius * 2.4;
  cam.x := -d; cam.y := 0; cam.z := radius * 0.55;
  cam.yaw := 0;
  cam.pitch := -0.18;

  ClearFB(RGB(28, 24, 34));
  { spin it for a three-quarter look }
  RenderMeshAt(m, cam, 0, 0, 0, 1.0, yaw, 256);

  { framebuffer indices out to a binary PPM }
  SetLength(outppm, FBW * FBH * 3);
  for i := 0 to FBW * FBH - 1 do begin
    c := Palette[FB[i]];
    outppm[i * 3]     := (c shr 16) and $FF;
    outppm[i * 3 + 1] := (c shr 8) and $FF;
    outppm[i * 3 + 2] := c and $FF;
  end;
  fs := TFileStream.Create(ParamStr(2), fmCreate);
  try
    hdr := Format('P6'#10'%d %d'#10'255'#10, [FBW, FBH]);
    fs.WriteBuffer(hdr[1], Length(hdr));
    fs.WriteBuffer(outppm[0], Length(outppm));
  finally
    fs.Free;
  end;
  writeln('  wrote ', ParamStr(2), ' (', Length(m.verts) div 3, ' tris)');
end.
