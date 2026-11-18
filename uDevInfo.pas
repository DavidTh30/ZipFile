unit uDevInfo;

{ Developer information window: everything about the open archive
  (EOCD / Zip64 / central directory / local headers / extra fields),
  annotated hex dumps, a BGRABitmap chart + file layout map,
  the live operation log, and build / runtime environment. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ComCtrls, ExtCtrls,
  StdCtrls, uArchiveBase, uZipInspector, uRarInspector, uDevLog;

type
  TOpStats = record
    Valid: Boolean;
    Name: string;
    Ms: QWord;
    InBytes: Int64;
    OutBytes: Int64;
    When: TDateTime;
  end;

  { TfrmDevInfo }

  TfrmDevInfo = class(TForm)
    btnClose: TButton;
    btnCopyReport: TButton;
    btnEnvRefresh: TButton;
    btnHexGo: TButton;
    btnLogClear: TButton;
    btnLogCopy: TButton;
    btnLogSave: TButton;
    btnSaveReport: TButton;
    cbHexSource: TComboBox;
    chkAutoScroll: TCheckBox;
    chkStayOnTop: TCheckBox;
    dlgSave: TSaveDialog;
    edtHexLen: TEdit;
    edtHexOffset: TEdit;
    lblHexLen: TLabel;
    lblHexOffset: TLabel;
    lvEntries: TListView;
    lvEnv: TListView;
    lvOverview: TListView;
    memoEntry: TMemo;
    memoHex: TMemo;
    memoLog: TMemo;
    pbChart: TPaintBox;
    pcMain: TPageControl;
    pnlBottom: TPanel;
    pnlEnvTop: TPanel;
    pnlHexTop: TPanel;
    pnlLogTop: TPanel;
    splEntries: TSplitter;
    tmrEnv: TTimer;
    tsChart: TTabSheet;
    tsEntries: TTabSheet;
    tsEnv: TTabSheet;
    tsHex: TTabSheet;
    tsLog: TTabSheet;
    tsOverview: TTabSheet;
    procedure btnCloseClick(Sender: TObject);
    procedure btnCopyReportClick(Sender: TObject);
    procedure btnEnvRefreshClick(Sender: TObject);
    procedure btnHexGoClick(Sender: TObject);
    procedure btnLogClearClick(Sender: TObject);
    procedure btnLogCopyClick(Sender: TObject);
    procedure btnLogSaveClick(Sender: TObject);
    procedure btnSaveReportClick(Sender: TObject);
    procedure cbHexSourceChange(Sender: TObject);
    procedure chkStayOnTopChange(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure lvEntriesSelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure pbChartPaint(Sender: TObject);
    procedure pcMainChange(Sender: TObject);
    procedure tmrEnvTimer(Sender: TObject);
  private
    FArchive: TArchiveInfo;
    FZip: TZipArchiveInfo;
    FRar: TRarArchiveInfo;
    FZipHexItems: TStringList;
    FSel: Integer;
    FLastOp: TOpStats;
    FUpdating: Boolean;
    procedure LogLine(const ALine: string);
    procedure FillOverview;
    procedure FillEntries;
    procedure FillEntryDetail;
    procedure FillHex;
    procedure FillHexRar;
    procedure FillEnv;
    function EntryDetailText(E: TZipEntryInfo): string;
    function ListViewText(LV: TListView): string;
    function BuildReport: string;
  public
    procedure SetArchive(AArchive: TArchiveInfo);
    procedure SelectEntry(AIndex: Integer; AFocusTab: Boolean = False);
    procedure SetLastOperation(const AName: string; AMs: QWord; AIn, AOut: Int64);
    procedure ShowTab(AIndex: Integer);
  end;

var
  frmDevInfo: TfrmDevInfo;

implementation

uses
  Math, Clipbrd, LCLVersion, InterfaceBase, LCLPlatformDef, LazFileUtils,
  BGRABitmap, BGRABitmapTypes, zbase, Zipper, uBGRAUI, uDevInfoRar, uRarBackend, uIPC, uHttpApi;

{$R *.lfm}

const
  AppVersion = '1.2.0';

  HEX_LOCAL = 0;
  HEX_CENTRAL = 1;
  HEX_EOCD = 2;
  HEX_ZIP64 = 3;
  HEX_START = 4;
  HEX_END = 5;
  HEX_CUSTOM = 6;

type
  TFieldDef = record
    Ofs: Integer;
    Size: Integer;
    Name: string;
  end;

const
  LocalFields: array[0..10] of TFieldDef = (
    (Ofs: 0; Size: 4; Name: 'signature (PK\3\4)'),
    (Ofs: 4; Size: 2; Name: 'version needed'),
    (Ofs: 6; Size: 2; Name: 'general purpose flags'),
    (Ofs: 8; Size: 2; Name: 'compression method'),
    (Ofs: 10; Size: 2; Name: 'last mod time (DOS)'),
    (Ofs: 12; Size: 2; Name: 'last mod date (DOS)'),
    (Ofs: 14; Size: 4; Name: 'crc-32'),
    (Ofs: 18; Size: 4; Name: 'compressed size'),
    (Ofs: 22; Size: 4; Name: 'uncompressed size'),
    (Ofs: 26; Size: 2; Name: 'file name length'),
    (Ofs: 28; Size: 2; Name: 'extra field length'));

  CentralFields: array[0..16] of TFieldDef = (
    (Ofs: 0; Size: 4; Name: 'signature (PK\1\2)'),
    (Ofs: 4; Size: 2; Name: 'version made by'),
    (Ofs: 6; Size: 2; Name: 'version needed'),
    (Ofs: 8; Size: 2; Name: 'general purpose flags'),
    (Ofs: 10; Size: 2; Name: 'compression method'),
    (Ofs: 12; Size: 2; Name: 'last mod time (DOS)'),
    (Ofs: 14; Size: 2; Name: 'last mod date (DOS)'),
    (Ofs: 16; Size: 4; Name: 'crc-32'),
    (Ofs: 20; Size: 4; Name: 'compressed size'),
    (Ofs: 24; Size: 4; Name: 'uncompressed size'),
    (Ofs: 28; Size: 2; Name: 'file name length'),
    (Ofs: 30; Size: 2; Name: 'extra field length'),
    (Ofs: 32; Size: 2; Name: 'file comment length'),
    (Ofs: 34; Size: 2; Name: 'disk number start'),
    (Ofs: 36; Size: 2; Name: 'internal attributes'),
    (Ofs: 38; Size: 4; Name: 'external attributes'),
    (Ofs: 42; Size: 4; Name: 'local header offset'));

  EOCDFields: array[0..7] of TFieldDef = (
    (Ofs: 0; Size: 4; Name: 'signature (PK\5\6)'),
    (Ofs: 4; Size: 2; Name: 'number of this disk'),
    (Ofs: 6; Size: 2; Name: 'disk where CD starts'),
    (Ofs: 8; Size: 2; Name: 'CD records on this disk'),
    (Ofs: 10; Size: 2; Name: 'total CD records'),
    (Ofs: 12; Size: 4; Name: 'size of CD'),
    (Ofs: 16; Size: 4; Name: 'offset of CD'),
    (Ofs: 20; Size: 2; Name: 'comment length'));

  Zip64Fields: array[0..9] of TFieldDef = (
    (Ofs: 0; Size: 4; Name: 'signature (PK\6\6)'),
    (Ofs: 4; Size: 8; Name: 'size of this record'),
    (Ofs: 12; Size: 2; Name: 'version made by'),
    (Ofs: 14; Size: 2; Name: 'version needed'),
    (Ofs: 16; Size: 4; Name: 'number of this disk'),
    (Ofs: 20; Size: 4; Name: 'disk where CD starts'),
    (Ofs: 24; Size: 8; Name: 'CD records on this disk'),
    (Ofs: 32; Size: 8; Name: 'total CD records'),
    (Ofs: 40; Size: 8; Name: 'size of CD'),
    (Ofs: 48; Size: 8; Name: 'offset of CD'));

function AnnotateFields(const B: TBytes; ABase: Int64; const AFields: array of TFieldDef): string;
var
  I, J: Integer;
  V: QWord;
  HexB: string;
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('File ofs  +Rel  Size  Field                        Bytes                    Value');
    SL.Add('--------  ----  ----  ---------------------------  -----------------------  ---------------------');
    for I := 0 to High(AFields) do
    begin
      if AFields[I].Ofs + AFields[I].Size > Length(B) then
        Break;
      V := 0;
      HexB := '';
      for J := AFields[I].Size - 1 downto 0 do
        V := (V shl 8) or B[AFields[I].Ofs + J];
      for J := 0 to AFields[I].Size - 1 do
        HexB := HexB + IntToHex(B[AFields[I].Ofs + J], 2) + ' ';
      SL.Add(Format('%s  +%.2x   %4d  %-27s  %-23s  %u (0x%s)',
        [IntToHex(ABase + AFields[I].Ofs, 8), AFields[I].Ofs, AFields[I].Size, AFields[I].Name,
         HexB, V, IntToHex(V, AFields[I].Size * 2)]));
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

{ TfrmDevInfo }

procedure TfrmDevInfo.FormCreate(Sender: TObject);
begin
  FSel := -1;
  FZipHexItems := TStringList.Create;
  FZipHexItems.Assign(cbHexSource.Items);
  memoLog.Lines.Assign(Log.Lines);
  Log.OnLine := @LogLine;
  pcMain.ActivePage := tsOverview;
  cbHexSource.ItemIndex := HEX_LOCAL;
  FillOverview;
  FillEnv;
  DevLog(llDebug, 'Developer window created');
end;

procedure TfrmDevInfo.FormDestroy(Sender: TObject);
begin
  Log.OnLine := nil;
  FZipHexItems.Free;
end;

procedure TfrmDevInfo.LogLine(const ALine: string);
begin
  memoLog.Lines.Add(ALine);
  if chkAutoScroll.Checked then
  begin
    memoLog.SelStart := Length(memoLog.Text);
    memoLog.SelLength := 0;
  end;
end;

procedure TfrmDevInfo.SetArchive(AArchive: TArchiveInfo);
var
  WasRar: Boolean;
begin
  WasRar := FRar <> nil;
  FArchive := AArchive;
  FZip := nil;
  FRar := nil;
  if AArchive is TZipArchiveInfo then
    FZip := TZipArchiveInfo(AArchive)
  else if AArchive is TRarArchiveInfo then
    FRar := TRarArchiveInfo(AArchive);
  if WasRar <> (FRar <> nil) then
  begin
    // the entry table and the hex sources differ per format
    SetupEntryColumns(lvEntries, FRar <> nil);
    if FRar <> nil then
      RarHexItems(cbHexSource.Items)
    else
      cbHexSource.Items.Assign(FZipHexItems);
    cbHexSource.ItemIndex := 0;
  end;
  FSel := -1;
  FillOverview;
  FillEntries;
  FillEntryDetail;
  FillHex;
  pbChart.Invalidate;
end;

procedure TfrmDevInfo.SelectEntry(AIndex: Integer; AFocusTab: Boolean);
var
  I: Integer;
begin
  if (FArchive = nil) or (AIndex < 0) or (AIndex >= FArchive.Count) then
    Exit;
  FSel := AIndex;
  FUpdating := True;
  try
    for I := 0 to lvEntries.Items.Count - 1 do
      if PtrInt(lvEntries.Items[I].Data) = AIndex then
      begin
        lvEntries.ItemIndex := I;
        lvEntries.Items[I].MakeVisible(False);
        Break;
      end;
  finally
    FUpdating := False;
  end;
  FillEntryDetail;
  if cbHexSource.ItemIndex in [HEX_LOCAL, HEX_CENTRAL] then
    FillHex;
  if AFocusTab then
    pcMain.ActivePage := tsEntries;
end;

procedure TfrmDevInfo.SetLastOperation(const AName: string; AMs: QWord; AIn, AOut: Int64);
begin
  FLastOp.Valid := True;
  FLastOp.Name := AName;
  FLastOp.Ms := AMs;
  FLastOp.InBytes := AIn;
  FLastOp.OutBytes := AOut;
  FLastOp.When := Now;
  FillOverview;
end;

procedure TfrmDevInfo.ShowTab(AIndex: Integer);
begin
  if (AIndex >= 0) and (AIndex < pcMain.PageCount) then
  begin
    pcMain.ActivePageIndex := AIndex;
    pcMainChange(pcMain);
  end;
end;

{ ---------- overview ---------- }

procedure AddKV(LV: TListView; const K, V: string);
var
  It: TListItem;
begin
  It := LV.Items.Add;
  It.Caption := K;
  It.SubItems.Add(V);
end;

procedure AddSection(LV: TListView; const ATitle: string);
var
  It: TListItem;
begin
  if LV.Items.Count > 0 then
    LV.Items.Add.Caption := '';
  It := LV.Items.Add;
  It.Caption := '[ ' + ATitle + ' ]';
  It.SubItems.Add('');
end;

procedure TfrmDevInfo.FillOverview;
var
  A: TZipArchiveInfo;
  E: TZipEntryInfo;
  Methods: array[0..99] of Integer;
  I, Enc, Utf, DD, Z64, MaxName, Dirs: Integer;
  Largest: TZipEntryInfo;
  S: string;
  Overhead: Int64;
begin
  lvOverview.Items.BeginUpdate;
  try
    lvOverview.Items.Clear;
    A := FZip;
    if FRar <> nil then
      FillRarOverview(lvOverview, FRar)
    else if A = nil then
    begin
      AddSection(lvOverview, 'Archive');
      AddKV(lvOverview, 'Status', 'No archive open');
    end
    else
    begin
      AddSection(lvOverview, 'File');
      AddKV(lvOverview, 'Path', A.FileName);
      AddKV(lvOverview, 'File size', FormatBytesFull(A.FileSize));
      AddKV(lvOverview, 'Modified', FormatDateTime('yyyy-mm-dd hh:nn:ss', FileDateToDateTime(FileAgeUTF8(A.FileName))));
      AddKV(lvOverview, 'Parse time', Format('%d ms', [A.ParseTimeMs]));
      AddKV(lvOverview, 'Prefix bytes (SFX / prepended)', IntToStr(A.PrefixBytes));

      AddSection(lvOverview, 'End of central directory');
      AddKV(lvOverview, 'EOCD offset', Format('%d (0x%x)', [A.EOCDOffset, A.EOCDOffset]));
      AddKV(lvOverview, 'Disk number', IntToStr(A.DiskNumber));
      AddKV(lvOverview, 'Disk with central directory', IntToStr(A.CDDisk));
      AddKV(lvOverview, 'Entries on this disk', IntToStr(A.EntriesOnDisk));
      AddKV(lvOverview, 'Total entries', IntToStr(A.TotalEntries));
      AddKV(lvOverview, 'Central directory offset', Format('%d (0x%x)', [A.CDOffset, A.CDOffset]));
      AddKV(lvOverview, 'Central directory size', FormatBytesFull(A.CDSize));
      AddKV(lvOverview, 'Archive comment length', IntToStr(A.CommentLen));
      AddKV(lvOverview, 'Archive comment', A.Comment);

      AddSection(lvOverview, 'Zip64');
      AddKV(lvOverview, 'Zip64 archive', BoolToStr(A.IsZip64, 'Yes', 'No'));
      if A.IsZip64 then
      begin
        AddKV(lvOverview, 'Zip64 locator offset', Format('%d (0x%x)', [A.Zip64LocatorOffset, A.Zip64LocatorOffset]));
        AddKV(lvOverview, 'Zip64 EOCD offset', Format('%d (0x%x)', [A.Zip64EOCDOffset, A.Zip64EOCDOffset]));
        AddKV(lvOverview, 'Zip64 record size', IntToStr(A.Zip64RecordSize));
        AddKV(lvOverview, 'Zip64 version made by', ZipVersionStr(A.Zip64VersionMadeBy) + ' / ' + HostOSName(A.Zip64VersionMadeBy));
        AddKV(lvOverview, 'Zip64 version needed', ZipVersionStr(A.Zip64VersionNeeded));
      end;

      FillChar(Methods, SizeOf(Methods), 0);
      Enc := 0; Utf := 0; DD := 0; Z64 := 0; MaxName := 0; Dirs := 0;
      Largest := nil;
      for E in A.Entries do
      begin
        if E.Method <= High(Methods) then
          Inc(Methods[E.Method]);
        if E.IsEncrypted then Inc(Enc);
        if E.IsUTF8 then Inc(Utf);
        if E.HasDataDescriptor then Inc(DD);
        for I := 0 to High(E.Extras) do
          if E.Extras[I].HeaderID = 1 then
          begin
            Inc(Z64);
            Break;
          end;
        if E.IsDirectory then Inc(Dirs);
        MaxName := Max(MaxName, Length(E.FileName));
        if (Largest = nil) or (E.UncompressedSize > Largest.UncompressedSize) then
          Largest := E;
      end;

      AddSection(lvOverview, 'Content statistics');
      AddKV(lvOverview, 'Files / folders', Format('%d / %d', [A.Entries.Count - Dirs, Dirs]));
      AddKV(lvOverview, 'Total uncompressed', FormatBytesFull(A.TotalUncompressed));
      AddKV(lvOverview, 'Total compressed', FormatBytesFull(A.TotalCompressed));
      AddKV(lvOverview, 'Space saved', FormatFloat('0.00', A.OverallSavedPercent) + ' %');
      if A.TotalCompressed > 0 then
        AddKV(lvOverview, 'Compression factor', FormatFloat('0.000', A.TotalUncompressed / A.TotalCompressed) + ' : 1');
      Overhead := A.FileSize - A.TotalCompressed;
      AddKV(lvOverview, 'ZIP structure overhead', Format('%s (%.2f %% of file)',
        [FormatBytesFull(Overhead), 100 * Overhead / Max(A.FileSize, 1)]));
      S := '';
      for I := 0 to High(Methods) do
        if Methods[I] > 0 then
          S := S + Format('%s=%d  ', [ZipMethodName(I), Methods[I]]);
      AddKV(lvOverview, 'Compression methods', Trim(S));
      AddKV(lvOverview, 'Encrypted entries', IntToStr(Enc));
      AddKV(lvOverview, 'UTF-8 flagged names', IntToStr(Utf));
      AddKV(lvOverview, 'Entries with data descriptor', IntToStr(DD));
      AddKV(lvOverview, 'Entries with Zip64 extra', IntToStr(Z64));
      AddKV(lvOverview, 'Longest name (chars)', IntToStr(MaxName));
      if Largest <> nil then
        AddKV(lvOverview, 'Largest entry', Largest.FileName + '  ' + FormatSize(Largest.UncompressedSize));

      AddSection(lvOverview, Format('Integrity warnings (%d)', [A.Warnings.Count]));
      if A.Warnings.Count = 0 then
        AddKV(lvOverview, 'Structure', 'OK - no inconsistencies found')
      else
        for I := 0 to A.Warnings.Count - 1 do
          AddKV(lvOverview, 'Warning ' + IntToStr(I + 1), A.Warnings[I]);
    end;

    AddSection(lvOverview, 'Last operation');
    if FLastOp.Valid then
    begin
      AddKV(lvOverview, 'Operation', FLastOp.Name);
      AddKV(lvOverview, 'Finished at', FormatDateTime('yyyy-mm-dd hh:nn:ss', FLastOp.When));
      AddKV(lvOverview, 'Duration', Format('%d ms', [FLastOp.Ms]));
      AddKV(lvOverview, 'Bytes in', FormatBytesFull(FLastOp.InBytes));
      AddKV(lvOverview, 'Bytes out', FormatBytesFull(FLastOp.OutBytes));
      AddKV(lvOverview, 'Throughput', FormatFloat('0.00', Max(FLastOp.InBytes, FLastOp.OutBytes) / 1048576 /
        Max(FLastOp.Ms, 1) * 1000) + ' MB/s');
    end
    else
      AddKV(lvOverview, 'Operation', '(none yet)');
  finally
    lvOverview.Items.EndUpdate;
  end;
end;

{ ---------- entries ---------- }

procedure TfrmDevInfo.FillEntries;
var
  E: TZipEntryInfo;
  It: TListItem;
  S: string;
  I: Integer;
begin
  lvEntries.Items.BeginUpdate;
  try
    lvEntries.Items.Clear;
    if FRar <> nil then
    begin
      FillRarEntries(lvEntries, FRar);
      Exit;
    end;
    if FZip = nil then
      Exit;
    for E in FZip.Entries do
    begin
      It := lvEntries.Items.Add;
      It.Data := Pointer(PtrInt(E.Index));
      It.Caption := IntToStr(E.Index);
      It.SubItems.Add(E.FileName);
      It.SubItems.Add(Format('%d %s', [E.Method, ZipMethodName(E.Method)]));
      It.SubItems.Add(Hex16(E.Flags));
      It.SubItems.Add(ZipVersionStr(E.VersionMadeBy) + ' ' + HostOSName(E.VersionMadeBy));
      It.SubItems.Add(ZipVersionStr(E.VersionNeeded));
      It.SubItems.Add(DosDateTimeStr(E.ModDate, E.ModTime));
      It.SubItems.Add(IntToHex(E.CRC32, 8));
      It.SubItems.Add(IntToStr(E.CompressedSize));
      It.SubItems.Add(IntToStr(E.UncompressedSize));
      It.SubItems.Add(FormatFloat('0.0', E.SavedPercent) + '%');
      It.SubItems.Add(IntToStr(E.LocalHeaderOffset));
      It.SubItems.Add(IntToStr(E.DataOffset));
      It.SubItems.Add(IntToStr(E.CentralOffset));
      It.SubItems.Add(Format('%d/%d/%d', [E.NameLen, E.ExtraLen, E.CommentLen]));
      It.SubItems.Add(Hex16(E.IntAttr));
      It.SubItems.Add(Hex32(E.ExtAttr));
      S := '';
      for I := 0 to High(E.Extras) do
        S := S + IntToHex(E.Extras[I].HeaderID, 4) + ' ';
      It.SubItems.Add(Trim(S));
      if E.LocalOK then
        It.SubItems.Add('OK')
      else
        It.SubItems.Add('MISSING');
    end;
  finally
    lvEntries.Items.EndUpdate;
  end;
end;

procedure TfrmDevInfo.lvEntriesSelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if FUpdating or not Selected or (Item = nil) then
    Exit;
  FSel := PtrInt(Item.Data);
  FillEntryDetail;
  if cbHexSource.ItemIndex in [HEX_LOCAL, HEX_CENTRAL] then
    FillHex;
end;

function TfrmDevInfo.EntryDetailText(E: TZipEntryInfo): string;
var
  SL: TStringList;
  I: Integer;
  S: string;

  procedure KV(const K, V: string);
  begin
    SL.Add(Format('  %-28s %s', [K, V]));
  end;

  procedure Cmp(const K: string; ACentral, ALocal: Int64; AIgnore: Boolean = False);
  var
    Mark: string;
  begin
    if ACentral = ALocal then
      Mark := ''
    else if AIgnore then
      Mark := '  (deferred to data descriptor)'
    else
      Mark := '  <-- MISMATCH';
    SL.Add(Format('  %-28s central=%-14d local=%-14d%s', [K, ACentral, ALocal, Mark]));
  end;

  procedure Extras(const AList: TZipExtraFields);
  var
    J: Integer;
  begin
    if Length(AList) = 0 then
      SL.Add('  (none)');
    for J := 0 to High(AList) do
    begin
      SL.Add(Format('  0x%.4x  %-28s size=%-5d at file ofs 0x%x', [AList[J].HeaderID,
        ExtraFieldName(AList[J].HeaderID), AList[J].DataSize, AList[J].FileOffset]));
      if DescribeExtraField(AList[J]) <> '' then
        SL.Add('          ' + DescribeExtraField(AList[J]));
    end;
  end;

begin
  SL := TStringList.Create;
  try
    SL.Add(Format('ENTRY #%d  %s', [E.Index, E.FileName]));
    SL.Add(StringOfChar('=', 78));
    SL.Add('Central directory record');
    KV('Record offset', Format('%d (0x%x), %d bytes', [E.CentralOffset, E.CentralOffset, E.CentralRecordSize]));
    KV('Version made by', Format('%s  (spec %s, host %s)', [Hex16(E.VersionMadeBy), ZipVersionStr(E.VersionMadeBy), HostOSName(E.VersionMadeBy)]));
    KV('Version needed', Format('%s  (spec %s)', [Hex16(E.VersionNeeded), ZipVersionStr(E.VersionNeeded)]));
    KV('General purpose flags', Format('%s  %s', [Hex16(E.Flags), DecodeFlags(E.Flags)]));
    KV('Compression method', Format('%d  %s', [E.Method, ZipMethodName(E.Method)]));
    if (E.Method = 8) then
      case (E.Flags shr 1) and 3 of
        0: KV('Deflate option', 'Normal');
        1: KV('Deflate option', 'Maximum');
        2: KV('Deflate option', 'Fast');
        3: KV('Deflate option', 'Super fast');
      end;
    KV('DOS time / date (raw)', Format('%s / %s', [Hex16(E.ModTime), Hex16(E.ModDate)]));
    KV('Modified', DosDateTimeStr(E.ModDate, E.ModTime) + ' (local, 2 s resolution)');
    KV('CRC-32', Hex32(E.CRC32));
    KV('Compressed size', FormatBytesFull(E.CompressedSize));
    KV('Uncompressed size', FormatBytesFull(E.UncompressedSize));
    KV('Space saved', FormatFloat('0.00', E.SavedPercent) + ' %');
    KV('Name / extra / comment len', Format('%d / %d / %d', [E.NameLen, E.ExtraLen, E.CommentLen]));
    S := '';
    for I := 1 to Min(Length(E.RawName), 48) do
      S := S + IntToHex(Ord(E.RawName[I]), 2) + ' ';
    if Length(E.RawName) > 48 then
      S := S + '...';
    KV('Raw name bytes', S);
    KV('Name encoding', BoolToStr(E.IsUTF8, 'UTF-8 (flag bit 11)', 'CP437 / system (no UTF-8 flag)'));
    KV('Disk number start', IntToStr(E.DiskStart));
    KV('Internal attributes', Format('%s  %s', [Hex16(E.IntAttr), BoolToStr((E.IntAttr and 1) <> 0, 'text', 'binary')]));
    KV('External attributes', Format('%s  %s', [Hex32(E.ExtAttr), DecodeExternalAttr(E.VersionMadeBy, E.ExtAttr)]));
    KV('Local header offset', Format('%d (0x%x)', [E.LocalHeaderOffset, E.LocalHeaderOffset]));
    KV('Is directory', BoolToStr(E.IsDirectory, True));
    KV('Encrypted', BoolToStr(E.IsEncrypted, True));
    KV('Comment', E.Comment);
    SL.Add('');
    SL.Add('Central extra fields');
    Extras(E.Extras);
    SL.Add('');
    SL.Add('Local file header');
    if not E.LocalOK then
      SL.Add('  ERROR: ' + E.LocalError)
    else
    begin
      KV('Header size', Format('%d bytes (30 + name %d + extra %d)', [E.LocalRecordSize, E.LocalNameLen, E.LocalExtraLen]));
      KV('Data offset', Format('%d (0x%x)', [E.DataOffset, E.DataOffset]));
      KV('Data end', Format('%d (0x%x)', [E.DataOffset + E.CompressedSize, E.DataOffset + E.CompressedSize]));
      Cmp('version needed', E.VersionNeeded, E.LocalVersionNeeded);
      Cmp('flags', E.Flags, E.LocalFlags);
      Cmp('method', E.Method, E.LocalMethod);
      Cmp('mod time', E.ModTime, E.LocalTime);
      Cmp('mod date', E.ModDate, E.LocalDate);
      Cmp('crc-32', E.CRC32, E.LocalCRC32, E.HasDataDescriptor);
      Cmp('compressed size', E.CompressedSize, E.LocalCompressedSize,
        E.HasDataDescriptor or (E.LocalCompressedSize = $FFFFFFFF));
      Cmp('uncompressed size', E.UncompressedSize, E.LocalUncompressedSize,
        E.HasDataDescriptor or (E.LocalUncompressedSize = $FFFFFFFF));
      Cmp('name length', E.NameLen, E.LocalNameLen);
      Cmp('extra length', E.ExtraLen, E.LocalExtraLen, True);
      SL.Add('');
      SL.Add('Local extra fields');
      Extras(E.LocalExtras);
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TfrmDevInfo.FillEntryDetail;
begin
  if (FArchive = nil) or (FSel < 0) or (FSel >= FArchive.Count) then
    memoEntry.Text := 'Select an entry above (or in the main window) to see every field of its ' +
      'headers.'
  else if FRar <> nil then
    memoEntry.Text := RarEntryDetailText(FRar, FRar.Entries[FSel])
  else
    memoEntry.Text := EntryDetailText(FZip.Entries[FSel]);
end;

{ ---------- hex ---------- }

procedure TfrmDevInfo.cbHexSourceChange(Sender: TObject);
begin
  FillHex;
end;

procedure TfrmDevInfo.btnHexGoClick(Sender: TObject);
begin
  cbHexSource.ItemIndex := HEX_CUSTOM;
  FillHex;
end;

procedure TfrmDevInfo.FillHex;
var
  E: TZipEntryInfo;
  Ofs: Int64;
  Len, DataLen: Integer;
  B: TBytes;
  Head: string;
begin
  if FRar <> nil then
  begin
    FillHexRar;
    Exit;
  end;
  if FZip = nil then
  begin
    memoHex.Text := 'No archive open.';
    Exit;
  end;
  E := nil;
  if (FSel >= 0) and (FSel < FZip.Entries.Count) then
    E := FZip.Entries[FSel];
  Head := '';
  try
    case cbHexSource.ItemIndex of
      HEX_LOCAL, HEX_CENTRAL:
        begin
          if E = nil then
          begin
            memoHex.Text := 'Select an entry in the Entries tab or main window.';
            Exit;
          end;
          if cbHexSource.ItemIndex = HEX_LOCAL then
          begin
            Ofs := E.LocalHeaderOffset + FZip.PrefixBytes;
            DataLen := Min(E.CompressedSize, 256);
            Len := LOCAL_HDR_SIZE + E.LocalNameLen + E.LocalExtraLen + DataLen;
            B := ReadFileRegion(FArchive.FileName, Ofs, Len);
            Head := Format('Local file header of #%d "%s" + first %d bytes of compressed data' + LineEnding +
              'header %d..%d   data %d..%d' + LineEnding + LineEnding,
              [E.Index, E.FileName, DataLen, Ofs, Ofs + E.LocalRecordSize - 1, E.DataOffset,
               E.DataOffset + E.CompressedSize - 1]) + AnnotateFields(B, Ofs, LocalFields);
          end
          else
          begin
            Ofs := E.CentralOffset;
            Len := E.CentralRecordSize;
            B := ReadFileRegion(FArchive.FileName, Ofs, Len);
            Head := Format('Central directory record of #%d "%s"' + LineEnding + LineEnding,
              [E.Index, E.FileName]) + AnnotateFields(B, Ofs, CentralFields);
          end;
        end;
      HEX_EOCD:
        begin
          Ofs := FZip.EOCDOffset;
          Len := EOCD_SIZE + FZip.CommentLen;
          B := ReadFileRegion(FArchive.FileName, Ofs, Len);
          Head := 'End of central directory record' + LineEnding + LineEnding + AnnotateFields(B, Ofs, EOCDFields);
        end;
      HEX_ZIP64:
        begin
          if not FZip.IsZip64 then
          begin
            memoHex.Text := 'This archive has no Zip64 end of central directory record.';
            Exit;
          end;
          Ofs := FZip.Zip64EOCDOffset;
          Len := 56 + ZIP64_LOC_SIZE;
          B := ReadFileRegion(FArchive.FileName, Ofs, Len);
          Head := 'Zip64 EOCD record + locator' + LineEnding + LineEnding + AnnotateFields(B, Ofs, Zip64Fields);
        end;
      HEX_START:
        begin
          Ofs := 0;
          Len := Min(FArchive.FileSize, 4096);
          B := ReadFileRegion(FArchive.FileName, Ofs, Len);
          Head := 'First 4 KB of file';
        end;
      HEX_END:
        begin
          Len := Min(FArchive.FileSize, 4096);
          Ofs := FArchive.FileSize - Len;
          B := ReadFileRegion(FArchive.FileName, Ofs, Len);
          Head := 'Last 4 KB of file';
        end;
    else
      begin
        Ofs := StrToInt64Def(Trim(edtHexOffset.Text), 0);
        Len := EnsureRange(StrToIntDef(Trim(edtHexLen.Text), 512), 1, 1024 * 1024);
        B := ReadFileRegion(FArchive.FileName, Ofs, Len);
        Head := Format('Custom range: offset %d, %d bytes', [Ofs, Len]);
      end;
    end;
    edtHexOffset.Text := IntToStr(Ofs);
    edtHexLen.Text := IntToStr(Len);
    memoHex.Text := Head + LineEnding + HexDump(B, Ofs);
  except
    on Ex: Exception do
      memoHex.Text := 'Error reading file: ' + Ex.Message;
  end;
end;

procedure TfrmDevInfo.FillHexRar;
var
  Blk: TRarBlock;
  Ofs: Int64;
  Len: Integer;
  B: TBytes;
  Head: string;
begin
  try
    Head := '';
    B := nil;
    case cbHexSource.ItemIndex of
      RAR_HEX_ENTRY:
        begin
          if (FSel < 0) or (FSel >= FRar.Entries.Count) then
          begin
            memoHex.Text := 'Select an entry in the Entries tab or main window.';
            Exit;
          end;
          Blk := FRar.Entries[FSel].Block;
          edtHexOffset.Text := IntToStr(Blk.Offset);
          edtHexLen.Text := IntToStr(Blk.HeaderLen + Min(Blk.DataSize, 256));
          memoHex.Text := RarBlockDump(FRar, Blk, 256);
          Exit;
        end;
      RAR_HEX_MAIN:
        begin
          // signature/marker block(s) + main header
          Head := '';
          for Blk in FRar.Blocks do
          begin
            Head := Head + RarBlockDump(FRar, Blk, 0) + LineEnding;
            if Blk = FRar.MainBlock then
              Break;
          end;
          memoHex.Text := Head;
          Exit;
        end;
      RAR_HEX_END:
        begin
          if FRar.EndBlock = nil then
            memoHex.Text := 'No end-of-archive block found.'
          else
            memoHex.Text := RarBlockDump(FRar, FRar.EndBlock, 0);
          Exit;
        end;
      RAR_HEX_START:
        begin
          Ofs := 0;
          Len := Min(FRar.FileSize, 4096);
          Head := 'First 4 KB of file';
        end;
      RAR_HEX_FILEEND:
        begin
          Len := Min(FRar.FileSize, 4096);
          Ofs := FRar.FileSize - Len;
          Head := 'Last 4 KB of file';
        end;
    else
      begin
        Ofs := StrToInt64Def(Trim(edtHexOffset.Text), 0);
        Len := EnsureRange(StrToIntDef(Trim(edtHexLen.Text), 512), 1, 1024 * 1024);
        Head := Format('Custom range: offset %d, %d bytes', [Ofs, Len]);
      end;
    end;
    B := ReadFileRegion(FRar.FileName, Ofs, Len);
    edtHexOffset.Text := IntToStr(Ofs);
    edtHexLen.Text := IntToStr(Len);
    memoHex.Text := Head + LineEnding + LineEnding + HexDump(B, Ofs);
  except
    on Ex: Exception do
      memoHex.Text := 'Error reading file: ' + Ex.Message;
  end;
end;

{ ---------- chart (BGRABitmap) ---------- }

procedure TfrmDevInfo.pbChartPaint(Sender: TObject);
const
  Palette: array[0..7] of TBGRAPixel = (
    (blue: 230; green: 140; red: 30; alpha: 255),
    (blue: 100; green: 180; red: 40; alpha: 255),
    (blue: 40; green: 150; red: 240; alpha: 255),
    (blue: 220; green: 90; red: 140; alpha: 255),
    (blue: 190; green: 200; red: 20; alpha: 255),
    (blue: 70; green: 70; red: 230; alpha: 255),
    (blue: 130; green: 130; red: 130; alpha: 255),
    (blue: 60; green: 200; red: 200; alpha: 255));
  ZipLegend: array[0..4] of string = ('Local headers', 'Compressed data', 'Central directory', 'Zip64 EOCD', 'EOCD');
  RarLegend: array[0..4] of string = ('File headers', 'Packed data', 'Signature / main header', 'Service blocks', 'End of archive');
var
  B: TBGRABitmap;
  W, H, I, J, N, Cnt: Integer;
  CX, CY, R, R2, A0, A1, Frac, X, Y, BW, BarH, Scale: Single;
  Pts: array of TPointF;
  Sorted: array of TArchiveEntry;
  T, E: TArchiveEntry;
  ZE: TZipEntryInfo;
  MaxSize: Int64;
  S: string;
  TS: TSize;
  MapX0, MapX1, MapY, MapH, P0, P1: Single;
  Pos: Int64;
  LegendC: array[0..4] of TBGRAPixel;

  function MapPos(AOfs: Int64): Single;
  begin
    Result := MapX0 + (MapX1 - MapX0) * AOfs / Max(FArchive.FileSize, 1);
  end;

  procedure Ring(AFrom, ATo: Single; C: TBGRAPixel);
  var
    K, Steps: Integer;
    Ang: Single;
  begin
    Steps := Max(2, Round((ATo - AFrom) * 60));
    SetLength(Pts, 0);
    for K := 0 to Steps do
    begin
      Ang := AFrom + (ATo - AFrom) * K / Steps;
      SetLength(Pts, Length(Pts) + 1);
      Pts[High(Pts)] := PointF(CX + R * Cos(Ang), CY + R * Sin(Ang));
    end;
    for K := Steps downto 0 do
    begin
      Ang := AFrom + (ATo - AFrom) * K / Steps;
      SetLength(Pts, Length(Pts) + 1);
      Pts[High(Pts)] := PointF(CX + R2 * Cos(Ang), CY + R2 * Sin(Ang));
    end;
    B.FillPolyAntialias(Pts, C);
  end;

begin
  W := pbChart.Width;
  H := pbChart.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  B := TBGRABitmap.Create(W, H, BGRA(250, 251, 253));
  try
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := 14;
    if (FArchive = nil) or (FArchive.Count = 0) then
    begin
      S := 'Open an archive to see compression charts and the file layout map';
      TS := B.TextSize(S);
      B.TextOut((W - TS.cx) / 2, (H - TS.cy) / 2, S, clrMuted);
      B.Draw(pbChart.Canvas, 0, 0, True);
      Exit;
    end;

    // ---- donut: compressed vs saved ----
    R := Min(110, Min(W * 0.18, (H - 140) * 0.42));
    if R < 30 then R := 30;
    R2 := R * 0.62;
    CX := 30 + R;
    CY := 40 + R;
    B.FontStyle := [fsBold];
    B.TextOut(16, 10, 'Overall compression (' + FArchive.FormatName + ')', clrText);
    B.FontStyle := [];
    Frac := EnsureRange(FArchive.OverallSavedPercent / 100, 0, 1);
    A0 := -Pi / 2;
    A1 := A0 + 2 * Pi * (1 - Frac);
    Ring(A0, A1, Palette[0]);
    if Frac > 0 then
      Ring(A1, A0 + 2 * Pi, BGRA(120, 200, 140));
    B.FontHeight := Round(R * 0.32);
    B.FontStyle := [fsBold];
    S := FormatFloat('0.0', FArchive.OverallSavedPercent) + '%';
    TS := B.TextSize(S);
    B.TextOut(CX - TS.cx / 2, CY - TS.cy * 0.7, S, clrText);
    B.FontStyle := [];
    B.FontHeight := 12;
    S := 'saved';
    TS := B.TextSize(S);
    B.TextOut(CX - TS.cx / 2, CY + TS.cy * 0.2, S, clrMuted);
    Y := CY + R + 12;
    B.FillRoundRectAntialias(16, Y + 3, 28, Y + 13, 3, 3, Palette[0]);
    B.TextOut(34, Y, 'Packed  ' + FormatSize(FArchive.TotalCompressed), clrText);
    B.FillRoundRectAntialias(16, Y + 21, 28, Y + 31, 3, 3, BGRA(120, 200, 140));
    B.TextOut(34, Y + 18, 'Saved   ' + FormatSize(Max(0, FArchive.TotalUncompressed - FArchive.TotalCompressed)), clrText);
    B.TextOut(34, Y + 36, 'Raw     ' + FormatSize(FArchive.TotalUncompressed), clrMuted);

    // ---- bars: top entries by size ----
    X := CX + R + 50;
    BW := W - X - 20;
    B.FontStyle := [fsBold];
    B.FontHeight := 14;
    B.TextOut(X, 10, 'Largest entries  (light = original, dark = packed)', clrText);
    B.FontStyle := [];
    B.FontHeight := 12;
    SetLength(Sorted, 0);
    for I := 0 to FArchive.Count - 1 do
      if not FArchive.Entry[I].IsDirectory then
      begin
        SetLength(Sorted, Length(Sorted) + 1);
        Sorted[High(Sorted)] := FArchive.Entry[I];
      end;
    for I := 1 to High(Sorted) do
    begin
      T := Sorted[I];
      J := I - 1;
      while (J >= 0) and (Sorted[J].UncompressedSize < T.UncompressedSize) do
      begin
        Sorted[J + 1] := Sorted[J];
        Dec(J);
      end;
      Sorted[J + 1] := T;
    end;
    BarH := 18;
    N := Min(Length(Sorted), Max(1, Trunc((H - 150) / (BarH + 6))));
    MaxSize := 1;
    if Length(Sorted) > 0 then
      MaxSize := Max(1, Sorted[0].UncompressedSize);
    if BW > 120 then
      for I := 0 to N - 1 do
      begin
        E := Sorted[I];
        Y := 36 + I * (BarH + 6);
        S := ExtractFileName(StringReplace(E.FileName, '/', PathDelim, [rfReplaceAll]));
        if Length(S) > 28 then
          S := System.Copy(S, 1, 25) + '...';
        B.TextOut(X, Y + 1, S, clrText);
        Scale := (BW - 190 - 200) / MaxSize;
        if Scale < 0 then Scale := 0;
        B.FillRoundRectAntialias(X + 190, Y + 2, X + 190 + Max(3, E.UncompressedSize * Scale), Y + BarH - 2,
          4, 4, BGRA(190, 215, 245));
        B.FillRoundRectAntialias(X + 190, Y + 2, X + 190 + Max(3, E.CompressedSize * Scale), Y + BarH - 2,
          4, 4, Palette[I mod 2]);
        B.TextOut(X + 196 + Max(3, E.UncompressedSize * Scale), Y + 1,
          Format('%s -> %s  (%s%%)', [FormatSize(E.UncompressedSize), FormatSize(E.CompressedSize),
          FormatFloat('0', E.SavedPercent)]), clrMuted);
      end;

    // ---- file layout map ----
    MapX0 := 16;
    MapX1 := W - 16;
    MapH := 34;
    MapY := H - MapH - 40;
    B.FontStyle := [fsBold];
    B.FontHeight := 14;
    B.TextOut(16, MapY - 24, Format('File layout map  (%s, offset 0 .. %d)', [FormatSize(FArchive.FileSize),
      FArchive.FileSize]), clrText);
    B.FontStyle := [];
    B.FontHeight := 12;
    if FRar <> nil then
    begin
      DrawRarLayout(B, FRar, MapX0, MapX1, MapY, MapH, FSel);
      LegendC[0] := BGRA(240, 150, 40);
      LegendC[1] := Palette[0];
      LegendC[2] := BGRA(140, 90, 220);
      LegendC[3] := BGRA(120, 120, 140);
      LegendC[4] := BGRA(220, 40, 40);
    end
    else
    begin
      B.FillRectAntialias(MapX0, MapY, MapX1, MapY + MapH, BGRA(230, 233, 240));
      if FZip.PrefixBytes > 0 then
        B.FillRectAntialias(MapPos(0), MapY, MapPos(FZip.PrefixBytes), MapY + MapH, BGRA(150, 150, 150));
      Cnt := 0;
      for ZE in FZip.Entries do
      begin
        if not ZE.LocalOK then
          Continue;
        Pos := ZE.LocalHeaderOffset + FZip.PrefixBytes;
        P0 := MapPos(Pos);
        P1 := MapPos(ZE.DataOffset);
        B.FillRectAntialias(P0, MapY, Max(P1, P0 + 0.6), MapY + MapH, BGRA(240, 150, 40));
        P0 := P1;
        P1 := MapPos(ZE.DataOffset + ZE.CompressedSize);
        if P1 > P0 then
          B.FillRectAntialias(P0, MapY, P1, MapY + MapH, Palette[Cnt mod 2]);
        if (FSel = ZE.Index) then
          B.RectangleAntialias(MapPos(Pos) - 1, MapY - 3, Max(P1, MapPos(Pos) + 2) + 1, MapY + MapH + 3,
            BGRA(220, 30, 60), 2);
        Inc(Cnt);
      end;
      P0 := MapPos(FZip.CDOffset + FZip.PrefixBytes);
      P1 := MapPos(FZip.CDOffset + FZip.PrefixBytes + FZip.CDSize);
      B.FillRectAntialias(P0, MapY, Max(P1, P0 + 1), MapY + MapH, BGRA(140, 90, 220));
      if FZip.IsZip64 then
        B.FillRectAntialias(MapPos(FZip.Zip64EOCDOffset), MapY, MapPos(FZip.EOCDOffset), MapY + MapH,
          BGRA(230, 70, 120));
      B.FillRectAntialias(MapPos(FZip.EOCDOffset), MapY, Max(MapX1, MapPos(FZip.EOCDOffset) + 1),
        MapY + MapH, BGRA(220, 40, 40));
      B.RectangleAntialias(MapX0, MapY, MapX1, MapY + MapH, BGRA(150, 160, 180), 1);
      LegendC[0] := BGRA(240, 150, 40);
      LegendC[1] := Palette[0];
      LegendC[2] := BGRA(140, 90, 220);
      LegendC[3] := BGRA(230, 70, 120);
      LegendC[4] := BGRA(220, 40, 40);
    end;

    X := 16;
    Y := MapY + MapH + 8;
    for I := 0 to 4 do
    begin
      if FRar <> nil then
        S := RarLegend[I]
      else
        S := ZipLegend[I];
      B.FillRectAntialias(X, Y + 3, X + 12, Y + 13, LegendC[I]);
      B.TextOut(X + 16, Y, S, clrText);
      X := X + 16 + B.TextSize(S).cx + 18;
    end;
    if FSel >= 0 then
      B.TextOut(X, Y, '(red frame = selected entry)', clrMuted);

    B.Draw(pbChart.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

{ ---------- environment ---------- }

procedure TfrmDevInfo.FillEnv;
var
  HS: TFPCHeapStatus;
  Z: TZipper;
  I, TopI: Integer;
  S: string;
  Tools: TRarTools;
  Tool: TRarTool;
begin
  TopI := 0;
  if lvEnv.TopItem <> nil then
    TopI := lvEnv.TopItem.Index;
  lvEnv.Items.BeginUpdate;
  try
    lvEnv.Items.Clear;
    AddSection(lvEnv, 'Application');
    AddKV(lvEnv, 'Title', Application.Title);
    AddKV(lvEnv, 'Version', AppVersion);
    AddKV(lvEnv, 'Executable', ParamStr(0));
    AddKV(lvEnv, 'Executable size', FormatBytesFull(FileSizeUtf8(ParamStr(0))));
    AddKV(lvEnv, 'Built', {$I %DATE%} + ' ' + {$I %TIME%});
    S := '';
    for I := 1 to ParamCount do
      S := S + '"' + ParamStr(I) + '" ';
    AddKV(lvEnv, 'Command line params', Format('%d  %s', [ParamCount, S]));
    AddKV(lvEnv, 'Process ID', IntToStr(GetProcessID));
    AddKV(lvEnv, 'Uptime', FormatFloat('0.0', Log.ElapsedMs / 1000) + ' s');
    AddKV(lvEnv, 'Log lines', IntToStr(Log.Lines.Count));

    AddSection(lvEnv, 'Compiler / libraries');
    AddKV(lvEnv, 'Free Pascal', {$I %FPCVERSION%});
    AddKV(lvEnv, 'Target', {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
    AddKV(lvEnv, 'Lazarus LCL', lcl_version);
    AddKV(lvEnv, 'Widgetset', LCLPlatformDisplayNames[WidgetSet.LCLPlatform]);
    AddKV(lvEnv, 'BGRABitmap', BGRABitmapVersionStr);
    AddKV(lvEnv, 'paszlib (zlib port)', zlibVersion);
    Z := TZipper.Create;
    try
      AddKV(lvEnv, 'TZipper buffer size', FormatBytesFull(Z.BufferSize));
      AddKV(lvEnv, 'TZipper in-memory threshold', FormatBytesFull(Z.InMemSize));
    finally
      Z.Free;
    end;
    AddKV(lvEnv, 'Pointer size', IntToStr(SizeOf(Pointer) * 8) + '-bit');
    AddKV(lvEnv, 'Endianness', {$IFDEF ENDIAN_LITTLE}'Little endian'{$ELSE}'Big endian'{$ENDIF});
    AddKV(lvEnv, 'Debug info', {$IFOPT D+}'On'{$ELSE}'Off'{$ENDIF});
    AddKV(lvEnv, 'Range checks', {$IFOPT R+}'On'{$ELSE}'Off'{$ENDIF});
    AddKV(lvEnv, 'Overflow checks', {$IFOPT Q+}'On'{$ELSE}'Off'{$ENDIF});
    AddKV(lvEnv, 'Assertions', {$IFOPT C+}'On'{$ELSE}'Off'{$ENDIF});

    AddSection(lvEnv, 'RAR backends (external tools)');
    Tools := FindRarTools;
    if Length(Tools) = 0 then
      AddKV(lvEnv, 'Tools', 'none found - RAR listing works, extract/test/create do not');
    for I := 0 to High(Tools) do
      AddKV(lvEnv, RarToolNames[Tools[I].Kind], Tools[I].Exe + '  [' + Tools[I].Version + ']');
    if FindRarExtractor(Tool) then
      AddKV(lvEnv, 'Used for extract / test', RarToolNames[Tool.Kind])
    else
      AddKV(lvEnv, 'Used for extract / test', '(none)');
    if FindRarCreator(Tool) then
      AddKV(lvEnv, 'Used for create', RarToolNames[Tool.Kind])
    else
      AddKV(lvEnv, 'Used for create', '(none - needs WinRAR rar.exe)');

    AddSection(lvEnv, 'IPC / MCP');
    AddKV(lvEnv, 'IPC pipe', IPCPipeName);
    if ApiCtl <> nil then
      AddKV(lvEnv, 'HTTP API', ApiCtl.BaseUrl + BoolToStr(ApiCtl.Active, '  (running)', '  (stopped)'));
    AddKV(lvEnv, 'MCP server exe', ExtractFilePath(ParamStr(0)) + 'BGRAZipMCP.exe' +
      BoolToStr(FileExistsUTF8(ExtractFilePath(ParamStr(0)) + 'BGRAZipMCP.exe'), '', '  (not built)'));

    AddSection(lvEnv, 'Operating system');
    {$IFDEF WINDOWS}
    AddKV(lvEnv, 'Windows version', Format('%d.%d build %d %s',
      [Win32MajorVersion, Win32MinorVersion, Win32BuildNumber, Win32CSDVersion]));
    {$ENDIF}
    AddKV(lvEnv, 'CPU cores', IntToStr(TThread.ProcessorCount));
    AddKV(lvEnv, 'Default code page', IntToStr(DefaultSystemCodePage));
    AddKV(lvEnv, 'Decimal / date format', DefaultFormatSettings.DecimalSeparator + '  ' +
      DefaultFormatSettings.ShortDateFormat);
    AddKV(lvEnv, 'Current directory', GetCurrentDirUTF8);
    AddKV(lvEnv, 'Temp directory', GetTempDir);
    AddKV(lvEnv, 'User directory', GetUserDir);
    AddKV(lvEnv, 'App config directory', GetAppConfigDirUTF8(False));

    AddSection(lvEnv, 'Display');
    AddKV(lvEnv, 'Screen', Format('%d x %d, %d monitor(s)', [Screen.Width, Screen.Height, Screen.MonitorCount]));
    AddKV(lvEnv, 'Screen PPI / form PPI', Format('%d / %d', [Screen.PixelsPerInch, PixelsPerInch]));
    AddKV(lvEnv, 'Work area', Format('%d x %d', [Screen.WorkAreaWidth, Screen.WorkAreaHeight]));

    HS := GetFPCHeapStatus;
    AddSection(lvEnv, 'FPC heap (live, 1 s refresh)');
    AddKV(lvEnv, 'Current heap size', FormatBytesFull(HS.CurrHeapSize));
    AddKV(lvEnv, 'Current heap used', FormatBytesFull(HS.CurrHeapUsed));
    AddKV(lvEnv, 'Current heap free', FormatBytesFull(HS.CurrHeapFree));
    AddKV(lvEnv, 'Max heap size', FormatBytesFull(HS.MaxHeapSize));
    AddKV(lvEnv, 'Max heap used', FormatBytesFull(HS.MaxHeapUsed));
  finally
    lvEnv.Items.EndUpdate;
  end;
  // keep the scroll position across the live refresh
  if (TopI > 0) and (TopI < lvEnv.Items.Count) then
  begin
    lvEnv.Items[lvEnv.Items.Count - 1].MakeVisible(False);
    lvEnv.Items[TopI].MakeVisible(False);
  end;
end;

procedure TfrmDevInfo.tmrEnvTimer(Sender: TObject);
begin
  if Visible and (pcMain.ActivePage = tsEnv) then
    FillEnv;
end;

procedure TfrmDevInfo.btnEnvRefreshClick(Sender: TObject);
begin
  FillEnv;
end;

procedure TfrmDevInfo.pcMainChange(Sender: TObject);
begin
  if pcMain.ActivePage = tsEnv then
    FillEnv
  else if pcMain.ActivePage = tsChart then
    pbChart.Invalidate;
end;

{ ---------- log ---------- }

procedure TfrmDevInfo.btnLogClearClick(Sender: TObject);
begin
  Log.Clear;
  memoLog.Clear;
end;

procedure TfrmDevInfo.btnLogCopyClick(Sender: TObject);
begin
  Clipboard.AsText := memoLog.Text;
end;

procedure TfrmDevInfo.btnLogSaveClick(Sender: TObject);
begin
  dlgSave.FileName := 'bgrazip-log.txt';
  if dlgSave.Execute then
  begin
    memoLog.Lines.SaveToFile(dlgSave.FileName);
    DevLog(llInfo, 'Log saved to ' + dlgSave.FileName);
  end;
end;

{ ---------- report ---------- }

function TfrmDevInfo.ListViewText(LV: TListView): string;
var
  I, J: Integer;
  S: string;
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    for I := 0 to LV.Items.Count - 1 do
    begin
      if LV.Items[I].SubItems.Count = 1 then
        S := Format('%-34s %s', [LV.Items[I].Caption, LV.Items[I].SubItems[0]])
      else
      begin
        S := LV.Items[I].Caption;
        for J := 0 to LV.Items[I].SubItems.Count - 1 do
          S := S + #9 + LV.Items[I].SubItems[J];
      end;
      SL.Add(TrimRight(S));
    end;
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

function TfrmDevInfo.BuildReport: string;
var
  SL: TStringList;
  I: Integer;
  S: string;
begin
  SL := TStringList.Create;
  try
    SL.Add('BGRA Zip developer report - ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    SL.Add(StringOfChar('#', 78));
    SL.Add(ListViewText(lvOverview));
    if FArchive <> nil then
    begin
      SL.Add('');
      S := '#';
      for I := 1 to lvEntries.Columns.Count - 1 do
        S := S + #9 + lvEntries.Columns[I].Caption;
      SL.Add(S);
      SL.Add(ListViewText(lvEntries));
      for I := 0 to FArchive.Count - 1 do
      begin
        SL.Add('');
        if FRar <> nil then
          SL.Add(RarEntryDetailText(FRar, FRar.Entries[I]))
        else
          SL.Add(EntryDetailText(FZip.Entries[I]));
      end;
    end;
    SL.Add('');
    SL.Add('[ Environment ]');
    FillEnv;
    SL.Add(ListViewText(lvEnv));
    SL.Add('');
    SL.Add('[ Log ]');
    SL.AddStrings(Log.Lines);
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure TfrmDevInfo.btnCopyReportClick(Sender: TObject);
begin
  Clipboard.AsText := BuildReport;
  DevLog(llInfo, 'Developer report copied to clipboard');
end;

procedure TfrmDevInfo.btnSaveReportClick(Sender: TObject);
var
  SL: TStringList;
begin
  dlgSave.FileName := 'bgrazip-report.txt';
  if not dlgSave.Execute then
    Exit;
  SL := TStringList.Create;
  try
    SL.Text := BuildReport;
    SL.SaveToFile(dlgSave.FileName);
  finally
    SL.Free;
  end;
  DevLog(llInfo, 'Developer report saved to ' + dlgSave.FileName);
end;

procedure TfrmDevInfo.chkStayOnTopChange(Sender: TObject);
begin
  if chkStayOnTop.Checked then
    FormStyle := fsStayOnTop
  else
    FormStyle := fsNormal;
end;

procedure TfrmDevInfo.btnCloseClick(Sender: TObject);
begin
  Close;
end;

end.
