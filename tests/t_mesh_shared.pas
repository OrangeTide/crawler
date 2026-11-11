program t_mesh_shared;

{** The CMSH mesh codec, shared and embedded texture kinds.

  A shared-texture tile ships no texture: its UVs index a trim atlas the
  renderer supplies. An embedded mesh ships its own texture, the prop
  case. Confirm each round-trips through EncodeMesh/DecodeMesh with its
  kind, geometry, and texture intact, and that a shared mesh carries no
  texture bytes on disk. }

{$mode objfpc}{$H+}

uses
  meshfmt, testing;

{ Build a one-triangle mesh with distinct positions and UVs. }
procedure MakeTri(out m: TMesh);
begin
  SetLength(m.verts, 3);
  m.verts[0].x := 0; m.verts[0].y := 0; m.verts[0].z := 0;
  m.verts[0].u := 0.10; m.verts[0].v := 0.20;
  m.verts[1].x := 1; m.verts[1].y := 0; m.verts[1].z := 0;
  m.verts[1].u := 0.80; m.verts[1].v := 0.25;
  m.verts[2].x := 1; m.verts[2].y := 2; m.verts[2].z := 3;
  m.verts[2].u := 0.55; m.verts[2].v := 0.90;
end;

function VertsMatch(const a, b: TMesh): boolean;
var i: longint;
begin
  VertsMatch := false;
  if Length(a.verts) <> Length(b.verts) then exit;
  for i := 0 to High(a.verts) do
    if (a.verts[i].x <> b.verts[i].x) or (a.verts[i].y <> b.verts[i].y)
      or (a.verts[i].z <> b.verts[i].z) or (a.verts[i].u <> b.verts[i].u)
      or (a.verts[i].v <> b.verts[i].v) then exit;
  VertsMatch := true;
end;

{ Build a two-triangle shared mesh with a material per triangle. }
procedure MakeTwoMat(out m: TMesh);
var i: longint;
begin
  SetLength(m.verts, 6);
  for i := 0 to 5 do begin
    m.verts[i].x := i; m.verts[i].y := i * 2; m.verts[i].z := i * 3;
    m.verts[i].u := i / 8; m.verts[i].v := i / 4;
  end;
  m.texKind := TEXKIND_SHARED;
  m.texW := 0; m.texH := 0; m.tex := nil;
  SetLength(m.mat, 2);
  m.mat[0] := 0; m.mat[1] := 1;
end;

var
  m, back: TMesh;
  blob: TByteArray;
  sharedLen, embedLen, i: longint;
begin
  { --- shared-texture tile --- }
  MakeTri(m);
  m.texKind := TEXKIND_SHARED;
  m.texW := 0; m.texH := 0; m.tex := nil;
  blob := EncodeMesh(m);
  sharedLen := Length(blob);
  Check(DecodeMesh(blob, back), 'shared mesh decodes');
  Check(back.texKind = TEXKIND_SHARED, 'shared kind survives');
  Check(VertsMatch(m, back), 'shared geometry and UVs survive');
  CheckEqI(Length(back.tex), 0, 'shared mesh carries no texture bytes');
  CheckEqI(back.texW, 0, 'shared texW is zero');

  { --- embedded-texture prop --- }
  MakeTri(m);
  m.texKind := TEXKIND_EMBED;
  m.texW := 2; m.texH := 2;
  SetLength(m.tex, 4);
  for i := 0 to 3 do m.tex[i] := byte(10 + i);
  blob := EncodeMesh(m);
  embedLen := Length(blob);
  Check(DecodeMesh(blob, back), 'embedded mesh decodes');
  Check(back.texKind = TEXKIND_EMBED, 'embedded kind survives');
  Check(VertsMatch(m, back), 'embedded geometry and UVs survive');
  CheckEqI(Length(back.tex), 4, 'embedded texture bytes survive');
  Check((back.tex[0] = 10) and (back.tex[3] = 13), 'embedded texels are intact');
  CheckEqI(back.texW, 2, 'embedded texW survives');

  { the shared lump is smaller by exactly its absent texture bytes }
  CheckEqI(embedLen - sharedLen, 4, 'shared lump omits the texture bytes');

  { --- single-material mesh reports one material and carries no mat bytes --- }
  MakeTri(m);
  m.texKind := TEXKIND_SHARED; m.texW := 0; m.texH := 0; m.tex := nil;
  m.mat := nil;
  CheckEqI(MeshMatCount(m), 1, 'a mesh with no mat bytes is single-material');
  blob := EncodeMesh(m);
  Check(DecodeMesh(blob, back), 'single-material mesh decodes');
  CheckEqI(Length(back.mat), 0, 'single-material mesh carries no mat bytes');

  { --- multi-material mesh: the per-triangle materials round-trip --- }
  MakeTwoMat(m);
  CheckEqI(MeshMatCount(m), 2, 'two materials across the triangles');
  blob := EncodeMesh(m);
  Check(DecodeMesh(blob, back), 'multi-material mesh decodes');
  CheckEqI(Length(back.mat), 2, 'both triangle materials survive');
  Check((back.mat[0] = 0) and (back.mat[1] = 1), 'the materials are intact');
  CheckEqI(MeshMatCount(back), 2, 'the decoded count is two');

  TestSummary('mesh_shared');
  halt(TestExit);
end.
