unit uZipInspector;

{ Low-level ZIP reader for the developer window.
  It parses the archive by hand (EOCD, Zip64 records, central directory,
  local headers, extra fields) so every raw field can be shown, instead of
  relying on the subset that TUnZipper exposes. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, uArchiveBase;

const
  SIG_LOCAL        = $04034B50;
  SIG_CENTRAL      = $02014B50;
  SIG_EOCD         = $06054B50;
  SIG_ZIP64_EOCD   = $06064B50;
  SIG_ZIP64_LOC    = $07064B50;
  SIG_DATA_DESC    = $08074B50;

  LOCAL_HDR_SIZE   = 30;
  CENTRAL_HDR_SIZE = 46;
  EOCD_SIZE        = 22;
  ZIP64_LOC_SIZE   = 20;

type
  TZipExtraField = record
    HeaderID: Word;
    DataSize: Word;
    FileOffset: Int64;   // absolute offset of the 4-byte extra header in the file
    Data: TBytes;
  end;
  TZipExtraFields = array of TZipExtraField;

  { TZipEntryInfo }

  TZipEntryInfo = class(TArchiveEntry)
  public
    RawName: RawByteString;    // bytes as stored
    Comment: string;
    // central directory record
    CentralOffset: Int64;
    VersionMadeBy: Word;
    VersionNeeded: Word;
    Flags: Word;
    Method: Word;
    ModTime: Word;
    ModDate: Word;
    NameLen: Word;
    ExtraLen: Word;
    CommentLen: Word;
    DiskStart: LongWord;
    IntAttr: Word;
    ExtAttr: LongWord;
    LocalHeaderOffset: Int64;
    Extras: TZipExtraFields;
    // local file header
    LocalOK: Boolean;
    LocalError: string;
    LocalVersionNeeded: Word;
    LocalFlags: Word;
    LocalMethod: Word;
    LocalTime: Word;
    LocalDate: Word;
    LocalCRC32: LongWord;
    LocalCompressedSize: Int64;
    LocalUncompressedSize: Int64;
    LocalNameLen: Word;
    LocalExtraLen: Word;
    LocalExtras: TZipExtraFields;
    DataOffset: Int64;
    function DateTime: TDateTime; override;
    function IsDirectory: Boolean; override;
    function IsEncrypted: Boolean; override;
    function MethodText: string; override;
    function EncryptionText: string; override;
    { WinZip AES extra field (0x9901): key strength 1..3 and the real compression method }
    function GetAesInfo(out AStrength: Byte; out AActualMethod: Word): Boolean;
    function IsUTF8: Boolean;
    function HasDataDescriptor: Boolean;
    function CentralRecordSize: Integer;
    function LocalRecordSize: Integer;
  end;

  TZipEntryList = specialize TFPGObjectList<TZipEntryInfo>;

  { TZipArchiveInfo }

  TZipArchiveInfo = class(TArchiveInfo)
  private
    procedure ReadEOCD(AStream: TStream);
    procedure ReadCentralDirectory(AStream: TStream);
    procedure ReadLocalHeaders(AStream: TStream);
  protected
    function GetEntry(AIndex: Integer): TArchiveEntry; override;
  public
    // End of central directory
    EOCDOffset: Int64;
    DiskNumber: LongWord;
    CDDisk: LongWord;
    EntriesOnDisk: Int64;
    TotalEntries: Int64;
    CDSize: Int64;
    CDOffset: Int64;
    CommentLen: Word;
    Comment: string;
    // Zip64
    IsZip64: Boolean;
    Zip64LocatorOffset: Int64;
    Zip64EOCDOffset: Int64;
    Zip64RecordSize: Int64;
    Zip64VersionMadeBy: Word;
    Zip64VersionNeeded: Word;
    // derived
    PrefixBytes: Int64;        // bytes before the first local header (SFX stub etc.)
    Entries: TZipEntryList;
    constructor Create; override;
    destructor Destroy; override;
    procedure LoadFromFile(const AFileName: string); override;
    function ArchiveFormat: TArchiveFormat; override;
    function Count: Integer; override;
  end;

function ReadFileRegion(const AFileName: string; AOffset: Int64; ACount: Integer): TBytes;
function HexDump(const ABytes: TBytes; ABaseOffset: Int64): string;

function ZipMethodName(AMethod: Word): string;
function DecodeFlags(AFlags: Word): string;
function HostOSName(AVersionMadeBy: Word): string;
function ZipVersionStr(AVersion: Word): string;
function ExtraFieldName(AID: Word): string;
function DescribeExtraField(const AField: TZipExtraField): string;
function DecodeExternalAttr(AVersionMadeBy: Word; AAttr: LongWord): string;
function DosDateTimeStr(ADate, ATime: Word): string;
function FormatSize(ABytes: Int64): string;
function FormatBytesFull(ABytes: Int64): string;
function Hex32(V: LongWord): string;
function Hex16(V: Word): string;

implementation

uses
  LazUTF8, LConvEncoding, DateUtils;

{ ---------- little-endian helpers ---------- }

function GetW(const B: TBytes; P: Integer): Word; inline;
begin
  Result := Word(B[P]) or (Word(B[P + 1]) shl 8);
end;

function GetL(const B: TBytes; P: Integer): LongWord; inline;
begin
  Result := LongWord(B[P]) or (LongWord(B[P + 1]) shl 8) or
    (LongWord(B[P + 2]) shl 16) or (LongWord(B[P + 3]) shl 24);
end;

function GetQ(const B: TBytes; P: Integer): Int64; inline;
begin
  Result := Int64(GetL(B, P)) or (Int64(GetL(B, P + 4)) shl 32);
end;

function BytesToRaw(const B: TBytes; P, Len: Integer): RawByteString;
begin
  Result := '';
  SetLength(Result, Len);
  if Len > 0 then
    Move(B[P], Result[1], Len);
  SetCodePage(Result, CP_NONE, False);
end;

function RawToDisplay(const ARaw: RawByteString; AIsUTF8: Boolean): string;
var
  S: string;
begin
  S := '';
  SetLength(S, Length(ARaw));
  if ARaw <> '' then
    Move(ARaw[1], S[1], Length(ARaw));
  if AIsUTF8 or (FindInvalidUTF8Codepoint(PChar(S), Length(S)) < 0) then
    Result := S
  else
    Result := CP437ToUTF8(S);
end;

function ParseExtras(const B: TBytes; P, Len: Integer; ABaseOffset: Int64): TZipExtraFields;
var
  Q, N, Sz: Integer;
begin
  Result := nil;
  Q := P;
  N := 0;
  while Q + 4 <= P + Len do
  begin
    Sz := GetW(B, Q + 2);
    SetLength(Result, N + 1);
    Result[N].HeaderID := GetW(B, Q);
    Result[N].DataSize := Sz;
    Result[N].FileOffset := ABaseOffset + Q;
    if Q + 4 + Sz > P + Len then
      Sz := P + Len - Q - 4;
    SetLength(Result[N].Data, Sz);
    if Sz > 0 then
      Move(B[Q + 4], Result[N].Data[0], Sz);
    Inc(N);
    Inc(Q, 4 + Result[N - 1].DataSize);
  end;
end;

function ReadBytes(AStream: TStream; AOffset: Int64; ACount: Integer): TBytes;
var
  Got: Integer;
begin
  Result := nil;
  if (AOffset < 0) or (ACount <= 0) then
    Exit;
  SetLength(Result, ACount);
  AStream.Position := AOffset;
  Got := AStream.Read(Result[0], ACount);
  SetLength(Result, Got);
end;

{ ---------- TZipEntryInfo ---------- }

function TZipEntryInfo.DateTime: TDateTime;
var
  Y, Mo, D, H, Mi, S: Word;
begin
  Y := 1980 + (ModDate shr 9);
  Mo := (ModDate shr 5) and $0F;
  D := ModDate and $1F;
  H := ModTime shr 11;
  Mi := (ModTime shr 5) and $3F;
  S := (ModTime and $1F) * 2;
  if not TryEncodeDateTime(Y, Mo, D, H, Mi, S, 0, Result) then
    Result := 0;
end;

function TZipEntryInfo.IsDirectory: Boolean;
begin
  Result := ((FileName <> '') and (FileName[Length(FileName)] in ['/', '\'])) or
    ((ExtAttr and $10) <> 0);
end;

function TZipEntryInfo.IsEncrypted: Boolean;
begin
  Result := (Flags and $0001) <> 0;
end;

function TZipEntryInfo.IsUTF8: Boolean;
begin
  Result := (Flags and $0800) <> 0;
end;

function TZipEntryInfo.HasDataDescriptor: Boolean;
begin
  Result := (Flags and $0008) <> 0;
end;

function TZipEntryInfo.MethodText: string;
var
  Strength: Byte;
  Actual: Word;
begin
  // method 99 only says "AES"; the real compression is in the AES extra field
  if (Method = 99) and GetAesInfo(Strength, Actual) then
    Result := ZipMethodName(Actual)
  else
    Result := ZipMethodName(Method);
end;

function TZipEntryInfo.GetAesInfo(out AStrength: Byte; out AActualMethod: Word): Boolean;
var
  I: Integer;
begin
  AStrength := 0;
  AActualMethod := 0;
  for I := 0 to High(Extras) do
    if (Extras[I].HeaderID = $9901) and (Length(Extras[I].Data) >= 7) then
    begin
      AStrength := Extras[I].Data[4];
      AActualMethod := GetW(Extras[I].Data, 5);
      Exit(True);
    end;
  Result := False;
end;

function TZipEntryInfo.EncryptionText: string;
var
  Strength: Byte;
  Actual: Word;
begin
  if not IsEncrypted then
    Result := ''
  else if GetAesInfo(Strength, Actual) then
    case Strength of
      1: Result := 'AES-128';
      2: Result := 'AES-192';
      3: Result := 'AES-256';
    else
      Result := 'AES';
    end
  else if (Flags and $0040) <> 0 then
    Result := 'PKWARE strong encryption'
  else
    Result := 'ZipCrypto';
end;

function TZipEntryInfo.CentralRecordSize: Integer;
begin
  Result := CENTRAL_HDR_SIZE + NameLen + ExtraLen + CommentLen;
end;

function TZipEntryInfo.LocalRecordSize: Integer;
begin
  Result := LOCAL_HDR_SIZE + LocalNameLen + LocalExtraLen;
end;

{ ---------- TZipArchiveInfo ---------- }

constructor TZipArchiveInfo.Create;
begin
  inherited Create;
  Entries := TZipEntryList.Create(True);
end;

destructor TZipArchiveInfo.Destroy;
begin
  Entries.Free;
  inherited Destroy;
end;

function TZipArchiveInfo.GetEntry(AIndex: Integer): TArchiveEntry;
begin
  Result := Entries[AIndex];
end;

function TZipArchiveInfo.ArchiveFormat: TArchiveFormat;
begin
  Result := afZip;
end;

function TZipArchiveInfo.Count: Integer;
begin
  Result := Entries.Count;
end;

procedure TZipArchiveInfo.ReadEOCD(AStream: TStream);
var
  Tail, B: TBytes;
  TailStart: Int64;
  I, TailLen: Integer;
begin
  // EOCD is 22 bytes + up to 65535 bytes of comment at the end of the file.
  TailLen := EOCD_SIZE + $FFFF;
  if TailLen > FileSize then
    TailLen := FileSize;
  TailStart := FileSize - TailLen;
  Tail := ReadBytes(AStream, TailStart, TailLen);
  EOCDOffset := -1;
  for I := Length(Tail) - EOCD_SIZE downto 0 do
    if GetL(Tail, I) = SIG_EOCD then
    begin
      EOCDOffset := TailStart + I;
      DiskNumber := GetW(Tail, I + 4);
      CDDisk := GetW(Tail, I + 6);
      EntriesOnDisk := GetW(Tail, I + 8);
      TotalEntries := GetW(Tail, I + 10);
      CDSize := GetL(Tail, I + 12);
      CDOffset := GetL(Tail, I + 16);
      CommentLen := GetW(Tail, I + 20);
      if I + EOCD_SIZE + CommentLen > Length(Tail) then
      begin
        Warnings.Add('EOCD comment length points past end of file');
        CommentLen := Length(Tail) - I - EOCD_SIZE;
      end;
      Comment := RawToDisplay(BytesToRaw(Tail, I + EOCD_SIZE, CommentLen), False);
      Break;
    end;
  if EOCDOffset < 0 then
    raise Exception.Create('End of central directory record not found - not a ZIP file?');

  // Zip64 end of central directory locator sits right before the EOCD.
  Zip64LocatorOffset := -1;
  Zip64EOCDOffset := -1;
  if EOCDOffset >= ZIP64_LOC_SIZE then
  begin
    B := ReadBytes(AStream, EOCDOffset - ZIP64_LOC_SIZE, ZIP64_LOC_SIZE);
    if (Length(B) = ZIP64_LOC_SIZE) and (GetL(B, 0) = SIG_ZIP64_LOC) then
    begin
      Zip64LocatorOffset := EOCDOffset - ZIP64_LOC_SIZE;
      Zip64EOCDOffset := GetQ(B, 8);
      B := ReadBytes(AStream, Zip64EOCDOffset, 56);
      if (Length(B) = 56) and (GetL(B, 0) = SIG_ZIP64_EOCD) then
      begin
        IsZip64 := True;
        Zip64RecordSize := GetQ(B, 4);
        Zip64VersionMadeBy := GetW(B, 12);
        Zip64VersionNeeded := GetW(B, 14);
        DiskNumber := GetL(B, 16);
        CDDisk := GetL(B, 20);
        EntriesOnDisk := GetQ(B, 24);
        TotalEntries := GetQ(B, 32);
        CDSize := GetQ(B, 40);
        CDOffset := GetQ(B, 48);
      end
      else
        Warnings.Add('Zip64 locator found but Zip64 EOCD record is invalid');
    end;
  end;

  if (DiskNumber <> 0) or (CDDisk <> 0) then
    Warnings.Add('Multi-disk (spanned) archive - only this disk is inspected');

  // Archives with a prefix (e.g. self-extracting stub) have shifted offsets.
  PrefixBytes := (EOCDOffset - CDSize) - CDOffset;
  if IsZip64 then
    PrefixBytes := Zip64EOCDOffset - CDSize - CDOffset;
  if PrefixBytes < 0 then
  begin
    Warnings.Add('Central directory offset/size are inconsistent with EOCD position');
    PrefixBytes := 0;
  end
  else if PrefixBytes > 0 then
    Warnings.Add(Format('%d bytes of data before ZIP content (SFX stub or prepended data)', [PrefixBytes]));
end;

procedure TZipArchiveInfo.ReadCentralDirectory(AStream: TStream);
var
  B: TBytes;
  P, J: Integer;
  E: TZipEntryInfo;
  Base: Int64;
  Ex: TZipExtraField;
  Q: Integer;
begin
  if CDSize > 512 * 1024 * 1024 then
    raise Exception.CreateFmt('Central directory too large (%d bytes)', [CDSize]);
  Base := CDOffset + PrefixBytes;
  B := ReadBytes(AStream, Base, CDSize);
  if Length(B) < CDSize then
    Warnings.Add('Central directory truncated');
  P := 0;
  while P + CENTRAL_HDR_SIZE <= Length(B) do
  begin
    if GetL(B, P) <> SIG_CENTRAL then
    begin
      Warnings.Add(Format('Unexpected signature %s at 0x%x inside central directory',
        [Hex32(GetL(B, P)), Base + P]));
      Break;
    end;
    E := TZipEntryInfo.Create;
    E.Index := Entries.Count;
    E.CentralOffset := Base + P;
    E.VersionMadeBy := GetW(B, P + 4);
    E.VersionNeeded := GetW(B, P + 6);
    E.Flags := GetW(B, P + 8);
    E.Method := GetW(B, P + 10);
    E.ModTime := GetW(B, P + 12);
    E.ModDate := GetW(B, P + 14);
    E.CRC32 := GetL(B, P + 16);
    E.CompressedSize := GetL(B, P + 20);
    E.UncompressedSize := GetL(B, P + 24);
    E.NameLen := GetW(B, P + 28);
    E.ExtraLen := GetW(B, P + 30);
    E.CommentLen := GetW(B, P + 32);
    E.DiskStart := GetW(B, P + 34);
    E.IntAttr := GetW(B, P + 36);
    E.ExtAttr := GetL(B, P + 38);
    E.LocalHeaderOffset := GetL(B, P + 42);
    if P + E.CentralRecordSize > Length(B) then
    begin
      Warnings.Add(Format('Central record #%d runs past end of central directory', [E.Index]));
      E.Free;
      Break;
    end;
    E.RawName := BytesToRaw(B, P + CENTRAL_HDR_SIZE, E.NameLen);
    E.FileName := RawToDisplay(E.RawName, E.IsUTF8);
    E.Extras := ParseExtras(B, P + CENTRAL_HDR_SIZE + E.NameLen, E.ExtraLen, Base);
    E.Comment := RawToDisplay(BytesToRaw(B, P + CENTRAL_HDR_SIZE + E.NameLen + E.ExtraLen,
      E.CommentLen), E.IsUTF8);

    for J := 0 to High(E.Extras) do
    begin
      Ex := E.Extras[J];
      if Ex.HeaderID = $0001 then
      begin
        // Zip64 extended info: only the fields saturated in the record are present.
        Q := 0;
        if (E.UncompressedSize = $FFFFFFFF) and (Q + 8 <= Length(Ex.Data)) then
        begin
          E.UncompressedSize := GetQ(Ex.Data, Q);
          Inc(Q, 8);
        end;
        if (E.CompressedSize = $FFFFFFFF) and (Q + 8 <= Length(Ex.Data)) then
        begin
          E.CompressedSize := GetQ(Ex.Data, Q);
          Inc(Q, 8);
        end;
        if (E.LocalHeaderOffset = $FFFFFFFF) and (Q + 8 <= Length(Ex.Data)) then
        begin
          E.LocalHeaderOffset := GetQ(Ex.Data, Q);
          Inc(Q, 8);
        end;
        if (E.DiskStart = $FFFF) and (Q + 4 <= Length(Ex.Data)) then
          E.DiskStart := GetL(Ex.Data, Q);
      end
      else if (Ex.HeaderID = $7075) and (Length(Ex.Data) > 5) then
        // Info-ZIP Unicode Path: version(1) + CRC of raw name(4) + UTF-8 name
        E.FileName := RawToDisplay(BytesToRaw(Ex.Data, 5, Length(Ex.Data) - 5), True);
    end;

    Entries.Add(E);
    Inc(P, E.CentralRecordSize);
  end;
  if Entries.Count <> TotalEntries then
    Warnings.Add(Format('EOCD says %d entries but central directory contains %d',
      [TotalEntries, Entries.Count]));
end;

procedure TZipArchiveInfo.ReadLocalHeaders(AStream: TStream);
var
  E: TZipEntryInfo;
  B: TBytes;
  Ofs: Int64;
  LocalName: RawByteString;
  I: Integer;
begin
  for I := 0 to Entries.Count - 1 do
  begin
    E := Entries[I];
    Ofs := E.LocalHeaderOffset + PrefixBytes;
    B := ReadBytes(AStream, Ofs, LOCAL_HDR_SIZE);
    if (Length(B) < LOCAL_HDR_SIZE) or (GetL(B, 0) <> SIG_LOCAL) then
    begin
      E.LocalOK := False;
      E.LocalError := Format('No local header signature at 0x%x', [Ofs]);
      Warnings.Add(Format('#%d %s: %s', [E.Index, E.FileName, E.LocalError]));
      Continue;
    end;
    E.LocalOK := True;
    E.LocalVersionNeeded := GetW(B, 4);
    E.LocalFlags := GetW(B, 6);
    E.LocalMethod := GetW(B, 8);
    E.LocalTime := GetW(B, 10);
    E.LocalDate := GetW(B, 12);
    E.LocalCRC32 := GetL(B, 14);
    E.LocalCompressedSize := GetL(B, 18);
    E.LocalUncompressedSize := GetL(B, 22);
    E.LocalNameLen := GetW(B, 26);
    E.LocalExtraLen := GetW(B, 28);
    B := ReadBytes(AStream, Ofs + LOCAL_HDR_SIZE, E.LocalNameLen + E.LocalExtraLen);
    if Length(B) = E.LocalNameLen + E.LocalExtraLen then
    begin
      LocalName := BytesToRaw(B, 0, E.LocalNameLen);
      if LocalName <> E.RawName then
        Warnings.Add(Format('#%d: local header name differs from central directory name', [E.Index]));
      E.LocalExtras := ParseExtras(B, E.LocalNameLen, E.LocalExtraLen, Ofs + LOCAL_HDR_SIZE);
    end;
    E.DataOffset := Ofs + E.LocalRecordSize;
    if E.LocalMethod <> E.Method then
      Warnings.Add(Format('#%d: method mismatch (local %d, central %d)', [E.Index, E.LocalMethod, E.Method]));
    if (not E.HasDataDescriptor) and (E.LocalCRC32 <> E.CRC32) then
      Warnings.Add(Format('#%d: CRC mismatch (local %s, central %s)', [E.Index, Hex32(E.LocalCRC32), Hex32(E.CRC32)]));
    if E.DataOffset + E.CompressedSize > FileSize then
      Warnings.Add(Format('#%d: compressed data runs past end of file', [E.Index]));
  end;
end;

procedure TZipArchiveInfo.LoadFromFile(const AFileName: string);
var
  FS: TFileStream;
  T0: QWord;
begin
  T0 := GetTickCount64;
  Entries.Clear;
  Warnings.Clear;
  IsZip64 := False;
  FileName := AFileName;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    FileSize := FS.Size;
    if FileSize < EOCD_SIZE then
      raise Exception.Create('File is too small to be a ZIP archive');
    ReadEOCD(FS);
    ReadCentralDirectory(FS);
    ReadLocalHeaders(FS);
  finally
    FS.Free;
  end;
  ParseTimeMs := GetTickCount64 - T0;
end;

{ ---------- free functions ---------- }

function ReadFileRegion(const AFileName: string; AOffset: Int64; ACount: Integer): TBytes;
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    Result := ReadBytes(FS, AOffset, ACount);
  finally
    FS.Free;
  end;
end;

function HexDump(const ABytes: TBytes; ABaseOffset: Int64): string;
var
  SB: TStringList;
  Line, Asc: string;
  I, J: Integer;
  C: Byte;
begin
  SB := TStringList.Create;
  try
    SB.Add('Offset    00 01 02 03 04 05 06 07  08 09 0A 0B 0C 0D 0E 0F  ASCII');
    SB.Add('--------  -----------------------  -----------------------  ----------------');
    I := 0;
    while I < Length(ABytes) do
    begin
      Line := IntToHex(ABaseOffset + I, 8) + '  ';
      Asc := '';
      for J := 0 to 15 do
      begin
        if I + J < Length(ABytes) then
        begin
          C := ABytes[I + J];
          Line := Line + IntToHex(C, 2) + ' ';
          if (C >= 32) and (C < 127) then
            Asc := Asc + Chr(C)
          else
            Asc := Asc + '.';
        end
        else
          Line := Line + '   ';
        if J = 7 then
          Line := Line + ' ';
      end;
      SB.Add(Line + ' ' + Asc);
      Inc(I, 16);
    end;
    Result := SB.Text;
  finally
    SB.Free;
  end;
end;

function ZipMethodName(AMethod: Word): string;
begin
  case AMethod of
    0: Result := 'Stored';
    1: Result := 'Shrunk';
    2..5: Result := 'Reduced(' + IntToStr(AMethod - 1) + ')';
    6: Result := 'Imploded';
    8: Result := 'Deflate';
    9: Result := 'Deflate64';
    12: Result := 'BZip2';
    14: Result := 'LZMA';
    93: Result := 'Zstandard';
    95: Result := 'XZ';
    98: Result := 'PPMd';
    99: Result := 'AES (WinZip)';
  else
    Result := 'Unknown(' + IntToStr(AMethod) + ')';
  end;
end;

function DecodeFlags(AFlags: Word): string;

  procedure AddBit(ABit: Integer; const AName: string);
  begin
    if (AFlags and (1 shl ABit)) <> 0 then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + AName;
    end;
  end;

begin
  Result := '';
  AddBit(0, 'Encrypted');
  AddBit(1, 'Option1');
  AddBit(2, 'Option2');
  AddBit(3, 'DataDescriptor');
  AddBit(4, 'EnhancedDeflate');
  AddBit(5, 'PatchedData');
  AddBit(6, 'StrongEncryption');
  AddBit(11, 'UTF-8');
  AddBit(13, 'MaskedHeader');
  if Result = '' then
    Result := '(none)';
end;

function HostOSName(AVersionMadeBy: Word): string;
begin
  case AVersionMadeBy shr 8 of
    0: Result := 'MS-DOS / FAT';
    1: Result := 'Amiga';
    2: Result := 'OpenVMS';
    3: Result := 'Unix';
    4: Result := 'VM/CMS';
    5: Result := 'Atari ST';
    6: Result := 'OS/2 HPFS';
    7: Result := 'Macintosh';
    8: Result := 'Z-System';
    9: Result := 'CP/M';
    10: Result := 'Windows NTFS';
    11: Result := 'MVS';
    12: Result := 'VSE';
    13: Result := 'Acorn RISC';
    14: Result := 'VFAT';
    15: Result := 'Alternate MVS';
    16: Result := 'BeOS';
    17: Result := 'Tandem';
    18: Result := 'OS/400';
    19: Result := 'OS X (Darwin)';
  else
    Result := 'Unknown(' + IntToStr(AVersionMadeBy shr 8) + ')';
  end;
end;

function ZipVersionStr(AVersion: Word): string;
var
  V: Integer;
begin
  V := AVersion and $FF;
  Result := Format('%d.%d', [V div 10, V mod 10]);
end;

function ExtraFieldName(AID: Word): string;
begin
  case AID of
    $0001: Result := 'Zip64 extended information';
    $0007: Result := 'AV Info';
    $000A: Result := 'NTFS timestamps';
    $000D: Result := 'UNIX';
    $0017: Result := 'Strong Encryption Header';
    $5455: Result := 'Extended Timestamp (UT)';
    $5855: Result := 'Info-ZIP UNIX (old)';
    $6375: Result := 'Info-ZIP Unicode Comment';
    $7075: Result := 'Info-ZIP Unicode Path';
    $7855: Result := 'Info-ZIP UNIX (Ux)';
    $7875: Result := 'Info-ZIP UNIX uid/gid (ux)';
    $9901: Result := 'WinZip AES';
    $CAFE: Result := 'Java JAR marker';
  else
    Result := 'Unknown';
  end;
end;

function DescribeExtraField(const AField: TZipExtraField): string;
var
  D: TBytes;
  FT: Int64;
  Q: Integer;

  function UnixToStr(AT: LongWord): string;
  begin
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss', UnixToDateTime(AT)) + ' UTC';
  end;

  function FileTimeToStr(AFT: Int64): string;
  begin
    // 100ns ticks since 1601-01-01
    Result := FormatDateTime('yyyy-mm-dd hh:nn:ss',
      EncodeDate(1601, 1, 1) + (AFT / 10000000) / SecsPerDay) + ' UTC';
  end;

begin
  D := AField.Data;
  Result := '';
  case AField.HeaderID of
    $5455:
      if Length(D) >= 1 then
      begin
        Result := 'flags=' + IntToHex(D[0], 2);
        Q := 1;
        if ((D[0] and 1) <> 0) and (Q + 4 <= Length(D)) then
        begin
          Result := Result + ' mtime=' + UnixToStr(GetL(D, Q));
          Inc(Q, 4);
        end;
        if ((D[0] and 2) <> 0) and (Q + 4 <= Length(D)) then
        begin
          Result := Result + ' atime=' + UnixToStr(GetL(D, Q));
          Inc(Q, 4);
        end;
        if ((D[0] and 4) <> 0) and (Q + 4 <= Length(D)) then
          Result := Result + ' ctime=' + UnixToStr(GetL(D, Q));
      end;
    $000A:
      if Length(D) >= 32 then
      begin
        // reserved(4) tag(2)=1 size(2)=24 mtime(8) atime(8) ctime(8)
        FT := GetQ(D, 8);
        Result := 'mtime=' + FileTimeToStr(FT);
        Result := Result + ' atime=' + FileTimeToStr(GetQ(D, 16));
        Result := Result + ' ctime=' + FileTimeToStr(GetQ(D, 24));
      end;
    $7875:
      if (Length(D) >= 3) then
      begin
        Result := 'version=' + IntToStr(D[0]);
        if (D[1] = 4) and (Length(D) >= 11) and (D[6] = 4) then
          Result := Result + Format(' uid=%d gid=%d', [GetL(D, 2), GetL(D, 7)]);
      end;
    $7075:
      if Length(D) > 5 then
        Result := Format('version=%d nameCRC=%s name="%s"',
          [D[0], Hex32(GetL(D, 1)), RawToDisplay(BytesToRaw(D, 5, Length(D) - 5), True)]);
    $0001:
      begin
        Result := 'values:';
        Q := 0;
        while Q + 8 <= Length(D) do
        begin
          Result := Result + ' ' + IntToStr(GetQ(D, Q));
          Inc(Q, 8);
        end;
      end;
    $9901:
      if Length(D) >= 7 then
        Result := Format('vendorVersion=AE-%d strength=%d actualMethod=%d',
          [GetW(D, 0), D[4], GetW(D, 5)]);
  end;
end;

function DecodeExternalAttr(AVersionMadeBy: Word; AAttr: LongWord): string;
var
  Mode: Word;
  S: string;
begin
  S := '';
  if (AAttr and $01) <> 0 then S := S + 'R';
  if (AAttr and $02) <> 0 then S := S + 'H';
  if (AAttr and $04) <> 0 then S := S + 'S';
  if (AAttr and $10) <> 0 then S := S + 'D';
  if (AAttr and $20) <> 0 then S := S + 'A';
  if S = '' then S := '-';
  Result := 'DOS:' + S;
  if (AVersionMadeBy shr 8) in [3, 19] then
  begin
    Mode := AAttr shr 16;
    Result := Result + ' Unix:' + OctStr(Mode, 6);
  end;
end;

function DosDateTimeStr(ADate, ATime: Word): string;
begin
  Result := Format('%.4d-%.2d-%.2d %.2d:%.2d:%.2d',
    [1980 + (ADate shr 9), (ADate shr 5) and $0F, ADate and $1F,
     ATime shr 11, (ATime shr 5) and $3F, (ATime and $1F) * 2]);
end;

function FormatSize(ABytes: Int64): string;
begin
  if ABytes < 1024 then
    Result := IntToStr(ABytes) + ' B'
  else if ABytes < 1024 * 1024 then
    Result := FormatFloat('0.0', ABytes / 1024) + ' KB'
  else if ABytes < Int64(1024) * 1024 * 1024 then
    Result := FormatFloat('0.00', ABytes / (1024 * 1024)) + ' MB'
  else
    Result := FormatFloat('0.00', ABytes / (Int64(1024) * 1024 * 1024)) + ' GB';
end;

function FormatBytesFull(ABytes: Int64): string;
begin
  Result := Format('%s (%s bytes)', [FormatSize(ABytes), FormatFloat('#,##0', ABytes)]);
end;

function Hex32(V: LongWord): string;
begin
  Result := '0x' + IntToHex(V, 8);
end;

function Hex16(V: Word): string;
begin
  Result := '0x' + IntToHex(V, 4);
end;

end.
