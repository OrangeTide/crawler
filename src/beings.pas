unit beings;

{** Shared traits common to every being in the world: the party, the
  NPCs, and the monsters. For now this is the gender enum and the small
  helpers to name it, author it from text, and store it as a byte. }

{$mode objfpc}{$H+}

interface

type
  TGender = (
    GenderUnspecified,
    GenderMale,
    GenderFemale,
    GenderNonBinary,
    GenderGenderqueer,
    GenderGenderfluid,
    GenderAgender,
    GenderOther,
    GenderPreferNotToSay
  );

{ A readable label for display. }
function GenderName(g: TGender): string;

{ Store and restore as a single byte, with an out-of-range byte read back
  as unspecified so an old or corrupt record never faults. }
function GenderToByte(g: TGender): byte;
function GenderFromByte(b: byte): TGender;

{ Parse an authored token (case insensitive), e.g. in a map or table.
  Accepts the short forms male/female/nb/... and returns unspecified for
  anything unrecognized. }
function GenderFromStr(const s: string): TGender;

implementation

uses
  sysutils;

function GenderName(g: TGender): string;
begin
  case g of
    GenderMale:          GenderName := 'Male';
    GenderFemale:        GenderName := 'Female';
    GenderNonBinary:     GenderName := 'Non-binary';
    GenderGenderqueer:   GenderName := 'Genderqueer';
    GenderGenderfluid:   GenderName := 'Genderfluid';
    GenderAgender:       GenderName := 'Agender';
    GenderOther:         GenderName := 'Other';
    GenderPreferNotToSay: GenderName := 'Prefer not to say';
  else
    GenderName := 'Unspecified';
  end;
end;

function GenderToByte(g: TGender): byte;
begin
  GenderToByte := byte(Ord(g));
end;

function GenderFromByte(b: byte): TGender;
begin
  if b > byte(Ord(High(TGender))) then
    GenderFromByte := GenderUnspecified
  else
    GenderFromByte := TGender(b);
end;

function GenderFromStr(const s: string): TGender;
var
  t: string;
begin
  t := LowerCase(Trim(s));
  if (t = 'male') or (t = 'm') then GenderFromStr := GenderMale
  else if (t = 'female') or (t = 'f') then GenderFromStr := GenderFemale
  else if (t = 'nonbinary') or (t = 'non-binary') or (t = 'nb') then GenderFromStr := GenderNonBinary
  else if (t = 'genderqueer') or (t = 'queer') then GenderFromStr := GenderGenderqueer
  else if (t = 'genderfluid') or (t = 'fluid') then GenderFromStr := GenderGenderfluid
  else if (t = 'agender') then GenderFromStr := GenderAgender
  else if (t = 'other') then GenderFromStr := GenderOther
  else if (t = 'prefernottosay') or (t = 'private') or (t = 'unsaid') then GenderFromStr := GenderPreferNotToSay
  else GenderFromStr := GenderUnspecified;
end;

end.
