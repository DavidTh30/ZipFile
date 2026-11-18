unit uRarInspector;

{ Low-level RAR reader (RAR 1.5-4.x and RAR 5.0+ block formats) for listing and
  the developer window. Only headers are parsed - decompression is done by an
  external tool (see uRarBackend), because RAR's compression is proprietary.

  Every header field read is recorded (offset, size, name, value) so the
  developer window can show an annotated breakdown of each block. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, uArchiveBase;

type
  TRarField = record
    Ofs: Int64;               // absolute file offset
    Size: Integer;
    Name: string;
    Value: string;
  end;
  TRarFields = array of TRarField;

  TRarExtra = record
    RecType: QWord;
    Size: QWord;
    Offset: Int64;
    Name: string;
    Desc: string;
  end;
  TRarExtras = array of TRarExtra;

  { One header block in the file (marker, main, file, service, end ...). }
  TRarBlock = class
  public
    Index: Integer;
    Offset: Int64;            // first byte of the header (its CRC field)
    HeaderLen: Int64;         // whole header incl. CRC
    DataOffset: Int64;
    DataSize: Int64;
    HeadType: Integer;
    TypeName: string;
    HeadFlags: QWord;
    CRCStored: LongWord;
    CRCCalc: LongWord;
    CRCChecked: Boolean;
    Name: string;             // file / service name, if any
    Fields: TRarFields;
    Extras: TRarExtras;
    function CRCOk: Boolean;
  end;

  { TRarEntryInfo }

  TRarEntryInfo = class(TArchiveEntry)
  public
    Block: TRarBlock;
    IsRar5: Boolean;
    HostOS: Integer;
    Attributes: QWord;
    MTime: TDateTime;
    MTimeRaw: LongWord;       // Unix time (RAR5) or DOS date/time (RAR4)
    HasCRC: Boolean;
    Method: Integer;          // 0 = store .. 5 = best
    AlgVersion: Integer;      // RAR5 compression version / RAR4 UNP_VER
    DictSize: Int64;          // bytes
    Solid: Boolean;
    Encrypted: Boolean;
    Directory: Boolean;
    SplitBefore: Boolean;
    SplitAfter: Boolean;
    UnknownSize: Boolean;
    FileFlags: QWord;         // RAR5 file flags / RAR4 header flags
    HashBLAKE2: string;       // hex, if a hash extra record is present
    RedirTarget: string;      // symlink / hardlink target
    function DateTime: TDateTime; override;
    function IsDirectory: Boolean; override;
    function IsEncrypted: Boolean; override;
    function MethodText: string; override;
    function EncryptionText: string; override;
  end;

  TRarBlockList = specialize TFPGObjectList<TRarBlock>;
  TRarEntryList = specialize TFPGObjectList<TRarEntryInfo>;

  { TRarArchiveInfo }

  TRarArchiveInfo = class(TArchiveInfo)
  private
    FFormat: TArchiveFormat;
    procedure ParseRar5(AStream: TStream);
    procedure ParseRar4(AStream: TStream);
  protected
    function GetEntry(AIndex: Integer): TArchiveEntry; override;
  public
    SigOffset: Int64;         // > 0 for self-extracting archives
    ArchiveFlags: QWord;
    VolumeNumber: Int64;
    IsVolume: Boolean;
    IsFirstVolume: Boolean;
    IsSolid: Boolean;
    IsLocked: Boolean;
    HasRecovery: Boolean;
    HasComment: Boolean;
    HeadersEncrypted: Boolean;
    QuickOpenOffset: Int64;
    RecoveryOffset: Int64;
    EndFlags: QWord;
    MainBlock: TRarBlock;
    EndBlock: TRarBlock;
    Blocks: TRarBlockList;
    Entries: TRarEntryList;
    constructor Create; override;
    destructor Destroy; override;
    procedure LoadFromFile(const AFileName: string); override;
    function ArchiveFormat: TArchiveFormat; override;
    function Count: Integer; override;
    function ServiceNames: string;
  end;

function RarMethodName(AMethod: Integer): string;
function RarHostOSName(AIsRar5: Boolean; AHostOS: Integer): string;
function DecodeRar5HeaderFlags(F: QWord): string;
function DecodeRar5ArchiveFlags(F: QWord): string;
function DecodeRar5FileFlags(F: QWord): string;
function DecodeRar4MainFlags(F: QWord): string;
function DecodeRar4FileFlags(F: QWord): string;
function DecodeWinAttributes(A: QWord): string;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  crc, DateUtils, LazUTF8, LConvEncoding;

type
  ERarFormat = class(Exception);

  { Reads little-endian fields / RAR5 vints out of a header buffer and records
    each one into the block's field list. }
  TFieldReader = class
  public
    B: TBytes;
    P: Integer;
    Base: Int64;
    Blk: TRarBlock;
    constructor Create(const ABytes: TBytes; ABase: Int64; ABlock: TRarBlock);
    procedure Need(N: Integer);
    procedure Add(AOfs, ASize: Integer; const AName, AValue: string);
    function U8(const AName: string): Byte;
    function U16(const AName: string): Word;
    function U32(const AName: string): LongWord;
    function U64(const AName: string): QWord;
    function VInt(const AName: string): QWord;
    function Bytes(N: Integer; const AName: string): TBytes;
    function Remaining: Integer;
  end;

function HexBytes(const A: TBytes; AMax: Integer = 32): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to Length(A) - 1 do
  begin
    if I >= AMax then
    begin
      Result := Result + '...';
      Break;
    end;
    Result := Result + IntToHex(A[I], 2);
  end;
end;

constructor TFieldReader.Create(const ABytes: TBytes; ABase: Int64; ABlock: TRarBlock);
begin
  B := ABytes;
  P := 0;
  Base := ABase;
  Blk := ABlock;
end;

procedure TFieldReader.Need(N: Integer);
begin
  if P + N > Length(B) then
    raise ERarFormat.CreateFmt('Header at 0x%x is truncated (needs %d more bytes at +%d)', [Base, N, P]);
end;

procedure TFieldReader.Add(AOfs, ASize: Integer; const AName, AValue: string);
var
  N: Integer;
begin
  if Blk = nil then
    Exit;
  N := Length(Blk.Fields);
  SetLength(Blk.Fields, N + 1);
  Blk.Fields[N].Ofs := Base + AOfs;
  Blk.Fields[N].Size := ASize;
  Blk.Fields[N].Name := AName;
  Blk.Fields[N].Value := AValue;
end;

function TFieldReader.U8(const AName: string): Byte;
begin
  Need(1);
  Result := B[P];
  Add(P, 1, AName, Format('%u (0x%.2x)', [Result, Result]));
  Inc(P);
end;

function TFieldReader.U16(const AName: string): Word;
begin
  Need(2);
  Result := B[P] or (B[P + 1] shl 8);
  Add(P, 2, AName, Format('%u (0x%.4x)', [Result, Result]));
  Inc(P, 2);
end;

function TFieldReader.U32(const AName: string): LongWord;
begin
  Need(4);
  Result := LongWord(B[P]) or (LongWord(B[P + 1]) shl 8) or (LongWord(B[P + 2]) shl 16) or
    (LongWord(B[P + 3]) shl 24);
  Add(P, 4, AName, Format('%u (0x%.8x)', [Result, Result]));
  Inc(P, 4);
end;

function TFieldReader.U64(const AName: string): QWord;
var
  I: Integer;
begin
  Need(8);
  Result := 0;
  for I := 7 downto 0 do
    Result := (Result shl 8) or B[P + I];
  Add(P, 8, AName, Format('%u (0x%.16x)', [Result, Result]));
  Inc(P, 8);
end;

function TFieldReader.VInt(const AName: string): QWord;
var
  Start, Shift: Integer;
  C: Byte;
begin
  // RAR5 variable-length integer: 7 bits per byte, high bit = more bytes follow
  Start := P;
  Result := 0;
  Shift := 0;
  repeat
    Need(1);
    C := B[P];
    Inc(P);
    Result := Result or (QWord(C and $7F) shl Shift);
    Inc(Shift, 7);
    if Shift > 63 then
      raise ERarFormat.CreateFmt('Invalid vint at 0x%x', [Base + Start]);
  until (C and $80) = 0;
  Add(Start, P - Start, AName, Format('%u (0x%x)  [vint]', [Result, Result]));
end;

function TFieldReader.Bytes(N: Integer; const AName: string): TBytes;
begin
  Need(N);
  Result := nil;
  SetLength(Result, N);
  if N > 0 then
    Move(B[P], Result[0], N);
  Add(P, N, AName, HexBytes(Result));
  Inc(P, N);
end;

function TFieldReader.Remaining: Integer;
begin
  Result := Length(B) - P;
end;

{ ---------- helpers ---------- }

function ReadAt(AStream: TStream; AOffset: Int64; ACount: Integer): TBytes;
var
  Got: Integer;
begin
  Result := nil;
  if (ACount <= 0) or (AOffset < 0) or (AOffset >= AStream.Size) then
    Exit;
  SetLength(Result, ACount);
  AStream.Position := AOffset;
  Got := AStream.Read(Result[0], ACount);
  SetLength(Result, Got);
end;

function CRCOfBytes(const B: TBytes; AStart, ALen: Integer): LongWord;
begin
  if ALen <= 0 then
    Exit(0);
  Result := crc.crc32(0, @B[AStart], ALen);
end;

function BytesToStr(const A: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(A));
  if Length(A) > 0 then
    Move(A[0], Result[1], Length(A));
end;

function OemToUTF8Name(const S: string): string;
var
  I: Integer;
  Ascii: Boolean;
begin
  Ascii := True;
  for I := 1 to Length(S) do
    if Ord(S[I]) > 127 then
    begin
      Ascii := False;
      Break;
    end;
  if Ascii then
    Exit(S);
  {$IFDEF WINDOWS}
  Result := ConvertEncoding(S, 'cp' + IntToStr(GetOEMCP), EncodingUTF8);
  {$ELSE}
  Result := CP437ToUTF8(S);
  {$ENDIF}
end;

{ RAR 2.x-4.x "unicode name" encoding: ANSI name + #0 + compressed UTF-16 }
function DecodeRar4UnicodeName(const AName: TBytes; AZeroPos: Integer): string;
var
  W: UnicodeString;
  EncPos, EncSize, DecPos, Len: Integer;
  HighByte, Flags, FlagBits, Correction: Byte;

  procedure Put(C: Word);
  begin
    Inc(DecPos);
    if DecPos > Length(W) then
      SetLength(W, DecPos + 16);
    W[DecPos] := WideChar(C);
  end;

  function NameByte(I: Integer): Byte;
  begin
    if I < AZeroPos then Result := AName[I] else Result := 0;
  end;

begin
  W := '';
  SetLength(W, AZeroPos + 16);
  DecPos := 0;
  EncPos := AZeroPos + 1;
  EncSize := Length(AName);
  if EncPos >= EncSize then
    Exit(OemToUTF8Name(BytesToStr(Copy(AName, 0, AZeroPos))));
  HighByte := AName[EncPos];
  Inc(EncPos);
  Flags := 0;
  FlagBits := 0;
  while EncPos < EncSize do
  begin
    if FlagBits = 0 then
    begin
      Flags := AName[EncPos];
      Inc(EncPos);
      FlagBits := 8;
    end;
    case Flags shr 6 of
      0:
        begin
          if EncPos >= EncSize then Break;
          Put(AName[EncPos]);
          Inc(EncPos);
        end;
      1:
        begin
          if EncPos >= EncSize then Break;
          Put(AName[EncPos] + (HighByte shl 8));
          Inc(EncPos);
        end;
      2:
        begin
          if EncPos + 1 >= EncSize then Break;
          Put(AName[EncPos] + (AName[EncPos + 1] shl 8));
          Inc(EncPos, 2);
        end;
      3:
        begin
          if EncPos >= EncSize then Break;
          Len := AName[EncPos];
          Inc(EncPos);
          if (Len and $80) <> 0 then
          begin
            if EncPos >= EncSize then Break;
            Correction := AName[EncPos];
            Inc(EncPos);
            Len := (Len and $7F) + 2;
            while Len > 0 do
            begin
              Put(((NameByte(DecPos) + Correction) and $FF) + (HighByte shl 8));
              Dec(Len);
            end;
          end
          else
          begin
            Len := Len + 2;
            while Len > 0 do
            begin
              Put(NameByte(DecPos));
              Dec(Len);
            end;
          end;
        end;
    end;
    Flags := Byte(Flags shl 2);
    Dec(FlagBits, 2);
  end;
  SetLength(W, DecPos);
  Result := UTF8Encode(W);
end;

function DosToDateTime(V: LongWord): TDateTime;
var
  D, T: Word;
begin
  D := V shr 16;
  T := V and $FFFF;
  if not TryEncodeDateTime(1980 + (D shr 9), (D shr 5) and $0F, D and $1F,
    T shr 11, (T shr 5) and $3F, (T and $1F) * 2, 0, Result) then
    Result := 0;
end;

function FileTimeToDT(FT: QWord): TDateTime;
begin
  Result := EncodeDate(1601, 1, 1) + (FT / 10000000) / SecsPerDay;
end;

{ ---------- TRarBlock / TRarEntryInfo ---------- }

function TRarBlock.CRCOk: Boolean;
begin
  Result := (not CRCChecked) or (CRCStored = CRCCalc);
end;

function TRarEntryInfo.DateTime: TDateTime;
begin
  Result := MTime;
end;

function TRarEntryInfo.IsDirectory: Boolean;
begin
  Result := Directory;
end;

function TRarEntryInfo.IsEncrypted: Boolean;
begin
  Result := Encrypted;
end;

function TRarEntryInfo.EncryptionText: string;
begin
  if not Encrypted then
    Result := ''
  else if IsRar5 then
    Result := 'AES-256'
  else
    Result := 'AES-128';   // RAR 3.x / 4.x
end;

function TRarEntryInfo.MethodText: string;
begin
  Result := RarMethodName(Method);
  if Solid then
    Result := Result + ' (solid)';
end;

{ ---------- TRarArchiveInfo ---------- }

constructor TRarArchiveInfo.Create;
begin
  inherited Create;
  Blocks := TRarBlockList.Create(True);
  Entries := TRarEntryList.Create(True);
end;

destructor TRarArchiveInfo.Destroy;
begin
  Entries.Free;
  Blocks.Free;
  inherited Destroy;
end;

function TRarArchiveInfo.GetEntry(AIndex: Integer): TArchiveEntry;
begin
  Result := Entries[AIndex];
end;

function TRarArchiveInfo.ArchiveFormat: TArchiveFormat;
begin
  Result := FFormat;
end;

function TRarArchiveInfo.Count: Integer;
begin
  Result := Entries.Count;
end;

function TRarArchiveInfo.ServiceNames: string;
var
  Blk: TRarBlock;
begin
  Result := '';
  for Blk in Blocks do
    if ((FFormat = afRar5) and (Blk.HeadType = 3)) or ((FFormat = afRar4) and (Blk.HeadType = $7A)) then
      Result := Result + Blk.Name + ' ';
  Result := Trim(Result);
end;

function NewBlock(AList: TRarBlockList; AOffset: Int64): TRarBlock;
begin
  Result := TRarBlock.Create;
  Result.Index := AList.Count;
  Result.Offset := AOffset;
  AList.Add(Result);
end;

procedure TRarArchiveInfo.ParseRar5(AStream: TStream);
var
  Pos, ExtraSize: Int64;
  Blk: TRarBlock;
  R: TFieldReader;
  B: TBytes;
  HSize, Typ, Flags, FF, CI, NameLen, V: QWord;
  SizeLen, I, ExtraStart, RecEnd, N: Integer;
  E: TRarEntryInfo;
  Ex: TRarExtra;
  RecSize, RecType, F2: QWord;

  procedure AddExtra(var AList: TRarExtras; const AEx: TRarExtra);
  begin
    SetLength(AList, Length(AList) + 1);
    AList[High(AList)] := AEx;
  end;

begin
  Blk := NewBlock(Blocks, SigOffset);
  Blk.TypeName := 'Signature (RAR 5.0)';
  Blk.HeaderLen := 8;
  Blk.HeadType := -1;
  B := ReadAt(AStream, SigOffset, 8);
  R := TFieldReader.Create(B, SigOffset, Blk);
  try
    R.Bytes(8, 'signature "Rar!" 1A 07 01 00');
  finally
    R.Free;
  end;
  Blk.DataOffset := SigOffset + 8;

  Pos := SigOffset + 8;
  while Pos < FileSize do
  begin
    // header size vint is at most 3 bytes (headers are limited to 2 MB)
    B := ReadAt(AStream, Pos, 4 + 3);
    if Length(B) < 5 then
    begin
      Warnings.Add(Format('Truncated block at 0x%x (archive ends without end-of-archive header)', [Pos]));
      Break;
    end;
    HSize := 0;
    SizeLen := 0;
    repeat
      HSize := HSize or (QWord(B[4 + SizeLen] and $7F) shl (7 * SizeLen));
      Inc(SizeLen);
    until ((B[3 + SizeLen] and $80) = 0) or (SizeLen >= 3);
    if (HSize = 0) or (HSize > 2 * 1024 * 1024) then
    begin
      Warnings.Add(Format('Invalid header size %d at 0x%x - stopping', [HSize, Pos]));
      Break;
    end;
    B := ReadAt(AStream, Pos, 4 + SizeLen + HSize);
    if Length(B) < 4 + SizeLen + HSize then
    begin
      Warnings.Add(Format('Header at 0x%x runs past end of file', [Pos]));
      Break;
    end;

    Blk := NewBlock(Blocks, Pos);
    Blk.HeaderLen := 4 + SizeLen + HSize;
    Blk.CRCCalc := CRCOfBytes(B, 4, SizeLen + HSize);
    Blk.CRCChecked := True;
    R := TFieldReader.Create(B, Pos, Blk);
    try
      try
        Blk.CRCStored := R.U32('header CRC32');
        R.VInt('header size');
        Typ := R.VInt('header type');
        Flags := R.VInt('header flags');
        Blk.HeadType := Typ;
        Blk.HeadFlags := Flags;
        ExtraSize := 0;
        if (Flags and $1) <> 0 then
          ExtraSize := R.VInt('extra area size');
        if (Flags and $2) <> 0 then
          Blk.DataSize := R.VInt('data size');
        Blk.DataOffset := Pos + Blk.HeaderLen;

        case Typ of
          1:
            begin
              Blk.TypeName := 'Main archive header';
              MainBlock := Blk;
              ArchiveFlags := R.VInt('archive flags');
              IsVolume := (ArchiveFlags and $1) <> 0;
              IsSolid := (ArchiveFlags and $4) <> 0;
              HasRecovery := (ArchiveFlags and $8) <> 0;
              IsLocked := (ArchiveFlags and $10) <> 0;
              if (ArchiveFlags and $2) <> 0 then
                VolumeNumber := R.VInt('volume number');
              IsFirstVolume := IsVolume and (VolumeNumber = 0);
            end;
          2, 3:
            begin
              if Typ = 2 then
                Blk.TypeName := 'File header'
              else
                Blk.TypeName := 'Service header';
              FF := R.VInt('file flags');
              E := TRarEntryInfo.Create;
              E.Block := Blk;
              E.IsRar5 := True;
              E.FileFlags := FF;
              E.Directory := (FF and $1) <> 0;
              E.UnknownSize := (FF and $8) <> 0;
              E.UncompressedSize := R.VInt('unpacked size');
              E.Attributes := R.VInt('attributes');
              if (FF and $2) <> 0 then
              begin
                E.MTimeRaw := R.U32('mtime (Unix)');
                E.MTime := UniversalTimeToLocal(UnixToDateTime(E.MTimeRaw));
              end;
              if (FF and $4) <> 0 then
              begin
                E.CRC32 := R.U32('data CRC32');
                E.HasCRC := True;
              end;
              CI := R.VInt('compression info');
              E.AlgVersion := CI and $3F;
              E.Solid := (CI and $40) <> 0;
              E.Method := (CI shr 7) and $7;
              E.DictSize := Int64(128 * 1024) shl ((CI shr 10) and $1F);
              if E.AlgVersion > 0 then
                E.DictSize := E.DictSize + (E.DictSize div 32) * ((CI shr 15) and $1F);
              E.HostOS := R.VInt('host OS');
              NameLen := R.VInt('name length');
              E.FileName := BytesToStr(R.Bytes(NameLen, 'name (UTF-8)'));
              Blk.Fields[High(Blk.Fields)].Value := E.FileName;
              Blk.Name := E.FileName;
              E.CompressedSize := Blk.DataSize;
              E.SplitBefore := (Flags and $8) <> 0;
              E.SplitAfter := (Flags and $10) <> 0;
            end;
          4:
            begin
              Blk.TypeName := 'Archive encryption header';
              R.VInt('encryption version');
              F2 := R.VInt('encryption flags');
              R.U8('KDF count (log2)');
              R.Bytes(16, 'salt');
              if (F2 and 1) <> 0 then
                R.Bytes(12, 'password check value');
              HeadersEncrypted := True;
            end;
          5:
            begin
              Blk.TypeName := 'End of archive';
              EndBlock := Blk;
              EndFlags := R.VInt('end of archive flags');
            end;
        else
          Blk.TypeName := Format('Unknown header type %d', [Typ]);
          Warnings.Add(Format('Unknown header type %d at 0x%x', [Typ, Pos]));
        end;

        // extra area: records of [size vint][type vint][data]
        if ExtraSize > 0 then
        begin
          ExtraStart := Length(B) - ExtraSize;
          if ExtraStart < R.P then
            Warnings.Add(Format('Extra area overlaps header fields at 0x%x', [Pos]))
          else
          begin
            R.P := ExtraStart;
            while R.P < Length(B) do
            begin
              Ex := Default(TRarExtra);
              Ex.Offset := Pos + R.P;
              RecSize := R.VInt('extra record size');
              RecEnd := R.P + RecSize;
              RecType := R.VInt('extra record type');
              Ex.RecType := RecType;
              Ex.Size := RecSize;
              if Typ = 1 then
                case RecType of
                  1:
                    begin
                      Ex.Name := 'Locator';
                      F2 := R.VInt('locator flags');
                      if (F2 and 1) <> 0 then
                      begin
                        QuickOpenOffset := R.VInt('quick open offset');
                        Ex.Desc := Format('quick open @%d ', [QuickOpenOffset]);
                      end;
                      if (F2 and 2) <> 0 then
                      begin
                        RecoveryOffset := R.VInt('recovery record offset');
                        Ex.Desc := Ex.Desc + Format('recovery @%d', [RecoveryOffset]);
                      end;
                    end;
                  2: Ex.Name := 'Metadata';
                else
                  Ex.Name := 'Unknown';
                end
              else if Typ in [2, 3] then
                case RecType of
                  1:
                    begin
                      Ex.Name := 'File encryption';
                      E.Encrypted := True;
                      V := R.VInt('encryption version');
                      F2 := R.VInt('encryption flags');
                      N := R.U8('KDF count (log2)');
                      R.Bytes(16, 'salt');
                      R.Bytes(16, 'IV');
                      if (F2 and 1) <> 0 then
                        R.Bytes(12, 'password check value');
                      Ex.Desc := Format('AES-256, version %d, KDF 2^%d, flags 0x%x', [V, N, F2]);
                    end;
                  2:
                    begin
                      Ex.Name := 'File hash';
                      V := R.VInt('hash type');
                      if (V = 0) and (RecEnd - R.P >= 32) then
                      begin
                        E.HashBLAKE2 := HexBytes(R.Bytes(32, 'BLAKE2sp hash'), 32);
                        Ex.Desc := 'BLAKE2sp ' + E.HashBLAKE2;
                      end;
                    end;
                  3:
                    begin
                      Ex.Name := 'File time';
                      F2 := R.VInt('time flags');
                      if (F2 and 1) <> 0 then
                      begin
                        if (F2 and 2) <> 0 then
                        begin
                          V := R.U32('mtime (Unix)');
                          E.MTime := UniversalTimeToLocal(UnixToDateTime(V));
                          Ex.Desc := 'mtime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss', E.MTime) + ' ';
                        end;
                        if (F2 and 4) <> 0 then
                          Ex.Desc := Ex.Desc + 'ctime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss',
                            UniversalTimeToLocal(UnixToDateTime(R.U32('ctime (Unix)')))) + ' ';
                        if (F2 and 8) <> 0 then
                          Ex.Desc := Ex.Desc + 'atime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss',
                            UniversalTimeToLocal(UnixToDateTime(R.U32('atime (Unix)')))) + ' ';
                      end
                      else
                      begin
                        if (F2 and 2) <> 0 then
                        begin
                          E.MTime := UniversalTimeToLocal(FileTimeToDT(R.U64('mtime (FILETIME)')));
                          Ex.Desc := 'mtime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', E.MTime) + ' ';
                        end;
                        if (F2 and 4) <> 0 then
                          Ex.Desc := Ex.Desc + 'ctime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss',
                            UniversalTimeToLocal(FileTimeToDT(R.U64('ctime (FILETIME)')))) + ' ';
                        if (F2 and 8) <> 0 then
                          Ex.Desc := Ex.Desc + 'atime=' + FormatDateTime('yyyy-mm-dd hh:nn:ss',
                            UniversalTimeToLocal(FileTimeToDT(R.U64('atime (FILETIME)')))) + ' ';
                      end;
                    end;
                  4:
                    begin
                      Ex.Name := 'File version';
                      R.VInt('version flags');
                      Ex.Desc := 'version ' + IntToStr(R.VInt('version number'));
                    end;
                  5:
                    begin
                      Ex.Name := 'Redirection';
                      V := R.VInt('redirection type');
                      R.VInt('redirection flags');
                      N := R.VInt('target name length');
                      E.RedirTarget := BytesToStr(R.Bytes(N, 'target name'));
                      case V of
                        1: Ex.Desc := 'Unix symlink -> ';
                        2: Ex.Desc := 'Windows symlink -> ';
                        3: Ex.Desc := 'Windows junction -> ';
                        4: Ex.Desc := 'Hard link -> ';
                        5: Ex.Desc := 'File copy -> ';
                      else
                        Ex.Desc := 'type ' + IntToStr(V) + ' -> ';
                      end;
                      Ex.Desc := Ex.Desc + E.RedirTarget;
                    end;
                  6:
                    begin
                      Ex.Name := 'Unix owner';
                      F2 := R.VInt('owner flags');
                      if (F2 and 1) <> 0 then
                        Ex.Desc := 'user=' + BytesToStr(R.Bytes(R.VInt('user name length'), 'user name')) + ' ';
                      if (F2 and 2) <> 0 then
                        Ex.Desc := Ex.Desc + 'group=' + BytesToStr(R.Bytes(R.VInt('group name length'), 'group name')) + ' ';
                      if (F2 and 4) <> 0 then
                        Ex.Desc := Ex.Desc + 'uid=' + IntToStr(R.VInt('uid')) + ' ';
                      if (F2 and 8) <> 0 then
                        Ex.Desc := Ex.Desc + 'gid=' + IntToStr(R.VInt('gid'));
                    end;
                  7: Ex.Name := 'Service data';
                else
                  Ex.Name := 'Unknown';
                end;
              Ex.Desc := Trim(Ex.Desc);
              AddExtra(Blk.Extras, Ex);
              if (RecEnd < R.P) or (RecEnd > Length(B)) then
              begin
                Warnings.Add(Format('Bad extra record size at 0x%x', [Ex.Offset]));
                Break;
              end;
              if RecEnd > R.P then
                R.Bytes(RecEnd - R.P, 'extra record data');
            end;
          end;
        end;
        if (Typ = 2) and (E <> nil) then
        begin
          E.Index := Entries.Count;
          Entries.Add(E);
          E := nil;
        end
        else if (Typ = 3) and (E <> nil) then
          FreeAndNil(E);
      except
        on Ex2: ERarFormat do
        begin
          Warnings.Add(Ex2.Message);
          FreeAndNil(E);
        end;
      end;
    finally
      R.Free;
    end;
    E := nil;
    if not Blk.CRCOk then
      Warnings.Add(Format('Header CRC mismatch in block #%d at 0x%x (stored %.8x, computed %.8x)',
        [Blk.Index, Blk.Offset, Blk.CRCStored, Blk.CRCCalc]));
    if Blk.HeadType = 4 then
    begin
      Warnings.Add('Archive headers are encrypted - the file list needs the password');
      Break;
    end;
    if Blk.HeadType = 5 then
      Break;
    Pos := Blk.DataOffset + Blk.DataSize;
    if Blk.DataOffset + Blk.DataSize > FileSize then
      Warnings.Add(Format('Data of block #%d runs past end of file', [Blk.Index]));
  end;
  if (EndBlock = nil) and not HeadersEncrypted then
    Warnings.Add('No end-of-archive header found (truncated or multi-volume archive)');
end;

procedure TRarArchiveInfo.ParseRar4(AStream: TStream);
var
  Pos, AddSize: Int64;
  Blk: TRarBlock;
  R: TFieldReader;
  B, NameB: TBytes;
  Typ, I, Z: Integer;
  Flags, HSize, NameSize: Word;
  E: TRarEntryInfo;
  PackLo, UnpLo, HighPack, HighUnp: LongWord;
begin
  Pos := SigOffset;
  while Pos + 7 <= FileSize do
  begin
    B := ReadAt(AStream, Pos, 7);
    if Length(B) < 7 then
      Break;
    Typ := B[2];
    Flags := B[3] or (B[4] shl 8);
    HSize := B[5] or (B[6] shl 8);
    if HSize < 7 then
    begin
      Warnings.Add(Format('Invalid header size %d at 0x%x - stopping', [HSize, Pos]));
      Break;
    end;
    B := ReadAt(AStream, Pos, HSize);
    if Length(B) < HSize then
    begin
      Warnings.Add(Format('Header at 0x%x runs past end of file', [Pos]));
      Break;
    end;
    Blk := NewBlock(Blocks, Pos);
    Blk.HeaderLen := HSize;
    Blk.HeadType := Typ;
    Blk.HeadFlags := Flags;
    Blk.DataOffset := Pos + HSize;
    E := nil;
    R := TFieldReader.Create(B, Pos, Blk);
    try
      try
        Blk.CRCStored := R.U16('HEAD_CRC');
        R.U8('HEAD_TYPE');
        R.U16('HEAD_FLAGS');
        R.U16('HEAD_SIZE');
        AddSize := 0;
        if Typ <> $72 then
        begin
          Blk.CRCCalc := CRCOfBytes(B, 2, HSize - 2) and $FFFF;
          Blk.CRCChecked := True;
        end;
        case Typ of
          $72:
            Blk.TypeName := 'Marker block (RAR 1.5-4.x signature)';
          $73:
            begin
              Blk.TypeName := 'Archive header';
              MainBlock := Blk;
              ArchiveFlags := Flags;
              IsVolume := (Flags and $0001) <> 0;
              HasComment := (Flags and $0002) <> 0;
              IsLocked := (Flags and $0004) <> 0;
              IsSolid := (Flags and $0008) <> 0;
              HasRecovery := (Flags and $0040) <> 0;
              HeadersEncrypted := (Flags and $0080) <> 0;
              IsFirstVolume := (Flags and $0100) <> 0;
              R.U16('RESERVED1 (high pos AV)');
              R.U32('RESERVED2 (pos AV)');
              if ((Flags and $0200) <> 0) and (R.Remaining > 0) then
                R.U8('ENCRYPT_VER');
            end;
          $74, $7A:
            begin
              if Typ = $74 then
                Blk.TypeName := 'File header'
              else
                Blk.TypeName := 'Service sub-block';
              PackLo := R.U32('PACK_SIZE');
              UnpLo := R.U32('UNP_SIZE');
              E := TRarEntryInfo.Create;
              E.Block := Blk;
              E.FileFlags := Flags;
              E.HostOS := R.U8('HOST_OS');
              E.CRC32 := R.U32('FILE_CRC');
              E.HasCRC := True;
              E.MTimeRaw := R.U32('FTIME (DOS date/time)');
              E.MTime := DosToDateTime(E.MTimeRaw);
              E.AlgVersion := R.U8('UNP_VER');
              E.Method := R.U8('METHOD') - $30;
              NameSize := R.U16('NAME_SIZE');
              E.Attributes := R.U32('ATTR');
              HighPack := 0;
              HighUnp := 0;
              if (Flags and $0100) <> 0 then
              begin
                HighPack := R.U32('HIGH_PACK_SIZE');
                HighUnp := R.U32('HIGH_UNP_SIZE');
              end;
              AddSize := Int64(PackLo) or (Int64(HighPack) shl 32);
              E.CompressedSize := AddSize;
              E.UncompressedSize := Int64(UnpLo) or (Int64(HighUnp) shl 32);
              NameB := R.Bytes(NameSize, 'FILE_NAME');
              Z := -1;
              for I := 0 to High(NameB) do
                if NameB[I] = 0 then
                begin
                  Z := I;
                  Break;
                end;
              if (Flags and $0200) <> 0 then
              begin
                if Z < 0 then
                  E.FileName := BytesToStr(NameB)           // UTF-8 name
                else
                  E.FileName := DecodeRar4UnicodeName(NameB, Z);
              end
              else
                E.FileName := OemToUTF8Name(BytesToStr(NameB));
              E.FileName := StringReplace(E.FileName, '\', '/', [rfReplaceAll]);
              Blk.Fields[High(Blk.Fields)].Value := E.FileName;
              Blk.Name := E.FileName;
              if ((Flags and $0400) <> 0) and (R.Remaining >= 8) then
                R.Bytes(8, 'SALT');
              if ((Flags and $1000) <> 0) and (R.Remaining > 0) then
                R.Bytes(R.Remaining, 'EXT_TIME');
              E.SplitBefore := (Flags and $0001) <> 0;
              E.SplitAfter := (Flags and $0002) <> 0;
              E.Encrypted := (Flags and $0004) <> 0;
              E.Solid := (Flags and $0010) <> 0;
              E.Directory := (Flags and $00E0) = $00E0;
              if not E.Directory then
                E.DictSize := Int64(64 * 1024) shl ((Flags and $00E0) shr 5);
            end;
          $7B:
            begin
              Blk.TypeName := 'End of archive';
              EndBlock := Blk;
              EndFlags := Flags;
              if ((Flags and $0002) <> 0) and (R.Remaining >= 4) then
                R.U32('ARC_DATA_CRC');
              if ((Flags and $0008) <> 0) and (R.Remaining >= 2) then
                VolumeNumber := R.U16('VOL_NUMBER');
            end;
          $75: Blk.TypeName := 'Old-style comment';
          $76: Blk.TypeName := 'Old-style authenticity';
          $77: Blk.TypeName := 'Old-style sub-block';
          $78: Blk.TypeName := 'Old-style recovery record';
          $79: Blk.TypeName := 'Old-style authenticity 2';
        else
          Blk.TypeName := Format('Unknown block type 0x%.2x', [Typ]);
          Warnings.Add(Format('Unknown block type 0x%.2x at 0x%x', [Typ, Pos]));
        end;
        // other block types may carry ADD_SIZE when bit 0x8000 is set
        if (Typ in [$75..$79]) and ((Flags and $8000) <> 0) and (R.Remaining >= 4) then
          AddSize := R.U32('ADD_SIZE');
        if R.Remaining > 0 then
          R.Bytes(R.Remaining, 'remaining header bytes');
        Blk.DataSize := AddSize;
        if E <> nil then
        begin
          if Typ = $74 then
          begin
            E.Index := Entries.Count;
            Entries.Add(E);
          end
          else
            E.Free;
          E := nil;
        end;
      except
        on Ex: ERarFormat do
        begin
          Warnings.Add(Ex.Message);
          E.Free;
        end;
      end;
    finally
      R.Free;
    end;
    if not Blk.CRCOk then
      Warnings.Add(Format('Header CRC mismatch in block #%d at 0x%x (stored %.4x, computed %.4x)',
        [Blk.Index, Blk.Offset, Blk.CRCStored, Blk.CRCCalc]));
    if Typ = $7B then
      Break;
    if (Typ = $73) and HeadersEncrypted then
    begin
      Warnings.Add('Archive headers are encrypted - the file list needs the password');
      Break;
    end;
    Pos := Blk.DataOffset + Blk.DataSize;
    if Pos > FileSize then
      Warnings.Add(Format('Data of block #%d runs past end of file', [Blk.Index]));
  end;
  if (EndBlock = nil) and not HeadersEncrypted then
    Warnings.Add('No end-of-archive block found (old RAR version, truncated or multi-volume archive)');
end;

procedure TRarArchiveInfo.LoadFromFile(const AFileName: string);
var
  FS: TFileStream;
  T0: QWord;
  Fmt: TArchiveFormat;
begin
  T0 := GetTickCount64;
  FileName := AFileName;
  Entries.Clear;
  Blocks.Clear;
  Warnings.Clear;
  if not DetectArchiveFormat(AFileName, Fmt, SigOffset) or not (Fmt in [afRar4, afRar5]) then
    raise Exception.Create('RAR signature not found');
  FFormat := Fmt;
  FS := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyNone);
  try
    FileSize := FS.Size;
    if SigOffset > 0 then
      Warnings.Add(Format('%d bytes before the RAR signature (self-extracting archive stub)', [SigOffset]));
    if FFormat = afRar5 then
      ParseRar5(FS)
    else
      ParseRar4(FS);
  finally
    FS.Free;
  end;
  if IsVolume then
    Warnings.Add(Format('Multi-volume archive (volume %d) - only this volume is listed', [VolumeNumber + 1]));
  ParseTimeMs := GetTickCount64 - T0;
end;

{ ---------- names / decoders ---------- }

function RarMethodName(AMethod: Integer): string;
begin
  case AMethod of
    0: Result := 'Store';
    1: Result := 'Fastest';
    2: Result := 'Fast';
    3: Result := 'Normal';
    4: Result := 'Good';
    5: Result := 'Best';
  else
    Result := 'Unknown(' + IntToStr(AMethod) + ')';
  end;
end;

function RarHostOSName(AIsRar5: Boolean; AHostOS: Integer): string;
begin
  if AIsRar5 then
    case AHostOS of
      0: Result := 'Windows';
      1: Result := 'Unix';
    else
      Result := 'Unknown(' + IntToStr(AHostOS) + ')';
    end
  else
    case AHostOS of
      0: Result := 'MS-DOS';
      1: Result := 'OS/2';
      2: Result := 'Windows';
      3: Result := 'Unix';
      4: Result := 'Mac OS';
      5: Result := 'BeOS';
    else
      Result := 'Unknown(' + IntToStr(AHostOS) + ')';
    end;
end;

function FlagList(F: QWord; const ANames: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ANames) do
    if (ANames[I] <> '') and ((F and (QWord(1) shl I)) <> 0) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + ANames[I];
    end;
  if Result = '' then
    Result := '(none)';
end;

function DecodeRar5HeaderFlags(F: QWord): string;
begin
  Result := FlagList(F, ['ExtraArea', 'DataArea', 'SkipIfUnknown', 'SplitBefore', 'SplitAfter',
    'Child', 'PreserveChild']);
end;

function DecodeRar5ArchiveFlags(F: QWord): string;
begin
  Result := FlagList(F, ['Volume', 'VolumeNumber', 'Solid', 'RecoveryRecord', 'Locked']);
end;

function DecodeRar5FileFlags(F: QWord): string;
begin
  Result := FlagList(F, ['Directory', 'UnixMTime', 'CRC32', 'UnknownUnpSize']);
end;

function DecodeRar4MainFlags(F: QWord): string;
begin
  Result := FlagList(F, ['Volume', 'Comment', 'Locked', 'Solid', 'NewNaming', 'AuthInfo',
    'RecoveryRecord', 'EncryptedHeaders', 'FirstVolume', 'EncryptVer', '', '', '', '', '', 'AddSize']);
end;

function DecodeRar4FileFlags(F: QWord): string;
const
  Dict: array[0..7] of string = ('dict 64K', 'dict 128K', 'dict 256K', 'dict 512K', 'dict 1M',
    'dict 2M', 'dict 4M', 'directory');
begin
  Result := FlagList(F and not QWord($E0), ['SplitBefore', 'SplitAfter', 'Encrypted', 'Comment', 'Solid',
    '', '', '', 'LargeFile', 'Unicode', 'Salt', 'Version', 'ExtTime', '', '', 'AddSize']);
  Result := Result + ', ' + Dict[(F and $E0) shr 5];
end;

function DecodeWinAttributes(A: QWord): string;
begin
  Result := '';
  if (A and $01) <> 0 then Result := Result + 'R';
  if (A and $02) <> 0 then Result := Result + 'H';
  if (A and $04) <> 0 then Result := Result + 'S';
  if (A and $10) <> 0 then Result := Result + 'D';
  if (A and $20) <> 0 then Result := Result + 'A';
  if Result = '' then Result := '-';
end;

end.
