unit apppaths;

{** Where the program finds its files, so it can run from anywhere.

  Two concerns pull in opposite directions, so they are kept apart. Read
  only assets (the pak) live next to the executable, which makes the
  program relocatable: unzip it anywhere and it finds its own data. Writable
  state (the save and the settings) cannot live there, because a shipped
  program often sits in a read only place (a macOS .app bundle, a system
  directory, a Gatekeeper translocation mount), so it goes to a per user
  directory instead.

  The executable path is resolved through the real OS call per platform, not
  from ParamStr(0), so a launch by bare name on the PATH or through a symlink
  still locates the assets. A "portable.txt" marker beside the binary opts
  back into keeping the save and settings next to it, for a single folder
  zip install on a writable disk.

  On DOS and the console target there is no bundle and no multi user home, so
  both the asset search and the user directory fall back to the executable's
  own folder, which is the whole model there. }

{$mode objfpc}{$H+}

interface

{ Directory of the running executable, resolved through symlinks where the
  platform allows it, with a trailing path separator. }
function ExeDir: string;

{ Locate a read only asset by the ordered search list and return its full,
  normalised path, or '' when none of the candidates exist. }
function AssetPath(const name: string): string;

{ Writable directory for the save and the settings, created if missing, with
  a trailing path separator. Honours the portable.txt marker. }
function UserDataDir: string;

{ UserDataDir joined with a file name. }
function UserFilePath(const name: string): string;

implementation

uses
  sysutils
  {$IFDEF WINDOWS}, windows{$ENDIF}
  ;

{$IFDEF DARWIN}
function _NSGetExecutablePath(buf: PAnsiChar; var bufsize: cardinal): longint;
  cdecl; external name '_NSGetExecutablePath';
{$ENDIF}

{ The raw executable path from the OS, before splitting off the directory. }
function RawExePath: string;
{$IFDEF LINUX}
var
  raw: RawByteString;
begin
  if FileGetSymLinkTarget('/proc/self/exe', raw) then
    Result := raw
  else
    Result := ParamStr(0);
end;
{$ELSE}
{$IFDEF DARWIN}
var
  size: cardinal;
  buf: PAnsiChar;
begin
  size := 0;
  _NSGetExecutablePath(nil, size);   { first call reports the needed size }
  if size = 0 then begin Result := ParamStr(0); exit; end;
  GetMem(buf, size + 1);
  try
    if _NSGetExecutablePath(buf, size) = 0 then
      Result := string(buf)
    else
      Result := ParamStr(0);
  finally
    FreeMem(buf);
  end;
  Result := ExpandFileName(Result);  { collapse any .. and . in the path }
end;
{$ELSE}
{$IFDEF WINDOWS}
var
  buf: array[0..1023] of WideChar;
  n: DWORD;
begin
  n := GetModuleFileNameW(0, @buf[0], Length(buf));
  if n > 0 then
    Result := UTF8Encode(WideString(PWideChar(@buf[0])))
  else
    Result := ParamStr(0);
end;
{$ELSE}
begin
  Result := ParamStr(0);   { DOS and any other target }
end;
{$ENDIF}
{$ENDIF}
{$ENDIF}

function ExeDir: string;
var
  dir: string;
begin
  dir := ExtractFilePath(RawExePath);
  if dir = '' then
    dir := GetCurrentDir;
  ExeDir := IncludeTrailingPathDelimiter(dir);
end;

function AssetPath(const name: string): string;
var
  base: string;

  function Probe(const cand: string): boolean;
  var
    full: string;
  begin
    full := ExpandFileName(cand);
    Probe := FileExists(full);
    if Probe then AssetPath := full;
  end;

begin
  AssetPath := '';
  base := ExeDir;
  if Probe(base + name) then exit;                                 { beside the binary }
  if Probe(base + '..' + PathDelim + 'Resources' + PathDelim + name) then exit;  { macOS .app }
  if Probe(base + '..' + PathDelim + 'share' + PathDelim + 'crawler' + PathDelim + name) then exit;  { unix install }
  if Probe(IncludeTrailingPathDelimiter(GetCurrentDir) + name) then exit;        { current dir }
  if Probe('build' + PathDelim + name) then exit;                  { dev tree }
end;

{ The per user base directory, before the portable override. }
function PlatformDataDir: string;
{$IFDEF WINDOWS}
var
  base: string;
begin
  { qualify SysUtils: on Windows the windows unit's GetEnvironmentVariable
    (the 3-argument WinAPI) is also in scope and would shadow this one. }
  base := SysUtils.GetEnvironmentVariable('APPDATA');
  if base = '' then base := SysUtils.GetEnvironmentVariable('USERPROFILE');
  if base = '' then begin PlatformDataDir := ExeDir; exit; end;
  PlatformDataDir := IncludeTrailingPathDelimiter(base) + 'crawler' + PathDelim;
end;
{$ELSE}
{$IFDEF DARWIN}
var
  home: string;
begin
  home := SysUtils.GetEnvironmentVariable('HOME');
  if home = '' then begin PlatformDataDir := ExeDir; exit; end;
  PlatformDataDir := IncludeTrailingPathDelimiter(home)
    + 'Library' + PathDelim + 'Application Support' + PathDelim + 'crawler' + PathDelim;
end;
{$ELSE}
{$IFDEF UNIX}
var
  base, home: string;
begin
  base := SysUtils.GetEnvironmentVariable('XDG_CONFIG_HOME');
  if base = '' then begin
    home := SysUtils.GetEnvironmentVariable('HOME');
    if home = '' then begin PlatformDataDir := ExeDir; exit; end;
    base := IncludeTrailingPathDelimiter(home) + '.config';
  end;
  PlatformDataDir := IncludeTrailingPathDelimiter(base) + 'crawler' + PathDelim;
end;
{$ELSE}
begin
  PlatformDataDir := ExeDir;   { DOS and any other target: beside the binary }
end;
{$ENDIF}
{$ENDIF}
{$ENDIF}

function UserDataDir: string;
var
  dir: string;
begin
  if FileExists(ExeDir + 'portable.txt') then
    dir := ExeDir
  else
    dir := PlatformDataDir;
  dir := IncludeTrailingPathDelimiter(dir);
  if not DirectoryExists(dir) then
    ForceDirectories(dir);
  UserDataDir := dir;
end;

function UserFilePath(const name: string): string;
begin
  UserFilePath := UserDataDir + name;
end;

end.
