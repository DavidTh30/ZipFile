unit uDevInfoRar;

{ RAR-specific views for the developer window: overview, raw entry table,
  per-entry detail, annotated block dumps and the file layout map. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, ComCtrls, BGRABitmap, BGRABitmapTypes,
  uArchiveBase, uRarInspector;

const
  RAR_HEX_ENTRY = 0;
  RAR_HEX_MAIN = 1;
  RAR_HEX_END = 2;
  RAR_HEX_START = 3;
  RAR_HEX_FILEEND = 4;
  RAR_HEX_CUSTOM = 5;

procedure DevAddKV(LV: TListView; const K, V: string);
procedure DevAddSection(LV: TListView; const ATitle: string);

procedure SetupEntryColumns(LV: TListView; ARar: Boolean);
procedure FillRarOverview(LV: TListView; A: TRarArchiveInfo);
procedure FillRarEntries(LV: TListView; A: TRarArchiveInfo);
function RarEntryDetailText(A: TRarArchiveInfo; E: TRarEntryInfo): string;
function RarBlockDump(A: TRarArchiveInfo; Blk: TRarBlock; AMaxData: Integer): string;
procedure DrawRarLayout(B: TBGRABitmap; A: TRarArchiveInfo; X0, X1, Y, H: Single; ASel: Integer);
procedure RarHexItems(AItems: TStrings);

implementation

uses
  Math, uZipInspector, uBGRAUI;

function IfS(ACond: Boolean; const ATrue, AFalse: string): string;
begin
  if ACond then Result := ATrue else Result := AFalse;
end;

procedure DevAddKV(LV: TListView; const K, V: string);
var
  It: TListItem;
begin
  It := LV.Items.Add;
  It.Caption := K;
  It.SubItems.Add(V);
end;

procedure DevAddSection(LV: TListView; const ATitle: string);
var
  It: TListItem;
begin
  if LV.Items.Count > 0 then
    LV.Items.Add.Caption := '';
  It := LV.Items.Add;
  It.Caption := '[ ' + ATitle + ' ]';
  It.SubItems.Add('');
end;

procedure SetupEntryColumns(LV: TListView; ARar: Boolean);
type
  TCol = record
    C: string;
    W: Integer;
    R: Boolean;
  end;
const
  ZipCols: array[0..18] of TCol = (
    (C: '#'; W: 40; R: False), (C: 'Name'; W: 220; R: False), (C: 'Method'; W: 80; R: False),
    (C: 'Flags'; W: 60; R: False), (C: 'Made by'; W: 120; R: False), (C: 'Needs'; W: 50; R: False),
    (C: 'DOS date/time'; W: 130; R: False), (C: 'CRC32'; W: 75; R: False), (C: 'Comp'; W: 80; R: True),
    (C: 'Uncomp'; W: 80; R: True), (C: 'Saved'; W: 55; R: True), (C: 'LocalHdr@'; W: 80; R: True),
    (C: 'Data@'; W: 80; R: True), (C: 'Central@'; W: 80; R: True), (C: 'N/E/C len'; W: 70; R: False),
    (C: 'IntAttr'; W: 60; R: False), (C: 'ExtAttr'; W: 85; R: False), (C: 'Extra IDs'; W: 110; R: False),
    (C: 'Local'; W: 60; R: False));
  RarCols: array[0..17] of TCol = (
    (C: '#'; W: 40; R: False), (C: 'Name'; W: 220; R: False), (C: 'Method'; W: 80; R: False),
    (C: 'Host OS'; W: 70; R: False), (C: 'Hdr flags'; W: 70; R: False), (C: 'File flags'; W: 70; R: False),
    (C: 'Attr'; W: 70; R: False), (C: 'Modified'; W: 130; R: False), (C: 'CRC32'; W: 75; R: False),
    (C: 'Packed'; W: 80; R: True), (C: 'Unpacked'; W: 80; R: True), (C: 'Saved'; W: 55; R: True),
    (C: 'Dict'; W: 60; R: True), (C: 'Header@'; W: 80; R: True), (C: 'Hdr len'; W: 55; R: True),
    (C: 'Data@'; W: 80; R: True), (C: 'Hdr CRC'; W: 60; R: False), (C: 'Extras / notes'; W: 200; R: False));
var
  I: Integer;
  Col: TListColumn;

  procedure AddCol(const ACol: TCol);
  begin
    Col := LV.Columns.Add;
    Col.Caption := ACol.C;
    Col.Width := ACol.W;
    if ACol.R then
      Col.Alignment := taRightJustify;
  end;

begin
  LV.Items.Clear;
  LV.Columns.BeginUpdate;
  try
    LV.Columns.Clear;
    if ARar then
      for I := 0 to High(RarCols) do
        AddCol(RarCols[I])
    else
      for I := 0 to High(ZipCols) do
        AddCol(ZipCols[I]);
  finally
    LV.Columns.EndUpdate;
  end;
end;

function MainFlagsText(A: TRarArchiveInfo): string;
begin
  if A.ArchiveFormat = afRar5 then
    Result := DecodeRar5ArchiveFlags(A.ArchiveFlags)
  else
    Result := DecodeRar4MainFlags(A.ArchiveFlags);
end;

function DictText(ASize: Int64): string;
begin
  if ASize <= 0 then
    Result := '-'
  else if ASize >= 1024 * 1024 then
    Result := IntToStr(ASize div (1024 * 1024)) + ' MB'
  else
    Result := IntToStr(ASize div 1024) + ' KB';
end;

procedure FillRarOverview(LV: TListView; A: TRarArchiveInfo);
var
  Blk: TRarBlock;
  E: TRarEntryInfo;
  Methods: array[0..7] of Integer;
  I, Solid, Split, Bad: Integer;
  S: string;
  Headers, Data: Int64;
begin
  DevAddSection(LV, 'File');
  DevAddKV(LV, 'Path', A.FileName);
  DevAddKV(LV, 'File size', FormatBytesFull(A.FileSize));
  DevAddKV(LV, 'Parse time', Format('%d ms', [A.ParseTimeMs]));
  DevAddKV(LV, 'Format', A.FormatName);
  DevAddKV(LV, 'Signature offset', Format('%d (0x%x)%s', [A.SigOffset, A.SigOffset,
    IfS(A.SigOffset > 0, '  - self-extracting stub before it', '')]));

  DevAddSection(LV, 'Main archive header');
  if A.MainBlock <> nil then
  begin
    DevAddKV(LV, 'Header offset', Format('%d (0x%x), %d bytes', [A.MainBlock.Offset, A.MainBlock.Offset,
      A.MainBlock.HeaderLen]));
    DevAddKV(LV, 'Archive flags', Format('0x%x  %s', [A.ArchiveFlags, MainFlagsText(A)]));
  end
  else
    DevAddKV(LV, 'Main header', 'MISSING');
  DevAddKV(LV, 'Solid', BoolToStr(A.IsSolid, 'Yes', 'No'));
  DevAddKV(LV, 'Multi-volume', BoolToStr(A.IsVolume, Format('Yes (volume %d)', [A.VolumeNumber + 1]), 'No'));
  DevAddKV(LV, 'Locked', BoolToStr(A.IsLocked, 'Yes', 'No'));
  DevAddKV(LV, 'Recovery record', BoolToStr(A.HasRecovery, 'Yes', 'No'));
  DevAddKV(LV, 'Headers encrypted', BoolToStr(A.HeadersEncrypted, 'YES - needs password', 'No'));
  if A.QuickOpenOffset > 0 then
    DevAddKV(LV, 'Quick open record offset', IntToStr(A.QuickOpenOffset));
  if A.RecoveryOffset > 0 then
    DevAddKV(LV, 'Recovery record offset', IntToStr(A.RecoveryOffset));
  S := A.ServiceNames;
  if S = '' then
    S := '(none)';
  DevAddKV(LV, 'Service blocks', S);

  DevAddSection(LV, 'End of archive');
  if A.EndBlock <> nil then
  begin
    DevAddKV(LV, 'Header offset', Format('%d (0x%x)', [A.EndBlock.Offset, A.EndBlock.Offset]));
    DevAddKV(LV, 'End flags', Format('0x%x%s', [A.EndFlags,
      IfS((A.EndFlags and 1) <> 0, '  (more volumes follow)', '')]));
    S := '';
    if A.EndBlock.DataOffset + A.EndBlock.DataSize < A.FileSize then
      S := Format('%d bytes after end-of-archive', [A.FileSize - A.EndBlock.DataOffset - A.EndBlock.DataSize]);
    if S <> '' then
      DevAddKV(LV, 'Trailing data', S);
  end
  else
    DevAddKV(LV, 'End of archive', 'not found');

  FillChar(Methods, SizeOf(Methods), 0);
  Solid := 0;
  Split := 0;
  for E in A.Entries do
  begin
    if (E.Method >= 0) and (E.Method <= High(Methods)) then
      Inc(Methods[E.Method]);
    if E.Solid then Inc(Solid);
    if E.SplitBefore or E.SplitAfter then Inc(Split);
  end;
  Headers := 0;
  Data := 0;
  Bad := 0;
  for Blk in A.Blocks do
  begin
    Inc(Headers, Blk.HeaderLen);
    Inc(Data, Blk.DataSize);
    if not Blk.CRCOk then Inc(Bad);
  end;

  DevAddSection(LV, 'Content statistics');
  DevAddKV(LV, 'Files / folders', Format('%d / %d', [A.FileCount, A.DirCount]));
  DevAddKV(LV, 'Total unpacked', FormatBytesFull(A.TotalUncompressed));
  DevAddKV(LV, 'Total packed', FormatBytesFull(A.TotalCompressed));
  DevAddKV(LV, 'Space saved', FormatFloat('0.00', A.OverallSavedPercent) + ' %');
  if A.TotalCompressed > 0 then
    DevAddKV(LV, 'Compression factor', FormatFloat('0.000', A.TotalUncompressed / A.TotalCompressed) + ' : 1');
  DevAddKV(LV, 'Header bytes / data bytes', Format('%s / %s', [FormatSize(Headers), FormatSize(Data)]));
  S := '';
  for I := 0 to High(Methods) do
    if Methods[I] > 0 then
      S := S + Format('%s=%d  ', [RarMethodName(I), Methods[I]]);
  DevAddKV(LV, 'Compression methods', Trim(S));
  DevAddKV(LV, 'Solid-flagged entries', IntToStr(Solid));
  DevAddKV(LV, 'Encrypted entries', IntToStr(A.EncryptedCount));
  DevAddKV(LV, 'Split (multi-volume) entries', IntToStr(Split));

  DevAddSection(LV, Format('Blocks (%d) - header CRC errors: %d', [A.Blocks.Count, Bad]));
  for Blk in A.Blocks do
  begin
    S := Format('@%d  hdr %d B', [Blk.Offset, Blk.HeaderLen]);
    if Blk.DataSize > 0 then
      S := S + Format('  data %s', [FormatSize(Blk.DataSize)]);
    if Blk.CRCChecked then
      S := S + IfS(Blk.CRCOk, '  CRC ok', '  CRC BAD');
    if Blk.Name <> '' then
      S := S + '  "' + Blk.Name + '"';
    DevAddKV(LV, Format('#%d %s', [Blk.Index, Blk.TypeName]), S);
  end;

  DevAddSection(LV, Format('Integrity warnings (%d)', [A.Warnings.Count]));
  if A.Warnings.Count = 0 then
    DevAddKV(LV, 'Structure', 'OK - no inconsistencies found')
  else
    for I := 0 to A.Warnings.Count - 1 do
      DevAddKV(LV, 'Warning ' + IntToStr(I + 1), A.Warnings[I]);
end;

procedure FillRarEntries(LV: TListView; A: TRarArchiveInfo);
var
  E: TRarEntryInfo;
  It: TListItem;
  S: string;
  I: Integer;
begin
  LV.Items.BeginUpdate;
  try
    LV.Items.Clear;
    for E in A.Entries do
    begin
      It := LV.Items.Add;
      It.Data := Pointer(PtrInt(E.Index));
      It.Caption := IntToStr(E.Index);
      It.SubItems.Add(E.FileName);
      It.SubItems.Add(Format('%d %s', [E.Method, RarMethodName(E.Method)]));
      It.SubItems.Add(RarHostOSName(E.IsRar5, E.HostOS));
      It.SubItems.Add('0x' + IntToHex(E.Block.HeadFlags, 4));
      It.SubItems.Add('0x' + IntToHex(E.FileFlags, 4));
      It.SubItems.Add(Format('0x%x %s', [E.Attributes, DecodeWinAttributes(E.Attributes)]));
      It.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', E.MTime));
      if E.HasCRC and not E.Directory then
        It.SubItems.Add(IntToHex(E.CRC32, 8))
      else
        It.SubItems.Add('-');
      It.SubItems.Add(IntToStr(E.CompressedSize));
      It.SubItems.Add(IntToStr(E.UncompressedSize));
      It.SubItems.Add(FormatFloat('0.0', E.SavedPercent) + '%');
      It.SubItems.Add(DictText(E.DictSize));
      It.SubItems.Add(IntToStr(E.Block.Offset));
      It.SubItems.Add(IntToStr(E.Block.HeaderLen));
      It.SubItems.Add(IntToStr(E.Block.DataOffset));
      It.SubItems.Add(BoolToStr(E.Block.CRCOk, 'OK', 'BAD'));
      S := '';
      for I := 0 to High(E.Block.Extras) do
        S := S + E.Block.Extras[I].Name + '; ';
      if E.Encrypted then S := S + 'ENCRYPTED; ';
      if E.Solid then S := S + 'solid; ';
      if E.SplitBefore then S := S + 'split<; ';
      if E.SplitAfter then S := S + 'split>; ';
      It.SubItems.Add(Trim(S));
    end;
  finally
    LV.Items.EndUpdate;
  end;
end;

function FieldTable(Blk: TRarBlock): string;
var
  SL: TStringList;
  I: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Add('File ofs  +Rel  Size  Field                          Value');
    SL.Add('--------  ----  ----  -----------------------------  ------------------------------');
    for I := 0 to High(Blk.Fields) do
      SL.Add(Format('%s  +%.2x  %4d  %-29s  %s', [IntToHex(Blk.Fields[I].Ofs, 8),
        Blk.Fields[I].Ofs - Blk.Offset, Blk.Fields[I].Size, Blk.Fields[I].Name, Blk.Fields[I].Value]));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function RarEntryDetailText(A: TRarArchiveInfo; E: TRarEntryInfo): string;
var
  SL: TStringList;
  I: Integer;
  Blk: TRarBlock;

  procedure KV(const K, V: string);
  begin
    SL.Add(Format('  %-28s %s', [K, V]));
  end;

begin
  Blk := E.Block;
  SL := TStringList.Create;
  try
    SL.Add(Format('ENTRY #%d  %s', [E.Index, E.FileName]));
    SL.Add(StringOfChar('=', 78));
    SL.Add(Format('%s block #%d (%s)', [A.FormatName, Blk.Index, Blk.TypeName]));
    KV('Header offset', Format('%d (0x%x), %d bytes', [Blk.Offset, Blk.Offset, Blk.HeaderLen]));
    KV('Header CRC', Format('stored %.8x, computed %.8x  %s', [Blk.CRCStored, Blk.CRCCalc,
      BoolToStr(Blk.CRCOk, 'OK', '<-- MISMATCH')]));
    if E.IsRar5 then
    begin
      KV('Header flags', Format('0x%x  %s', [Blk.HeadFlags, DecodeRar5HeaderFlags(Blk.HeadFlags)]));
      KV('File flags', Format('0x%x  %s', [E.FileFlags, DecodeRar5FileFlags(E.FileFlags)]));
      KV('Compression version', IntToStr(E.AlgVersion) + IfS(E.AlgVersion = 0, ' (RAR 5.0)', ' (RAR 7.0+)'));
    end
    else
    begin
      KV('Header flags', Format('0x%.4x  %s', [E.FileFlags, DecodeRar4FileFlags(E.FileFlags)]));
      KV('Unpack version (UNP_VER)', Format('%d (RAR %d.%d)', [E.AlgVersion, E.AlgVersion div 10, E.AlgVersion mod 10]));
    end;
    KV('Method', Format('%d  %s', [E.Method, RarMethodName(E.Method)]));
    KV('Dictionary', DictText(E.DictSize));
    KV('Solid', BoolToStr(E.Solid, 'Yes (depends on previous files)', 'No'));
    KV('Host OS', RarHostOSName(E.IsRar5, E.HostOS));
    KV('Attributes', Format('0x%x  %s', [E.Attributes, DecodeWinAttributes(E.Attributes)]));
    if E.IsRar5 then
      KV('mtime raw', Format('%d (Unix seconds)', [E.MTimeRaw]))
    else
      KV('FTIME raw', Format('0x%.8x (DOS date/time)', [E.MTimeRaw]));
    KV('Modified', FormatDateTime('yyyy-mm-dd hh:nn:ss', E.MTime) + ' (local)');
    if E.HasCRC then
      KV('Data CRC32', Format('0x%.8x', [E.CRC32]))
    else
      KV('Data CRC32', '(not stored)');
    if E.HashBLAKE2 <> '' then
      KV('BLAKE2sp', E.HashBLAKE2);
    KV('Packed size', FormatBytesFull(E.CompressedSize));
    KV('Unpacked size', FormatBytesFull(E.UncompressedSize) + IfS(E.UnknownSize, ' (declared unknown)', ''));
    KV('Space saved', FormatFloat('0.00', E.SavedPercent) + ' %');
    KV('Data offset', Format('%d (0x%x) .. %d', [Blk.DataOffset, Blk.DataOffset, Blk.DataOffset + Blk.DataSize - 1]));
    KV('Directory', BoolToStr(E.Directory, True));
    KV('Encrypted', BoolToStr(E.Encrypted, True));
    KV('Split before / after', Format('%s / %s', [BoolToStr(E.SplitBefore, True), BoolToStr(E.SplitAfter, True)]));
    if E.RedirTarget <> '' then
      KV('Link target', E.RedirTarget);
    SL.Add('');
    SL.Add('Extra records');
    if Length(Blk.Extras) = 0 then
      SL.Add('  (none)');
    for I := 0 to High(Blk.Extras) do
      SL.Add(Format('  type %d  %-20s size=%-4d @0x%x  %s', [Blk.Extras[I].RecType, Blk.Extras[I].Name,
        Blk.Extras[I].Size, Blk.Extras[I].Offset, Blk.Extras[I].Desc]));
    SL.Add('');
    SL.Add('Raw header fields');
    SL.Add(FieldTable(Blk));
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function RarBlockDump(A: TRarArchiveInfo; Blk: TRarBlock; AMaxData: Integer): string;
var
  Len: Int64;
  B: TBytes;
begin
  Len := Blk.HeaderLen + Min(Blk.DataSize, AMaxData);
  B := ReadFileRegion(A.FileName, Blk.Offset, Len);
  Result := Format('%s block #%d: %s' + LineEnding + 'header %d..%d', [A.FormatName, Blk.Index, Blk.TypeName,
    Blk.Offset, Blk.Offset + Blk.HeaderLen - 1]);
  if Blk.DataSize > 0 then
    Result := Result + Format('   data %d..%d (first %d bytes shown)', [Blk.DataOffset,
      Blk.DataOffset + Blk.DataSize - 1, Min(Blk.DataSize, AMaxData)]);
  Result := Result + LineEnding + LineEnding + FieldTable(Blk) + LineEnding + HexDump(B, Blk.Offset);
end;

procedure DrawRarLayout(B: TBGRABitmap; A: TRarArchiveInfo; X0, X1, Y, H: Single; ASel: Integer);
var
  Blk: TRarBlock;
  P0, P1: Single;
  C: TBGRAPixel;
  Cnt: Integer;
  IsFile, IsMain, IsEnd: Boolean;

  function MapPos(AOfs: Int64): Single;
  begin
    Result := X0 + (X1 - X0) * AOfs / Max(A.FileSize, 1);
  end;

begin
  B.FillRectAntialias(X0, Y, X1, Y + H, BGRA(230, 233, 240));
  if A.SigOffset > 0 then
    B.FillRectAntialias(MapPos(0), Y, MapPos(A.SigOffset), Y + H, BGRA(150, 150, 150));
  Cnt := 0;
  for Blk in A.Blocks do
  begin
    if A.ArchiveFormat = afRar5 then
    begin
      IsFile := Blk.HeadType = 2;
      IsMain := (Blk.HeadType = -1) or (Blk.HeadType = 1) or (Blk.HeadType = 4);
      IsEnd := Blk.HeadType = 5;
    end
    else
    begin
      IsFile := Blk.HeadType = $74;
      IsMain := Blk.HeadType in [$72, $73];
      IsEnd := Blk.HeadType = $7B;
    end;
    if IsMain then
      C := BGRA(140, 90, 220)
    else if IsEnd then
      C := BGRA(220, 40, 40)
    else if IsFile then
      C := BGRA(240, 150, 40)
    else
      C := BGRA(120, 120, 140);   // service / old blocks
    P0 := MapPos(Blk.Offset);
    P1 := MapPos(Blk.Offset + Blk.HeaderLen);
    B.FillRectAntialias(P0, Y, Max(P1, P0 + 0.6), Y + H, C);
    if Blk.DataSize > 0 then
    begin
      P0 := P1;
      P1 := MapPos(Blk.DataOffset + Blk.DataSize);
      if IsFile then
      begin
        if Odd(Cnt) then C := BGRA(40, 180, 100) else C := BGRA(30, 140, 230);
        Inc(Cnt);
      end
      else
        C := BGRA(170, 170, 185);
      B.FillRectAntialias(P0, Y, Max(P1, P0 + 0.6), Y + H, C);
    end;
    if (ASel >= 0) and (ASel < A.Entries.Count) and (A.Entries[ASel].Block = Blk) then
      B.RectangleAntialias(MapPos(Blk.Offset) - 1, Y - 3, Max(MapPos(Blk.DataOffset + Blk.DataSize),
        MapPos(Blk.Offset) + 2) + 1, Y + H + 3, BGRA(220, 30, 60), 2);
  end;
  B.RectangleAntialias(X0, Y, X1, Y + H, BGRA(150, 160, 180), 1);
end;

procedure RarHexItems(AItems: TStrings);
begin
  AItems.Clear;
  AItems.Add('File header block + data (selected entry)');
  AItems.Add('Signature + main archive header');
  AItems.Add('End of archive header');
  AItems.Add('File start (first 4 KB)');
  AItems.Add('File end (last 4 KB)');
  AItems.Add('Custom range');
end;

end.
