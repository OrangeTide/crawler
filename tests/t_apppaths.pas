program t_apppaths;

{** Relocatable file location: the asset search, the user data directory,
  and the portable override. The test drops probe files next to its own
  binary (that directory is writable in the build tree) to drive the exe
  relative branches directly, and cleans them up. }

{$mode objfpc}{$H+}

uses
  sysutils, apppaths, testing;

procedure Touch(const fn: string);
var
  f: text;
begin
  Assign(f, fn);
  Rewrite(f);
  writeln(f, 'probe');
  Close(f);
end;

function StartsWith(const whole, prefix: string): boolean;
begin
  StartsWith := Copy(whole, 1, Length(prefix)) = prefix;
end;

var
  dir, probe, got, udir, uf, marker: string;
begin
  dir := ExeDir;
  Check(dir <> '', 'ExeDir is not empty');
  Check(dir[Length(dir)] = PathDelim, 'ExeDir ends with a path separator');
  Check(DirectoryExists(dir), 'ExeDir names a real directory');

  { an asset beside the binary resolves to that copy }
  probe := dir + '_probe_asset.dat';
  Touch(probe);
  got := AssetPath('_probe_asset.dat');
  Check(got <> '', 'an asset beside the binary is found');
  Check(FileExists(got), 'the found asset path exists on disk');
  Check(StartsWith(got, dir), 'it resolves to the copy next to the binary');
  DeleteFile(probe);

  { a missing asset returns empty, not a bogus path }
  Check(AssetPath('_absent_zzzzz.dat') = '', 'a missing asset returns empty');

  { the dev-tree fallback still finds the real pak from the project root }
  got := AssetPath('game.pak');
  Check(got <> '', 'game.pak is located through the search list');
  Check(FileExists(got), 'the located pak exists on disk');

  { the user data directory is writable and round-trips a file }
  udir := UserDataDir;
  Check(udir <> '', 'UserDataDir is not empty');
  Check(udir[Length(udir)] = PathDelim, 'UserDataDir ends with a separator');
  Check(DirectoryExists(udir), 'UserDataDir exists after the call');

  uf := UserFilePath('_selftest.tmp');
  Check(uf = udir + '_selftest.tmp', 'UserFilePath joins dir and name');
  Touch(uf);
  Check(FileExists(uf), 'a file written to the user dir is readable back');
  DeleteFile(uf);

  { the portable marker redirects writable state back beside the binary }
  marker := dir + 'portable.txt';
  Touch(marker);
  Check(UserDataDir = dir, 'portable.txt points the user dir at the binary');
  Check(UserFilePath('x') = dir + 'x', 'portable user files sit beside the binary');
  DeleteFile(marker);
  Check(UserDataDir <> dir, 'removing the marker restores the per-user dir');

  TestSummary('apppaths');
  halt(TestExit);
end.
