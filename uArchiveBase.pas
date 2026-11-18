unit uArchiveBase;

{ Format-neutral view of an archive, shared by the ZIP and RAR inspectors so
  the main window can list / total / sort entries without knowing the format. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TArchiveFormat = (afZip, afRar4, afRar5);

  { TArchiveEntry }

  TArchiveEntry = class
  public
    Index: Integer;
    FileName: string;          // display name (UTF-8, '/' separators)
    CRC32: LongWord;
    CompressedSize: Int64;
    UncompressedSize: Int64;
    function DateTime: TDateTime; virtual; abstract;
    function IsDirectory: Boolean; virtual; abstract;
    function IsEncrypted: Boolean; virtual; abstract;
    function MethodText: string; virtual; abstract;
    { Cipher of a password-protected entry ('AES-256', 'ZipCrypto'...), '' when not encrypted }
    function EncryptionText: string; virtual;
    function SavedPercent: Double;
  end;

  { TArchiveInfo }

  TArchiveInfo = class
  protected
    function GetEntry(AIndex: Integer): TArchiveEntry; virtual; abstract;
  public
    FileName: string;
    FileSize: Int64;
    ParseTimeMs: QWord;
    Warnings: TStringList;
    constructor Create; virtual;
    destructor Destroy; override;
    procedure LoadFromFile(const AFileName: string); virtual; abstract;
    function ArchiveFormat: TArchiveFormat; virtual; abstract;
    function FormatName: string;
    function Count: Integer; virtual; abstract;
    function TotalUncompressed: Int64;
    function TotalCompressed: Int64;
    function FileCount: Integer;
    function DirCount: Integer;
    function EncryptedCount: Integer;
    { The ciphers used, e.g. 'AES-256' or 'AES-256, ZipCrypto'; '' when nothing is encrypted }
    function EncryptionSummary: string;
    function OverallSavedPercent: Double;
    property Entry[AIndex: Integer]: TArchiveEntry read GetEntry;
  end;

  TArchiveInfoClass = class of TArchiveInfo;

{ Looks at the file's signature (not its extension). Searches the first
  1 MB for a RAR signature so self-extracting .exe archives are found too. }
function DetectArchiveFormat(const AFileName: string; out AFormat: TArchiveFormat;
  out ASigOffset: Int64): Boolean;

const
  ArchiveFormatNames: array[TArchiveFormat] of string = ('ZIP', 'RAR 4.x', 'RAR 5.0');

implementation

function TArchiveEntry.EncryptionText: string;
begin
  Result := '';
end;

function TArchiveEntry.SavedPercent: Double;
begin
  if UncompressedSize <= 0 then
    Result := 0
  else
    Result := 100 * (1 - CompressedSize / UncompressedSize);
end;

constructor TArchiveInfo.Create;
begin
  Warnings := TStringList.Create;
end;

destructor TArchiveInfo.Destroy;
begin
  Warnings.Free;
  inherited Destroy;
end;

function TArchiveInfo.FormatName: string;
begin
  Result := ArchiveFormatNames[ArchiveFormat];
end;

function TArchiveInfo.TotalUncompressed: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    Inc(Result, Entry[I].UncompressedSize);
end;

function TArchiveInfo.TotalCompressed: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    Inc(Result, Entry[I].CompressedSize);
end;

function TArchiveInfo.FileCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if not Entry[I].IsDirectory then
      Inc(Result);
end;

function TArchiveInfo.DirCount: Integer;
begin
  Result := Count - FileCount;
end;

function TArchiveInfo.EncryptedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to Count - 1 do
    if Entry[I].IsEncrypted then
      Inc(Result);
end;

function TArchiveInfo.EncryptionSummary: string;
var
  I: Integer;
  S: string;
begin
  Result := '';
  for I := 0 to Count - 1 do
  begin
    S := Entry[I].EncryptionText;
    if (S <> '') and (Pos(', ' + S + ', ', ', ' + Result + ', ') = 0) then
      if Result = '' then
        Result := S
      else
        Result := Result + ', ' + S;
  end;
end;

function TArchiveInfo.OverallSavedPercent: Double;
var
  U: Int64;
begin
  U := TotalUncompressed;
  if U <= 0 then
    Result := 0
  else
    Result := 100 * (1 - TotalCompressed / U);
end;

function DetectArchiveFormat(const AFileName: string; out AFormat: TArchiveFormat;
  out ASigOffset: Int64): Boolean;
const
  RarSig: array[0..5] of Byte = ($52, $61, $72, $21, $1A, $07);
var
  FS: TFileStream;
  Buf: array of Byte;
  N, I: Integer;
begin
  Result := False;
  AFormat := afZip;
  ASigOffset := 0;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    N := FS.Size;
    if N > 1024 * 1024 then
      N := 1024 * 1024;
    SetLength(Buf, N);
    if N > 0 then
      N := FS.Read(Buf[0], N);
  finally
    FS.Free;
  end;
  if (N >= 4) and (Buf[0] = $50) and (Buf[1] = $4B) then
  begin
    AFormat := afZip;
    Exit(True);
  end;
  for I := 0 to N - 8 do
    if CompareMem(@Buf[I], @RarSig[0], 6) then
    begin
      if Buf[I + 6] = 0 then
      begin
        AFormat := afRar4;
        ASigOffset := I;
        Exit(True);
      end
      else if (Buf[I + 6] = 1) and (Buf[I + 7] = 0) then
      begin
        AFormat := afRar5;
        ASigOffset := I;
        Exit(True);
      end;
    end;
  // Not obviously RAR: let the ZIP reader try (it finds the EOCD from the end,
  // which also covers ZIP-based SFX files).
  AFormat := afZip;
  Result := True;
end;

end.
