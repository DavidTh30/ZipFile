unit uMain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, ExtCtrls, ComCtrls,
  StdCtrls, Menus, LCLType, Zipper, zstream,
  uBGRAUI, uArchiveBase, uZipInspector, uRarInspector, uRarBackend, uArchiveTree, uDevLog, uIPC, uEffects;

type
  TViewMode = (vmEmpty, vmStaging, vmArchive);

  { One row of the right-hand list: a sub-folder or a file of the current folder }
  TRowInfo = record
    Folder: TVFolder;          // non-nil for folder rows
    Index: Integer;            // item index for file rows
  end;

  TCrumb = record
    R: TRect;
    Folder: TVFolder;
  end;

  TDragSource = (dsNone, dsList, dsTree);

  TStagedFile = record
    DiskPath: string;
    ArchiveName: string;
    Size: Int64;
    Modified: TDateTime;
  end;

  { TfrmMain }

  TfrmMain = class(TForm)
    cbLevel: TComboBox;
    cbHideNames: TCheckBox;
    edPassword: TEdit;
    lblPassword: TLabel;
    dlgAddFiles: TOpenDialog;
    dlgFolder: TSelectDirectoryDialog;
    dlgOpenZip: TOpenDialog;
    dlgSaveZip: TSaveDialog;
    ilIcons: TImageList;
    lblLevel: TLabel;
    lvFiles: TListView;
    miShowDev: TMenuItem;
    mnuMain: TMainMenu;
    miFile: TMenuItem;
    miFileNew: TMenuItem;
    miFileOpen: TMenuItem;
    miFileRecent: TMenuItem;
    miFileClose: TMenuItem;
    miFileSep1: TMenuItem;
    miFileCreate: TMenuItem;
    miFileSep2: TMenuItem;
    miFileShowInExplorer: TMenuItem;
    miFileProperties: TMenuItem;
    miFileSep3: TMenuItem;
    miFileExit: TMenuItem;
    miEdit: TMenuItem;
    miEditAddFiles: TMenuItem;
    miEditAddFolder: TMenuItem;
    miEditRemove: TMenuItem;
    miEditSep1: TMenuItem;
    miEditSelectAll: TMenuItem;
    miEditInvert: TMenuItem;
    miEditDeselect: TMenuItem;
    miEditSep2: TMenuItem;
    miEditCopyName: TMenuItem;
    miEditCopyPath: TMenuItem;
    miView: TMenuItem;
    miViewTree: TMenuItem;
    miViewToolbar: TMenuItem;
    miViewHeader: TMenuItem;
    miViewStatus: TMenuItem;
    miViewEffects: TMenuItem;
    miViewEffectOptions: TMenuItem;
    miViewSep1: TMenuItem;
    miViewUp: TMenuItem;
    miViewRoot: TMenuItem;
    miViewExpand: TMenuItem;
    miViewCollapse: TMenuItem;
    miViewSep2: TMenuItem;
    miViewSort: TMenuItem;
    miSortName: TMenuItem;
    miSortSize: TMenuItem;
    miSortPacked: TMenuItem;
    miSortSaved: TMenuItem;
    miSortMethod: TMenuItem;
    miSortModified: TMenuItem;
    miSortCRC: TMenuItem;
    miSortSep: TMenuItem;
    miSortDesc: TMenuItem;
    miViewSep3: TMenuItem;
    miViewRefresh: TMenuItem;
    miActions: TMenuItem;
    miActExtractAll: TMenuItem;
    miActExtractSel: TMenuItem;
    miActExtractHere: TMenuItem;
    miActExtractSub: TMenuItem;
    miActSep1: TMenuItem;
    miActTest: TMenuItem;
    miActSep2: TMenuItem;
    miActLevel: TMenuItem;
    miLevel0: TMenuItem;
    miLevel1: TMenuItem;
    miLevel2: TMenuItem;
    miLevel3: TMenuItem;
    miTools: TMenuItem;
    miDefaultOpen: TMenuItem;
    miDefaultZip: TMenuItem;
    miDefaultRar: TMenuItem;
    miDefaultSep: TMenuItem;
    miDefaultSettings: TMenuItem;
    miDefaultRemove: TMenuItem;
    miToolsSep1: TMenuItem;
    miToolsRarTools: TMenuItem;
    miToolsCleanTemp: TMenuItem;
    miDev: TMenuItem;
    miDevInfo: TMenuItem;
    miDevTabs: TMenuItem;
    miDevTab0: TMenuItem;
    miDevTab1: TMenuItem;
    miDevTab2: TMenuItem;
    miDevTab3: TMenuItem;
    miDevTab4: TMenuItem;
    miDevTab5: TMenuItem;
    miDevSep1: TMenuItem;
    miDevCopyReport: TMenuItem;
    miDevSaveReport: TMenuItem;
    miDevSaveLog: TMenuItem;
    miDevClearLog: TMenuItem;
    miDevSep2: TMenuItem;
    miDevReparse: TMenuItem;
    miDevRescanTools: TMenuItem;
    miDevSep3: TMenuItem;
    miDevOpenTemp: TMenuItem;
    miDevOpenConfig: TMenuItem;
    miDevOpenAppDir: TMenuItem;
    miDevSep4: TMenuItem;
    miDevCmdLine: TMenuItem;
    miDevMCP: TMenuItem;
    miDevApi: TMenuItem;
    miScript: TMenuItem;
    miScriptEditor: TMenuItem;
    miScriptRunFile: TMenuItem;
    miScriptStop: TMenuItem;
    miScriptSep1: TMenuItem;
    miScriptExamples: TMenuItem;
    miHelp: TMenuItem;
    miHelpKeys: TMenuItem;
    miHelpSep: TMenuItem;
    miHelpAbout: TMenuItem;
    miCopyName: TMenuItem;
    miExtractSel: TMenuItem;
    miRemove: TMenuItem;
    pbHeader: TPaintBox;
    pbPath: TPaintBox;
    pbProgress: TPaintBox;
    pbToolbar: TPaintBox;
    pmList: TPopupMenu;
    pnlLevel: TPanel;
    pnlRight: TPanel;
    pnlTools: TPanel;
    sbStatus: TStatusBar;
    splMain: TSplitter;
    tvFolders: TTreeView;
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormDropFiles(Sender: TObject; const FileNames: array of string);
    procedure FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormShow(Sender: TObject);
    procedure lvFilesColumnClick(Sender: TObject; Column: TListColumn);
    procedure lvFilesDblClick(Sender: TObject);
    procedure lvFilesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure lvFilesMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure lvFilesMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure lvFilesSelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure pbPathMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure pbPathPaint(Sender: TObject);
    procedure tvFoldersChange(Sender: TObject; Node: TTreeNode);
    procedure tvFoldersMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure tvFoldersMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure miCopyNameClick(Sender: TObject);
    procedure miFileOpenClick(Sender: TObject);
    procedure miFileExtractAllClick(Sender: TObject);
    procedure miFileExitClick(Sender: TObject);
    procedure MenuPopup(Sender: TObject);
    procedure miFileNewClick(Sender: TObject);
    procedure miFileCreateClick(Sender: TObject);
    procedure miFileShowInExplorerClick(Sender: TObject);
    procedure miFilePropertiesClick(Sender: TObject);
    procedure miRecentClick(Sender: TObject);
    procedure miRecentClearClick(Sender: TObject);
    procedure miEditAddFilesClick(Sender: TObject);
    procedure miEditAddFolderClick(Sender: TObject);
    procedure miEditSelectAllClick(Sender: TObject);
    procedure miEditInvertClick(Sender: TObject);
    procedure miEditDeselectClick(Sender: TObject);
    procedure miEditCopyPathClick(Sender: TObject);
    procedure miViewToggleClick(Sender: TObject);
    procedure miViewUpClick(Sender: TObject);
    procedure miViewRootClick(Sender: TObject);
    procedure miViewExpandClick(Sender: TObject);
    procedure miViewCollapseClick(Sender: TObject);
    procedure miSortClick(Sender: TObject);
    procedure miSortDescClick(Sender: TObject);
    procedure miViewRefreshClick(Sender: TObject);
    procedure miActExtractHereClick(Sender: TObject);
    procedure miActExtractSubClick(Sender: TObject);
    procedure miActTestClick(Sender: TObject);
    procedure miLevelClick(Sender: TObject);
    procedure miToolsRarToolsClick(Sender: TObject);
    procedure miToolsCleanTempClick(Sender: TObject);
    procedure miDevInfoClick(Sender: TObject);
    procedure miDevTabClick(Sender: TObject);
    procedure miDevCopyReportClick(Sender: TObject);
    procedure miDevSaveReportClick(Sender: TObject);
    procedure miDevSaveLogClick(Sender: TObject);
    procedure miDevClearLogClick(Sender: TObject);
    procedure miDevRescanToolsClick(Sender: TObject);
    procedure miDevOpenTempClick(Sender: TObject);
    procedure miDevOpenConfigClick(Sender: TObject);
    procedure miDevOpenAppDirClick(Sender: TObject);
    procedure miDevCmdLineClick(Sender: TObject);
    procedure miDevMCPClick(Sender: TObject);
    procedure miDevApiClick(Sender: TObject);
    procedure miViewEffectsClick(Sender: TObject);
    procedure miViewEffectOptionsClick(Sender: TObject);
    procedure miScriptEditorClick(Sender: TObject);
    procedure miScriptRunFileClick(Sender: TObject);
    procedure miScriptStopClick(Sender: TObject);
    procedure miScriptExamplesClick(Sender: TObject);
    procedure miHelpKeysClick(Sender: TObject);
    procedure miHelpAboutClick(Sender: TObject);
    procedure miDefaultOpenClick(Sender: TObject);
    procedure miDefaultZipClick(Sender: TObject);
    procedure miDefaultRarClick(Sender: TObject);
    procedure miDefaultSettingsClick(Sender: TObject);
    procedure miDefaultRemoveClick(Sender: TObject);
    procedure miExtractSelClick(Sender: TObject);
    procedure miRemoveClick(Sender: TObject);
    procedure miShowDevClick(Sender: TObject);
    procedure pbHeaderPaint(Sender: TObject);
    procedure pbProgressPaint(Sender: TObject);
  private
    FToolbar: TBGRAToolbar;
    FMode: TViewMode;
    FStaged: array of TStagedFile;
    FArchive: TArchiveInfo;
    FTree: TVTree;
    FCurFolder: TVFolder;
    FRows: array of TRowInfo;
    FCrumbs: array of TCrumb;
    FTreeUpdating: Boolean;
    // drag-out to Explorer
    FDragArmed: Boolean;
    FDragStart: TPoint;
    FDragSource: TDragSource;
    FDragNode: TTreeNode;
    FDraggingOut: Boolean;
    FDragTops: TStringList;     // top-level archive paths being dragged (Objects<>nil = folder)
    FDragIndexes: TFPList;      // every item index to extract for the drag
    FRecent: TStringList;       // most recently opened archives, newest first
    FIPC: TIPCServer;           // named-pipe command server (other apps, MCP, 2nd instance)
    FSortColumn: Integer;
    FSortDesc: Boolean;
    FBusy: Boolean;
    FZipper: TZipper;
    FUnZipper: TUnZipper;
    FToolCancel: Boolean;
    FProgress: Double;
    FProgressText: string;
    FProgressActive: Boolean;
    FLastPump: QWord;
    FOpIndex: Integer;
    FOpCount: Integer;
    FOpDone: Int64;
    FOpTotal: Int64;
    FOpCurSize: Int64;
    FOpCurName: string;
    FOpVerb: string;
    FDevTabAtStart: Integer;
    FScriptAtStart: string;
    FStartFxDone: Boolean;
    FScriptWatch: TTimer;
    FScriptWatchId: Integer;
    // password of the open archive, asked once when it is needed
    FPassword: string;
    // files a rar_pure test checked (an encrypted-names RAR lists none); -1 = use the list
    FTestChecked: Integer;
    // RAR tool progress
    FTool: TRarTool;
    FProgNames: TStringList;   // archive name -> size (Objects = entry index or staged index)
    FProgSizes: array of Int64;
    procedure ToolClick(Sender: TObject; ATag: Integer);
    procedure UpdateUI;
    procedure RefreshList;
    procedure FillTreeView;
    procedure ShowFolder(AFolder: TVFolder);
    procedure GoUp;
    procedure ItemInfo(AIndex: Integer; out ASize, APacked: Int64; out ATime: TDateTime);
    function ItemPath(AIndex: Integer): string;
    function CompareRows(A, B: Integer): Integer;
    function CompareFolderRows(A, B: TVFolder): Integer;
    function SelectedIndexes: TStringList;
    function RowAt(AItem: TListItem): TRowInfo;
    procedure ArmDrag(ASource: TDragSource; X, Y: Integer);
    procedure CheckDrag(Shift: TShiftState; X, Y: Integer);
    procedure BeginDragOut;
    function RenderDragFiles(APaths: TStrings): Boolean;
    procedure CleanupDragTemp(AAll: Boolean);
    procedure AddFile(const AFileName, AArchiveName: string);
    procedure AddFiles(AFiles: TStrings);
    procedure AddFolder(const ADir: string);
    procedure RemoveSelected;
    procedure NewArchive;
    procedure OpenArchive(const AFileName: string);
    procedure CreateArchive;
    procedure CreateZip(const AOutName: string);
    procedure CreateRar(const AOutName: string);
    procedure ExtractTo(ASelectedOnly: Boolean; const ADir: string = '');
    function ExtractZip(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
    function ExtractRar(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
    function DoExtractRar(const ADir: string; ANames: TStrings; Plain: TStringList; ATotal: Int64;
      AQuiet: Boolean): Boolean;
    { rar_pure.exe (next to the program) extracts, tests with a password and creates ZIP / RAR }
    function ArchiveLocked: Boolean;
    function AskPassword(const AVerb: string): Boolean;
    function PureProgress(ABytes: Int64): Boolean;
    function ExtractPure(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
    procedure TestPure(ABad, ALocked: TStringList; out ACancelled: Boolean);
    function CreatePure(const AOutName: string): Boolean;
    procedure TestArchive;
    { ABad: real problems; ALocked: password-protected entries that could not be checked }
    procedure TestZip(ABad, ALocked: TStringList; out ACancelled: Boolean);
    procedure TestRar(ABad, ALocked: TStringList; out ACancelled: Boolean);
    function TestSummary(ABad, ALocked: TStringList; out AOK: Boolean): string;
    procedure SetProgress(AFraction: Double; const AText: string; AActive: Boolean; AForce: Boolean = False);
    procedure ZipStartFile(Sender: TObject; const AFileName: string);
    procedure ZipProgress(Sender: TObject; const Pct: Double);
    procedure UnzipStartFile(Sender: TObject; const AFileName: string);
    procedure UnzipProgressEx(Sender: TObject; const ATotPos, ATotSize: Int64);
    procedure TestCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure TestDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure ToolLine(const ALine: string);
    function ToolPoll(ABytesOut: Int64): Boolean;
    function ToolStreamPoll(ABytesOut: Int64): Boolean;
    procedure ResetProgNames;
    procedure AddProgName(const AName: string; ASize: Int64);
    function RequireRarTool(out ATool: TRarTool; ACreate: Boolean): Boolean;
    procedure CancelOperation;
    procedure SetDefaultOpen(const AExt, ADescription: string);
    function HandleIPC(const ARequest: string): string;
    procedure AsyncClose(Data: PtrInt);
    procedure AsyncWindow(Data: PtrInt);
    procedure PlayFx(AEvent: TFxEvent);
    procedure PreviewFx(AEvent: Integer);
    procedure ScriptWatch(Sender: TObject);
    procedure SetupMenuIcons;
    procedure LoadSettings;
    procedure SaveSettings;
    procedure AddRecent(const AFileName: string);
    procedure BuildRecentMenu;
    procedure UpdateMenus;
    procedure ApplyViewToggles;
    procedure ShowDevInfo;
    function StagedTotal: Int64;
    { Header pill text when the open archive is password-protected ('' if not); ADetail says what is locked }
    function LockInfo(out ADetail: string): string;
    function CompressionLevel: TCompressionLevel;
    function IsRar: Boolean;
  public
    property Archive: TArchiveInfo read FArchive;
  end;

var
  frmMain: TfrmMain;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  LazFileUtils, FileUtil, LCLIntf, Clipbrd, Math, BGRABitmap, BGRABitmapTypes,
  IniFiles, LCLVersion, fpjson, jsonparser, uDevInfo, uDragOut, uFileAssoc, uMcpSetup, uHttpApi, uApiDialog, uScriptEngine, uScriptWindow, uEffectsDialog,
  uArchiveOps, uRarPure;

{$R *.lfm}

const
  TB_NEW = 1;
  TB_ADDFILES = 2;
  TB_ADDFOLDER = 3;
  TB_REMOVE = 4;
  TB_CREATE = 5;
  TB_OPEN = 6;
  TB_EXTRACT = 7;
  TB_EXTRACTSEL = 8;
  TB_TEST = 9;
  TB_DEV = 10;

  IMG_FILE = 0;
  IMG_FOLDER = 1;
  IMG_ZIP = 2;
  IMG_FILE_LOCKED = 3;
  IMG_ZIP_LOCKED = 4;

  // command lines on Windows are limited to 32767 chars; keep a margin
  MAX_ARGS_CHARS = 24000;

function DevForm: TfrmDevInfo;
begin
  if frmDevInfo = nil then
    Application.CreateForm(TfrmDevInfo, frmDevInfo);
  Result := frmDevInfo;
end;

function IsArchiveFile(const AFileName: string): Boolean;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(AFileName));
  Result := (Ext = '.zip') or (Ext = '.rar');
end;

{ Splits a long name list into several lists that each fit on a command line. }
function ChunkNames(ANames: TStrings): TList;
var
  Cur: TStringList;
  Len, I: Integer;
begin
  Result := TList.Create;
  Cur := TStringList.Create;
  Len := 0;
  for I := 0 to ANames.Count - 1 do
  begin
    if (Cur.Count > 0) and (Len + Length(ANames[I]) + 3 > MAX_ARGS_CHARS) then
    begin
      Result.Add(Cur);
      Cur := TStringList.Create;
      Len := 0;
    end;
    Cur.Add(ANames[I]);
    Inc(Len, Length(ANames[I]) + 3);
  end;
  Result.Add(Cur);
end;

procedure FreeChunks(AList: TList);
var
  I: Integer;
begin
  for I := 0 to AList.Count - 1 do
    TObject(AList[I]).Free;
  AList.Free;
end;

type
  { Output sink for ZIP "Test": discards data, TUnZipper still verifies CRC32. }
  TDiscardStream = class(TStream)
  private
    FSize: Int64;
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

function TDiscardStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TDiscardStream.Write(const Buffer; Count: Longint): Longint;
begin
  Inc(FSize, Count);
  Result := Count;
end;

function TDiscardStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FSize;
end;

{ TfrmMain }

function ConfigFileName: string; forward;

procedure TfrmMain.FormCreate(Sender: TObject);
var
  Ic: TToolIcon;
  I: Integer;
  P: string;
  ApiWanted: Boolean;
begin
  DevLog(llInfo, 'Application started: ' + ParamStr(0));
  FDevTabAtStart := -1;
  FProgNames := TStringList.Create;
  FProgNames.Sorted := True;
  FProgNames.CaseSensitive := False;
  FProgNames.Duplicates := dupIgnore;
  FTree := TVTree.Create;
  FTree.OnItemInfo := @ItemInfo;
  FDragTops := TStringList.Create;
  FDragIndexes := TFPList.Create;
  CleanupDragTemp(True);
  FRecent := TStringList.Create;
  LoadSettings;
  FToolbar := TBGRAToolbar.Create(pbToolbar);
  FToolbar.OnClick := @ToolClick;
  // New / Open / Developer live in the main menu only
  FToolbar.AddButton(TB_ADDFILES, 'Add files', 'Add files to the new archive (Ins)', tiAddFile);
  FToolbar.AddButton(TB_ADDFOLDER, 'Add folder', 'Add a folder recursively', tiAddFolder);
  FToolbar.AddButton(TB_REMOVE, 'Remove', 'Remove selected files from the list (Del)', tiRemove);
  FToolbar.AddSeparator;
  FToolbar.AddButton(TB_CREATE, 'Create', 'Compress the listed files into a .zip or .rar (Ctrl+S)', tiCreate);
  FToolbar.AddButton(TB_EXTRACT, 'Extract all', 'Extract every entry to a folder (Ctrl+E)', tiExtract);
  FToolbar.AddButton(TB_EXTRACTSEL, 'Extract selected', 'Extract only the selected entries', tiExtractSel);
  FToolbar.AddButton(TB_TEST, 'Test', 'Decompress everything in memory and verify CRC32 (Ctrl+T)', tiTest);

  ilIcons.Clear;
  for Ic in [tiFile, tiFolder, tiZip, tiFileLocked, tiZipLocked] do
    AddIconToImageList(ilIcons, Ic);
  SetupMenuIcons;

  FSortColumn := -1;
  FTestChecked := -1;
  FMode := vmEmpty;
  UpdateUI;
  SetProgress(0, 'Ready', False, True);

  // Command line: BGRAZip [archive.zip|.rar | files...] [--dev[=tab]]
  for I := 1 to ParamCount do
  begin
    P := ParamStr(I);
    if (P = '--dev') or (Copy(P, 1, 6) = '--dev=') then
      FDevTabAtStart := StrToIntDef(Copy(P, 7, 3), 0)
    else if (I > 1) and (ParamStr(I - 1) = '--script') then
      FScriptAtStart := P
    else if FileExistsUTF8(P) then
    begin
      if (FMode = vmEmpty) and IsArchiveFile(P) then
        OpenArchive(P)
      else if FMode <> vmArchive then
        AddFile(P, ExtractFileName(P));
    end;
  end;
  if FMode = vmStaging then
    RefreshList;

  FIPC := TIPCServer.Create(@HandleIPC);
  if FIPC.Active then
    DevLogFmt(llInfo, 'IPC server listening on %s', [IPCPipeName])
  else
    DevLogFmt(llWarn, 'IPC pipe %s is owned by another instance - this window does not accept commands',
      [IPCPipeName]);

  ScriptLocalHandler := @HandleIPC;
  Fx := TFxEngine.Create(Handle, ConfigFileName);
  try
    Fx.Load;
  except
    on E: Exception do
      DevLog(llWarn, 'Effect settings: ' + E.Message);
  end;
  miViewEffects.Checked := Fx.Enabled;
  FScriptWatch := TTimer.Create(Self);
  FScriptWatch.Interval := 400;
  FScriptWatch.OnTimer := @ScriptWatch;
  ApiCtl := TApiController.Create(ConfigFileName, @HandleIPC);
  try
    ApiCtl.Load;
    ApiWanted := ApiCtl.Enabled;
    for I := 1 to ParamCount do
      if ParamStr(I) = '--api' then
        ApiWanted := True;
    if ApiWanted then
      ApiCtl.Start;
  except
    on E: Exception do
      DevLog(llWarn, 'HTTP API: ' + E.Message);
  end;
end;

procedure TfrmMain.FormShow(Sender: TObject);
begin
  if FDevTabAtStart >= 0 then
  begin
    ShowDevInfo;
    DevForm.ShowTab(FDevTabAtStart);
    if (FMode = vmArchive) and (FArchive.Count > 0) then
      DevForm.SelectEntry(Min(1, FArchive.Count - 1));
    FDevTabAtStart := -1;
  end;
  if FScriptAtStart <> '' then
  begin
    ShowScriptEditor(FScriptAtStart);
    FScriptAtStart := '';
  end;
end;

procedure TfrmMain.FormDestroy(Sender: TObject);
begin
  FreeAndNil(ApiCtl);
  FreeAndNil(CurrentScriptJob);
  FreeAndNil(Fx);
  FreeAndNil(FIPC);
  FToolbar.Free;
  if frmDevInfo <> nil then
    frmDevInfo.SetArchive(nil);
  FArchive.Free;
  FProgNames.Free;
  FTree.Free;
  FDragTops.Free;
  FDragIndexes.Free;
  CleanupDragTemp(False);
  SaveSettings;
  FRecent.Free;
end;

procedure TfrmMain.CancelOperation;
begin
  DevLog(llWarn, 'Cancel requested by user');
  if FZipper <> nil then FZipper.Terminate;
  if FUnZipper <> nil then FUnZipper.Terminate;
  FToolCancel := True;
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  if FBusy then
  begin
    CanClose := False;
    if MessageDlg('An operation is running. Cancel it?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
      CancelOperation;
  end;
end;

procedure TfrmMain.FormDropFiles(Sender: TObject; const FileNames: array of string);
var
  I: Integer;
begin
  // our own drag-out landing back on this window
  if FBusy or FDraggingOut then
    Exit;
  DevLogFmt(llDebug, 'Drop: %d item(s)', [Length(FileNames)]);
  if (Length(FileNames) = 1) and IsArchiveFile(FileNames[0]) and (FMode <> vmStaging) then
  begin
    OpenArchive(FileNames[0]);
    Exit;
  end;
  if FMode = vmArchive then
    NewArchive;
  for I := 0 to High(FileNames) do
    if DirectoryExistsUTF8(FileNames[I]) then
      AddFolder(FileNames[I])
    else
      AddFile(FileNames[I], ExtractFileName(FileNames[I]));
  RefreshList;
end;

procedure TfrmMain.FormKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // all other shortcuts live on the main menu items
  if (Key = VK_ESCAPE) and FBusy then
  begin
    CancelOperation;
    Key := 0;
  end;
end;

procedure TfrmMain.ToolClick(Sender: TObject; ATag: Integer);
begin
  if FBusy then
    Exit;
  case ATag of
    TB_NEW:
      NewArchive;
    TB_ADDFILES:
      if dlgAddFiles.Execute then
      begin
        if FMode = vmArchive then
          NewArchive;
        AddFiles(dlgAddFiles.Files);
        RefreshList;
      end;
    TB_ADDFOLDER:
      if dlgFolder.Execute then
      begin
        if FMode = vmArchive then
          NewArchive;
        AddFolder(dlgFolder.FileName);
        RefreshList;
      end;
    TB_REMOVE:
      RemoveSelected;
    TB_CREATE:
      if FMode = vmStaging then
        CreateArchive;
    TB_OPEN:
      if dlgOpenZip.Execute then
        OpenArchive(dlgOpenZip.FileName);
    TB_EXTRACT:
      if FMode = vmArchive then
        ExtractTo(False);
    TB_EXTRACTSEL:
      if FMode = vmArchive then
        ExtractTo(True);
    TB_TEST:
      if FMode = vmArchive then
        TestArchive;
    TB_DEV:
      ShowDevInfo;
  end;
end;

function TfrmMain.IsRar: Boolean;
begin
  Result := FArchive is TRarArchiveInfo;
end;

procedure TfrmMain.UpdateUI;
var
  HasSel, Idle: Boolean;
  Detail: string;
begin
  Idle := not FBusy;
  HasSel := lvFiles.SelCount > 0;
  FToolbar.SetEnabled(TB_NEW, Idle and (FMode <> vmEmpty));
  FToolbar.SetEnabled(TB_ADDFILES, Idle);
  FToolbar.SetEnabled(TB_ADDFOLDER, Idle);
  FToolbar.SetEnabled(TB_REMOVE, Idle and (FMode = vmStaging) and HasSel);
  FToolbar.SetEnabled(TB_CREATE, Idle and (FMode = vmStaging) and (Length(FStaged) > 0));
  FToolbar.SetEnabled(TB_OPEN, Idle);
  FToolbar.SetEnabled(TB_EXTRACT, Idle and (FMode = vmArchive));
  FToolbar.SetEnabled(TB_EXTRACTSEL, Idle and (FMode = vmArchive) and HasSel);
  FToolbar.SetEnabled(TB_TEST, Idle and (FMode = vmArchive));
  FToolbar.SetEnabled(TB_DEV, True);
  miRemove.Enabled := Idle and (FMode = vmStaging) and HasSel;
  miExtractSel.Enabled := Idle and (FMode = vmArchive) and HasSel;
  cbLevel.Enabled := Idle;

  case FMode of
    vmEmpty:
      begin
        Caption := 'BGRA Zip';
        sbStatus.Panels[0].Text := 'Empty';
        sbStatus.Panels[2].Text := 'Drop files, a .zip or a .rar here, or use Add files / Open';
      end;
    vmStaging:
      begin
        Caption := 'BGRA Zip - new archive';
        sbStatus.Panels[0].Text := Format('New archive: %d file(s)', [Length(FStaged)]);
        sbStatus.Panels[2].Text := 'Total ' + FormatSize(StagedTotal);
      end;
    vmArchive:
      begin
        Caption := 'BGRA Zip - ' + ExtractFileName(FArchive.FileName);
        if (FArchive is TRarArchiveInfo) and TRarArchiveInfo(FArchive).HeadersEncrypted then
          sbStatus.Panels[0].Text := FArchive.FormatName + ': names encrypted'
        else
          sbStatus.Panels[0].Text := Format('%s: %d entries', [FArchive.FormatName, FArchive.Count]);
        if LockInfo(Detail) <> '' then
        begin
          Caption := Caption + '  [password-protected]';
          sbStatus.Panels[2].Text := 'Locked: ' + Detail + '  -  ' + FArchive.FileName;
        end
        else
          sbStatus.Panels[2].Text := FArchive.FileName;
      end;
  end;
  if HasSel then
    sbStatus.Panels[1].Text := Format('%d selected', [lvFiles.SelCount])
  else
    sbStatus.Panels[1].Text := '';
  pbHeader.Invalidate;
end;

function TfrmMain.StagedTotal: Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(FStaged) do
    Inc(Result, FStaged[I].Size);
end;

function TfrmMain.LockInfo(out ADetail: string): string;
var
  N: Integer;
begin
  Result := '';
  ADetail := '';
  if (FMode <> vmArchive) or (FArchive = nil) then
    Exit;
  if (FArchive is TRarArchiveInfo) and TRarArchiveInfo(FArchive).HeadersEncrypted then
  begin
    Result := 'Names encrypted';
    ADetail := 'the file list needs the password';
    if FArchive.ArchiveFormat = afRar5 then
      ADetail := ADetail + ' (AES-256)';
    Exit;
  end;
  N := FArchive.EncryptedCount;
  if N = 0 then
    Exit;
  if N >= FArchive.FileCount then
    Result := 'Password-protected'
  else
    Result := 'Partly encrypted';
  ADetail := Format('%d of %d files need a password (%s)', [N, FArchive.FileCount, FArchive.EncryptionSummary]);
end;

function TfrmMain.CompressionLevel: TCompressionLevel;
begin
  case cbLevel.ItemIndex of
    0: Result := clnone;
    1: Result := clfastest;
    3: Result := clmax;
  else
    Result := cldefault;
  end;
end;

{ ---------- list ---------- }

procedure TfrmMain.ItemInfo(AIndex: Integer; out ASize, APacked: Int64; out ATime: TDateTime);
var
  E: TArchiveEntry;
begin
  if FMode = vmArchive then
  begin
    E := FArchive.Entry[AIndex];
    ASize := E.UncompressedSize;
    APacked := E.CompressedSize;
    ATime := E.DateTime;
  end
  else
  begin
    ASize := FStaged[AIndex].Size;
    APacked := 0;
    ATime := FStaged[AIndex].Modified;
  end;
end;

function TfrmMain.ItemPath(AIndex: Integer): string;
begin
  if FMode = vmArchive then
    Result := FArchive.Entry[AIndex].FileName
  else
    Result := FStaged[AIndex].ArchiveName;
end;

function TfrmMain.CompareRows(A, B: Integer): Integer;
var
  EA, EB: TArchiveEntry;
begin
  Result := 0;
  if FMode = vmArchive then
  begin
    EA := FArchive.Entry[A];
    EB := FArchive.Entry[B];
    case FSortColumn of
      1: Result := CompareValue(EA.UncompressedSize, EB.UncompressedSize);
      2: Result := CompareValue(EA.CompressedSize, EB.CompressedSize);
      3: Result := CompareValue(EA.SavedPercent, EB.SavedPercent);
      4: Result := CompareText(EA.MethodText, EB.MethodText);
      5: Result := CompareValue(EA.DateTime, EB.DateTime);
      6: Result := CompareValue(Int64(EA.CRC32), Int64(EB.CRC32));
    else
      Result := CompareText(ExtractFileName(EA.FileName), ExtractFileName(EB.FileName));
    end;
  end
  else
    case FSortColumn of
      1, 2: Result := CompareValue(FStaged[A].Size, FStaged[B].Size);
      5: Result := CompareValue(FStaged[A].Modified, FStaged[B].Modified);
      6: Result := CompareText(FStaged[A].DiskPath, FStaged[B].DiskPath);
    else
      Result := CompareText(ExtractFileName(FStaged[A].ArchiveName), ExtractFileName(FStaged[B].ArchiveName));
    end;
  if Result = 0 then
    Result := A - B;
  if FSortDesc then
    Result := -Result;
end;

function TfrmMain.CompareFolderRows(A, B: TVFolder): Integer;
begin
  case FSortColumn of
    1: Result := CompareValue(A.TotalSize, B.TotalSize);
    2: Result := CompareValue(A.TotalPacked, B.TotalPacked);
    5: Result := CompareValue(A.Latest, B.Latest);
  else
    Result := CompareText(A.Name, B.Name);
  end;
  if Result = 0 then
    Result := CompareText(A.Name, B.Name);
  if FSortDesc then
    Result := -Result;
end;

procedure TfrmMain.RefreshList;
var
  OldPath, RootName: string;
  I: Integer;
  T0: QWord;
  F: TVFolder;
begin
  T0 := GetTickCount64;
  if (FMode = vmStaging) and (Length(FStaged) = 0) then
    FMode := vmEmpty;
  OldPath := '';
  if FCurFolder <> nil then
    OldPath := FCurFolder.Path;
  FCurFolder := nil;
  case FMode of
    vmArchive: RootName := ExtractFileName(FArchive.FileName);
    vmStaging: RootName := 'New archive';
  else
    RootName := '(empty)';
  end;
  FTree.Clear(RootName);
  case FMode of
    vmArchive:
      for I := 0 to FArchive.Count - 1 do
        FTree.AddItem(FArchive.Entry[I].FileName, I, FArchive.Entry[I].IsDirectory);
    vmStaging:
      for I := 0 to High(FStaged) do
        FTree.AddItem(FStaged[I].ArchiveName, I, False);
  end;
  FTree.Finish;
  FillTreeView;
  F := FTree.FolderByPath(OldPath);
  if F = nil then
    F := FTree.Root;
  ShowFolder(F);
  DevLogFmt(llTiming, 'Folder tree rebuilt: %d items, %d files below root, in %d ms',
    [IfThen(FMode = vmArchive, FArchive.Count, Length(FStaged)), FTree.Root.FileCountDeep, GetTickCount64 - T0]);
end;

procedure TfrmMain.FillTreeView;

  procedure AddNode(AParent: TTreeNode; F: TVFolder);
  var
    N: TTreeNode;
    Sub: TVFolder;
  begin
    if AParent = nil then
      N := tvFolders.Items.Add(nil, F.Name)
    else
      N := tvFolders.Items.AddChild(AParent, F.Name);
    N.Data := F;
    if F.Parent = nil then
      N.ImageIndex := IMG_ZIP
    else
      N.ImageIndex := IMG_FOLDER;
    N.SelectedIndex := N.ImageIndex;
    for Sub in F.Folders do
      AddNode(N, Sub);
  end;

begin
  FTreeUpdating := True;
  tvFolders.Items.BeginUpdate;
  try
    tvFolders.Items.Clear;
    AddNode(nil, FTree.Root);
    if tvFolders.Items.Count > 0 then
      tvFolders.Items[0].Expand(False);
  finally
    tvFolders.Items.EndUpdate;
    FTreeUpdating := False;
  end;
end;

procedure TfrmMain.ShowFolder(AFolder: TVFolder);
var
  I, J, N: Integer;
  Subs: array of TVFolder;
  Files: array of Integer;
  TF: TVFolder;
  TI: Integer;
  It: TListItem;
  E: TArchiveEntry;
  Ext: string;
  Node: TTreeNode;
begin
  if AFolder = nil then
    AFolder := FTree.Root;
  FCurFolder := AFolder;

  // keep the tree selection in sync
  FTreeUpdating := True;
  try
    Node := tvFolders.Items.GetFirstNode;
    while Node <> nil do
    begin
      if Node.Data = Pointer(AFolder) then
      begin
        Node.Selected := True;
        Node.MakeVisible;
        Break;
      end;
      Node := Node.GetNext;
    end;
  finally
    FTreeUpdating := False;
  end;

  // sub-folders first, then files, each group sorted (insertion sort: stable, lists are small)
  SetLength(Subs, AFolder.Folders.Count);
  for I := 0 to High(Subs) do
    Subs[I] := AFolder.Folders[I];
  for I := 1 to High(Subs) do
  begin
    TF := Subs[I];
    J := I - 1;
    while (J >= 0) and (CompareFolderRows(Subs[J], TF) > 0) do
    begin
      Subs[J + 1] := Subs[J];
      Dec(J);
    end;
    Subs[J + 1] := TF;
  end;
  Files := Copy(AFolder.Files);
  for I := 1 to High(Files) do
  begin
    TI := Files[I];
    J := I - 1;
    while (J >= 0) and (CompareRows(Files[J], TI) > 0) do
    begin
      Files[J + 1] := Files[J];
      Dec(J);
    end;
    Files[J + 1] := TI;
  end;

  N := Length(Subs) + Length(Files);
  SetLength(FRows, N);
  for I := 0 to High(Subs) do
  begin
    FRows[I].Folder := Subs[I];
    FRows[I].Index := Subs[I].DirEntry;
  end;
  for I := 0 to High(Files) do
  begin
    FRows[Length(Subs) + I].Folder := nil;
    FRows[Length(Subs) + I].Index := Files[I];
  end;

  if FMode = vmArchive then
    lvFiles.Columns[6].Caption := 'CRC32'
  else
    lvFiles.Columns[6].Caption := 'Source path';

  lvFiles.Items.BeginUpdate;
  try
    lvFiles.Items.Clear;
    for I := 0 to N - 1 do
    begin
      It := lvFiles.Items.Add;
      It.Data := Pointer(PtrInt(I));
      if FRows[I].Folder <> nil then
      begin
        TF := FRows[I].Folder;
        It.Caption := TF.Name;
        It.ImageIndex := IMG_FOLDER;
        It.SubItems.Add(FormatSize(TF.TotalSize));
        if FMode = vmArchive then
        begin
          It.SubItems.Add(FormatSize(TF.TotalPacked));
          if TF.TotalSize > 0 then
            It.SubItems.Add(FormatFloat('0.0', 100 * (1 - TF.TotalPacked / TF.TotalSize)) + '%')
          else
            It.SubItems.Add('');
        end
        else
        begin
          It.SubItems.Add('-');
          It.SubItems.Add('-');
        end;
        It.SubItems.Add(Format('Folder (%d files)', [TF.FileCountDeep]));
        if TF.Latest > 0 then
          It.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', TF.Latest))
        else
          It.SubItems.Add('');
        It.SubItems.Add('');
      end
      else if FMode = vmArchive then
      begin
        E := FArchive.Entry[FRows[I].Index];
        It.Caption := ExtractFileName(StringReplace(E.FileName, '/', PathDelim, [rfReplaceAll]));
        Ext := LowerCase(ExtractFileExt(E.FileName));
        if (Ext = '.zip') or (Ext = '.rar') then
          It.ImageIndex := IfThen(E.IsEncrypted, IMG_ZIP_LOCKED, IMG_ZIP)
        else
          It.ImageIndex := IfThen(E.IsEncrypted, IMG_FILE_LOCKED, IMG_FILE);
        It.SubItems.Add(FormatSize(E.UncompressedSize));
        It.SubItems.Add(FormatSize(E.CompressedSize));
        It.SubItems.Add(FormatFloat('0.0', E.SavedPercent) + '%');
        if E.IsEncrypted then
          It.SubItems.Add(E.MethodText + ' + ' + E.EncryptionText)
        else
          It.SubItems.Add(E.MethodText);
        It.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', E.DateTime));
        It.SubItems.Add(IntToHex(E.CRC32, 8));
      end
      else
      begin
        J := FRows[I].Index;
        It.Caption := ExtractFileName(StringReplace(FStaged[J].ArchiveName, '/', PathDelim, [rfReplaceAll]));
        It.ImageIndex := IMG_FILE;
        It.SubItems.Add(FormatSize(FStaged[J].Size));
        It.SubItems.Add('-');
        It.SubItems.Add('-');
        It.SubItems.Add('pending');
        It.SubItems.Add(FormatDateTime('yyyy-mm-dd hh:nn:ss', FStaged[J].Modified));
        It.SubItems.Add(FStaged[J].DiskPath);
      end;
    end;
  finally
    lvFiles.Items.EndUpdate;
  end;
  pbPath.Invalidate;
  UpdateUI;
end;

procedure TfrmMain.GoUp;
begin
  if (FCurFolder <> nil) and (FCurFolder.Parent <> nil) then
    ShowFolder(FCurFolder.Parent);
end;

function TfrmMain.RowAt(AItem: TListItem): TRowInfo;
var
  I: PtrInt;
begin
  Result.Folder := nil;
  Result.Index := -1;
  if AItem = nil then
    Exit;
  I := PtrInt(AItem.Data);
  if (I >= 0) and (I <= High(FRows)) then
    Result := FRows[I];
end;

function TfrmMain.SelectedIndexes: TStringList;
var
  I, K: Integer;
  R: TRowInfo;
  L: TFPList;
begin
  // Item indexes behind the selected rows; a selected folder contributes
  // every file (and directory entry) below it.
  Result := TStringList.Create;
  L := TFPList.Create;
  try
    for I := 0 to lvFiles.Items.Count - 1 do
      if lvFiles.Items[I].Selected then
      begin
        R := RowAt(lvFiles.Items[I]);
        if R.Folder <> nil then
          R.Folder.CollectItems(L)
        else if R.Index >= 0 then
          L.Add(Pointer(PtrInt(R.Index)));
      end;
    for K := 0 to L.Count - 1 do
      Result.AddObject(IntToStr(PtrInt(L[K])), TObject(L[K]));
  finally
    L.Free;
  end;
end;

procedure TfrmMain.lvFilesColumnClick(Sender: TObject; Column: TListColumn);
begin
  if FSortColumn = Column.Index then
    FSortDesc := not FSortDesc
  else
  begin
    FSortColumn := Column.Index;
    FSortDesc := False;
  end;
  DevLogFmt(llDebug, 'Sort by column %d (%s)', [FSortColumn, BoolToStr(FSortDesc, 'desc', 'asc')]);
  ShowFolder(FCurFolder);
end;

procedure TfrmMain.lvFilesSelectItem(Sender: TObject; Item: TListItem; Selected: Boolean);
var
  R: TRowInfo;
begin
  UpdateUI;
  if Selected and (FMode = vmArchive) and (frmDevInfo <> nil) then
  begin
    R := RowAt(Item);
    if R.Index >= 0 then
      frmDevInfo.SelectEntry(R.Index);
  end;
end;

procedure TfrmMain.lvFilesDblClick(Sender: TObject);
var
  R: TRowInfo;
begin
  R := RowAt(lvFiles.Selected);
  if R.Folder <> nil then
    ShowFolder(R.Folder)
  else if (FMode = vmArchive) and (R.Index >= 0) then
  begin
    ShowDevInfo;
    DevForm.SelectEntry(R.Index, True);
  end;
end;

procedure TfrmMain.lvFilesKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = VK_BACK then
  begin
    GoUp;
    Key := 0;
  end
  else if (Key = VK_RETURN) and (RowAt(lvFiles.Selected).Folder <> nil) then
  begin
    ShowFolder(RowAt(lvFiles.Selected).Folder);
    Key := 0;
  end;
end;

procedure TfrmMain.tvFoldersChange(Sender: TObject; Node: TTreeNode);
begin
  if FTreeUpdating or (Node = nil) or (Node.Data = nil) then
    Exit;
  if TVFolder(Node.Data) <> FCurFolder then
    ShowFolder(TVFolder(Node.Data));
end;

{ ---------- breadcrumb path bar (BGRABitmap) ---------- }

procedure TfrmMain.pbPathPaint(Sender: TObject);
var
  B: TBGRABitmap;
  W, H, I, N: Integer;
  X: Single;
  Chain: array of TVFolder;
  F: TVFolder;
  S: string;
  TS: TSize;
  HintText: string;
begin
  W := pbPath.Width;
  H := pbPath.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  B := TBGRABitmap.Create(W, H);
  try
    B.GradientFill(0, 0, W, H, BGRA(246, 248, 252), BGRA(234, 238, 245), gtLinear,
      PointF(0, 0), PointF(0, H), dmSet);
    B.DrawLineAntialias(0, H - 0.5, W, H - 0.5, BGRA(205, 212, 225), 1);
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := Round(H * 0.46);

    SetLength(Chain, 0);
    F := FCurFolder;
    while F <> nil do
    begin
      SetLength(Chain, Length(Chain) + 1);
      Chain[High(Chain)] := F;
      F := F.Parent;
    end;
    N := Length(Chain);
    SetLength(FCrumbs, N);
    X := 6;
    for I := N - 1 downto 0 do
    begin
      F := Chain[I];
      if F.Parent = nil then
      begin
        DrawToolIcon(B, tiZip, X, (H - 18) / 2, 18);
        X := X + 22;
      end;
      S := F.Name;
      TS := B.TextSize(S);
      FCrumbs[N - 1 - I].Folder := F;
      FCrumbs[N - 1 - I].R := Classes.Rect(Round(X) - 4, 3, Round(X + TS.cx) + 4, H - 3);
      if I = 0 then
      begin
        B.FillRoundRectAntialias(X - 5, 4, X + TS.cx + 5, H - 4, 6, 6, BGRA(210, 228, 250));
        B.FontStyle := [fsBold];
        TS := B.TextSize(S);
      end;
      B.TextOut(X, (H - TS.cy) / 2, S, clrText);
      B.FontStyle := [];
      X := X + TS.cx + 8;
      if I > 0 then
      begin
        B.DrawPolyLineAntialias([PointF(X, H * 0.35), PointF(X + 5, H * 0.5), PointF(X, H * 0.65)],
          clrMuted, 1.5);
        X := X + 13;
      end;
    end;

    if FMode = vmArchive then
      HintText := 'Drag files or folders to Explorer / Desktop to extract them there'
    else if FMode = vmStaging then
      HintText := 'Files to be added - press Create'
    else
      HintText := '';
    if HintText <> '' then
    begin
      B.FontHeight := Round(H * 0.4);
      TS := B.TextSize(HintText);
      if W - TS.cx - 10 > X + 20 then
        B.TextOut(W - TS.cx - 10, (H - TS.cy) / 2, HintText, clrMuted);
    end;
    B.Draw(pbPath.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

procedure TfrmMain.pbPathMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  for I := 0 to High(FCrumbs) do
    if PtInRect(FCrumbs[I].R, Classes.Point(X, Y)) then
    begin
      ShowFolder(FCrumbs[I].Folder);
      Exit;
    end;
end;

{ ---------- drag-out to Explorer ---------- }

procedure TfrmMain.ArmDrag(ASource: TDragSource; X, Y: Integer);
begin
  FDragArmed := (FMode = vmArchive) and not FBusy;
  FDragSource := ASource;
  FDragStart := Classes.Point(X, Y);
end;

procedure TfrmMain.CheckDrag(Shift: TShiftState; X, Y: Integer);
var
  DX, DY: Integer;
begin
  if not FDragArmed then
    Exit;
  if not (ssLeft in Shift) then
  begin
    FDragArmed := False;
    Exit;
  end;
  {$IFDEF WINDOWS}
  DX := GetSystemMetrics(SM_CXDRAG);
  DY := GetSystemMetrics(SM_CYDRAG);
  {$ELSE}
  DX := 4;
  DY := 4;
  {$ENDIF}
  if (Abs(X - FDragStart.X) > DX) or (Abs(Y - FDragStart.Y) > DY) then
  begin
    FDragArmed := False;
    BeginDragOut;
  end;
end;

procedure TfrmMain.lvFilesMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if (Button = mbLeft) and (lvFiles.GetItemAt(X, Y) <> nil) then
    ArmDrag(dsList, X, Y)
  else
    FDragArmed := False;
end;

procedure TfrmMain.lvFilesMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if FDragSource = dsList then
    CheckDrag(Shift, X, Y);
end;

procedure TfrmMain.tvFoldersMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  FDragNode := tvFolders.GetNodeAt(X, Y);
  if (Button = mbLeft) and (FDragNode <> nil) then
    ArmDrag(dsTree, X, Y)
  else
    FDragArmed := False;
end;

procedure TfrmMain.tvFoldersMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
begin
  if FDragSource = dsTree then
    CheckDrag(Shift, X, Y);
end;

procedure TfrmMain.BeginDragOut;
var
  I: Integer;
  R: TRowInfo;
  F, Sub: TVFolder;
  It: TListItem;
  Res: TDragOutResult;
  Rendered: Boolean;

  procedure AddFolderTop(AFolder: TVFolder);
  begin
    FDragTops.AddObject(AFolder.Path, AFolder);
    AFolder.CollectItems(FDragIndexes);
  end;

  procedure AddFileTop(AIndex: Integer);
  begin
    FDragTops.AddObject(NormalizeArchivePath(ItemPath(AIndex)), nil);
    FDragIndexes.Add(Pointer(PtrInt(AIndex)));
  end;

begin
  if (FMode <> vmArchive) or FBusy then
    Exit;
  FDragTops.Clear;
  FDragIndexes.Clear;
  if FDragSource = dsList then
  begin
    // dragging an unselected row drags just that row, like Explorer
    It := lvFiles.GetItemAt(FDragStart.X, FDragStart.Y);
    if (It <> nil) and not It.Selected then
    begin
      lvFiles.ClearSelection;
      It.Selected := True;
    end;
    for I := 0 to lvFiles.Items.Count - 1 do
      if lvFiles.Items[I].Selected then
      begin
        R := RowAt(lvFiles.Items[I]);
        if R.Folder <> nil then
          AddFolderTop(R.Folder)
        else if R.Index >= 0 then
          AddFileTop(R.Index);
      end;
  end
  else if (FDragSource = dsTree) and (FDragNode <> nil) then
  begin
    F := TVFolder(FDragNode.Data);
    if F.Parent = nil then
    begin
      // the archive root itself: drop all of its content
      for Sub in F.Folders do
        AddFolderTop(Sub);
      for I := 0 to High(F.Files) do
        AddFileTop(F.Files[I]);
    end
    else
      AddFolderTop(F);
  end;
  if FDragTops.Count = 0 then
    Exit;

  DevLogFmt(llInfo, 'Drag-out started: %d top item(s), %d archive entries', [FDragTops.Count, FDragIndexes.Count]);
  SetProgress(0, Format('Dragging %d item(s) - drop on Explorer or the Desktop to extract there',
    [FDragTops.Count]), True, True);
  FDraggingOut := True;
  try
    Res := StartFileDragOut(@RenderDragFiles, Rendered);
  finally
    FDraggingOut := False;
  end;
  case Res of
    droDropped:
      begin
        DevLog(llInfo, 'Drag-out dropped - the target copied the extracted files');
        SetProgress(1, Format('Extracted %d item(s) by drag & drop', [FDragTops.Count]), False, True);
        PlayFx(feDrag);
      end;
    droCancelled:
      begin
        DevLog(llInfo, 'Drag-out cancelled');
        SetProgress(0, 'Drag cancelled', False, True);
      end;
  else
    begin
      DevLog(llError, 'Drag-out failed (OLE not available or the extraction failed)');
      SetProgress(0, 'Drag & drop failed', False, True);
    end;
  end;
end;

function DragTempRoot: string;
begin
  Result := AppendPathDelim(GetTempDir(False)) + 'BGRAZip-drag' + PathDelim;
end;

function TfrmMain.RenderDragFiles(APaths: TStrings): Boolean;
var
  Job, P: string;
  Names: TStringList;
  I: Integer;
  Total: Int64;
  E: TArchiveEntry;
begin
  Result := False;
  Job := DragTempRoot + Format('%d-%d', [GetProcessID, GetTickCount64]) + PathDelim;
  if not ForceDirectoriesUTF8(Job) then
  begin
    DevLog(llError, 'Cannot create temp folder ' + Job);
    Exit;
  end;
  Names := TStringList.Create;
  try
    Total := 0;
    for I := 0 to FDragIndexes.Count - 1 do
    begin
      E := FArchive.Entry[PtrInt(FDragIndexes[I])];
      Names.Add(E.FileName);
      Inc(Total, E.UncompressedSize);
    end;
    DevLogFmt(llInfo, 'Drag-out: extracting %d entries (%s) to %s', [Names.Count, FormatSize(Total), Job]);
    if IsRar then
      Result := ExtractRar(Job, Names, Total, True)
    else
      Result := ExtractZip(Job, Names, Total, True);
  finally
    Names.Free;
  end;
  if not Result then
    Exit;
  for I := 0 to FDragTops.Count - 1 do
  begin
    P := Job + StringReplace(FDragTops[I], '/', PathDelim, [rfReplaceAll]);
    if FDragTops.Objects[I] <> nil then
      ForceDirectoriesUTF8(P);         // folders without explicit entries / empty folders
    if FileExistsUTF8(P) or DirectoryExistsUTF8(P) then
      APaths.Add(P)
    else
      DevLogFmt(llWarn, 'Drag-out: %s was not extracted (encrypted or unsupported?)', [FDragTops[I]]);
  end;
  Result := APaths.Count > 0;
end;

procedure TfrmMain.CleanupDragTemp(AAll: Boolean);
var
  SR: TSearchRec;
  Root, Mine: string;
  Age: Int64;
  K: Integer;
begin
  // Explorer may still be copying right after a drop, so only remove jobs from
  // earlier sessions (on start) or our own jobs older than two minutes (on exit).
  Root := DragTempRoot;
  if not DirectoryExistsUTF8(Root) then
    Exit;
  Mine := IntToStr(GetProcessID) + '-';
  if FindFirstUTF8(Root + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') or ((SR.Attr and faDirectory) = 0) then
        Continue;
      if Copy(SR.Name, 1, Length(Mine)) = Mine then
      begin
        if AAll then
          Continue;
        K := Pos('-', SR.Name);
        Age := Int64(GetTickCount64) - StrToInt64Def(Copy(SR.Name, K + 1, 30), 0);
        if Age < 120000 then
          Continue;
      end
      else if not AAll then
        Continue;
      if DeleteDirectory(Root + SR.Name, False) then
        DevLogFmt(llDebug, 'Removed drag temp folder %s', [SR.Name]);
    until FindNextUTF8(SR) <> 0;
  finally
    FindCloseUTF8(SR);
  end;
end;


procedure TfrmMain.miCopyNameClick(Sender: TObject);
var
  L: TStringList;
  I: Integer;
begin
  L := TStringList.Create;
  try
    for I := 0 to lvFiles.Items.Count - 1 do
      if lvFiles.Items[I].Selected then
        L.Add(lvFiles.Items[I].Caption);
    Clipboard.AsText := TrimRight(L.Text);
  finally
    L.Free;
  end;
end;

{ ---------- IPC commands (named pipe, see uIPC) ---------- }

function TfrmMain.HandleIPC(const ARequest: string): string;
var
  Req, Res, O: TJSONObject;
  Arr: TJSONArray;
  D: TJSONData;
  Cmd, S, P: string;
  Names, Bad, Locked: TStringList;
  I, N: Integer;
  Total: Int64;
  E: TArchiveEntry;
  Cancelled, OK: Boolean;
  Checker: TScriptRunner;
  FxE: TFxEvent;
  FxS: TFxStyle;

  procedure Fail(const AMsg: string);
  begin
    Res.Booleans['ok'] := False;
    Res.Strings['error'] := AMsg;
  end;

  procedure AddStatus(AObj: TJSONObject);
  const
    ModeNames: array[TViewMode] of string = ('empty', 'new-archive', 'archive');
  begin
    AObj.Add('mode', ModeNames[FMode]);
    AObj.Add('busy', FBusy);
    if FMode = vmArchive then
    begin
      AObj.Add('archive', FArchive.FileName);
      AObj.Add('format', FArchive.FormatName);
      AObj.Add('file_size', FArchive.FileSize);
      AObj.Add('entries', FArchive.Count);
      AObj.Add('files', FArchive.FileCount);
      AObj.Add('folders', FArchive.DirCount);
      AObj.Add('unpacked_size', FArchive.TotalUncompressed);
      AObj.Add('packed_size', FArchive.TotalCompressed);
      AObj.Add('saved_percent', Round(FArchive.OverallSavedPercent * 100) / 100);
      AObj.Add('encrypted_entries', FArchive.EncryptedCount);
      AObj.Add('encryption', FArchive.EncryptionSummary);
      if (FArchive is TRarArchiveInfo) and TRarArchiveInfo(FArchive).HeadersEncrypted then
        AObj.Add('headers_encrypted', True);
      AObj.Add('warnings', FArchive.Warnings.Count);
    end
    else if FMode = vmStaging then
    begin
      AObj.Add('staged_files', Length(FStaged));
      AObj.Add('staged_size', StagedTotal);
    end;
    if FCurFolder <> nil then
      AObj.Add('current_folder', FCurFolder.Path);
  end;

  procedure BringUp;
  begin
    if WindowState = wsMinimized then
      WindowState := wsNormal;
    Show;
    BringToFront;
    {$IFDEF WINDOWS}
    SetForegroundWindow(Handle);
    {$ENDIF}
  end;

begin
  Res := TJSONObject.Create;
  Req := nil;
  try
    try
      D := ParseJSON(ARequest);
      if not (D is TJSONObject) then
      begin
        D.Free;
        raise Exception.Create('request must be a JSON object');
      end;
      Req := TJSONObject(D);
      Cmd := LowerCase(Req.Get('cmd', ''));
      Res.Add('ok', True);
      Res.Add('cmd', Cmd);
      if Cmd <> 'ping' then
        DevLogFmt(llDebug, 'IPC <- %s', [Copy(ARequest, 1, 300)]);

      if Cmd = 'ping' then
      begin
        Res.Add('app', 'BGRA Zip');
        Res.Add('version', '1.2.0');
        Res.Add('pid', GetProcessID);
      end
      else if Cmd = 'status' then
        AddStatus(Res)
      else if Cmd = 'show' then
        BringUp
      else if Cmd = 'open' then
      begin
        S := Req.Get('path', '');
        if FBusy then
          Fail('busy: another operation is running')
        else if not FileExistsUTF8(S) then
          Fail('file not found: ' + S)
        else
        begin
          OpenArchive(S);
          if Req.Get('activate', True) then
            BringUp;
          if (FMode <> vmArchive) or not SameFileName(FArchive.FileName, S) then
            Fail('could not open ' + S + ' (see the log)')
          else
            AddStatus(Res);
        end;
      end
      else if Cmd = 'add' then
      begin
        if FBusy then
          Fail('busy')
        else
        begin
          if FMode = vmArchive then
            NewArchive;
          Arr := Req.Get('files', TJSONArray(nil));
          if Arr <> nil then
            for I := 0 to Arr.Count - 1 do
              if DirectoryExistsUTF8(Arr.Strings[I]) then
                AddFolder(Arr.Strings[I])
              else if FileExistsUTF8(Arr.Strings[I]) then
                AddFile(Arr.Strings[I], ExtractFileName(Arr.Strings[I]));
          RefreshList;
          if Req.Get('activate', True) then
            BringUp;
          AddStatus(Res);
        end;
      end
      else if Cmd = 'new' then
      begin
        if FBusy then Fail('busy') else NewArchive;
      end
      else if Cmd = 'list' then
      begin
        if FMode <> vmArchive then
          Fail('no archive open')
        else
        begin
          N := Req.Get('limit', 5000);
          Arr := TJSONArray.Create;
          for I := 0 to Min(FArchive.Count, N) - 1 do
          begin
            E := FArchive.Entry[I];
            O := TJSONObject.Create;
            O.Add('name', E.FileName);
            O.Add('dir', E.IsDirectory);
            O.Add('size', E.UncompressedSize);
            O.Add('packed', E.CompressedSize);
            O.Add('method', E.MethodText);
            O.Add('crc32', IntToHex(E.CRC32, 8));
            O.Add('modified', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', E.DateTime));
            O.Add('encrypted', E.IsEncrypted);
            if E.IsEncrypted then
              O.Add('encryption', E.EncryptionText);
            Arr.Add(O);
          end;
          Res.Add('total', FArchive.Count);
          Res.Add('entries', Arr);
        end;
      end
      else if Cmd = 'extract' then
      begin
        S := Req.Get('destination', '');
        FPassword := Req.Get('password', FPassword);
        if FMode <> vmArchive then
          Fail('no archive open')
        else if FBusy then
          Fail('busy')
        else if (S = '') or not ForceDirectoriesUTF8(S) then
          Fail('invalid destination: ' + S)
        else
        begin
          Names := TStringList.Create;
          try
            Total := 0;
            Arr := Req.Get('entries', TJSONArray(nil));
            if Arr <> nil then
              for I := 0 to Arr.Count - 1 do
                Names.Add(Arr.Strings[I]);
            if Names.Count = 0 then
              Total := FArchive.TotalUncompressed
            else
              for I := 0 to FArchive.Count - 1 do
                if Names.IndexOf(FArchive.Entry[I].FileName) >= 0 then
                  Inc(Total, FArchive.Entry[I].UncompressedSize);
            if IsRar then
              OK := ExtractRar(S, Names, Total, True)
            else
              OK := ExtractZip(S, Names, Total, True);
            if not OK then
              Fail('extraction failed or was cancelled (see the log)')
            else
              Res.Add('destination', S);
          finally
            Names.Free;
          end;
        end;
      end
      else if Cmd = 'test' then
      begin
        if FMode <> vmArchive then
          Fail('no archive open')
        else if FBusy then
          Fail('busy')
        else
        begin
          Bad := TStringList.Create;
          Locked := TStringList.Create;
          FBusy := True;
          UpdateUI;
          try
            FOpIndex := 0;
            FOpDone := 0;
            FOpVerb := 'Testing';
            FTestChecked := -1;
            FPassword := Req.Get('password', FPassword);
            if (RarPureExe <> '') and ArchiveLocked and (FPassword <> '') then
              TestPure(Bad, Locked, Cancelled)
            else if IsRar then
              TestRar(Bad, Locked, Cancelled)
            else
              TestZip(Bad, Locked, Cancelled);
          finally
            FBusy := False;
            UpdateUI;
          end;
          Arr := TJSONArray.Create;
          for I := 0 to Bad.Count - 1 do
            Arr.Add(Bad[I]);
          Res.Add('cancelled', Cancelled);
          // nothing unchecked may count as passed
          Res.Add('passed', (Bad.Count = 0) and (Locked.Count = 0) and not Cancelled);
          Res.Add('problems', Arr);
          Arr := TJSONArray.Create;
          for I := 0 to Locked.Count - 1 do
            Arr.Add(Locked[I]);
          Res.Add('needs_password', Arr);
          S := TestSummary(Bad, Locked, OK);
          SetProgress(IfThen(OK, 1, 0), S + ' (requested over IPC)', False, True);
          if OK then
            PlayFx(feTestOk)
          else if Bad.Count > 0 then
            PlayFx(feTestFail);
          Locked.Free;
          Bad.Free;
        end;
      end
      else if Cmd = 'dev' then
      begin
        ShowDevInfo;
        DevForm.ShowTab(Req.Get('tab', 0));
      end
      else if Cmd = 'log' then
      begin
        N := Req.Get('lines', 100);
        Arr := TJSONArray.Create;
        for I := Max(0, Log.Lines.Count - N) to Log.Lines.Count - 1 do
          Arr.Add(Log.Lines[I]);
        Res.Add('lines', Arr);
      end
      else if Cmd = 'quit' then
      begin
        if FBusy then
          Fail('busy')
        else
          Application.QueueAsyncCall(@AsyncClose, 0);
      end
      else if Cmd = 'effect' then
      begin
        // "event" uses that event's settings, "style" plays one directly, "force" previews while off
        S := Req.Get('event', '');
        P := Req.Get('style', '');
        OK := False;
        if P <> '' then
        begin
          if not FxStyleByName(P, FxS) then
            Fail('unknown style "' + P + '"')
          else
            OK := Fx.PlayStyle(FxS, Req.Get('x', ClientWidth div 2), Req.Get('y', ClientHeight div 2));
        end
        else if not FxEventByName(S, FxE) then
          Fail('unknown event "' + S + '"')
        else
          OK := Fx.Play(FxE, Req.Get('x', ClientWidth div 2), Req.Get('y', ClientHeight div 2), Req.Get('force', False));
        if Res.Booleans['ok'] then
        begin
          Res.Add('played', OK);
          if not OK then
            Res.Add('why', Fx.WhyNot);
        end;
      end
      else if Cmd = 'effect_status' then
      begin
        Res.Add('enabled', Fx.Enabled);
        Res.Add('blocked_by', Fx.WhyNot);
        Res.Add('intensity', Fx.Intensity);
        Res.Add('playing', Fx.ActiveCount);
        Res.Add('stats', Fx.Stats);
        Res.Add('overlay_window', Int64(Fx.WindowHandle));
        Arr := TJSONArray.Create;
        for FxE := Low(TFxEvent) to High(TFxEvent) do
          Arr.Add(TJSONObject.Create(['event', FxEventNames[FxE], 'enabled', Fx.Options[FxE].Enabled,
            'style', FxStyleNames[Fx.Options[FxE].Style]]));
        Res.Add('events', Arr);
      end
      else if Cmd = 'effect_set' then
      begin
        Fx.Enabled := Req.Get('enabled', Fx.Enabled);
        Fx.Intensity := EnsureRange(Req.Get('intensity', Fx.Intensity), 25, 200);
        miViewEffects.Checked := Fx.Enabled;
        Fx.Save;
      end
      else if Cmd = 'effect_options' then
        // modal, so it must not run inside this request
        Application.QueueAsyncCall(@AsyncWindow, 0)
      else if Cmd = 'open_window' then
      begin
        S := LowerCase(Req.Get('name', ''));
        if S = 'effects' then
          Application.QueueAsyncCall(@AsyncWindow, 0)
        else if S = 'api' then
          Application.QueueAsyncCall(@AsyncWindow, 1)
        else if S = 'mcp' then
          Application.QueueAsyncCall(@AsyncWindow, 2)
        else if S = 'script' then
          ShowScriptEditor(Req.Get('file', ''))
        else
          Fail('unknown window "' + S + '". Windows: effects api mcp script');
      end
      else if Cmd = 'effect_snapshot' then
      begin
        S := Req.Get('path', '');
        if S = '' then
          Fail('"path" is required')
        else
          Fx.SaveSnapshot(S);
      end
      else if Cmd = 'script_run' then
      begin
        S := Req.Get('source', '');
        P := Req.Get('file', '');
        if (S = '') = (P = '') then
          Fail('pass either "source" or "file"')
        else if (P <> '') and not FileExistsUTF8(P) then
          Fail('file not found: ' + P)
        else if not ScriptSlotFree then
          Fail('busy: a script is running')
        else
        begin
          if P <> '' then
          begin
            Names := TStringList.Create;
            try
              Names.LoadFromFile(P);
              S := Names.Text;
            finally
              Names.Free;
            end;
            if Copy(S, 1, 3) = #$EF#$BB#$BF then
              Delete(S, 1, 3);
          end;
          Names := TStringList.Create;
          try
            Arr := Req.Get('args', TJSONArray(nil));
            if Arr <> nil then
              for I := 0 to Arr.Count - 1 do
                Names.Add(Arr.Strings[I]);
            CurrentScriptJob := TScriptJob.Create(S, P, Names, False);
          finally
            Names.Free;
          end;
          CurrentScriptJob.LocalHandler := @Self.HandleIPC;
          CurrentScriptJob.Go;
          Res.Add('state', 'running');
        end;
      end
      else if Cmd = 'script_status' then
      begin
        Result := ScriptJobStatusJSON(CurrentScriptJob, Req.Get('from', 0));
        Exit;
      end
      else if Cmd = 'script_stop' then
      begin
        if (CurrentScriptJob = nil) or CurrentScriptJob.Finished then
          Fail('no script is running')
        else
          CurrentScriptJob.Runner.Stop;
      end
      else if Cmd = 'script_check' then
      begin
        Checker := TScriptRunner.Create;
        try
          Checker.Source := Req.Get('source', '');
          Res.Add('compiles', Checker.Check);
          Res.Add('error', Checker.ErrorText);
          Res.Add('error_row', Checker.ErrorRow);
          Res.Add('error_col', Checker.ErrorCol);
          Arr := TJSONArray.Create;
          for I := 0 to Checker.Messages.Count - 1 do
            Arr.Add(Checker.Messages[I]);
          Res.Add('messages', Arr);
        finally
          Checker.Free;
        end;
      end
      else if Cmd = 'script_functions' then
        Res.Add('functions', ParseJSON(ScriptFunctionsJSON))
      else
        Fail('unknown command "' + Cmd + '". Commands: ping status show open add new list extract test dev log quit ' +
          'script_run script_status script_stop script_check script_functions effect effect_status effect_set effect_options effect_snapshot open_window');
    except
      on Ex: Exception do
        Fail(Ex.Message);
    end;
    Result := Res.AsJSON;
  finally
    Res.Free;
    Req.Free;
  end;
end;

procedure TfrmMain.AsyncClose(Data: PtrInt);
begin
  Close;
end;

{ ---------- menu icons (BGRABitmap vector icons) ---------- }

procedure TfrmMain.SetupMenuIcons;
var
  IL: TImageList;

  function Img(AIcon: TToolIcon): Integer;
  begin
    Result := IL.Count;
    AddIconToImageList(IL, AIcon);
  end;

  procedure Use(AItem: TMenuItem; AIndex: Integer);
  begin
    AItem.ImageIndex := AIndex;
  end;

var
  INew, IOpen, ICreate, IAddF, IAddD, IRemove, IExtract, IExtractSel, ITest, IDev, IZip, IFolder: Integer;
begin
  IL := TImageList.Create(Self);
  IL.Width := Scale96ToForm(16);
  IL.Height := Scale96ToForm(16);
  INew := Img(tiNew);
  IOpen := Img(tiOpen);
  ICreate := Img(tiCreate);
  IAddF := Img(tiAddFile);
  IAddD := Img(tiAddFolder);
  IRemove := Img(tiRemove);
  IExtract := Img(tiExtract);
  IExtractSel := Img(tiExtractSel);
  ITest := Img(tiTest);
  IDev := Img(tiDev);
  IZip := Img(tiZip);
  IFolder := Img(tiFolder);
  mnuMain.Images := IL;
  pmList.Images := IL;

  Use(miFileNew, INew);
  Use(miFileOpen, IOpen);
  Use(miFileRecent, IOpen);
  Use(miFileCreate, ICreate);
  Use(miFileShowInExplorer, IFolder);
  Use(miFileProperties, IZip);
  Use(miEditAddFiles, IAddF);
  Use(miEditAddFolder, IAddD);
  Use(miEditRemove, IRemove);
  Use(miViewTree, IFolder);
  Use(miActExtractAll, IExtract);
  Use(miActExtractSel, IExtractSel);
  Use(miActExtractHere, IExtract);
  Use(miActExtractSub, IAddD);
  Use(miActTest, ITest);
  Use(miActLevel, IZip);
  Use(miDefaultOpen, IZip);
  Use(miToolsRarTools, IZip);
  Use(miDevInfo, IDev);
  Use(miDevTabs, IDev);
  Use(miDevReparse, ITest);
  Use(miDevOpenTemp, IFolder);
  Use(miDevOpenConfig, IFolder);
  Use(miDevOpenAppDir, IFolder);
  Use(miHelpAbout, IZip);
  Use(miShowDev, IDev);
  Use(miExtractSel, IExtractSel);
  Use(miRemove, IRemove);
end;

{ ---------- settings (recent files, view, level) ---------- }

function ConfigFileName: string;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, 9) = '--config=' then
      Exit(Copy(ParamStr(I), 10, MaxInt));
  Result := AppendPathDelim(GetAppConfigDirUTF8(False, True)) + 'bgrazip.ini';
end;

procedure TfrmMain.LoadSettings;
var
  Ini: TIniFile;
  I: Integer;
  S: string;
begin
  try
    Ini := TIniFile.Create(ConfigFileName);
    try
      FRecent.Clear;
      for I := 0 to 9 do
      begin
        S := Ini.ReadString('Recent', 'File' + IntToStr(I), '');
        if S <> '' then
          FRecent.Add(S);
      end;
      miViewTree.Checked := Ini.ReadBool('View', 'Tree', True);
      miViewToolbar.Checked := Ini.ReadBool('View', 'Toolbar', True);
      miViewHeader.Checked := Ini.ReadBool('View', 'Header', True);
      miViewStatus.Checked := Ini.ReadBool('View', 'StatusBar', True);
      tvFolders.Width := Ini.ReadInteger('View', 'TreeWidth', tvFolders.Width);
      cbLevel.ItemIndex := EnsureRange(Ini.ReadInteger('Compression', 'Level', 2), 0, 3);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      DevLog(llWarn, 'Cannot read settings: ' + E.Message);
  end;
  ApplyViewToggles;
  DevLogFmt(llDebug, 'Settings loaded from %s (%d recent files)', [ConfigFileName, FRecent.Count]);
end;

procedure TfrmMain.SaveSettings;
var
  Ini: TIniFile;
  I: Integer;
begin
  try
    Ini := TIniFile.Create(ConfigFileName);
    try
      Ini.EraseSection('Recent');
      for I := 0 to FRecent.Count - 1 do
        Ini.WriteString('Recent', 'File' + IntToStr(I), FRecent[I]);
      Ini.WriteBool('View', 'Tree', miViewTree.Checked);
      Ini.WriteBool('View', 'Toolbar', miViewToolbar.Checked);
      Ini.WriteBool('View', 'Header', miViewHeader.Checked);
      Ini.WriteBool('View', 'StatusBar', miViewStatus.Checked);
      Ini.WriteInteger('View', 'TreeWidth', tvFolders.Width);
      Ini.WriteInteger('Compression', 'Level', cbLevel.ItemIndex);
    finally
      Ini.Free;
    end;
  except
    on E: Exception do
      DevLog(llWarn, 'Cannot save settings: ' + E.Message);
  end;
end;

procedure TfrmMain.AddRecent(const AFileName: string);
var
  I: Integer;
begin
  for I := FRecent.Count - 1 downto 0 do
    if SameFileName(FRecent[I], AFileName) then
      FRecent.Delete(I);
  FRecent.Insert(0, AFileName);
  while FRecent.Count > 10 do
    FRecent.Delete(FRecent.Count - 1);
end;

procedure TfrmMain.BuildRecentMenu;
var
  I: Integer;
  M: TMenuItem;
begin
  miFileRecent.Clear;
  for I := 0 to FRecent.Count - 1 do
  begin
    M := TMenuItem.Create(miFileRecent);
    M.Caption := Format('&%d  %s', [(I + 1) mod 10, FRecent[I]]);
    M.Tag := I;
    M.Enabled := FileExistsUTF8(FRecent[I]);
    M.OnClick := @miRecentClick;
    miFileRecent.Add(M);
  end;
  if FRecent.Count > 0 then
  begin
    miFileRecent.AddSeparator;
    M := TMenuItem.Create(miFileRecent);
    M.Caption := '&Clear list';
    M.OnClick := @miRecentClearClick;
    miFileRecent.Add(M);
  end;
  miFileRecent.Enabled := FRecent.Count > 0;
end;

procedure TfrmMain.miRecentClick(Sender: TObject);
var
  I: Integer;
begin
  I := TMenuItem(Sender).Tag;
  if (I >= 0) and (I < FRecent.Count) and not FBusy then
    OpenArchive(FRecent[I]);
end;

procedure TfrmMain.miRecentClearClick(Sender: TObject);
begin
  FRecent.Clear;
  BuildRecentMenu;
end;

procedure TfrmMain.ApplyViewToggles;
begin
  tvFolders.Visible := miViewTree.Checked;
  splMain.Visible := miViewTree.Checked;
  if splMain.Visible then
    splMain.Left := tvFolders.Left + tvFolders.Width + 1;
  pnlTools.Visible := miViewToolbar.Checked;
  pbHeader.Visible := miViewHeader.Checked;
  if pbHeader.Visible then
    pbHeader.Top := 0;
  sbStatus.Visible := miViewStatus.Checked;
  if sbStatus.Visible then
    sbStatus.Top := ClientHeight;
end;

{ Enables / checks every menu item for the current state; runs when a
  top-level menu opens, so the menu never offers a command that cannot run. }
procedure TfrmMain.UpdateMenus;
var
  Idle, Arc, Stg, HasSel, Sub: Boolean;
  I: Integer;
begin
  Idle := not FBusy;
  Arc := (FMode = vmArchive) and (FArchive <> nil);
  Stg := FMode = vmStaging;
  HasSel := lvFiles.SelCount > 0;
  Sub := (FCurFolder <> nil) and (FCurFolder.Parent <> nil);

  miFileNew.Enabled := Idle and (FMode <> vmEmpty);
  miFileOpen.Enabled := Idle;
  miFileClose.Enabled := Idle and Arc;
  miFileCreate.Enabled := Idle and Stg;
  miFileShowInExplorer.Enabled := Arc;
  miFileProperties.Enabled := Arc;
  BuildRecentMenu;
  miFileRecent.Enabled := Idle and (FRecent.Count > 0);

  miEditAddFiles.Enabled := Idle;
  miEditAddFolder.Enabled := Idle;
  miEditRemove.Enabled := Idle and Stg and HasSel;
  miEditSelectAll.Enabled := lvFiles.Items.Count > 0;
  miEditInvert.Enabled := lvFiles.Items.Count > 0;
  miEditDeselect.Enabled := HasSel;
  miEditCopyName.Enabled := HasSel;
  miEditCopyPath.Enabled := HasSel;

  miViewUp.Enabled := Sub;
  miViewRoot.Enabled := Sub;
  miViewRefresh.Enabled := Idle and Arc;
  for I := 0 to miViewSort.Count - 1 do
    if miViewSort.Items[I].RadioItem then
      miViewSort.Items[I].Checked := miViewSort.Items[I].Tag = Max(FSortColumn, 0);
  miSortDesc.Checked := FSortDesc;

  miActExtractAll.Enabled := Idle and Arc;
  miActExtractSel.Enabled := Idle and Arc and HasSel;
  miActExtractHere.Enabled := Idle and Arc;
  miActExtractSub.Enabled := Idle and Arc;
  if Arc then
    miActExtractSub.Caption := Format('Extract to "%s\"', [ChangeFileExt(ExtractFileName(FArchive.FileName), '')])
  else
    miActExtractSub.Caption := 'Extract to folder';
  miActTest.Enabled := Idle and Arc;
  for I := 0 to miActLevel.Count - 1 do
    miActLevel.Items[I].Checked := miActLevel.Items[I].Tag = cbLevel.ItemIndex;
  miActLevel.Enabled := Idle;

  miDevReparse.Enabled := Idle and Arc;
  miDevOpenTemp.Enabled := DirectoryExistsUTF8(DragTempRoot);
end;

procedure TfrmMain.MenuPopup(Sender: TObject);
begin
  UpdateMenus;
end;

{ ---------- main menu ---------- }

procedure TfrmMain.miFileNewClick(Sender: TObject);
begin
  ToolClick(nil, TB_NEW);
end;

procedure TfrmMain.miFileCreateClick(Sender: TObject);
begin
  ToolClick(nil, TB_CREATE);
end;

procedure TfrmMain.miFileShowInExplorerClick(Sender: TObject);
begin
  if FArchive = nil then
    Exit;
  {$IFDEF WINDOWS}
  ShellExecuteW(0, 'open', 'explorer.exe', PWideChar(UnicodeString('/select,"' + FArchive.FileName + '"')),
    nil, SW_SHOWNORMAL);
  {$ELSE}
  OpenDocument(ExtractFilePath(FArchive.FileName));
  {$ENDIF}
end;

procedure TfrmMain.miFilePropertiesClick(Sender: TObject);
begin
  ShowDevInfo;
  DevForm.ShowTab(0);
end;

procedure TfrmMain.miEditAddFilesClick(Sender: TObject);
begin
  ToolClick(nil, TB_ADDFILES);
end;

procedure TfrmMain.miEditAddFolderClick(Sender: TObject);
begin
  ToolClick(nil, TB_ADDFOLDER);
end;

procedure TfrmMain.miEditSelectAllClick(Sender: TObject);
begin
  lvFiles.SelectAll;
  lvFiles.SetFocus;
end;

procedure TfrmMain.miEditInvertClick(Sender: TObject);
var
  I: Integer;
begin
  lvFiles.Items.BeginUpdate;
  try
    for I := 0 to lvFiles.Items.Count - 1 do
      lvFiles.Items[I].Selected := not lvFiles.Items[I].Selected;
  finally
    lvFiles.Items.EndUpdate;
  end;
  UpdateUI;
end;

procedure TfrmMain.miEditDeselectClick(Sender: TObject);
begin
  lvFiles.ClearSelection;
  UpdateUI;
end;

procedure TfrmMain.miEditCopyPathClick(Sender: TObject);
var
  L: TStringList;
  I: Integer;
  R: TRowInfo;
begin
  L := TStringList.Create;
  try
    for I := 0 to lvFiles.Items.Count - 1 do
      if lvFiles.Items[I].Selected then
      begin
        R := RowAt(lvFiles.Items[I]);
        if R.Folder <> nil then
          L.Add(R.Folder.Path + '/')
        else if R.Index >= 0 then
          L.Add(ItemPath(R.Index));
      end;
    Clipboard.AsText := TrimRight(L.Text);
  finally
    L.Free;
  end;
end;

procedure TfrmMain.miViewToggleClick(Sender: TObject);
begin
  ApplyViewToggles;
end;

procedure TfrmMain.miViewUpClick(Sender: TObject);
begin
  GoUp;
end;

procedure TfrmMain.miViewRootClick(Sender: TObject);
begin
  ShowFolder(FTree.Root);
end;

procedure TfrmMain.miViewExpandClick(Sender: TObject);
begin
  tvFolders.FullExpand;
end;

procedure TfrmMain.miViewCollapseClick(Sender: TObject);
begin
  tvFolders.FullCollapse;
  if tvFolders.Items.Count > 0 then
    tvFolders.Items[0].Expand(False);
end;

procedure TfrmMain.miSortClick(Sender: TObject);
begin
  FSortColumn := TMenuItem(Sender).Tag;
  ShowFolder(FCurFolder);
end;

procedure TfrmMain.miSortDescClick(Sender: TObject);
begin
  FSortDesc := not FSortDesc;
  if FSortColumn < 0 then
    FSortColumn := 0;
  ShowFolder(FCurFolder);
end;

procedure TfrmMain.miViewRefreshClick(Sender: TObject);
begin
  if (FArchive <> nil) and not FBusy then
  begin
    DevLog(llInfo, 'Re-reading archive structure');
    OpenArchive(FArchive.FileName);
  end;
end;

procedure TfrmMain.miActExtractHereClick(Sender: TObject);
begin
  if (FArchive <> nil) and not FBusy then
    ExtractTo(False, ExtractFileDir(FArchive.FileName));
end;

procedure TfrmMain.miActExtractSubClick(Sender: TObject);
begin
  if (FArchive <> nil) and not FBusy then
    ExtractTo(False, ChangeFileExt(FArchive.FileName, ''));
end;

procedure TfrmMain.miActTestClick(Sender: TObject);
begin
  ToolClick(nil, TB_TEST);
end;

procedure TfrmMain.miLevelClick(Sender: TObject);
begin
  cbLevel.ItemIndex := TMenuItem(Sender).Tag;
  pbHeader.Invalidate;
end;

procedure TfrmMain.miToolsRarToolsClick(Sender: TObject);
var
  T: TRarTools;
  Tool: TRarTool;
  S: string;
  I: Integer;
begin
  T := FindRarTools;
  S := '';
  for I := 0 to High(T) do
    S := S + Format('%s'#13#10'   %s'#13#10'   %s'#13#10#13#10, [RarToolNames[T[I].Kind], T[I].Exe, T[I].Version]);
  if S = '' then
    S := 'No RAR tool found.' + LineEnding + LineEnding;
  if FindRarExtractor(Tool) then
    S := S + 'Extract / test uses: ' + RarToolNames[Tool.Kind] + LineEnding
  else
    S := S + 'Extract / test: not available' + LineEnding;
  if FindRarCreator(Tool) then
    S := S + 'Create .rar uses: ' + RarToolNames[Tool.Kind]
  else
    S := S + 'Create .rar: not available (install WinRAR for rar.exe)';
  MessageDlg('RAR backends', S, mtInformation, [mbOK], 0);
end;

procedure TfrmMain.miToolsCleanTempClick(Sender: TObject);
begin
  if MessageDlg('Delete all temporary files left by drag && drop extraction?' + LineEnding + DragTempRoot +
    LineEnding + LineEnding + 'Do this only when no drop is still being copied by Explorer.',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  if DeleteDirectory(DragTempRoot, False) then
    DevLog(llInfo, 'Drag & drop temp folder deleted')
  else
    DevLog(llWarn, 'Drag & drop temp folder could not be fully deleted (files in use?)');
end;

{ ---------- Developer menu ---------- }

procedure TfrmMain.miDevInfoClick(Sender: TObject);
begin
  ShowDevInfo;
end;

procedure TfrmMain.miDevTabClick(Sender: TObject);
begin
  ShowDevInfo;
  DevForm.ShowTab(TMenuItem(Sender).Tag);
end;

procedure TfrmMain.miDevCopyReportClick(Sender: TObject);
begin
  DevForm.SetArchive(FArchive);
  DevForm.btnCopyReportClick(nil);
  SetProgress(FProgress, 'Developer report copied to the clipboard', False, True);
end;

procedure TfrmMain.miDevSaveReportClick(Sender: TObject);
begin
  DevForm.SetArchive(FArchive);
  DevForm.btnSaveReportClick(nil);
end;

procedure TfrmMain.miDevSaveLogClick(Sender: TObject);
begin
  DevForm.btnLogSaveClick(nil);
end;

procedure TfrmMain.miDevClearLogClick(Sender: TObject);
begin
  DevForm.btnLogClearClick(nil);
  DevLog(llInfo, 'Log cleared');
end;

procedure TfrmMain.miDevRescanToolsClick(Sender: TObject);
var
  T: TRarTools;
begin
  T := FindRarTools(True);
  DevLogFmt(llInfo, 'RAR tools re-detected: %d found', [Length(T)]);
  miToolsRarToolsClick(nil);
end;

procedure TfrmMain.miDevOpenTempClick(Sender: TObject);
begin
  OpenDocument(DragTempRoot);
end;

procedure TfrmMain.miDevOpenConfigClick(Sender: TObject);
begin
  ForceDirectoriesUTF8(ExtractFileDir(ConfigFileName));
  OpenDocument(ExtractFileDir(ConfigFileName));
end;

procedure TfrmMain.miDevOpenAppDirClick(Sender: TObject);
begin
  OpenDocument(ExtractFileDir(ParamStr(0)));
end;

procedure TfrmMain.miDevCmdLineClick(Sender: TObject);
begin
  MessageDlg('Command-line usage',
    'BGRAZip.exe [archive.zip | archive.rar] [--dev[=tab]]' + LineEnding +
    'BGRAZip.exe file1 file2 ...   (starts a new archive with these files)' + LineEnding + LineEnding +
    '--dev        open the Developer window at start' + LineEnding +
    '--dev=N      ... on tab N: 0 Overview, 1 Entries, 2 Hex, 3 Chart, 4 Log, 5 Environment' + LineEnding +
    '--api        start the local HTTP API for this run (see Developer > HTTP API)' + LineEnding +
    '--script F   open script F in the script editor' + LineEnding +
    '--config=F   use settings file F instead of the one in your profile' + LineEnding +
    'bzscript.exe F [args]   run a script from the console, without a window' + LineEnding +
    LineEnding + 'Settings file: ' + ConfigFileName + LineEnding +
    'Drag & drop temp: ' + DragTempRoot,
    mtInformation, [mbOK], 0);
end;

procedure TfrmMain.miDevMCPClick(Sender: TObject);
begin
  ShowMcpDialog(IPCPipeName, (FIPC <> nil) and FIPC.Active);
end;

procedure TfrmMain.miDevApiClick(Sender: TObject);
begin
  ShowApiDialog;
end;

{ ---------- effects ---------- }

{ Each event starts where the eye already is. }
procedure TfrmMain.PlayFx(AEvent: TFxEvent);
var
  X, Y: Integer;
begin
  if Fx = nil then
    Exit;
  X := ClientWidth div 2;
  Y := ClientHeight div 2;
  case AEvent of
    feStart, feOpen:
      if pbHeader.Visible then
      begin
        X := 46;
        Y := pbHeader.Top + pbHeader.Height div 2;
      end;
    feExtract, feTestFail, feError, feScriptFail, feProgress, feCreate:
      begin
        Y := pbProgress.Top + pbProgress.Height div 2;
      end;
    feAdd, feRemove, feDrag:
      if lvFiles.Visible then
      begin
        X := lvFiles.ClientOrigin.X - ClientOrigin.X + lvFiles.Width div 2;
        Y := lvFiles.ClientOrigin.Y - ClientOrigin.Y + lvFiles.Height div 2;
      end;
  end;
  Fx.Play(AEvent, X, Y);
end;

procedure TfrmMain.AsyncWindow(Data: PtrInt);
begin
  case Data of
    0: miViewEffectOptionsClick(nil);
    1: miDevApiClick(nil);
    2: miDevMCPClick(nil);
  end;
end;

procedure TfrmMain.PreviewFx(AEvent: Integer);
begin
  Fx.Play(TFxEvent(AEvent), ClientWidth div 2, ClientHeight div 2, True);
end;

procedure TfrmMain.miViewEffectsClick(Sender: TObject);
begin
  Fx.Enabled := miViewEffects.Checked;
  Fx.Save;
end;

procedure TfrmMain.miViewEffectOptionsClick(Sender: TObject);
begin
  ShowEffectsDialog(@PreviewFx);
  miViewEffects.Checked := Fx.Enabled;
end;

{ A script ends on its own thread, so the end is noticed here. }
procedure TfrmMain.ScriptWatch(Sender: TObject);
var
  J: TScriptJob;
begin
  // the window is not on screen yet in OnShow, so the welcome waits for this first tick
  if not FStartFxDone then
  begin
    FStartFxDone := True;
    PlayFx(feStart);
  end;
  J := CurrentScriptJob;
  if (J = nil) or (J.Id = FScriptWatchId) or not J.Finished then
    Exit;
  FScriptWatchId := J.Id;
  if J.Runner.ErrorText <> '' then
    PlayFx(feScriptFail)
  else if not J.Runner.Stopped or (J.Runner.ExitCode <> 0) then
    PlayFx(feScriptOk);
end;

{ ---------- Script menu ---------- }

procedure TfrmMain.miScriptEditorClick(Sender: TObject);
begin
  ShowScriptEditor;
end;

procedure TfrmMain.miScriptRunFileClick(Sender: TObject);
var
  D: TOpenDialog;
begin
  D := TOpenDialog.Create(nil);
  try
    D.Filter := 'BGRA Zip scripts (*.bzs)|*.bzs|All files (*.*)|*.*';
    if D.Execute then
      ShowScriptEditor(D.FileName, True);
  finally
    D.Free;
  end;
end;

procedure TfrmMain.miScriptStopClick(Sender: TObject);
begin
  if CurrentScriptJob <> nil then
    CurrentScriptJob.Runner.Stop;
end;

procedure TfrmMain.miScriptExamplesClick(Sender: TObject);
begin
  if ScriptExamplesDir <> '' then
    OpenDocument(ScriptExamplesDir);
end;

{ ---------- Help menu ---------- }

procedure TfrmMain.miHelpKeysClick(Sender: TObject);
begin
  MessageDlg('Keyboard shortcuts',
    'Ctrl+N'#9'New archive' + LineEnding +
    'Ctrl+O'#9'Open archive' + LineEnding +
    'Ctrl+W'#9'Close archive' + LineEnding +
    'Ctrl+S'#9'Create archive (ZIP / RAR)' + LineEnding +
    'Alt+Enter'#9'Archive properties' + LineEnding +
    'Ins / Del'#9'Add files / remove from list' + LineEnding +
    'Ctrl+A'#9'Select all' + LineEnding +
    'Ctrl+I'#9'Invert selection' + LineEnding +
    'Ctrl+C'#9'Copy name' + LineEnding +
    'Ctrl+Shift+C'#9'Copy path inside archive' + LineEnding +
    'Enter'#9'Open folder' + LineEnding +
    'Backspace'#9'Go up' + LineEnding +
    'Ctrl+Home'#9'Go to root' + LineEnding +
    'F5'#9'Refresh (re-read archive)' + LineEnding +
    'Ctrl+E'#9'Extract all' + LineEnding +
    'Ctrl+Shift+E'#9'Extract here' + LineEnding +
    'Ctrl+T'#9'Test archive' + LineEnding +
    'Esc'#9'Cancel running operation / drag' + LineEnding +
    'F12'#9'Developer window' + LineEnding +
    'Ctrl+1..6'#9'Developer window tab' + LineEnding +
    'Ctrl+Shift+D'#9'Copy developer report' + LineEnding +
    'Ctrl+Shift+R'#9'Re-parse archive structure' + LineEnding +
    'F1'#9'This list' + LineEnding + LineEnding +
    'Drag files or folders from the list or the tree to Explorer to extract them there.',
    mtInformation, [mbOK], 0);
end;

procedure TfrmMain.miHelpAboutClick(Sender: TObject);
begin
  MessageDlg('About BGRA Zip',
    'BGRA Zip 1.0' + LineEnding +
    'ZIP / RAR archiver built with Lazarus and BGRABitmap' + LineEnding + LineEnding +
    'Free Pascal ' + {$I %FPCVERSION%} + '  (' + {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%} + ')' + LineEnding +
    'Lazarus LCL ' + lcl_version + LineEnding +
    'BGRABitmap ' + BGRABitmapVersionStr + LineEnding +
    'Built ' + {$I %DATE%} + ' ' + {$I %TIME%} + LineEnding + LineEnding +
    'ZIP: FPC paszlib (TZipper / TUnZipper) + own structure parser' + LineEnding +
    'RAR: own RAR4 / RAR5 header parser + external rar / unrar / 7-Zip / tar for data',
    mtInformation, [mbOK], 0);
end;

procedure TfrmMain.miFileOpenClick(Sender: TObject);
begin
  ToolClick(nil, TB_OPEN);
end;

procedure TfrmMain.miFileExtractAllClick(Sender: TObject);
begin
  ToolClick(nil, TB_EXTRACT);
end;

procedure TfrmMain.miFileExitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.miDefaultOpenClick(Sender: TObject);

  procedure Mark(AItem: TMenuItem; const AExt, ACaption: string);
  begin
    AItem.Checked := IsDefaultFor(AExt);
    if AItem.Checked then
      AItem.Caption := ACaption + '  (current default)'
    else if IsRegisteredFor(AExt) then
      AItem.Caption := ACaption + '  (registered, not default)'
    else
      AItem.Caption := ACaption;
  end;

begin
  // refresh the check marks every time the submenu opens
  Mark(miDefaultZip, '.zip', 'Default &ZIP');
  Mark(miDefaultRar, '.rar', 'Default &RAR');
  miDefaultRemove.Enabled := IsRegisteredFor('.zip') or IsRegisteredFor('.rar');
end;

procedure TfrmMain.miDefaultZipClick(Sender: TObject);
begin
  SetDefaultOpen('.zip', 'ZIP archive (BGRA Zip)');
end;

procedure TfrmMain.miDefaultRarClick(Sender: TObject);
begin
  SetDefaultOpen('.rar', 'RAR archive (BGRA Zip)');
end;

procedure TfrmMain.miDefaultSettingsClick(Sender: TObject);
begin
  OpenDefaultAppsSettings;
end;

procedure TfrmMain.miDefaultRemoveClick(Sender: TObject);
begin
  if MessageDlg('Remove BGRA Zip''s .zip / .rar registration and restore the previous file types?',
    mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    Exit;
  UnregisterFileType('.zip');
  UnregisterFileType('.rar');
  MessageDlg('BGRA Zip associations removed.' + LineEnding +
    'If Windows still opens archives with BGRA Zip, pick another app in Settings > Default apps.',
    mtInformation, [mbOK], 0);
end;

procedure TfrmMain.SetDefaultOpen(const AExt, ADescription: string);
var
  Cur, UC: string;
begin
  if IsDefaultFor(AExt) then
  begin
    MessageDlg(Format('BGRA Zip is already the default program for %s files.', [AExt]),
      mtInformation, [mbOK], 0);
    Exit;
  end;
  Cur := CurrentDefaultExe(AExt);
  DevLogFmt(llInfo, 'Set default open %s: current handler "%s", UserChoice "%s"',
    [AExt, Cur, UserChoiceProgId(AExt)]);
  if not RegisterFileType(AExt, ADescription) then
  begin
    MessageDlg(Format('Could not write the %s registration to the registry.', [AExt]), mtError, [mbOK], 0);
    Exit;
  end;
  if IsDefaultFor(AExt) then
  begin
    DevLogFmt(llInfo, 'BGRA Zip is now the default for %s', [AExt]);
    MessageDlg(Format('BGRA Zip is now the default program for %s files.', [AExt]),
      mtInformation, [mbOK], 0);
    Exit;
  end;
  // A protected UserChoice decides; Windows only lets the user change it.
  UC := UserChoiceProgId(AExt);
  DevLogFmt(llInfo, '%s is controlled by UserChoice "%s" - user confirmation needed', [AExt, UC]);
  if Cur = '' then
    Cur := UC;
  if MessageDlg('Set default open', Format(
    'BGRA Zip is now registered for %s files and appears in "Open with".' + LineEnding + LineEnding +
    'Windows keeps the default app for %s in a protected setting (currently: %s), ' +
    'so Windows asks you to confirm the change yourself.' + LineEnding + LineEnding +
    'Open Settings > Default apps > BGRA Zip now and choose BGRA Zip for %s?',
    [AExt, AExt, Cur, AExt]), mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    OpenDefaultAppsSettings;
end;

procedure TfrmMain.miExtractSelClick(Sender: TObject);
begin
  ToolClick(nil, TB_EXTRACTSEL);
end;

procedure TfrmMain.miRemoveClick(Sender: TObject);
begin
  RemoveSelected;
end;

procedure TfrmMain.miShowDevClick(Sender: TObject);
begin
  if (FMode = vmArchive) and (lvFiles.Selected <> nil) then
    lvFilesDblClick(nil)
  else
    ShowDevInfo;
end;

{ ---------- staging ---------- }

procedure TfrmMain.AddFile(const AFileName, AArchiveName: string);
var
  I, N: Integer;
  EntryName: string;
begin
  EntryName := StringReplace(AArchiveName, '\', '/', [rfReplaceAll]);
  for I := 0 to High(FStaged) do
    if SameText(FStaged[I].ArchiveName, EntryName) then
    begin
      DevLogFmt(llWarn, 'Skipped duplicate entry name: %s', [EntryName]);
      Exit;
    end;
  N := Length(FStaged);
  SetLength(FStaged, N + 1);
  FStaged[N].DiskPath := AFileName;
  FStaged[N].ArchiveName := EntryName;
  FStaged[N].Size := FileSizeUtf8(AFileName);
  FStaged[N].Modified := FileDateToDateTime(FileAgeUTF8(AFileName));
  FMode := vmStaging;
end;

procedure TfrmMain.AddFiles(AFiles: TStrings);
var
  I: Integer;
begin
  for I := 0 to AFiles.Count - 1 do
    AddFile(AFiles[I], ExtractFileName(AFiles[I]));
  DevLogFmt(llInfo, 'Added %d file(s); staging list now %d', [AFiles.Count, Length(FStaged)]);
  PlayFx(feAdd);
end;

procedure TfrmMain.AddFolder(const ADir: string);
var
  L: TStringList;
  Base, Root: string;
  I: Integer;
  T0: QWord;
begin
  T0 := GetTickCount64;
  Base := IncludeTrailingPathDelimiter(ADir);
  Root := ExtractFileName(ExcludeTrailingPathDelimiter(ADir));
  L := FindAllFiles(ADir, '', True);
  try
    for I := 0 to L.Count - 1 do
      AddFile(L[I], Root + '/' + ExtractRelativePath(Base, L[I]));
    DevLogFmt(llInfo, 'Added folder %s: %d file(s) scanned in %d ms',
      [ADir, L.Count, GetTickCount64 - T0]);
  finally
    L.Free;
  end;
  if Length(FStaged) > 0 then
    FMode := vmStaging;
  PlayFx(feAdd);
end;

procedure TfrmMain.RemoveSelected;
var
  Sel: TStringList;
  Keep: array of Boolean;
  I, N: Integer;
begin
  if (FMode <> vmStaging) or (lvFiles.SelCount = 0) then
    Exit;
  Sel := SelectedIndexes;
  try
    SetLength(Keep, Length(FStaged));
    for I := 0 to High(Keep) do
      Keep[I] := True;
    for I := 0 to Sel.Count - 1 do
      Keep[PtrInt(Sel.Objects[I])] := False;
    N := 0;
    for I := 0 to High(FStaged) do
      if Keep[I] then
      begin
        FStaged[N] := FStaged[I];
        Inc(N);
      end;
    SetLength(FStaged, N);
    DevLogFmt(llInfo, 'Removed %d item(s) from staging list', [Sel.Count]);
  finally
    Sel.Free;
  end;
  RefreshList;
  PlayFx(feRemove);
end;

procedure TfrmMain.NewArchive;
begin
  SetLength(FStaged, 0);
  DevForm.SetArchive(nil);
  FreeAndNil(FArchive);
  FMode := vmEmpty;
  DevLog(llInfo, 'New archive (list cleared)');
  RefreshList;
  SetProgress(0, 'Ready', False, True);
end;

{ ---------- progress ---------- }

procedure TfrmMain.SetProgress(AFraction: Double; const AText: string; AActive: Boolean; AForce: Boolean);
var
  T: QWord;
begin
  FProgress := AFraction;
  FProgressText := AText;
  FProgressActive := AActive;
  if AActive and (Fx <> nil) then
    Fx.ProgressSpark(pbProgress.Left + Round(pbProgress.Width * Min(Max(AFraction, 0), 1)),
      pbProgress.Top + pbProgress.Height div 2);
  T := GetTickCount64;
  if AForce or (T - FLastPump >= 40) then
  begin
    FLastPump := T;
    pbProgress.Invalidate;
    if FBusy then
      Application.ProcessMessages
    else
      pbProgress.Update;
  end;
end;

procedure TfrmMain.pbProgressPaint(Sender: TObject);
begin
  PaintProgress(pbProgress, FProgress, FProgressText, FProgressActive);
end;

procedure TfrmMain.pbHeaderPaint(Sender: TObject);
var
  Badge, Detail: string;
begin
  case FMode of
    vmArchive:
      begin
        Badge := LockInfo(Detail);
        // a locked archive says what is locked where the folder path usually is
        if Badge = '' then
          Detail := ExtractFilePath(FArchive.FileName);
        if (FArchive is TRarArchiveInfo) and TRarArchiveInfo(FArchive).HeadersEncrypted then
          // nothing can be counted without the password; "0 files" would be wrong
          PaintHeader(pbHeader, ExtractFileName(FArchive.FileName),
            FArchive.FormatName + ' archive  ' + FormatSize(FArchive.FileSize) + '  -  ' + Detail,
            ['contents hidden'], Badge)
        else
          PaintHeader(pbHeader, ExtractFileName(FArchive.FileName),
            FArchive.FormatName + ' archive  ' + FormatSize(FArchive.FileSize) + '  -  ' + Detail,
            [Format('%d files', [FArchive.FileCount]),
             Format('%d folders', [FArchive.DirCount]),
             FormatSize(FArchive.TotalUncompressed) + ' raw',
             'saved ' + FormatFloat('0.0', FArchive.OverallSavedPercent) + '%'], Badge);
      end;
    vmStaging:
      PaintHeader(pbHeader, 'New archive', 'Press "Create" to compress the listed files into .zip or .rar',
        [Format('%d files', [Length(FStaged)]), FormatSize(StagedTotal), cbLevel.Text]);
  else
    PaintHeader(pbHeader, 'BGRA Zip', 'ZIP / RAR archiver - Lazarus + BGRABitmap  -  drag & drop files, .zip or .rar here',
      ['F12: Developer info']);
  end;
end;

{ ---------- zipper callbacks ---------- }

procedure TfrmMain.ZipStartFile(Sender: TObject; const AFileName: string);
begin
  if FOpIndex >= 0 then
    Inc(FOpDone, FOpCurSize);
  Inc(FOpIndex);
  if FOpIndex <= High(FStaged) then
    FOpCurSize := FStaged[FOpIndex].Size
  else
    FOpCurSize := 0;
  FOpCurName := AFileName;
  if FOpTotal > 0 then
    SetProgress(FOpDone / FOpTotal, 'Compressing ' + AFileName, True)
  else
    SetProgress(0, 'Compressing ' + AFileName, True);
end;

procedure TfrmMain.ZipProgress(Sender: TObject; const Pct: Double);
var
  F: Double;
begin
  if FOpTotal <= 0 then
    Exit;
  F := (FOpDone + FOpCurSize * Pct / 100) / FOpTotal;
  SetProgress(F, Format('Compressing %s  %.0f%%', [FOpCurName, F * 100]), True);
end;

procedure TfrmMain.UnzipStartFile(Sender: TObject; const AFileName: string);
begin
  FOpCurName := ExtractFileName(AFileName);
  Inc(FOpIndex);
end;

procedure TfrmMain.UnzipProgressEx(Sender: TObject; const ATotPos, ATotSize: Int64);
var
  F: Double;
begin
  if ATotSize > 0 then
    F := ATotPos / ATotSize
  else
    F := 0;
  SetProgress(F, Format('%s %s  %.0f%%', [FOpVerb, FOpCurName, F * 100]), True);
end;

procedure TfrmMain.TestCreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := TDiscardStream.Create;
end;

procedure TfrmMain.TestDoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  FreeAndNil(AStream);
end;

{ ---------- external RAR tool callbacks ---------- }

procedure TfrmMain.ResetProgNames;
begin
  FProgNames.Clear;
  SetLength(FProgSizes, 0);
  FOpIndex := 0;
  FOpDone := 0;
end;

procedure TfrmMain.AddProgName(const AName: string; ASize: Int64);
var
  N: Integer;
begin
  N := Length(FProgSizes);
  SetLength(FProgSizes, N + 1);
  FProgSizes[N] := ASize;
  FProgNames.AddObject(AName, TObject(PtrInt(N)));
end;

procedure TfrmMain.ToolLine(const ALine: string);
var
  EntryName: string;
  I: Integer;
  F: Double;
begin
  DevLog(llDebug, '  > ' + ALine);
  EntryName := ProgressLineName(FTool, ALine);
  if EntryName = '' then
    Exit;
  Inc(FOpIndex);
  FOpCurName := ExtractFileName(EntryName);
  I := FProgNames.IndexOf(EntryName);
  if I >= 0 then
    Inc(FOpDone, FProgSizes[PtrInt(FProgNames.Objects[I])]);
  F := 0;
  if FOpTotal > 0 then
    F := FOpDone / FOpTotal;
  if FOpCount > 0 then
    F := Max(F, FOpIndex / FOpCount);
  SetProgress(Min(F, 1), Format('%s %s  %.0f%%', [FOpVerb, FOpCurName, Min(F, 1) * 100]), True);
end;

function TfrmMain.ToolPoll(ABytesOut: Int64): Boolean;
begin
  SetProgress(FProgress, FProgressText, True);
  Result := FToolCancel;
end;

function TfrmMain.ToolStreamPoll(ABytesOut: Int64): Boolean;
var
  F: Double;
begin
  F := 0;
  if FOpTotal > 0 then
    F := Min(1, (FOpDone + ABytesOut) / FOpTotal);
  SetProgress(F, Format('%s %s  %.0f%%', [FOpVerb, FormatSize(FOpDone + ABytesOut), F * 100]), True);
  Result := FToolCancel;
end;

function TfrmMain.RequireRarTool(out ATool: TRarTool; ACreate: Boolean): Boolean;
begin
  if ACreate then
    Result := FindRarCreator(ATool)
  else
    Result := FindRarExtractor(ATool);
  if Result then
  begin
    DevLogFmt(llInfo, 'Using %s: %s', [RarToolNames[ATool.Kind], ATool.Exe]);
    Exit;
  end;
  if ACreate then
    MessageDlg('RAR compression not available',
      'Creating .rar archives needs WinRAR''s console tool rar.exe (the RAR format''s compressor ' +
      'is proprietary).' + LineEnding + LineEnding +
      'Install WinRAR (www.win-rar.com) or put rar.exe on the PATH, or create a .zip instead.',
      mtWarning, [mbOK], 0)
  else
    MessageDlg('No RAR extractor found',
      'Extracting .rar needs one of: WinRAR (rar.exe / UnRAR.exe), 7-Zip (7z.exe), or tar.exe ' +
      '(built into Windows 10 1803+ and Windows 11).', mtWarning, [mbOK], 0);
end;

{ ---------- operations ---------- }

procedure TfrmMain.OpenArchive(const AFileName: string);
var
  A: TArchiveInfo;
  Fmt: TArchiveFormat;
  SigOfs: Int64;
  I: Integer;
  Detail: string;
begin
  DevLogFmt(llInfo, 'Opening archive: %s', [AFileName]);
  A := nil;
  try
    DetectArchiveFormat(AFileName, Fmt, SigOfs);
    if Fmt in [afRar4, afRar5] then
      A := TRarArchiveInfo.Create
    else
      A := TZipArchiveInfo.Create;
    DevLogFmt(llDebug, 'Detected format: %s (signature at %d)', [ArchiveFormatNames[Fmt], SigOfs]);
    A.LoadFromFile(AFileName);
  except
    on E: Exception do
    begin
      A.Free;
      DevLogFmt(llError, 'Open failed: %s: %s', [E.ClassName, E.Message]);
      MessageDlg('Cannot open archive', AFileName + LineEnding + LineEnding + E.Message, mtError, [mbOK], 0);
      Exit;
    end;
  end;
  DevForm.SetArchive(nil);
  FreeAndNil(FArchive);
  FArchive := A;
  FPassword := '';
  SetLength(FStaged, 0);
  FMode := vmArchive;
  DevLogFmt(llTiming, 'Parsed %s: %d entries, %s, in %d ms',
    [A.FormatName, A.Count, FormatSize(A.FileSize), A.ParseTimeMs]);
  for I := 0 to A.Warnings.Count - 1 do
    DevLog(llWarn, A.Warnings[I]);
  RefreshList;
  DevForm.SetArchive(FArchive);
  AddRecent(AFileName);
  // password-protected archives are flagged in the header, list and status bar
  // instead of a dialog, so opening never blocks (IPC, drag & drop, command line)
  if LockInfo(Detail) <> '' then
  begin
    DevLog(llWarn, 'Password-protected: ' + Detail);
    SetProgress(0, Format('Opened %s (%s) - password-protected: %s', [ExtractFileName(AFileName), A.FormatName, Detail]),
      False, True);
  end
  else
    SetProgress(0, Format('Opened %s (%s) - %d entries', [ExtractFileName(AFileName), A.FormatName, A.Count]),
      False, True);
  PlayFx(feOpen);
end;

procedure TfrmMain.CreateArchive;
var
  OutName: string;
  I: Integer;
begin
  if dlgSaveZip.FileName = '' then
    dlgSaveZip.FileName := 'archive.zip';
  if not dlgSaveZip.Execute then
    Exit;
  OutName := dlgSaveZip.FileName;
  // the filter decides the format when the user did not type an extension
  if (ExtractFileExt(OutName) = '') then
    if dlgSaveZip.FilterIndex = 2 then
      OutName := OutName + '.rar'
    else
      OutName := OutName + '.zip';
  for I := 0 to High(FStaged) do
    if SameFileName(ExpandFileNameUTF8(FStaged[I].DiskPath), ExpandFileNameUTF8(OutName)) then
    begin
      MessageDlg('The output file is also in the input list.', mtError, [mbOK], 0);
      Exit;
    end;
  if SameText(ExtractFileExt(OutName), '.rar') then
    CreateRar(OutName)
  else
    CreateZip(OutName);
end;

procedure TfrmMain.CreateZip(const AOutName: string);
var
  I: Integer;
  T0, Ms: QWord;
  Entry: TZipFileEntry;
  Cancelled: Boolean;
begin
  if CreatePure(AOutName) then
    Exit;
  FBusy := True;
  UpdateUI;
  FZipper := TZipper.Create;
  Cancelled := False;
  try
    FZipper.FileName := AOutName;
    FZipper.UseLanguageEncoding := True;
    FZipper.OnStartFile := @ZipStartFile;
    FZipper.OnProgress := @ZipProgress;
    for I := 0 to High(FStaged) do
    begin
      Entry := FZipper.Entries.AddFileEntry(FStaged[I].DiskPath, FStaged[I].ArchiveName);
      Entry.CompressionLevel := CompressionLevel;
    end;
    FOpIndex := -1;
    FOpDone := 0;
    FOpCurSize := 0;
    FOpTotal := StagedTotal;
    DevLogFmt(llInfo, 'Create ZIP: %s, %d entries, %s, level=%s, buffer=%d',
      [AOutName, Length(FStaged), FormatSize(FOpTotal), cbLevel.Text, FZipper.BufferSize]);
    T0 := GetTickCount64;
    try
      FZipper.ZipAllFiles;
      Cancelled := FZipper.Terminated;
    except
      on E: Exception do
      begin
        DevLogFmt(llError, 'Compression failed: %s: %s', [E.ClassName, E.Message]);
        SetProgress(0, 'Failed: ' + E.Message, False, True);
        PlayFx(feError);
        FreeAndNil(FZipper);
        FBusy := False;
        UpdateUI;
        MessageDlg('Compression failed', E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    Ms := GetTickCount64 - T0;
  finally
    FreeAndNil(FZipper);
    FBusy := False;
  end;

  if Cancelled then
  begin
    DeleteFileUTF8(AOutName);
    DevLog(llWarn, 'Compression cancelled - partial file deleted');
    SetProgress(0, 'Cancelled', False, True);
    UpdateUI;
    Exit;
  end;

  DevLogFmt(llTiming, 'ZIP created in %d ms: %s -> %s (%.1f MB/s)',
    [Ms, FormatSize(FOpTotal), FormatSize(FileSizeUtf8(AOutName)),
     FOpTotal / 1048576 / Max(Ms, 1) * 1000]);
  DevForm.SetLastOperation('Create ZIP', Ms, FOpTotal, FileSizeUtf8(AOutName));
  OpenArchive(AOutName);
  SetProgress(1, Format('Created %s in %.2f s', [ExtractFileName(AOutName), Ms / 1000]), False, True);
  PlayFx(feCreate);
end;

procedure TfrmMain.CreateRar(const AOutName: string);
const
  RarLevels: array[0..3] of Integer = (0, 1, 3, 5);
var
  Groups: TStringList;       // base directory -> TStringList of relative names
  Names, Args: TStringList;
  Chunks: TList;
  I, J, K: Integer;
  Base, Rel: string;
  R: TToolResult;
  T0, Ms: QWord;
  Failed: Boolean;
begin
  if CreatePure(AOutName) then
    Exit;
  if not RequireRarTool(FTool, True) then
    Exit;
  // "rar a" adds to an existing archive; the save dialog already confirmed overwrite
  if FileExistsUTF8(AOutName) and not DeleteFileUTF8(AOutName) then
  begin
    MessageDlg('Cannot overwrite ' + AOutName, mtError, [mbOK], 0);
    Exit;
  end;

  // rar stores paths relative to its working directory, so group the files by
  // the directory their archive name is relative to.
  R := Default(TToolResult);
  Groups := TStringList.Create;
  Groups.OwnsObjects := True;
  Args := TStringList.Create;
  ResetProgNames;
  try
    for I := 0 to High(FStaged) do
    begin
      Rel := StringReplace(FStaged[I].ArchiveName, '/', PathDelim, [rfReplaceAll]);
      if SameText(Copy(FStaged[I].DiskPath, Length(FStaged[I].DiskPath) - Length(Rel) + 1, Length(Rel)), Rel) then
        Base := Copy(FStaged[I].DiskPath, 1, Length(FStaged[I].DiskPath) - Length(Rel))
      else
      begin
        Base := ExtractFilePath(FStaged[I].DiskPath);
        Rel := ExtractFileName(FStaged[I].DiskPath);
        DevLogFmt(llWarn, 'RAR: %s stored as %s', [FStaged[I].ArchiveName, Rel]);
      end;
      J := Groups.IndexOf(Base);
      if J < 0 then
        J := Groups.AddObject(Base, TStringList.Create);
      TStringList(Groups.Objects[J]).Add(Rel);
      AddProgName(StringReplace(Rel, PathDelim, '/', [rfReplaceAll]), FStaged[I].Size);
    end;

    FBusy := True;
    FToolCancel := False;
    FOpVerb := 'Adding';
    FOpTotal := StagedTotal;
    FOpCount := Length(FStaged);
    UpdateUI;
    DevLogFmt(llInfo, 'Create RAR: %s, %d entries in %d base folder(s), %s, -m%d',
      [AOutName, Length(FStaged), Groups.Count, FormatSize(FOpTotal), RarLevels[cbLevel.ItemIndex]]);
    T0 := GetTickCount64;
    Failed := False;
    for J := 0 to Groups.Count - 1 do
    begin
      Chunks := ChunkNames(TStringList(Groups.Objects[J]));
      try
        for K := 0 to Chunks.Count - 1 do
        begin
          Names := TStringList(Chunks[K]);
          BuildCreateArgs(FTool, AOutName, RarLevels[cbLevel.ItemIndex], Names, Args);
          R := RunTool(FTool, Args, Groups[J], nil, @ToolLine, @ToolPoll);
          if R.Cancelled or (R.ExitCode > 1) then
          begin
            Failed := True;
            Break;
          end;
        end;
      finally
        FreeChunks(Chunks);
      end;
      if Failed then
        Break;
    end;
    Ms := GetTickCount64 - T0;
  finally
    FBusy := False;
    Groups.Free;
    Args.Free;
  end;
  UpdateUI;
  if R.Cancelled then
  begin
    DeleteFileUTF8(AOutName);
    DevLog(llWarn, 'RAR creation cancelled - partial file deleted');
    SetProgress(0, 'Cancelled', False, True);
    Exit;
  end;
  if Failed then
  begin
    DevLogFmt(llError, 'rar.exe failed with exit code %d', [R.ExitCode]);
    SetProgress(0, Format('RAR creation failed (exit code %d)', [R.ExitCode]), False, True);
    PlayFx(feError);
    MessageDlg('RAR creation failed', Format('rar.exe exit code %d', [R.ExitCode]) + LineEnding +
      Copy(R.Output, Max(1, Length(R.Output) - 1500), 1500), mtError, [mbOK], 0);
    Exit;
  end;
  DevLogFmt(llTiming, 'RAR created in %d ms: %s -> %s', [Ms, FormatSize(FOpTotal),
    FormatSize(FileSizeUtf8(AOutName))]);
  DevForm.SetLastOperation('Create RAR', Ms, FOpTotal, FileSizeUtf8(AOutName));
  OpenArchive(AOutName);
  SetProgress(1, Format('Created %s in %.2f s', [ExtractFileName(AOutName), Ms / 1000]), False, True);
  PlayFx(feCreate);
end;

procedure TfrmMain.ExtractTo(ASelectedOnly: Boolean; const ADir: string);
var
  Dir: string;
  Sel, Names: TStringList;
  I: Integer;
  Total: Int64;
begin
  if ADir <> '' then
  begin
    Dir := ADir;
    if not ForceDirectoriesUTF8(Dir) then
    begin
      MessageDlg('Cannot create folder ' + Dir, mtError, [mbOK], 0);
      Exit;
    end;
  end
  else if dlgFolder.Execute then
    Dir := dlgFolder.FileName
  else
    Exit;
  Names := TStringList.Create;
  Sel := nil;
  try
    Total := 0;
    if ASelectedOnly then
    begin
      Sel := SelectedIndexes;
      for I := 0 to Sel.Count - 1 do
      begin
        Names.Add(FArchive.Entry[PtrInt(Sel.Objects[I])].FileName);
        Inc(Total, FArchive.Entry[PtrInt(Sel.Objects[I])].UncompressedSize);
      end;
    end
    else
      Total := FArchive.TotalUncompressed;
    if IsRar then
      ExtractRar(Dir, Names, Total, False)
    else
      ExtractZip(Dir, Names, Total, False);
  finally
    Names.Free;
    Sel.Free;
  end;
end;

{ ---------- rar_pure.exe ---------- }

function TfrmMain.ArchiveLocked: Boolean;
begin
  Result := (FArchive <> nil) and ((FArchive.EncryptedCount > 0) or
    ((FArchive is TRarArchiveInfo) and TRarArchiveInfo(FArchive).HeadersEncrypted));
end;

function TfrmMain.AskPassword(const AVerb: string): Boolean;
var
  S: string;
begin
  Result := True;
  if (FPassword <> '') or not ArchiveLocked or (RarPureExe = '') then
    Exit;
  S := '';
  repeat
    if not InputQuery('Password',
      Format('%s is password-protected.' + LineEnding + LineEnding +
        'Password (leave empty to %s only the files that do not need one):',
        [ExtractFileName(FArchive.FileName), AVerb]), True, S) then
      Exit(False);
    if IsAsciiText(S) then
      Break;
    MessageDlg('Password', 'rar_pure.exe accepts only English letters, digits and symbols in a password.',
      mtWarning, [mbOK], 0);
  until False;
  FPassword := S;
end;

function TfrmMain.PureProgress(ABytes: Int64): Boolean;
var
  F: Double;
begin
  F := 0;
  if FOpTotal > 0 then
    F := Min(ABytes / FOpTotal, 1);
  SetProgress(F, Format('%s %s  %.0f%%', [FOpVerb, FOpCurName, F * 100]), True);
  Result := FToolCancel;
end;

function TfrmMain.ExtractPure(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
var
  R: TRarPureResult;
  T0, Ms: QWord;
  Msg: string;
  I, Skipped: Integer;
begin
  Result := False;
  if not AQuiet and not AskPassword('extract') then
    Exit;
  FBusy := True;
  FToolCancel := False;
  FOpVerb := 'Extracting';
  FOpCurName := ExtractFileName(FArchive.FileName);
  FOpTotal := ATotal;
  UpdateUI;
  DevLogFmt(llInfo, 'Extract with rar_pure: %s to %s (%d selected, password %s)',
    [FArchive.FileName, ADir, ANames.Count, BoolToStr(FPassword <> '', 'given', 'none')]);
  T0 := GetTickCount64;
  try
    try
      R := RarPureExtract(FArchive.FileName, ADir, FPassword, ANames, @PureProgress);
    except
      on E: Exception do
      begin
        DevLogFmt(llError, 'Extraction failed: %s', [E.Message]);
        SetProgress(0, 'Failed: ' + E.Message, False, True);
        PlayFx(feError);
        FBusy := False;
        UpdateUI;
        if not AQuiet then
          MessageDlg('Extraction failed', E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    Ms := GetTickCount64 - T0;
  finally
    FBusy := False;
  end;
  UpdateUI;
  if R.Cancelled then
  begin
    DevLog(llWarn, 'Extraction cancelled');
    SetProgress(0, 'Cancelled', False, True);
    Exit;
  end;
  if R.ExitCode <> 0 then
  begin
    if IsPasswordFailure(R) then
      FPassword := '';  // ask again next time
    Msg := R.Message;
    if R.Files > 0 then
      Msg := Format('%s (%d file(s) were extracted)', [Msg, R.Files]);
    DevLogFmt(llError, 'rar_pure exit code %d: %s', [R.ExitCode, R.Message]);
    SetProgress(0, 'Extraction failed: ' + Msg, False, True);
    PlayFx(feError);
    if not AQuiet then
      MessageDlg('Extraction failed', Msg, mtError, [mbOK], 0);
    // a drag still delivers whatever came out
    Result := AQuiet and (R.Files > 0);
    Exit;
  end;
  // rar_pure reads the whole archive; count only protected entries that were wanted
  Skipped := R.Skipped;
  if (Skipped > 0) and (ANames.Count > 0) then
  begin
    Skipped := 0;
    for I := 0 to FArchive.Count - 1 do
      if FArchive.Entry[I].IsEncrypted and (ANames.IndexOf(FArchive.Entry[I].FileName) >= 0) then
        Inc(Skipped);
  end;
  DevLogFmt(llTiming, 'Extracted %d file(s), %s in %d ms with rar_pure', [R.Files, FormatSize(R.Bytes), Ms]);
  DevForm.SetLastOperation('Extract (rar_pure)', Ms, FArchive.TotalCompressed, ATotal);
  if Skipped > 0 then
    SetProgress(1, Format('Extracted %d file(s) in %.2f s, %d password-protected skipped',
      [R.Files, Ms / 1000, Skipped]), False, True)
  else
    SetProgress(1, Format('Extracted %d file(s) in %.2f s', [R.Files, Ms / 1000]), False, True);
  PlayFx(feExtract);
  Result := True;
  if not AQuiet and (MessageDlg(Format('Extracted %d file(s) to' + LineEnding + '%s' + LineEnding + LineEnding +
    'Open the folder?', [R.Files, ADir]), mtInformation, [mbYes, mbNo], 0) = mrYes) then
    OpenDocument(ADir);
end;

procedure TfrmMain.TestPure(ABad, ALocked: TStringList; out ACancelled: Boolean);
var
  R: TRarPureResult;
  I: Integer;
begin
  FToolCancel := False;
  FOpVerb := 'Testing';
  FOpCurName := ExtractFileName(FArchive.FileName);
  FOpTotal := FArchive.TotalUncompressed;
  DevLogFmt(llInfo, 'Test with rar_pure and the password: %s', [FArchive.FileName]);
  R := RarPureTest(FArchive.FileName, FPassword, @PureProgress);
  ACancelled := R.Cancelled;
  if ACancelled then
    Exit;
  FTestChecked := R.Files;
  if R.Message <> '' then
  begin
    ABad.Add(R.Message);
    if IsPasswordFailure(R) then
      FPassword := '';
  end
  else if R.CrcErrors > 0 then
    ABad.Add(Format('%d CRC error(s)', [R.CrcErrors]));
  if R.Skipped > 0 then
    for I := 0 to FArchive.Count - 1 do
      if FArchive.Entry[I].IsEncrypted and not FArchive.Entry[I].IsDirectory then
        ALocked.Add(FArchive.Entry[I].FileName);
end;

function TfrmMain.CreatePure(const AOutName: string): Boolean;
const
  Levels: array[0..3] of Integer = (0, 1, 5, 9);
var
  Stage, Pack, Root, Rel, Pw, Done: string;
  Sources: TStringList;
  R: TRarPureResult;
  I, P: Integer;
  T0, Ms: QWord;
begin
  Result := False;
  Pw := edPassword.Text;
  if RarPureExe = '' then
  begin
    if Pw <> '' then
    begin
      MessageDlg('Password', 'Encrypting a new archive needs rar_pure.exe next to BGRA Zip.', mtWarning, [mbOK], 0);
      Result := True;
    end;
    Exit;
  end;
  if not IsAsciiText(Pw) then
  begin
    MessageDlg('Password', 'rar_pure.exe accepts only English letters, digits and symbols in a password.',
      mtWarning, [mbOK], 0);
    Exit(True);
  end;
  // the list may differ from the folders on disk, so mirror it with hard links
  Sources := TStringList.Create;
  Stage := NewStageDir;
  Pack := Stage + 'pack' + PathDelim;
  try
    for I := 0 to High(FStaged) do
    begin
      Rel := FStaged[I].ArchiveName;
      P := Pos('/', Rel);
      if P > 0 then
        Root := Copy(Rel, 1, P - 1)
      else
        Root := Rel;
      if not IsAsciiText(Root) then
      begin
        if Pw = '' then
        begin
          DevLogFmt(llInfo, 'rar_pure cannot take "%s" on its command line; using the built-in compressor', [Root]);
          Exit;
        end;
        MessageDlg('Password', Format('"%s" has non-English letters in its name, which rar_pure.exe cannot ' +
          'receive. Rename it, or put it inside a folder with an English name, to encrypt it.', [Root]),
          mtWarning, [mbOK], 0);
        Exit(True);
      end;
      StageFile(FStaged[I].DiskPath, Pack + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]));
      if Sources.IndexOf(Pack + Root) < 0 then
        Sources.Add(Pack + Root);
    end;
    Result := True;
    FBusy := True;
    FToolCancel := False;
    FOpVerb := 'Compressing';
    FOpCurName := ExtractFileName(AOutName);
    FOpTotal := StagedTotal;
    UpdateUI;
    DevLogFmt(llInfo, 'Create with rar_pure: %s, %d entries, %s, level %d, password %s%s',
      [AOutName, Length(FStaged), FormatSize(FOpTotal), Levels[Max(cbLevel.ItemIndex, 0)],
       BoolToStr(Pw <> '', 'given', 'none'), BoolToStr(cbHideNames.Checked and (Pw <> ''), ', names hidden', '')]);
    T0 := GetTickCount64;
    try
      try
        R := RarPureCreate(AOutName, Sources, Levels[Max(cbLevel.ItemIndex, 0)], Pw, False,
          cbHideNames.Checked, @PureProgress);
      except
        on E: Exception do
        begin
          R := Default(TRarPureResult);
          R.ExitCode := -1;
          R.Message := E.Message;
        end;
      end;
      Ms := GetTickCount64 - T0;
    finally
      FBusy := False;
    end;
    UpdateUI;
    if R.Cancelled then
    begin
      DevLog(llWarn, 'Compression cancelled');
      SetProgress(0, 'Cancelled', False, True);
      Exit;
    end;
    if R.ExitCode <> 0 then
    begin
      DevLogFmt(llError, 'Compression failed: %s', [R.Message]);
      SetProgress(0, 'Failed: ' + R.Message, False, True);
      PlayFx(feError);
      MessageDlg('Compression failed', R.Message, mtError, [mbOK], 0);
      Exit;
    end;
    DevLogFmt(llTiming, 'Created with rar_pure in %d ms: %s -> %s', [Ms, FormatSize(FOpTotal),
      FormatSize(FileSizeUtf8(AOutName))]);
    DevForm.SetLastOperation('Create (rar_pure)', Ms, FOpTotal, FileSizeUtf8(AOutName));
    OpenArchive(AOutName);
    Done := Format('Created %s in %.2f s', [ExtractFileName(AOutName), Ms / 1000]);
    if Pw <> '' then
    begin
      FPassword := Pw;  // the new archive opens without asking again
      Done := Done + ', password-protected';
    end;
    SetProgress(1, Done, False, True);
    PlayFx(feCreate);
  finally
    Sources.Free;
    RemoveStageDir(Stage);
  end;
end;

function TfrmMain.ExtractZip(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
var
  T0, Ms: QWord;
  Cancelled, HasPlain: Boolean;
  Skipped: TStringList;
  SkippedCount: Integer;
begin
  if RarPureExe <> '' then
    Exit(ExtractPure(ADir, ANames, ATotal, AQuiet));
  Result := False;
  FBusy := True;
  UpdateUI;
  FUnZipper := TUnZipper.Create;
  Skipped := TStringList.Create;
  Cancelled := False;
  SkippedCount := 0;
  try
    FUnZipper.FileName := FArchive.FileName;
    FUnZipper.OutputPath := ADir;
    FUnZipper.UseUTF8 := True;
    FUnZipper.OnStartFile := @UnzipStartFile;
    FUnZipper.OnProgressEx := @UnzipProgressEx;
    FOpIndex := 0;
    FOpVerb := 'Extracting';
    DevLogFmt(llInfo, 'Extract %s to %s (%d entries, %s)',
      [BoolToStr(ANames.Count > 0, 'selected', 'all'), ADir,
       IfThen(ANames.Count > 0, ANames.Count, FArchive.Count), FormatSize(ATotal)]);
    T0 := GetTickCount64;
    try
      // TUnZipper stops at the first encrypted entry, so leave those out
      HasPlain := SelectZipEntries(FUnZipper, ANames, Skipped);
      SkippedCount := Skipped.Count;
      if SkippedCount > 0 then
      begin
        DevLogFmt(llWarn, 'Extract: %d password-protected entries skipped', [SkippedCount]);
        if not HasPlain then
        begin
          SetProgress(0, 'Nothing extracted: password-protected', False, True);
          FBusy := False;
          UpdateUI;
          if not AQuiet then
            MessageDlg('Password-protected', Format('All %d entries are password-protected and cannot be extracted.',
              [SkippedCount]), mtWarning, [mbOK], 0);
          Exit;
        end;
        if not AQuiet and (MessageDlg(Format('%d entries are password-protected and cannot be extracted. Continue with the rest?',
          [SkippedCount]), mtWarning, [mbYes, mbNo], 0) <> mrYes) then
        begin
          FBusy := False;
          UpdateUI;
          Exit;
        end;
      end;
      if HasPlain then
        FUnZipper.UnZipAllFiles;
      Cancelled := FUnZipper.Terminated;
    except
      on E: Exception do
      begin
        DevLogFmt(llError, 'Extraction failed: %s: %s', [E.ClassName, E.Message]);
        SetProgress(0, 'Failed: ' + E.Message, False, True);
        PlayFx(feError);
        FBusy := False;
        UpdateUI;
        if not AQuiet then
          MessageDlg('Extraction failed', E.Message, mtError, [mbOK], 0);
        Exit;
      end;
    end;
    Ms := GetTickCount64 - T0;
  finally
    FreeAndNil(FUnZipper);
    Skipped.Free;
    FBusy := False;
  end;

  UpdateUI;
  if Cancelled then
  begin
    DevLog(llWarn, 'Extraction cancelled');
    SetProgress(0, 'Cancelled', False, True);
    Exit;
  end;
  DevLogFmt(llTiming, 'Extracted %d file(s), %s in %d ms', [FOpIndex, FormatSize(ATotal), Ms]);
  DevForm.SetLastOperation('Extract', Ms, FArchive.TotalCompressed, ATotal);
  if SkippedCount > 0 then
    SetProgress(1, Format('Extracted %d file(s) in %.2f s, %d password-protected skipped',
      [FOpIndex, Ms / 1000, SkippedCount]), False, True)
  else
    SetProgress(1, Format('Extracted %d file(s) in %.2f s', [FOpIndex, Ms / 1000]), False, True);
  PlayFx(feExtract);
  Result := True;
  if not AQuiet and (MessageDlg(Format('Extracted %d file(s) to' + LineEnding + '%s' + LineEnding + LineEnding +
    'Open the folder?', [FOpIndex, ADir]), mtInformation, [mbYes, mbNo], 0) = mrYes) then
    OpenDocument(ADir);
end;

function TfrmMain.ExtractRar(const ADir: string; ANames: TStrings; ATotal: Int64; AQuiet: Boolean): Boolean;
var
  Plain: TStringList;
begin
  if RarPureExe <> '' then
    Exit(ExtractPure(ADir, ANames, ATotal, AQuiet));
  // the entries to extract when some are password-protected; owned here so
  // every exit of DoExtractRar frees it
  Plain := TStringList.Create;
  try
    Result := DoExtractRar(ADir, ANames, Plain, ATotal, AQuiet);
  finally
    Plain.Free;
  end;
end;

function TfrmMain.DoExtractRar(const ADir: string; ANames: TStrings; Plain: TStringList; ATotal: Int64;
  AQuiet: Boolean): Boolean;
var
  Args: TStringList;
  Chunks: TList;
  R: TToolResult;
  I, Skipped: Integer;
  T0, Ms: QWord;
  E: TArchiveEntry;
begin
  Result := False;
  if AQuiet then
  begin
    if not FindRarExtractor(FTool) then
    begin
      DevLog(llError, 'No RAR extractor found (rar/unrar/7z/tar)');
      Exit;
    end;
  end
  else if not RequireRarTool(FTool, False) then
    Exit;
  if TRarArchiveInfo(FArchive).HeadersEncrypted then
  begin
    SetProgress(0, 'Nothing extracted: the file names are encrypted', False, True);
    if not AQuiet then
      MessageDlg('Password-protected', 'The file names in this archive are encrypted, so nothing can be ' +
        'extracted without the password.', mtWarning, [mbOK], 0);
    Exit;
  end;
  // name only the plain entries, or the tool fails on the protected ones
  Skipped := 0;
  if FArchive.EncryptedCount > 0 then
  begin
    for I := 0 to FArchive.Count - 1 do
    begin
      E := FArchive.Entry[I];
      if (ANames.Count > 0) and (ANames.IndexOf(E.FileName) < 0) then
        Continue;
      // a folder named to rar brings its (encrypted) contents along: make it here
      if E.IsDirectory then
        ForceDirectoriesUTF8(IncludeTrailingPathDelimiter(ADir) +
          StringReplace(E.FileName, '/', PathDelim, [rfReplaceAll]))
      else if E.IsEncrypted then
        Inc(Skipped)
      else
        Plain.Add(E.FileName);
    end;
  end;
  if Skipped > 0 then
  begin
    DevLogFmt(llWarn, 'Extract: %d password-protected entries skipped', [Skipped]);
    if Plain.Count = 0 then
    begin
      SetProgress(0, 'Nothing extracted: password-protected', False, True);
      if not AQuiet then
        MessageDlg('Password-protected', Format('All %d entries are password-protected and cannot be extracted.',
          [Skipped]), mtWarning, [mbOK], 0);
      Exit;
    end;
    if not AQuiet and (MessageDlg(Format('%d entries are password-protected and cannot be extracted. Continue with the rest?',
      [Skipped]), mtWarning, [mbYes, mbNo], 0) <> mrYes) then
      Exit;
    ANames := Plain;
  end;
  R := Default(TToolResult);
  Args := TStringList.Create;
  ResetProgNames;
  for I := 0 to FArchive.Count - 1 do
  begin
    E := FArchive.Entry[I];
    AddProgName(E.FileName, E.UncompressedSize);
  end;
  FBusy := True;
  FToolCancel := False;
  FOpVerb := 'Extracting';
  FOpTotal := ATotal;
  if ANames.Count > 0 then
    FOpCount := ANames.Count
  else
    FOpCount := FArchive.Count;
  UpdateUI;
  DevLogFmt(llInfo, 'Extract RAR %s to %s with %s (%d entries, %s)',
    [BoolToStr(ANames.Count > 0, 'selected', 'all'), ADir, RarToolNames[FTool.Kind], FOpCount, FormatSize(ATotal)]);
  T0 := GetTickCount64;
  try
    if ANames.Count = 0 then
    begin
      BuildExtractArgs(FTool, FArchive.FileName, ADir, nil, Args);
      R := RunTool(FTool, Args, '', nil, @ToolLine, @ToolPoll);
    end
    else
    begin
      Chunks := ChunkNames(ANames);
      try
        for I := 0 to Chunks.Count - 1 do
        begin
          BuildExtractArgs(FTool, FArchive.FileName, ADir, TStringList(Chunks[I]), Args);
          R := RunTool(FTool, Args, '', nil, @ToolLine, @ToolPoll);
          if R.Cancelled or (R.ExitCode > 1) then
            Break;
        end;
      finally
        FreeChunks(Chunks);
      end;
    end;
    Ms := GetTickCount64 - T0;
  finally
    FBusy := False;
    Args.Free;
  end;
  UpdateUI;
  if R.Cancelled then
  begin
    DevLog(llWarn, 'Extraction cancelled');
    SetProgress(0, 'Cancelled', False, True);
    Exit;
  end;
  if R.ExitCode <> 0 then
  begin
    DevLogFmt(llError, '%s exit code %d', [ExtractFileName(FTool.Exe), R.ExitCode]);
    SetProgress(0, Format('Extraction finished with errors (exit code %d)', [R.ExitCode]), False, True);
    PlayFx(feError);
    if not AQuiet then
      MessageDlg('Extraction problem', Format('%s returned exit code %d:', [RarToolNames[FTool.Kind], R.ExitCode]) +
        LineEnding + Copy(R.Output, Max(1, Length(R.Output) - 1500), 1500), mtWarning, [mbOK], 0);
    // a drag still delivers whatever was extracted
    Result := AQuiet;
    Exit;
  end;
  DevLogFmt(llTiming, 'Extracted %d item(s), %s in %d ms', [FOpIndex, FormatSize(ATotal), Ms]);
  DevForm.SetLastOperation('Extract (' + RarToolNames[FTool.Kind] + ')', Ms, FArchive.TotalCompressed, ATotal);
  if Skipped > 0 then
    SetProgress(1, Format('Extracted %d item(s) in %.2f s, %d password-protected skipped',
      [FOpIndex, Ms / 1000, Skipped]), False, True)
  else
    SetProgress(1, Format('Extracted %d item(s) in %.2f s', [FOpIndex, Ms / 1000]), False, True);
  PlayFx(feExtract);
  Result := True;
  if not AQuiet and (MessageDlg(Format('Extracted %d item(s) to' + LineEnding + '%s' + LineEnding + LineEnding +
    'Open the folder?', [FOpIndex, ADir]), mtInformation, [mbYes, mbNo], 0) = mrYes) then
    OpenDocument(ADir);
end;

procedure TfrmMain.TestZip(ABad, ALocked: TStringList; out ACancelled: Boolean);
var
  E: TZipEntryInfo;
  Zip: TZipArchiveInfo;

  function NewUnzipper: TUnZipper;
  begin
    Result := TUnZipper.Create;
    Result.FileName := FArchive.FileName;
    Result.UseUTF8 := True;
    Result.OnCreateStream := @TestCreateStream;
    Result.OnDoneStream := @TestDoneStream;
    Result.OnStartFile := @UnzipStartFile;
    Result.OnProgressEx := @UnzipProgressEx;
  end;

begin
  ACancelled := False;
  Zip := TZipArchiveInfo(FArchive);
  FUnZipper := NewUnzipper;
  try
    // password-protected entries cannot be checked: list them apart, test the rest
    if not SelectZipEntries(FUnZipper, nil, ALocked) then
      Exit;
    try
      FUnZipper.UnZipAllFiles;
      ACancelled := FUnZipper.Terminated;
    except
      on Ex: Exception do
      begin
        DevLogFmt(llWarn, 'Bulk test stopped (%s) - checking entries one by one', [Ex.Message]);
        FreeAndNil(FUnZipper);
        // Find every broken entry, not only the first one.
        for E in Zip.Entries do
        begin
          if E.IsDirectory or E.IsEncrypted then
            Continue;
          FUnZipper := NewUnzipper;
          try
            try
              FUnZipper.UnZipFile(E.FileName);
            except
              on Ex2: Exception do
              begin
                ABad.Add(E.FileName + ': ' + Ex2.Message);
                DevLogFmt(llError, 'Test failed: %s: %s', [E.FileName, Ex2.Message]);
              end;
            end;
            ACancelled := FUnZipper.Terminated;
          finally
            FreeAndNil(FUnZipper);
          end;
          if ACancelled then
            Break;
        end;
      end;
    end;
  finally
    FreeAndNil(FUnZipper);
  end;
end;

procedure TfrmMain.TestRar(ABad, ALocked: TStringList; out ACancelled: Boolean);
var
  Args, Names: TStringList;
  Chunks: TList;
  Verifier: TStreamVerifier;
  Streams: Boolean;
  R: TToolResult;
  I, J: Integer;
  E: TArchiveEntry;
begin
  ACancelled := False;
  if TRarArchiveInfo(FArchive).HeadersEncrypted then
  begin
    ALocked.Add('(file names are encrypted)');
    Exit;
  end;
  if not RequireRarTool(FTool, False) then
  begin
    ABad.Add('No RAR tool available');
    Exit;
  end;
  FToolCancel := False;
  FOpTotal := FArchive.TotalUncompressed;
  FOpCount := FArchive.Count;
  ResetProgNames;
  Args := TStringList.Create;
  Names := TStringList.Create;
  Verifier := TStreamVerifier.Create;
  try
    for I := 0 to FArchive.Count - 1 do
    begin
      E := FArchive.Entry[I];
      AddProgName(E.FileName, E.UncompressedSize);
      if E.IsDirectory then
        Continue;
      if E.IsEncrypted then
      begin
        ALocked.Add(E.FileName);
        Continue;
      end;
      if TRarEntryInfo(E).SplitBefore or TRarEntryInfo(E).SplitAfter then
      begin
        DevLogFmt(llWarn, 'Skipping split entry %s (spans volumes)', [E.FileName]);
        Continue;
      end;
      Names.Add(E.FileName);
      Verifier.AddEntry(E.FileName, E.UncompressedSize, E.CRC32);
    end;
    BuildTestArgs(FTool, FArchive.FileName, nil, Args, Streams);
    if not Streams then
    begin
      // rar / unrar / 7z verify CRCs themselves; with encrypted entries, name
      // only the plain files or the tool fails on the others
      Chunks := nil;
      if ALocked.Count > 0 then
        Chunks := ChunkNames(Names);
      try
        J := 0;
        repeat
          if Chunks <> nil then
          begin
            if J >= Chunks.Count then
              Break;
            BuildTestArgs(FTool, FArchive.FileName, TStringList(Chunks[J]), Args, Streams);
          end;
          if (Chunks = nil) or (TStringList(Chunks[J]).Count > 0) then
          begin
            R := RunTool(FTool, Args, '', nil, @ToolLine, @ToolPoll);
            ACancelled := R.Cancelled;
            if not ACancelled and (R.ExitCode > 1) then
              ABad.Add(Format('%s reported errors (exit code %d):', [RarToolNames[FTool.Kind], R.ExitCode]) +
                LineEnding + Copy(R.Output, Max(1, Length(R.Output) - 1500), 1500));
          end;
          Inc(J);
        until (Chunks = nil) or ACancelled;
      finally
        if Chunks <> nil then
          FreeChunks(Chunks);
      end;
      Exit;
    end;
    // tar: stream every file's data into our own CRC32 check
    Verifier.Start;
    Chunks := ChunkNames(Names);
    try
      for J := 0 to Chunks.Count - 1 do
      begin
        if TStringList(Chunks[J]).Count = 0 then
          Continue;
        BuildTestArgs(FTool, FArchive.FileName, TStringList(Chunks[J]), Args, Streams);
        R := RunTool(FTool, Args, '', @Verifier.Feed, @ToolLine, @ToolStreamPoll);
        Inc(FOpDone, R.BytesOut);
        if R.Cancelled then
        begin
          ACancelled := True;
          Break;
        end;
        if R.ExitCode <> 0 then
          ABad.Add(Format('tar exit code %d: %s', [R.ExitCode, Trim(R.Output)]));
      end;
    finally
      FreeChunks(Chunks);
    end;
    if not ACancelled then
    begin
      Verifier.Finish;
      ABad.AddStrings(Verifier.Bad);
      DevLogFmt(llInfo, 'Own CRC32 check: %d entries OK, %d bad', [Verifier.Verified, Verifier.Bad.Count]);
    end;
  finally
    Verifier.Free;
    Names.Free;
    Args.Free;
  end;
end;

function TfrmMain.TestSummary(ABad, ALocked: TStringList; out AOK: Boolean): string;
var
  Checked: Integer;
begin
  AOK := False;
  if FTestChecked >= 0 then
    Checked := FTestChecked
  else
    Checked := FArchive.FileCount - ALocked.Count;
  if (ABad.Count = 0) and (ALocked.Count > 0) and (Checked <= 0) then
  begin
    if (ALocked.Count = 1) and (ALocked[0] = '(file names are encrypted)') then
      Result := 'Not tested - the file names are encrypted, a password is needed'
    else
      Result := Format('Not tested - all %d files need a password', [ALocked.Count]);
    Exit;
  end;
  if ABad.Count > 0 then
    Result := Format('Test FAILED - %d problem(s)', [ABad.Count])
  else
  begin
    AOK := True;
    Result := Format('Test OK - %d file(s) checked', [Checked]);
  end;
  if ALocked.Count > 0 then
    Result := Result + Format(', %d need a password (not checked)', [ALocked.Count]);
end;

procedure TfrmMain.TestArchive;
var
  T0, Ms: QWord;
  Bad, Locked: TStringList;
  Msg, Line: string;
  Cancelled, OK: Boolean;
begin
  if not AskPassword('test') then
    Exit;
  Bad := TStringList.Create;
  Locked := TStringList.Create;
  FBusy := True;
  UpdateUI;
  Cancelled := False;
  T0 := GetTickCount64;
  try
    DevLogFmt(llInfo, 'Test archive: %s', [FArchive.FileName]);
    FOpIndex := 0;
    FOpDone := 0;
    FOpVerb := 'Testing';
    FTestChecked := -1;
    // with a password only rar_pure can open the protected entries
    if (RarPureExe <> '') and ArchiveLocked and (FPassword <> '') then
      TestPure(Bad, Locked, Cancelled)
    else if IsRar then
      TestRar(Bad, Locked, Cancelled)
    else
      TestZip(Bad, Locked, Cancelled);
  finally
    FBusy := False;
  end;
  Ms := GetTickCount64 - T0;
  UpdateUI;
  try
    if Cancelled then
    begin
      DevLog(llWarn, 'Test cancelled');
      SetProgress(0, 'Test cancelled', False, True);
    end
    else if Locked.Count > 0 then
    begin
      // not a failure by itself: the protected files simply could not be read
      for Line in Bad do
        DevLog(llError, 'Test: ' + Line);
      Msg := TestSummary(Bad, Locked, OK);
      DevLog(llWarn, Msg);
      SetProgress(IfThen(OK, 1, 0), Msg, False, True);
      if OK then
        PlayFx(feTestOk)
      else if Bad.Count > 0 then
        PlayFx(feTestFail);
      if Bad.Count > 0 then
        Msg := Msg + LineEnding + LineEnding + Copy(Bad.Text, 1, 2000);
      Msg := Msg + LineEnding + LineEnding + 'Password-protected:' + LineEnding + Copy(Locked.Text, 1, 1500);
      if Bad.Count > 0 then
        MessageDlg('Test failed', Msg, mtError, [mbOK], 0)
      else
        MessageDlg('Password-protected', Msg, mtWarning, [mbOK], 0);
    end
    else if Bad.Count = 0 then
    begin
      DevLogFmt(llTiming, 'Test OK: %d entries, %s verified in %d ms',
        [FArchive.Count, FormatSize(FArchive.TotalUncompressed), Ms]);
      DevForm.SetLastOperation('Test', Ms, FArchive.TotalCompressed, FArchive.TotalUncompressed);
      SetProgress(1, Format('Test OK - %d entries, all CRC32 match (%.2f s)', [FArchive.Count, Ms / 1000]),
        False, True);
      PlayFx(feTestOk);
      MessageDlg('Test OK', Format('All %d entries decompressed and CRC32 verified.', [FArchive.Count]),
        mtInformation, [mbOK], 0);
    end
    else
    begin
      for Msg in Bad do
        DevLog(llError, 'Test: ' + Msg);
      SetProgress(0, Format('Test FAILED - %d problem(s)', [Bad.Count]), False, True);
      PlayFx(feTestFail);
      Msg := Bad.Text;
      if Length(Msg) > 2000 then
        Msg := Copy(Msg, 1, 2000) + LineEnding + '...';
      MessageDlg('Test failed', Format('%d problem(s) found:', [Bad.Count]) + LineEnding + Msg,
        mtError, [mbOK], 0);
    end;
  finally
    Locked.Free;
    Bad.Free;
  end;
end;

procedure TfrmMain.ShowDevInfo;
begin
  DevForm.SetArchive(FArchive);
  DevForm.Show;
  DevForm.BringToFront;
end;

end.
