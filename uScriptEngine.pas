unit uScriptEngine;

{ BGRA Zip scripting: PascalScript with a library for archives, files, text,
  processes and the BGRA Zip window (no LCL dependency, so the console runner
  and the MCP server share it).

  TScriptRunner compiles and runs one script on the calling thread.
  TScriptJob runs one on its own thread and collects the output, for the editor,
  IPC, the HTTP API and MCP. The function table in the initialization section
  is the single list behind the compiler, the runtime and the reference. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, uPSCompiler, uPSRuntime, uPSUtils, uPSDebugger, uPSPreProcessor;

const
  SCRIPT_MAIN = 'main';
  SCRIPT_EXT = '.bzs';

type
  TScriptRequestEvent = function(const ARequest: string): string of object;

  { What a script can reach outside itself. The defaults suit an unattended run. }
  TScriptHost = class
  public
    procedure Output(const S: string; AIsError: Boolean); virtual; abstract;
    procedure Progress(APercent: Integer; const AText: string); virtual;
    function Input(const APrompt, ADefault: string): string; virtual;
    function Confirm(const AMessage: string): Boolean; virtual;
    procedure Message(const AText: string); virtual;
    function GuiRunning: Boolean; virtual;
    function GuiRequest(const ARequest: string; out AReply: string): Boolean; virtual;
  end;

  TScriptRunner = class
  private
    FComp: TPSPascalCompiler;
    FPP: TPSPreProcessor;
    FExec: TPSDebugExec;
    FLock: TCriticalSection;
    FBreakpoints: array of Integer;
    FLastPausedRow: Cardinal;
    FLastStep: (lsNone, lsInto, lsOver);
    FPauseRequested: Boolean;
    FPausedRow: Integer;
    FVars, FCallStack: string;
    FStopped: Boolean;
    function Compile: Boolean;
    procedure Snapshot(ARow: Cardinal);
    function IsBreakpoint(ARow: Cardinal): Boolean;
  public
    Source: string;
    FileName: string;       // '' for unsaved text; used for ScriptDir and includes
    Args: TStringList;
    Host: TScriptHost;
    Debug: Boolean;         // line tracking: breakpoints, stepping, pause (slower)
    BreakOnStart: Boolean;
    Messages: TStringList;  // compiler output
    ErrorText: string;
    ErrorRow, ErrorCol: Integer;
    ExitCode: Integer;
    constructor Create;
    destructor Destroy; override;
    function Check: Boolean;
    function Run: Boolean;
    procedure Stop;
    procedure SetBreakpoints(const ARows: array of Integer);
    procedure DebugContinue;
    procedure DebugStepInto;
    procedure DebugStepOver;
    procedure DebugPause;
    { Row where the script is stopped in the debugger, 0 when it is not. }
    function PausedRow: Integer;
    function VarsText: string;
    function CallStackText: string;
    property Stopped: Boolean read FStopped;
  end;

  TScriptDialogKind = (sdInput, sdConfirm, sdMessage);
  TScriptDialogEvent = function(AKind: TScriptDialogKind; const AText, ADefault: string): string of object;

  { TScriptJob }

  TScriptJob = class(TThread)
  private
    FLock: TCriticalSection;
    FLines: TStringList;
    FDropped: Integer;
    FHost: TScriptHost;
    FFinished: Boolean;
    FPercent: Integer;
    FProgressText: string;
    FReq, FReply: string;
    FDlgKind: TScriptDialogKind;
    FDlgText, FDlgDefault, FDlgResult: string;
    procedure AddLine(const S: string);
    procedure DoLocalRequest;
    procedure DoDialog;
    function RunDialog(AKind: TScriptDialogKind; const AText, ADefault: string): string;
  protected
    procedure Execute; override;
  public
    Runner: TScriptRunner;
    Id: Integer;                         // unique per job; a new job can reuse a freed address
    LocalHandler: TScriptRequestEvent;   // set in the GUI: gui* calls skip the pipe
    OnDialog: TScriptDialogEvent;        // nil = unattended, dialogs use their defaults
    constructor Create(const ASource, AFileName: string; AArgs: TStrings; ADebug: Boolean);
    destructor Destroy; override;
    { Lines from index AFrom on; returns the index to ask for next. }
    function GetLines(AFrom: Integer; ADest: TStrings): Integer;
    function Finished: Boolean;
    function ProgressPercent: Integer;
    function ProgressText: string;
    { Runs the script now that the fields are set. }
    procedure Go;
    { Ends the script, waits and returns; the job can then be freed. }
    procedure Cancel;
  end;

  TScriptFunc = record
    Category, Decl, Doc: string;
    Ptr: Pointer;
  end;

  TScriptMethod = record
    Decl: string;
    Ptr: Pointer;
  end;

const
  SCRIPT_CAT_GUI = 'BGRA Zip window';

var
  { What a program built on this unit calls itself; set before the first script. }
  ScriptAppName: string = 'BGRA Zip';
  ScriptFileExt: string = SCRIPT_EXT;
  ScriptDefine: string = 'BGRAZIP';

{ Extending the library, for a program's own initialization section. }
procedure ScriptAddFunction(const ACategory, ADecl: string; APtr: Pointer; const ADoc: string);
procedure ScriptRemoveFunction(const AName: string);
{ Also puts ScriptAppName in the descriptions. }
procedure ScriptRenameCategory(const AOld, ANew: string);
function ScriptMethod(const ADecl: string; APtr: Pointer): TScriptMethod;
procedure ScriptAddClass(const AName, ADoc: string; AClass: TClass; const AMethods: array of TScriptMethod);
{ For library functions: the script running on this thread, and a window command
  that raises when the window answers "ok": false. }
function ScriptRunnerNow: TScriptRunner;
function ScriptGuiDo(const AJson: string): string;

function ScriptFunctions: specialize TArray<TScriptFunc>;
{ Name of a table entry: 'function Foo(A: Integer): string;' -> 'Foo'. }
function ScriptFuncName(const ADecl: string): string;
{ Every function as text, grouped by category. }
function ScriptReferenceText: string;
function ScriptFunctionsJSON: string;

{ One job at a time per process: the editor, IPC and the API share this slot. }
var
  CurrentScriptJob: TScriptJob = nil;

{ Frees a finished job. True when the slot is free. }
function ScriptSlotFree: Boolean;
{ JSON for script_status / run_script; AFrom = first output line wanted. }
function ScriptJobStatusJSON(AJob: TScriptJob; AFrom: Integer): string;

implementation

uses
  Math, StrUtils, process, md5, sha1, crc, base64, regexpr, fpjson, jsonparser,
  LazUTF8, LazFileUtils, FileUtil,
  uPSC_std, uPSR_std, uPSC_classes, uPSR_classes,
  uArchiveBase, uArchiveOps, uZipInspector, uRarBackend, uIPC, uDevLog;

threadvar
  Cur: TScriptRunner;

{ ---------- TScriptHost defaults ---------- }

procedure TScriptHost.Progress(APercent: Integer; const AText: string);
begin
end;

function TScriptHost.Input(const APrompt, ADefault: string): string;
begin
  Result := ADefault;
end;

function TScriptHost.Confirm(const AMessage: string): Boolean;
begin
  Result := False;
end;

procedure TScriptHost.Message(const AText: string);
begin
  Output(AText, False);
end;

function TScriptHost.GuiRunning: Boolean;
var
  Pid: Cardinal;
begin
  Result := IPCServerRunning(Pid);
end;

function TScriptHost.GuiRequest(const ARequest: string; out AReply: string): Boolean;
begin
  Result := IPCRequest(ARequest, AReply, 300000);
end;

{ ---------- TArchive, as scripts see it ---------- }

type
  TScriptArchive = class
  private
    FInfo: TArchiveInfo;
    function Item(I: Integer): TArchiveEntry;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    function Count: Integer;
    function FileCount: Integer;
    function DirCount: Integer;
    function FileName: string;
    function FormatName: string;
    function FileSize: Int64;
    function TotalSize: Int64;
    function TotalPacked: Int64;
    function SavedPercent: Double;
    function EncryptedCount: Integer;
    function Warnings: string;
    function Name(I: Integer): string;
    function IsDir(I: Integer): Boolean;
    function Size(I: Integer): Int64;
    function PackedSize(I: Integer): Int64;
    function Method(I: Integer): string;
    function CRC(I: Integer): string;
    function Modified(I: Integer): TDateTime;
    function Encrypted(I: Integer): Boolean;
    function IndexOf(const AName: string): Integer;
    procedure Extract(const ADest: string);
    procedure ExtractFiles(ANames: TStrings; const ADest: string);
    function Test(AProblems: TStrings): Boolean;
    procedure List(ADest: TStrings);
  end;

constructor TScriptArchive.Create(const APath: string);
begin
  FInfo := OpenArchiveInfo(APath);
end;

destructor TScriptArchive.Destroy;
begin
  FInfo.Free;
  inherited Destroy;
end;

function TScriptArchive.Item(I: Integer): TArchiveEntry;
begin
  if (I < 0) or (I >= FInfo.Count) then
    raise Exception.CreateFmt('entry index %d out of range (0..%d)', [I, FInfo.Count - 1]);
  Result := FInfo.Entry[I];
end;

function TScriptArchive.Count: Integer; begin Result := FInfo.Count; end;
function TScriptArchive.FileCount: Integer; begin Result := FInfo.FileCount; end;
function TScriptArchive.DirCount: Integer; begin Result := FInfo.DirCount; end;
function TScriptArchive.FileName: string; begin Result := FInfo.FileName; end;
function TScriptArchive.FormatName: string; begin Result := FInfo.FormatName; end;
function TScriptArchive.FileSize: Int64; begin Result := FInfo.FileSize; end;
function TScriptArchive.TotalSize: Int64; begin Result := FInfo.TotalUncompressed; end;
function TScriptArchive.TotalPacked: Int64; begin Result := FInfo.TotalCompressed; end;
function TScriptArchive.SavedPercent: Double; begin Result := FInfo.OverallSavedPercent; end;
function TScriptArchive.EncryptedCount: Integer; begin Result := FInfo.EncryptedCount; end;
function TScriptArchive.Warnings: string; begin Result := FInfo.Warnings.Text; end;
function TScriptArchive.Name(I: Integer): string; begin Result := Item(I).FileName; end;
function TScriptArchive.IsDir(I: Integer): Boolean; begin Result := Item(I).IsDirectory; end;
function TScriptArchive.Size(I: Integer): Int64; begin Result := Item(I).UncompressedSize; end;
function TScriptArchive.PackedSize(I: Integer): Int64; begin Result := Item(I).CompressedSize; end;
function TScriptArchive.Method(I: Integer): string; begin Result := Item(I).MethodText; end;
function TScriptArchive.CRC(I: Integer): string; begin Result := IntToHex(Item(I).CRC32, 8); end;
function TScriptArchive.Modified(I: Integer): TDateTime; begin Result := Item(I).DateTime; end;
function TScriptArchive.Encrypted(I: Integer): Boolean; begin Result := Item(I).IsEncrypted; end;

function TScriptArchive.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FInfo.Count - 1 do
    if FInfo.Entry[I].FileName = AName then
      Exit(I);
  Result := -1;
end;

procedure TScriptArchive.Extract(const ADest: string);
begin
  ExtractArchiveInfo(FInfo, ADest, nil);
end;

procedure TScriptArchive.ExtractFiles(ANames: TStrings; const ADest: string);
begin
  if (ANames = nil) or (ANames.Count = 0) then
    raise Exception.Create('ExtractFiles needs at least one entry name; use Extract for all');
  ExtractArchiveInfo(FInfo, ADest, ANames);
end;

function TScriptArchive.Test(AProblems: TStrings): Boolean;
var
  Bad: TStringList;
begin
  Bad := TStringList.Create;
  try
    TestArchiveInfo(FInfo, Bad);
    Result := Bad.Count = 0;
    if AProblems <> nil then
      AProblems.AddStrings(Bad);
  finally
    Bad.Free;
  end;
end;

procedure TScriptArchive.List(ADest: TStrings);
var
  I: Integer;
begin
  for I := 0 to FInfo.Count - 1 do
    ADest.Add(FInfo.Entry[I].FileName);
end;

{ ---------- standard classes ---------- }

{ PascalScript takes the address of these overloaded FPC methods and gets the wrong
  overload, so calling them crashes. The last registration of a name wins, so
  RegisterClassFixes replaces them after the standard registration. }

type
  TStringsFix = class(TStrings)
  public
    procedure FixLoadFile(const AName: string);
    procedure FixSaveFile(const AName: string);
    procedure FixLoadStream(AStream: TStream);
    procedure FixSaveStream(AStream: TStream);
  end;

  TStreamFix = class(TStream)
  public
    function FixSeek(AOffset: Longint; AOrigin: Word): Longint;
    function FixCopyFrom(ASource: TStream; ACount: Longint): Longint;
  end;

procedure TStringsFix.FixLoadStream(AStream: TStream);
var
  S: string;
begin
  SetLength(S, AStream.Size - AStream.Position);
  if S <> '' then
    AStream.ReadBuffer(S[1], Length(S));
  Text := S;
end;

procedure TStringsFix.FixSaveStream(AStream: TStream);
var
  S: string;
begin
  S := Text;
  if S <> '' then
    AStream.WriteBuffer(S[1], Length(S));
end;

procedure TStringsFix.FixLoadFile(const AName: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(AName, fmOpenRead or fmShareDenyWrite);
  try
    FixLoadStream(F);
  finally
    F.Free;
  end;
end;

procedure TStringsFix.FixSaveFile(const AName: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(AName, fmCreate);
  try
    FixSaveStream(F);
  finally
    F.Free;
  end;
end;

function TStreamFix.FixSeek(AOffset: Longint; AOrigin: Word): Longint;
begin
  Result := Seek(Int64(AOffset), TSeekOrigin(AOrigin));
end;

function TStreamFix.FixCopyFrom(ASource: TStream; ACount: Longint): Longint;
begin
  Result := CopyFrom(ASource, Int64(ACount));
end;

function FixFileStreamCreate(AClass: Pointer; AAlloc: Byte; const AName: string; AMode: Word): TFileStream;
begin
  Result := TFileStream.Create(AName, AMode);
end;

function FixStringStreamCreate(AClass: Pointer; AAlloc: Byte; const AText: string): TStringStream;
begin
  Result := TStringStream.Create(AText);
end;

procedure RegisterClassFixes(RI: TPSRuntimeClassImporter);
begin
  with RI.Add(TStrings) do
  begin
    RegisterMethod(@TStringsFix.FixLoadFile, 'LOADFROMFILE');
    RegisterMethod(@TStringsFix.FixSaveFile, 'SAVETOFILE');
    RegisterMethod(@TStringsFix.FixLoadStream, 'LOADFROMSTREAM');
    RegisterMethod(@TStringsFix.FixSaveStream, 'SAVETOSTREAM');
  end;
  with RI.Add(TStream) do
  begin
    RegisterMethod(@TStreamFix.FixSeek, 'SEEK');
    RegisterMethod(@TStreamFix.FixCopyFrom, 'COPYFROM');
  end;
  RI.Add(TFileStream).RegisterConstructor(@FixFileStreamCreate, 'CREATE');
  RI.Add(TStringStream).RegisterConstructor(@FixStringStreamCreate, 'CREATE');
end;

{ ---------- library ---------- }

procedure ScrPrint(const S: string); begin Cur.Host.Output(S, False); end;
procedure ScrPrintErr(const S: string); begin Cur.Host.Output(S, True); end;
procedure ScrLog(const S: string); begin DevLog(llInfo, 'Script: ' + S); end;
procedure ScrProgress(APercent: Integer; const AText: string); begin Cur.Host.Progress(APercent, AText); end;
function ScrInput(const APrompt, ADefault: string): string; begin Result := Cur.Host.Input(APrompt, ADefault); end;
function ScrConfirm(const AMsg: string): Boolean; begin Result := Cur.Host.Confirm(AMsg); end;
procedure ScrMessage(const AText: string); begin Cur.Host.Message(AText); end;

function ScrFormat(const AFmt: string; const AArgs: array of const): string;
begin
  Result := Format(AFmt, AArgs);
end;

procedure ScrHalt(ACode: Integer);
begin
  Cur.ExitCode := ACode;
  Cur.Stop;
end;

function ScrStopped: Boolean; begin Result := Cur.Stopped; end;
function ScrArgCount: Integer; begin Result := Cur.Args.Count; end;

function ScrArg(I: Integer): string;
begin
  if (I < 0) or (I >= Cur.Args.Count) then
    Result := ''
  else
    Result := Cur.Args[I];
end;

function ScrScriptFile: string; begin Result := Cur.FileName; end;
function ScrScriptDir: string;
begin
  if Cur.FileName <> '' then
    Result := ExtractFilePath(Cur.FileName)
  else
    Result := IncludeTrailingPathDelimiter(GetCurrentDirUTF8);
end;
function ScrAppDir: string; begin Result := ExtractFilePath(ParamStr(0)); end;
function ScrTempDir: string; begin Result := GetTempDir(False); end;
function ScrUserDir: string; begin Result := GetUserDir; end;
function ScrCurrentDir: string; begin Result := IncludeTrailingPathDelimiter(GetCurrentDirUTF8); end;
function ScrGetEnv(const AName: string): string; begin Result := GetEnvironmentVariableUTF8(AName); end;

procedure ScrSleep(AMs: Integer);
var
  T0: QWord;
begin
  T0 := GetTickCount64;
  while (GetTickCount64 - T0 < QWord(Max(AMs, 0))) and not Cur.Stopped do
    SysUtils.Sleep(Min(20, Max(AMs, 1)));
end;

function ScrTick: Int64; begin Result := GetTickCount64; end;

{ files }

function ScrFileExists(const P: string): Boolean; begin Result := FileExistsUTF8(P); end;
function ScrDirExists(const P: string): Boolean; begin Result := DirectoryExistsUTF8(P); end;
function ScrForceDirs(const P: string): Boolean; begin Result := ForceDirectoriesUTF8(P); end;
function ScrDeleteFile(const P: string): Boolean; begin Result := DeleteFileUTF8(P); end;
function ScrDeleteDir(const P: string): Boolean; begin Result := DeleteDirectory(P, False); end;
function ScrRenameFile(const A, B: string): Boolean; begin Result := RenameFileUTF8(A, B); end;
function ScrCopyFile(const A, B: string): Boolean;
begin
  Result := CopyFile(A, B, [cffOverwriteFile, cffCreateDestDirectory]);
end;

function ScrFileSize(const P: string): Int64;
begin
  if not FileExistsUTF8(P) then
    raise Exception.Create('file not found: ' + P);
  Result := FileSizeUtf8(P);
end;

function ScrFileDate(const P: string): TDateTime;
begin
  if not FileExistsUTF8(P) then
    raise Exception.Create('file not found: ' + P);
  Result := FileDateToDateTime(FileAgeUTF8(P));
end;

function ScrReadFile(const P: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(UTF8ToSys(P), fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
end;

procedure WriteOut(const P, S: string; AAppend: Boolean);
var
  F: TFileStream;
begin
  if AAppend and FileExistsUTF8(P) then
  begin
    F := TFileStream.Create(UTF8ToSys(P), fmOpenWrite or fmShareDenyWrite);
    F.Seek(0, soEnd);
  end
  else
    F := TFileStream.Create(UTF8ToSys(P), fmCreate);
  try
    if S <> '' then
      F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
end;

procedure ScrWriteFile(const P, S: string); begin WriteOut(P, S, False); end;
procedure ScrAppendFile(const P, S: string); begin WriteOut(P, S, True); end;

function ScrFindFiles(const ADir, AMask: string; ARecursive: Boolean): TStringList;
begin
  Result := FindAllFiles(ADir, AMask, ARecursive);
end;

function ScrFindDirs(const ADir: string; ARecursive: Boolean): TStringList;
begin
  Result := FindAllDirectories(ADir, ARecursive);
end;

function ScrExtractFileName(const P: string): string; begin Result := ExtractFileName(P); end;
function ScrExtractFilePath(const P: string): string; begin Result := ExtractFilePath(P); end;
function ScrExtractFileExt(const P: string): string; begin Result := ExtractFileExt(P); end;
function ScrChangeFileExt(const P, E: string): string; begin Result := ChangeFileExt(P, E); end;
function ScrExpandFileName(const P: string): string; begin Result := ExpandFileNameUTF8(P); end;
function ScrAddSlash(const P: string): string; begin Result := IncludeTrailingPathDelimiter(P); end;
{ Int64 parameters lose their high half in PascalScript's i386 call code (Int64
  results are fine), so sizes and offsets come in as Double. }
function ScrFormatSize(N: Double): string; begin Result := FormatSize(Round(N)); end;

{ text }

function ScrReplace(const S, AOld, ANew: string): string;
begin
  Result := StringReplace(S, AOld, ANew, [rfReplaceAll]);
end;

function ScrReplaceI(const S, AOld, ANew: string): string;
begin
  Result := StringReplace(S, AOld, ANew, [rfReplaceAll, rfIgnoreCase]);
end;

function ScrStartsWith(const S, APrefix: string): Boolean;
begin
  Result := Copy(S, 1, Length(APrefix)) = APrefix;
end;

function ScrEndsWith(const S, ASuffix: string): Boolean;
begin
  Result := (Length(S) >= Length(ASuffix)) and
    (Copy(S, Length(S) - Length(ASuffix) + 1, Length(ASuffix)) = ASuffix);
end;

function ScrSplit(const S, ADelim: string): TStringList;
var
  From, P: Integer;
begin
  Result := TStringList.Create;
  if ADelim = '' then
  begin
    Result.Add(S);
    Exit;
  end;
  From := 1;
  repeat
    P := PosEx(ADelim, S, From);
    if P = 0 then
    begin
      Result.Add(Copy(S, From, MaxInt));
      Break;
    end;
    Result.Add(Copy(S, From, P - From));
    From := P + Length(ADelim);
  until False;
end;

{ dates: PascalScript's own date library registers overloaded FPC functions and
  crashes in FormatDateTime, which has an extra parameter here }

function ScrNow: TDateTime; begin Result := Now; end;
function ScrDate: TDateTime; begin Result := Date; end;
function ScrTime: TDateTime; begin Result := Time; end;
function ScrEncodeDate(Y, M, D: Word): TDateTime; begin Result := EncodeDate(Y, M, D); end;
function ScrEncodeTime(H, M, S, Ms: Word): TDateTime; begin Result := EncodeTime(H, M, S, Ms); end;
procedure ScrDecodeDate(V: TDateTime; var Y, M, D: Word); begin DecodeDate(V, Y, M, D); end;
procedure ScrDecodeTime(V: TDateTime; var H, M, S, Ms: Word); begin DecodeTime(V, H, M, S, Ms); end;
function ScrDayOfWeek(V: TDateTime): Word; begin Result := DayOfWeek(V); end;
function ScrFormatDateTime(const AFmt: string; V: TDateTime): string; begin Result := FormatDateTime(AFmt, V); end;
function ScrDateToStr(V: TDateTime): string; begin Result := DateToStr(V); end;
function ScrTimeToStr(V: TDateTime): string; begin Result := TimeToStr(V); end;
function ScrDateTimeToStr(V: TDateTime): string; begin Result := DateTimeToStr(V); end;

function ScrFloatFmt(V: Double; ADecimals: Integer): string;
begin
  Result := FloatToStrF(V, ffFixed, 18, ADecimals);
end;
function ScrUtf8Length(const S: string): Integer; begin Result := UTF8Length(S); end;

function ScrRegexMatch(const S, APattern: string): Boolean;
var
  R: TRegExpr;
begin
  R := TRegExpr.Create(APattern);
  try
    Result := R.Exec(S);
  finally
    R.Free;
  end;
end;

function ScrRegexFind(const S, APattern: string; AGroup: Integer): string;
var
  R: TRegExpr;
begin
  Result := '';
  R := TRegExpr.Create(APattern);
  try
    if R.Exec(S) then
      Result := R.Match[AGroup];
  finally
    R.Free;
  end;
end;

function ScrRegexReplace(const S, APattern, AReplace: string): string;
var
  R: TRegExpr;
begin
  R := TRegExpr.Create(APattern);
  try
    Result := R.Replace(S, AReplace, True);
  finally
    R.Free;
  end;
end;

{ data }

function ScrMD5Str(const S: string): string; begin Result := MD5Print(MD5String(S)); end;
function ScrMD5File(const P: string): string; begin Result := MD5Print(MD5File(UTF8ToSys(P))); end;
function ScrSHA1Str(const S: string): string; begin Result := SHA1Print(SHA1String(S)); end;
function ScrSHA1File(const P: string): string; begin Result := SHA1Print(SHA1File(UTF8ToSys(P))); end;

function ScrCRC32Str(const S: string): string;
var
  C: Cardinal;
begin
  C := crc32(0, nil, 0);
  if S <> '' then
    C := crc32(C, PByte(@S[1]), Length(S));
  Result := IntToHex(C, 8);
end;

function ScrCRC32File(const P: string): string;
var
  F: TFileStream;
  Buf: array[0..65535] of Byte;
  N: Integer;
  C: Cardinal;
begin
  C := crc32(0, nil, 0);
  F := TFileStream.Create(UTF8ToSys(P), fmOpenRead or fmShareDenyWrite);
  try
    repeat
      N := F.Read(Buf, SizeOf(Buf));
      if N > 0 then
        C := crc32(C, @Buf[0], N);
    until N <= 0;
  finally
    F.Free;
  end;
  Result := IntToHex(C, 8);
end;

function ScrBase64Enc(const S: string): string; begin Result := EncodeStringBase64(S); end;
function ScrBase64Dec(const S: string): string; begin Result := DecodeStringBase64(S); end;
function ScrJsonQuote(const S: string): string; begin Result := JSONQuote(S); end;

function ScrJsonGet(const AJson, APath: string): string;
var
  D, V: TJSONData;
begin
  Result := '';
  D := ParseJSON(AJson);
  if D = nil then      // empty text
    Exit;
  try
    V := D.FindPath(APath);
    if V <> nil then
      if V.JSONType in [jtArray, jtObject] then
        Result := V.AsJSON
      else if V.JSONType <> jtNull then
        Result := V.AsString;
  finally
    D.Free;
  end;
end;

function ScrHexDump(const P: string; AOffset: Double; ALength: Integer): string;
var
  Ofs: Int64;
begin
  if not FileExistsUTF8(P) then
    raise Exception.Create('file not found: ' + P);
  Ofs := Round(AOffset);
  Result := HexDump(ReadFileRegion(P, Ofs, EnsureRange(ALength, 1, 1024 * 1024)), Ofs);
end;

{ archives }

function ScrOpenArchive(const P: string): TScriptArchive; begin Result := TScriptArchive.Create(P); end;

function ScrIsArchive(const P: string): Boolean;
var
  A: TArchiveInfo;
begin
  Result := False;
  if not FileExistsUTF8(P) then
    Exit;
  try
    A := OpenArchiveInfo(P);
    A.Free;
    Result := True;
  except
    on Exception do
      Result := False;
  end;
end;

procedure ScrExtract(const P, ADest: string);
var
  A: TArchiveInfo;
begin
  A := OpenArchiveInfo(P);
  try
    ExtractArchiveInfo(A, ADest, nil);
  finally
    A.Free;
  end;
end;

function ScrTestArchive(const P: string; AProblems: TStrings): Boolean;
var
  A: TScriptArchive;
begin
  A := TScriptArchive.Create(P);
  try
    Result := A.Test(AProblems);
  finally
    A.Free;
  end;
end;

function ScrCreateZip(const AOut: string; ASources: TStrings; const ALevel: string; AOverwrite: Boolean): Integer;
var
  Total: Int64;
begin
  CreateZipFile(AOut, ASources, ALevel, AOverwrite, Result, Total);
end;

procedure ScrCreateRar(const AOut: string; ASources: TStrings; const ALevel: string; AOverwrite: Boolean);
begin
  CreateRarFile(AOut, ASources, ALevel, AOverwrite);
end;

function ScrRarTool(ACreate: Boolean): string;
var
  T: TRarTool;
begin
  Result := '';
  if ACreate then
  begin
    if FindRarCreator(T) then
      Result := T.Exe;
  end
  else if FindRarExtractor(T) then
    Result := T.Exe;
end;

{ processes }

function ScrRunCommand(const AExe: string; AArgs: TStrings; var AOutput: string): Integer;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  N: Integer;
  Busy: Boolean;
  S: string;
begin
  AOutput := '';
  P := TProcess.Create(nil);
  try
    P.Executable := AExe;
    if AArgs <> nil then
      P.Parameters.Assign(AArgs);
    P.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    P.Execute;
    repeat
      Busy := False;
      while P.Output.NumBytesAvailable > 0 do
      begin
        N := P.Output.Read(Buf, SizeOf(Buf));
        if N <= 0 then
          Break;
        SetString(S, PChar(@Buf[0]), N);
        AOutput := AOutput + S;
        Busy := True;
      end;
      if Cur.Stopped then
      begin
        P.Terminate(1);
        Break;
      end;
      if not Busy then
      begin
        if not P.Running then
          Break;
        SysUtils.Sleep(10);
      end;
    until False;
    Result := P.ExitStatus;
  finally
    P.Free;
  end;
end;

{ the window, over IPC }

function ScrGuiRunning: Boolean; begin Result := Cur.Host.GuiRunning; end;

function ScrGuiCall(const AJson: string): string;
begin
  if not Cur.Host.GuiRequest(AJson, Result) then
    raise Exception.Create(ScriptAppName + ' window is not running');
end;

{ Sends a command; raises when the window answers "ok": false. }
function GuiDo(const AJson: string): string;
var
  Err: string;
begin
  Result := ScrGuiCall(AJson);
  if ScrJsonGet(Result, 'ok') <> 'True' then
  begin
    Err := ScrJsonGet(Result, 'error');
    if Err = '' then
      Err := 'request failed';
    raise Exception.Create(ScriptAppName + ': ' + Err);
  end;
end;

function ScrGuiStatus: string; begin Result := GuiDo('{"cmd":"status"}'); end;
procedure ScrGuiOpen(const P: string); begin GuiDo('{"cmd":"open","path":' + JSONQuote(P) + '}'); end;
procedure ScrGuiNew; begin GuiDo('{"cmd":"new"}'); end;
procedure ScrGuiShow; begin GuiDo('{"cmd":"show"}'); end;
procedure ScrGuiExtract(const ADest: string); begin GuiDo('{"cmd":"extract","destination":' + JSONQuote(ADest) + '}'); end;
function ScrGuiTest: Boolean;
begin
  Result := ScrJsonGet(GuiDo('{"cmd":"test"}'), 'passed') = 'True';
end;
procedure ScrGuiEffect(const AName: string); begin GuiDo('{"cmd":"effect","event":' + JSONQuote(AName) + ',"force":true}'); end;
procedure ScrGuiDeveloper(ATab: Integer); begin GuiDo('{"cmd":"dev","tab":' + IntToStr(ATab) + '}'); end;
function ScrGuiLog(ALines: Integer): string;
begin
  Result := ScrJsonGet(GuiDo('{"cmd":"log","lines":' + IntToStr(ALines) + '}'), 'lines');
end;

{ ---------- function table ---------- }

var
  Funcs: specialize TArray<TScriptFunc>;

procedure Add(const ACategory, ADecl: string; APtr: Pointer; const ADoc: string);
var
  N: Integer;
begin
  N := Length(Funcs);
  SetLength(Funcs, N + 1);
  Funcs[N].Category := ACategory;
  Funcs[N].Decl := ADecl;
  Funcs[N].Ptr := APtr;
  Funcs[N].Doc := ADoc;
end;

procedure BuildTable;
const
  COut = 'Output'; CRun = 'Script'; CFile = 'Files'; CText = 'Text'; CData = 'Data';
  CArc = 'Archives'; CProc = 'Processes'; CGui = SCRIPT_CAT_GUI;
begin
  Add(COut, 'procedure Print(const S: string);', @ScrPrint, 'Write a line to the output');
  Add(COut, 'procedure Writeln(const S: string);', @ScrPrint, 'Same as Print');
  Add(COut, 'procedure PrintErr(const S: string);', @ScrPrintErr, 'Write a line to the error output');
  Add(COut, 'procedure Log(const S: string);', @ScrLog, 'Write to the developer log');
  Add(COut, 'procedure Progress(Percent: Integer; const Text: string);', @ScrProgress, 'Show progress, 0..100');
  Add(COut, 'function Input(const Prompt, Default: string): string;', @ScrInput, 'Ask for text. Unattended runs get Default');
  Add(COut, 'function Confirm(const Msg: string): Boolean;', @ScrConfirm, 'Ask yes/no. Unattended runs get False');
  Add(COut, 'procedure Message(const Text: string);', @ScrMessage, 'Show a message. Unattended runs print it');

  Add(CRun, 'procedure Halt(Code: Integer);', @ScrHalt, 'End the script with an exit code');
  Add(CRun, 'function Stopped: Boolean;', @ScrStopped, 'True after Stop was requested');
  Add(CRun, 'function ArgCount: Integer;', @ScrArgCount, 'Number of script arguments');
  Add(CRun, 'function Arg(I: Integer): string;', @ScrArg, 'Script argument I (from 0), '''' if missing');
  Add(CRun, 'function ScriptFile: string;', @ScrScriptFile, 'Path of this script, '''' if unsaved');
  Add(CRun, 'function ScriptDir: string;', @ScrScriptDir, 'Folder of this script');
  Add(CRun, 'function AppDir: string;', @ScrAppDir, 'Folder of the running program');
  Add(CRun, 'function TempDir: string;', @ScrTempDir, 'Temporary folder');
  Add(CRun, 'function UserDir: string;', @ScrUserDir, 'User profile folder');
  Add(CRun, 'function CurrentDir: string;', @ScrCurrentDir, 'Current folder');
  Add(CRun, 'function GetEnv(const Name: string): string;', @ScrGetEnv, 'Environment variable');
  Add(CRun, 'procedure Sleep(Ms: Integer);', @ScrSleep, 'Wait; ends early on Stop');
  Add(CRun, 'function Tick: Int64;', @ScrTick, 'Milliseconds since Windows started');

  Add(CFile, 'function FileExists(const Path: string): Boolean;', @ScrFileExists, '');
  Add(CFile, 'function DirExists(const Path: string): Boolean;', @ScrDirExists, '');
  Add(CFile, 'function ForceDirs(const Path: string): Boolean;', @ScrForceDirs, 'Create a folder and its parents');
  Add(CFile, 'function DeleteFile(const Path: string): Boolean;', @ScrDeleteFile, 'Delete permanently');
  Add(CFile, 'function DeleteDir(const Path: string): Boolean;', @ScrDeleteDir, 'Delete a folder and its contents permanently');
  Add(CFile, 'function RenameFile(const OldPath, NewPath: string): Boolean;', @ScrRenameFile, 'Rename or move');
  Add(CFile, 'function CopyFile(const Source, Dest: string): Boolean;', @ScrCopyFile, 'Overwrites; creates the folder');
  Add(CFile, 'function FileSize(const Path: string): Int64;', @ScrFileSize, '');
  Add(CFile, 'function FileDate(const Path: string): TDateTime;', @ScrFileDate, 'Last modified');
  Add(CFile, 'function ReadFile(const Path: string): string;', @ScrReadFile, 'Whole file');
  Add(CFile, 'procedure WriteFile(const Path, Text: string);', @ScrWriteFile, 'Replace the file');
  Add(CFile, 'procedure AppendFile(const Path, Text: string);', @ScrAppendFile, 'Add to the end');
  Add(CFile, 'function FindFiles(const Dir, Mask: string; Recursive: Boolean): TStringList;', @ScrFindFiles, 'Mask like *.txt;*.log. Free the list');
  Add(CFile, 'function FindDirs(const Dir: string; Recursive: Boolean): TStringList;', @ScrFindDirs, 'Free the list');
  Add(CFile, 'function ExtractFileName(const Path: string): string;', @ScrExtractFileName, '');
  Add(CFile, 'function ExtractFilePath(const Path: string): string;', @ScrExtractFilePath, '');
  Add(CFile, 'function ExtractFileExt(const Path: string): string;', @ScrExtractFileExt, '');
  Add(CFile, 'function ChangeFileExt(const Path, Ext: string): string;', @ScrChangeFileExt, '');
  Add(CFile, 'function ExpandFileName(const Path: string): string;', @ScrExpandFileName, '');
  Add(CFile, 'function AddSlash(const Path: string): string;', @ScrAddSlash, 'Add a trailing backslash');
  Add(CFile, 'function FormatSize(Bytes: Double): string;', @ScrFormatSize, 'Like 1.2 MB');

  Add(CText, 'function Format(const Fmt: string; const Args: array of const): string;', @ScrFormat, 'Format(''%d files'', [N])');
  Add(CText, 'function Replace(const S, OldText, NewText: string): string;', @ScrReplace, 'All occurrences');
  Add(CText, 'function ReplaceI(const S, OldText, NewText: string): string;', @ScrReplaceI, 'Ignoring case');
  Add(CText, 'function StartsWith(const S, Prefix: string): Boolean;', @ScrStartsWith, '');
  Add(CText, 'function EndsWith(const S, Suffix: string): Boolean;', @ScrEndsWith, '');
  Add(CText, 'function Split(const S, Delim: string): TStringList;', @ScrSplit, 'Free the list');
  Add(CText, 'function Now: TDateTime;', @ScrNow, '');
  Add(CText, 'function Date: TDateTime;', @ScrDate, '');
  Add(CText, 'function Time: TDateTime;', @ScrTime, '');
  Add(CText, 'function EncodeDate(Year, Month, Day: Word): TDateTime;', @ScrEncodeDate, '');
  Add(CText, 'function EncodeTime(Hour, Min, Sec, MSec: Word): TDateTime;', @ScrEncodeTime, '');
  Add(CText, 'procedure DecodeDate(V: TDateTime; var Year, Month, Day: Word);', @ScrDecodeDate, '');
  Add(CText, 'procedure DecodeTime(V: TDateTime; var Hour, Min, Sec, MSec: Word);', @ScrDecodeTime, '');
  Add(CText, 'function DayOfWeek(V: TDateTime): Word;', @ScrDayOfWeek, '1 = Sunday');
  Add(CText, 'function FormatDateTime(const Fmt: string; V: TDateTime): string;', @ScrFormatDateTime, 'FormatDateTime(''yyyy-mm-dd'', Now)');
  Add(CText, 'function DateToStr(V: TDateTime): string;', @ScrDateToStr, '');
  Add(CText, 'function TimeToStr(V: TDateTime): string;', @ScrTimeToStr, '');
  Add(CText, 'function DateTimeToStr(V: TDateTime): string;', @ScrDateTimeToStr, '');
  Add(CText, 'function FloatFmt(V: Double; Decimals: Integer): string;', @ScrFloatFmt, '');
  Add(CText, 'function Utf8Length(const S: string): Integer;', @ScrUtf8Length, 'Characters, not bytes');
  Add(CText, 'function RegexMatch(const S, Pattern: string): Boolean;', @ScrRegexMatch, '');
  Add(CText, 'function RegexFind(const S, Pattern: string; Group: Integer): string;', @ScrRegexFind, 'Group 0 = whole match');
  Add(CText, 'function RegexReplace(const S, Pattern, Replacement: string): string;', @ScrRegexReplace, '$1 = group 1');

  Add(CData, 'function MD5Str(const S: string): string;', @ScrMD5Str, '');
  Add(CData, 'function MD5File(const Path: string): string;', @ScrMD5File, '');
  Add(CData, 'function SHA1Str(const S: string): string;', @ScrSHA1Str, '');
  Add(CData, 'function SHA1File(const Path: string): string;', @ScrSHA1File, '');
  Add(CData, 'function CRC32Str(const S: string): string;', @ScrCRC32Str, '');
  Add(CData, 'function CRC32File(const Path: string): string;', @ScrCRC32File, '');
  Add(CData, 'function Base64Encode(const S: string): string;', @ScrBase64Enc, '');
  Add(CData, 'function Base64Decode(const S: string): string;', @ScrBase64Dec, '');
  Add(CData, 'function JsonQuote(const S: string): string;', @ScrJsonQuote, 'Quoted JSON string');
  Add(CData, 'function JsonGet(const Json, Path: string): string;', @ScrJsonGet, 'JsonGet(J, ''a.b[0]''), '''' if missing');
  Add(CData, 'function HexDump(const Path: string; Offset: Double; Count: Integer): string;', @ScrHexDump, 'Hex + ASCII');

  Add(CArc, 'function OpenArchive(const Path: string): TArchive;', @ScrOpenArchive, 'ZIP or RAR. Free it');
  Add(CArc, 'function IsArchive(const Path: string): Boolean;', @ScrIsArchive, 'Readable as ZIP or RAR');
  Add(CArc, 'procedure ExtractArchive(const Path, Dest: string);', @ScrExtract, 'Everything; overwrites');
  Add(CArc, 'function TestArchive(const Path: string; Problems: TStrings): Boolean;', @ScrTestArchive, 'Problems may be nil');
  Add(CArc, 'function CreateZip(const Output: string; Sources: TStrings; const Level: string; Overwrite: Boolean): Integer;', @ScrCreateZip, 'Level: store, fastest, default, maximum. Returns the file count');
  Add(CArc, 'procedure CreateRar(const Output: string; Sources: TStrings; const Level: string; Overwrite: Boolean);', @ScrCreateRar, 'Needs WinRAR''s rar.exe');
  Add(CArc, 'function RarTool(ForCreate: Boolean): string;', @ScrRarTool, 'Path of the RAR tool in use, '''' if none');

  Add(CProc, 'function RunCommand(const Exe: string; Args: TStrings; var Output: string): Integer;', @ScrRunCommand, 'Wait for a program, return its exit code. Args may be nil');

  Add(CGui, 'function GuiRunning: Boolean;', @ScrGuiRunning, 'Is a BGRA Zip window open');
  Add(CGui, 'function GuiCall(const Json: string): string;', @ScrGuiCall, 'Any IPC command, raw JSON reply');
  Add(CGui, 'function GuiStatus: string;', @ScrGuiStatus, 'Status as JSON');
  Add(CGui, 'procedure GuiOpen(const Path: string);', @ScrGuiOpen, 'Open an archive in the window');
  Add(CGui, 'procedure GuiNew;', @ScrGuiNew, 'Start a new archive list');
  Add(CGui, 'procedure GuiShow;', @ScrGuiShow, 'Bring the window to the front');
  Add(CGui, 'procedure GuiExtract(const Dest: string);', @ScrGuiExtract, 'Extract what the window has open');
  Add(CGui, 'function GuiTest: Boolean;', @ScrGuiTest, 'Test what the window has open');
  Add(CGui, 'procedure GuiDeveloper(Tab: Integer);', @ScrGuiDeveloper, 'Developer window on a tab, 0..5');
  Add(CGui, 'function GuiLog(Lines: Integer): string;', @ScrGuiLog, 'Last log lines as a JSON array');
  Add(CGui, 'procedure GuiEffect(const Event: string);', @ScrGuiEffect, 'Play an effect: start, open, add, remove, progress, create, extract, drag, test_ok, test_fail, error, script_ok, script_fail');
end;

type
  TScriptClassDef = record
    Name, Doc: string;
    Cls: TClass;
    Methods: array of TScriptMethod;
  end;

var
  ExtraClasses: array of TScriptClassDef;

procedure ScriptAddFunction(const ACategory, ADecl: string; APtr: Pointer; const ADoc: string);
begin
  Add(ACategory, ADecl, APtr, ADoc);
end;

procedure ScriptRemoveFunction(const AName: string);
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to High(Funcs) do
    if not SameText(ScriptFuncName(Funcs[I].Decl), AName) then
    begin
      Funcs[N] := Funcs[I];
      Inc(N);
    end;
  SetLength(Funcs, N);
end;

procedure ScriptRenameCategory(const AOld, ANew: string);
var
  I: Integer;
begin
  for I := 0 to High(Funcs) do
    if Funcs[I].Category = AOld then
    begin
      Funcs[I].Category := ANew;
      Funcs[I].Doc := StringReplace(Funcs[I].Doc, 'BGRA Zip', ScriptAppName, [rfReplaceAll]);
    end;
end;

function ScriptMethod(const ADecl: string; APtr: Pointer): TScriptMethod;
begin
  Result.Decl := ADecl;
  Result.Ptr := APtr;
end;

procedure ScriptAddClass(const AName, ADoc: string; AClass: TClass; const AMethods: array of TScriptMethod);
var
  I, N: Integer;
begin
  N := Length(ExtraClasses);
  SetLength(ExtraClasses, N + 1);
  ExtraClasses[N].Name := AName;
  ExtraClasses[N].Doc := ADoc;
  ExtraClasses[N].Cls := AClass;
  SetLength(ExtraClasses[N].Methods, Length(AMethods));
  for I := 0 to High(AMethods) do
    ExtraClasses[N].Methods[I] := AMethods[I];
end;

function ScriptRunnerNow: TScriptRunner;
begin
  Result := Cur;
end;

function ScriptGuiDo(const AJson: string): string;
begin
  Result := GuiDo(AJson);
end;

function ScriptFunctions: specialize TArray<TScriptFunc>;
begin
  Result := Funcs;
end;

function ScriptFuncName(const ADecl: string): string;
var
  P, E: Integer;
begin
  P := Pos(' ', ADecl) + 1;
  E := P;
  while (E <= Length(ADecl)) and not (ADecl[E] in ['(', ':', ';']) do
    Inc(E);
  Result := Copy(ADecl, P, E - P);
end;

const
  ArchiveMethods: array[0..23] of string = (
    'function Count: Integer;', 'function FileCount: Integer;', 'function DirCount: Integer;',
    'function FileName: string;', 'function FormatName: string;', 'function FileSize: Int64;',
    'function TotalSize: Int64;', 'function TotalPacked: Int64;', 'function SavedPercent: Double;',
    'function EncryptedCount: Integer;', 'function Warnings: string;',
    'function Name(I: Integer): string;', 'function IsDir(I: Integer): Boolean;',
    'function Size(I: Integer): Int64;', 'function PackedSize(I: Integer): Int64;',
    'function Method(I: Integer): string;', 'function CRC(I: Integer): string;',
    'function Modified(I: Integer): TDateTime;', 'function Encrypted(I: Integer): Boolean;',
    'function IndexOf(const AName: string): Integer;', 'procedure Extract(const ADest: string);',
    'procedure ExtractFiles(ANames: TStrings; const ADest: string);',
    'function Test(AProblems: TStrings): Boolean;', 'procedure List(ADest: TStrings);');

function ScriptReferenceText: string;
var
  S: TStringList;
  I, J: Integer;
  LastCat: string;
begin
  S := TStringList.Create;
  try
    LastCat := '';
    for I := 0 to High(Funcs) do
    begin
      if Funcs[I].Category <> LastCat then
      begin
        LastCat := Funcs[I].Category;
        S.Add('');
        S.Add(UpperCase(LastCat));
      end;
      S.Add('  ' + Funcs[I].Decl);
      if Funcs[I].Doc <> '' then
        S.Add('      ' + Funcs[I].Doc);
    end;
    S.Add('');
    S.Add('TARCHIVE (from OpenArchive; I counts from 0)');
    for I := 0 to High(ArchiveMethods) do
      S.Add('  ' + ArchiveMethods[I]);
    for J := 0 to High(ExtraClasses) do
    begin
      S.Add('');
      S.Add(UpperCase(ExtraClasses[J].Name) + ' (' + ExtraClasses[J].Doc + ')');
      for I := 0 to High(ExtraClasses[J].Methods) do
        S.Add('  ' + ExtraClasses[J].Methods[I].Decl);
    end;
    S.Add('');
    S.Add('ALSO AVAILABLE');
    S.Add('  Pascal syntax with try/except, classes TStrings, TStringList, TStream, TFileStream,');
    S.Add('  TMemoryStream; IntToStr, StrToInt, Copy, Pos, Trim, UpperCase, Now, FormatDateTime...');
    S.Add('  {$I other' + ScriptFileExt + '} includes a file from the script''s folder.');
    Result := S.Text;
  finally
    S.Free;
  end;
end;

function ScriptFunctionsJSON: string;
var
  Arr: TJSONArray;
  O: TJSONObject;
  I, J: Integer;
begin
  Arr := TJSONArray.Create;
  try
    for I := 0 to High(Funcs) do
    begin
      O := TJSONObject.Create;
      O.Add('name', ScriptFuncName(Funcs[I].Decl));
      O.Add('category', Funcs[I].Category);
      O.Add('declaration', Funcs[I].Decl);
      O.Add('doc', Funcs[I].Doc);
      Arr.Add(O);
    end;
    for I := 0 to High(ArchiveMethods) do
    begin
      O := TJSONObject.Create;
      O.Add('name', 'TArchive.' + ScriptFuncName(ArchiveMethods[I]));
      O.Add('category', 'TArchive');
      O.Add('declaration', ArchiveMethods[I]);
      O.Add('doc', '');
      Arr.Add(O);
    end;
    for J := 0 to High(ExtraClasses) do
      for I := 0 to High(ExtraClasses[J].Methods) do
      begin
        O := TJSONObject.Create;
        O.Add('name', ExtraClasses[J].Name + '.' + ScriptFuncName(ExtraClasses[J].Methods[I].Decl));
        O.Add('category', ExtraClasses[J].Name);
        O.Add('declaration', ExtraClasses[J].Methods[I].Decl);
        O.Add('doc', '');
        Arr.Add(O);
      end;
    Result := Arr.AsJSON;
  finally
    Arr.Free;
  end;
end;

{ ---------- compile ---------- }

function CompUses(Sender: TPSPascalCompiler; const Name: tbtstring): Boolean;
var
  Cl: TPSCompileTimeClass;
  I, J: Integer;
begin
  Result := Name = 'SYSTEM';
  if not Result then
  begin
    Sender.MakeError('', ecUnknownIdentifier, Name);
    Exit;
  end;
  SIRegister_Std(Sender);
  SIRegister_Classes(Sender, True);
  Sender.AddType('TDateTime', btDouble).ExportName := True;
  Cl :=Sender.AddClassN(Sender.FindClass('TObject'), 'TArchive');
  for I := 0 to High(ArchiveMethods) do
    Cl.RegisterMethod(ArchiveMethods[I]);
  for J := 0 to High(ExtraClasses) do
  begin
    Cl := Sender.AddClassN(Sender.FindClass('TObject'), ExtraClasses[J].Name);
    for I := 0 to High(ExtraClasses[J].Methods) do
      Cl.RegisterMethod(ExtraClasses[J].Methods[I].Decl);
  end;
  for I := 0 to High(Funcs) do
    Sender.AddDelphiFunction(Funcs[I].Decl);
end;

function PPNeedFile(Sender: TPSPreProcessor; const CallingFileName: tbtstring;
  var FileName, Output: tbtstring): Boolean;
var
  R: TScriptRunner;
  P: string;
begin
  R := TScriptRunner(Sender.Id);
  if FilenameIsAbsolute(FileName) then
    P := FileName
  else if R.FileName <> '' then
    P := ExtractFilePath(R.FileName) + FileName
  else
    P := ExpandFileNameUTF8(FileName);
  Result := FileExistsUTF8(P);
  if Result then
    Output := ScrReadFile(P);
end;

procedure CompTranslate(Sender: TPSPascalCompiler; var Pos, Row, Col: Cardinal; var Name: tbtstring);
var
  Res: TPSLineInfoResults;
begin
  if TScriptRunner(Sender.ID).FPP.CurrentLineInfo.GetLineInfo(Name, Pos, Res) then
  begin
    Pos := Res.Pos;
    Row := Res.Row;
    Col := Res.Col;
    Name := Res.Name;
  end;
end;

constructor TScriptRunner.Create;
begin
  Args := TStringList.Create;
  Messages := TStringList.Create;
  FLock := TCriticalSection.Create;
end;

destructor TScriptRunner.Destroy;
begin
  FLock.Free;
  Messages.Free;
  Args.Free;
  inherited Destroy;
end;

function TScriptRunner.Compile: Boolean;
var
  Data: tbtstring;
  I: Integer;
  M: TPSPascalCompilerMessage;
  Line: string;
begin
  Result := False;
  Messages.Clear;
  ErrorText := '';
  ErrorRow := 0;
  ErrorCol := 0;
  FreeAndNil(FComp);
  FreeAndNil(FPP);
  FComp := TPSPascalCompiler.Create;
  FComp.ID := Self;
  FComp.OnUses := @CompUses;
  FComp.BooleanShortCircuit := True;
  FComp.AllowNoBegin := True;
  FComp.AllowNoEnd := True;
  FComp.OnTranslateLineInfo := @CompTranslate;
  FPP := TPSPreProcessor.Create;
  FPP.Id := Self;
  FPP.OnNeedFile := @PPNeedFile;
  FPP.Defines.Add(ScriptDefine);
  FPP.MainFile := Source;
  FPP.MainFileName := SCRIPT_MAIN;
  try
    FPP.PreProcess(SCRIPT_MAIN, Data);
    Result := FComp.Compile(Data);
    FPP.AdjustMessages(FComp);
  except
    on E: Exception do
    begin
      Result := False;
      ErrorText := E.Message;
      Messages.Add(E.Message);
      Exit;
    end;
  end;
  for I := 0 to FComp.MsgCount - 1 do
  begin
    M := FComp.Msg[I];
    Line := M.ShortMessageToString;
    if M.ModuleName <> SCRIPT_MAIN then
      Line := Format('%s(%d:%d): %s', [M.ModuleName, M.Row, M.Col, Line])
    else
      Line := Format('(%d:%d): %s', [M.Row, M.Col, Line]);
    Line := M.ErrorType + ' ' + Line;
    Messages.Add(Line);
    if (ErrorText = '') and (M is TPSPascalCompilerError) then
    begin
      ErrorText := Line;
      if M.ModuleName = SCRIPT_MAIN then
      begin
        ErrorRow := M.Row;
        ErrorCol := M.Col;
      end;
    end;
  end;
end;

function TScriptRunner.Check: Boolean;
begin
  Result := Compile;
  FreeAndNil(FComp);
  FreeAndNil(FPP);
end;

{ ---------- debugger hooks (script thread) ---------- }

function TScriptRunner.IsBreakpoint(ARow: Cardinal): Boolean;
var
  I: Integer;
begin
  Result := False;
  FLock.Enter;
  try
    for I := 0 to High(FBreakpoints) do
      if FBreakpoints[I] = Integer(ARow) then
        Exit(True);
  finally
    FLock.Leave;
  end;
end;

procedure TScriptRunner.Snapshot(ARow: Cardinal);
var
  L: TStringList;
  I: Integer;
  N: Cardinal;
  Names: TIfStringList;

  function Show(V: PIFVariant): string;
  begin
    try
      Result := PSVariantToString(NewTPSVariantIFC(V, False), '');
    except
      on Exception do
        Result := '?';
    end;
  end;

begin
  L := TStringList.Create;
  try
    Names := FExec.CurrentProcParams;
    if Names <> nil then
      for I := 0 to Names.Count - 1 do
        L.Add(Names[I] + ' = ' + Show(FExec.GetProcParam(I)));
    Names := FExec.CurrentProcVars;
    if Names <> nil then
      for I := 0 to Names.Count - 1 do
        L.Add(Names[I] + ' = ' + Show(FExec.GetProcVar(I)));
    Names := FExec.GlobalVarNames;
    if Names <> nil then
      for I := 0 to Names.Count - 1 do
        L.Add('(global) ' + Names[I] + ' = ' + Show(FExec.GetGlobalVar(I)));
    FLock.Enter;
    try
      FVars := L.Text;
      // GetCallStack lists the callers but neither this procedure nor the main body
      FCallStack := '';
      N := FExec.GetCurrentProcNo;
      if (FExec.ProcNames <> nil) and (N < Cardinal(FExec.ProcNames.Count)) then
        FCallStack := FExec.ProcNames[N];
      if FCallStack = '' then
        FCallStack := '(main)'
      else
      begin
        N := 0;
        try
          FCallStack := Trim(FCallStack + FExec.GetCallStack(N)) + LineEnding + '(main)';
        except
          on Exception do
            FCallStack := FCallStack + LineEnding + '(main)';
        end;
      end;
      FPausedRow := ARow;
      FPauseRequested := False;
    finally
      FLock.Leave;
    end;
  finally
    L.Free;
  end;
end;

procedure ExecSourceLine(Sender: TPSDebugExec; const Name: tbtstring; Position, Row, Col: Cardinal);
var
  R: TScriptRunner;
  IsMain: Boolean;
begin
  R := TScriptRunner(Sender.Id);
  IsMain := Name = SCRIPT_MAIN;
  if IsMain and (Row <> R.FLastPausedRow) and (Sender.DebugMode <> dmPaused) and R.IsBreakpoint(Row) then
    Sender.Pause;
  if Sender.DebugMode = dmPaused then
  begin
    if IsMain and ((Row <> R.FLastPausedRow) or R.FPauseRequested) then
    begin
      R.Snapshot(Row);
      R.FLastPausedRow := Row;
    end
    else if not R.FPauseRequested then
      // another statement on the line just paused at, or an included file: keep going as asked
      case R.FLastStep of
        lsInto: Sender.StepInto;
        lsOver: Sender.StepOver;
      else
        Sender.Run;
      end;
  end
  else if IsMain and (Row <> R.FLastPausedRow) then
    R.FLastPausedRow := 0;
end;

{ Runs while paused. A pause asked for between two source positions gets no
  OnSourceLine, so the row is worked out here; otherwise nothing would show it. }
procedure ExecIdle(Sender: TPSDebugExec);
var
  R: TScriptRunner;
  P, Row, Col: Cardinal;
  Fn: tbtstring;
begin
  R := TScriptRunner(Sender.Id);
  R.FLock.Enter;
  try
    if (R.FPausedRow = 0) and (Sender.DebugMode = dmPaused) then
    begin
      P := 0; Row := 0; Col := 0; Fn := '';
      Sender.TranslatePositionEx(Sender.GetCurrentProcNo, Sender.GetCurrentPosition, P, Row, Col, Fn);
      R.Snapshot(Max(Row, 1));
      R.FLastPausedRow := Row;
    end;
  finally
    R.FLock.Leave;
  end;
  SysUtils.Sleep(10);
end;

function TScriptRunner.Run: Boolean;
var
  RI: TPSRuntimeClassImporter;
  Rc: TPSRuntimeClass;
  Data, Dbg: tbtstring;
  I, J: Integer;
  P, R, C: Cardinal;
  Fn: tbtstring;
  Saved: TScriptRunner;
begin
  Result := False;
  ExitCode := 0;
  FStopped := False;
  if not Compile then
  begin
    ExitCode := 2;
    FreeAndNil(FComp);
    FreeAndNil(FPP);
    Exit;
  end;
  Data := '';
  Dbg := '';
  FComp.GetOutput(Data);
  FComp.GetDebugOutput(Dbg);
  FreeAndNil(FComp);
  FreeAndNil(FPP);

  Saved := Cur;
  Cur := Self;
  RI := TPSRuntimeClassImporter.Create;
  FExec := TPSDebugExec.Create;
  try
    FExec.Id := Self;
    RIRegister_Std(RI);
    RIRegister_Classes(RI, True);
    RegisterClassFixes(RI);
    Rc := RI.Add2(TScriptArchive, 'TARCHIVE');
    Rc.RegisterMethod(@TScriptArchive.Count, 'COUNT');
    Rc.RegisterMethod(@TScriptArchive.FileCount, 'FILECOUNT');
    Rc.RegisterMethod(@TScriptArchive.DirCount, 'DIRCOUNT');
    Rc.RegisterMethod(@TScriptArchive.FileName, 'FILENAME');
    Rc.RegisterMethod(@TScriptArchive.FormatName, 'FORMATNAME');
    Rc.RegisterMethod(@TScriptArchive.FileSize, 'FILESIZE');
    Rc.RegisterMethod(@TScriptArchive.TotalSize, 'TOTALSIZE');
    Rc.RegisterMethod(@TScriptArchive.TotalPacked, 'TOTALPACKED');
    Rc.RegisterMethod(@TScriptArchive.SavedPercent, 'SAVEDPERCENT');
    Rc.RegisterMethod(@TScriptArchive.EncryptedCount, 'ENCRYPTEDCOUNT');
    Rc.RegisterMethod(@TScriptArchive.Warnings, 'WARNINGS');
    Rc.RegisterMethod(@TScriptArchive.Name, 'NAME');
    Rc.RegisterMethod(@TScriptArchive.IsDir, 'ISDIR');
    Rc.RegisterMethod(@TScriptArchive.Size, 'SIZE');
    Rc.RegisterMethod(@TScriptArchive.PackedSize, 'PACKEDSIZE');
    Rc.RegisterMethod(@TScriptArchive.Method, 'METHOD');
    Rc.RegisterMethod(@TScriptArchive.CRC, 'CRC');
    Rc.RegisterMethod(@TScriptArchive.Modified, 'MODIFIED');
    Rc.RegisterMethod(@TScriptArchive.Encrypted, 'ENCRYPTED');
    Rc.RegisterMethod(@TScriptArchive.IndexOf, 'INDEXOF');
    Rc.RegisterMethod(@TScriptArchive.Extract, 'EXTRACT');
    Rc.RegisterMethod(@TScriptArchive.ExtractFiles, 'EXTRACTFILES');
    Rc.RegisterMethod(@TScriptArchive.Test, 'TEST');
    Rc.RegisterMethod(@TScriptArchive.List, 'LIST');
    for J := 0 to High(ExtraClasses) do
    begin
      Rc := RI.Add2(ExtraClasses[J].Cls, UpperCase(ExtraClasses[J].Name));
      for I := 0 to High(ExtraClasses[J].Methods) do
        Rc.RegisterMethod(ExtraClasses[J].Methods[I].Ptr, UpperCase(ScriptFuncName(ExtraClasses[J].Methods[I].Decl)));
    end;
    RegisterClassLibraryRuntime(FExec, RI);
    for I := 0 to High(Funcs) do
      FExec.RegisterDelphiFunction(Funcs[I].Ptr, UpperCase(ScriptFuncName(Funcs[I].Decl)), cdRegister);
    if not FExec.LoadData(Data) then
    begin
      ErrorText := TIFErrorToString(FExec.ExceptionCode, FExec.ExceptionString);
      ExitCode := 2;
      Exit;
    end;
    FExec.LoadDebugData(Dbg);
    FExec.DebugEnabled := Debug;
    if Debug then
    begin
      FExec.OnSourceLine := @ExecSourceLine;
      FExec.OnIdleCall := @ExecIdle;
      if BreakOnStart then
      begin
        FLastStep := lsInto;
        FExec.StepInto;
      end;
    end;
    if FStopped then
      Exit;
    FExec.RunScript;
    if FExec.ExceptionCode <> erNoError then
    begin
      ErrorText := TIFErrorToString(FExec.ExceptionCode, FExec.ExceptionString);
      P := 0; R := 0; C := 0; Fn := '';
      if FExec.TranslatePositionEx(FExec.ExceptionProcNo, FExec.ExceptionPos, P, R, C, Fn) then
      begin
        if Fn = SCRIPT_MAIN then
        begin
          ErrorRow := R;
          ErrorCol := C;
          ErrorText := Format('Runtime error (%d:%d): %s', [R, C, ErrorText]);
        end
        else
          ErrorText := Format('Runtime error %s(%d:%d): %s', [Fn, R, C, ErrorText]);
      end
      else
        ErrorText := 'Runtime error: ' + ErrorText;
      if ExitCode = 0 then
        ExitCode := 1;
    end
    else
      Result := True;
  finally
    FLock.Enter;
    FPausedRow := 0;
    FLock.Leave;
    FreeAndNil(FExec);
    RI.Free;
    Cur := Saved;
  end;
end;

procedure TScriptRunner.Stop;
begin
  FStopped := True;
  if FExec <> nil then
    FExec.Stop;
end;

procedure TScriptRunner.SetBreakpoints(const ARows: array of Integer);
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(FBreakpoints, Length(ARows));
    for I := 0 to High(ARows) do
      FBreakpoints[I] := ARows[I];
  finally
    FLock.Leave;
  end;
end;

{ The lock keeps "not paused any more" and the new debug mode together, so the
  script thread cannot pause again in between and have that pause wiped. }

procedure TScriptRunner.DebugContinue;
begin
  FLock.Enter;
  try
    FPausedRow := 0;
    FLastStep := lsNone;
    if FExec <> nil then
      FExec.Run;
  finally
    FLock.Leave;
  end;
end;

procedure TScriptRunner.DebugStepInto;
begin
  FLock.Enter;
  try
    FPausedRow := 0;
    FLastStep := lsInto;
    if FExec <> nil then
      FExec.StepInto;
  finally
    FLock.Leave;
  end;
end;

procedure TScriptRunner.DebugStepOver;
begin
  FLock.Enter;
  try
    FPausedRow := 0;
    FLastStep := lsOver;
    if FExec <> nil then
      FExec.StepOver;
  finally
    FLock.Leave;
  end;
end;

procedure TScriptRunner.DebugPause;
begin
  FLock.Enter;
  try
    if FExec <> nil then
    begin
      FPauseRequested := True;
      FExec.Pause;
    end;
  finally
    FLock.Leave;
  end;
end;

function TScriptRunner.PausedRow: Integer;
begin
  FLock.Enter;
  Result := FPausedRow;
  FLock.Leave;
end;

function TScriptRunner.VarsText: string;
begin
  FLock.Enter;
  Result := FVars;
  FLock.Leave;
end;

function TScriptRunner.CallStackText: string;
begin
  FLock.Enter;
  Result := FCallStack;
  FLock.Leave;
end;

{ ---------- TScriptJob ---------- }

type
  TJobHost = class(TScriptHost)
  private
    FJob: TScriptJob;
  public
    constructor Create(AJob: TScriptJob);
    procedure Output(const S: string; AIsError: Boolean); override;
    procedure Progress(APercent: Integer; const AText: string); override;
    function Input(const APrompt, ADefault: string): string; override;
    function Confirm(const AMessage: string): Boolean; override;
    procedure Message(const AText: string); override;
    function GuiRunning: Boolean; override;
    function GuiRequest(const ARequest: string; out AReply: string): Boolean; override;
  end;

const
  MAX_JOB_LINES = 200000;

var
  LastJobId: Integer = 0;

constructor TJobHost.Create(AJob: TScriptJob);
begin
  FJob := AJob;
end;

procedure TJobHost.Output(const S: string; AIsError: Boolean);
begin
  if AIsError then
    FJob.AddLine('[error] ' + S)
  else
    FJob.AddLine(S);
end;

procedure TJobHost.Progress(APercent: Integer; const AText: string);
begin
  FJob.FLock.Enter;
  FJob.FPercent := EnsureRange(APercent, 0, 100);
  FJob.FProgressText := AText;
  FJob.FLock.Leave;
end;

function TJobHost.Input(const APrompt, ADefault: string): string;
begin
  if FJob.OnDialog <> nil then
    Result := FJob.RunDialog(sdInput, APrompt, ADefault)
  else
    Result := ADefault;
end;

function TJobHost.Confirm(const AMessage: string): Boolean;
begin
  Result := (FJob.OnDialog <> nil) and (FJob.RunDialog(sdConfirm, AMessage, '') = '1');
end;

procedure TJobHost.Message(const AText: string);
begin
  if FJob.OnDialog <> nil then
    FJob.RunDialog(sdMessage, AText, '')
  else
    Output(AText, False);
end;

function TJobHost.GuiRunning: Boolean;
begin
  Result := (FJob.LocalHandler <> nil) or inherited GuiRunning;
end;

function TJobHost.GuiRequest(const ARequest: string; out AReply: string): Boolean;
begin
  if FJob.LocalHandler = nil then
    Exit(inherited GuiRequest(ARequest, AReply));
  FJob.FReq := ARequest;
  FJob.FReply := '';
  FJob.Synchronize(@FJob.DoLocalRequest);
  AReply := FJob.FReply;
  Result := True;
end;

constructor TScriptJob.Create(const ASource, AFileName: string; AArgs: TStrings; ADebug: Boolean);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
  FHost := TJobHost.Create(Self);
  FPercent := -1;
  Inc(LastJobId);
  Id := LastJobId;
  Runner := TScriptRunner.Create;
  Runner.Source := ASource;
  Runner.FileName := AFileName;
  Runner.Debug := ADebug;
  Runner.Host := FHost;
  if AArgs <> nil then
    Runner.Args.Assign(AArgs);
end;

destructor TScriptJob.Destroy;
begin
  Cancel;
  inherited Destroy;
  Runner.Free;
  FHost.Free;
  FLines.Free;
  FLock.Free;
end;

procedure TScriptJob.Go;
begin
  Start;
end;

procedure TScriptJob.Cancel;
begin
  if Suspended then
  begin
    Terminate;
    Start;
  end;
  if not Finished then
    Runner.Stop;
  WaitFor;
end;

procedure TScriptJob.AddLine(const S: string);
begin
  FLock.Enter;
  try
    if FLines.Count >= MAX_JOB_LINES then
    begin
      FLines.Delete(0);
      Inc(FDropped);
    end;
    FLines.Add(S);
  finally
    FLock.Leave;
  end;
end;

procedure TScriptJob.DoLocalRequest;
begin
  try
    FReply := LocalHandler(FReq);
  except
    on E: Exception do
      FReply := '{"ok":false,"error":' + JSONQuote(E.Message) + '}';
  end;
end;

procedure TScriptJob.DoDialog;
begin
  FDlgResult := OnDialog(FDlgKind, FDlgText, FDlgDefault);
end;

function TScriptJob.RunDialog(AKind: TScriptDialogKind; const AText, ADefault: string): string;
begin
  FDlgKind := AKind;
  FDlgText := AText;
  FDlgDefault := ADefault;
  Synchronize(@DoDialog);
  Result := FDlgResult;
end;

procedure TScriptJob.Execute;
begin
  try
    if not Terminated then
    begin
      Runner.Run;
      if Runner.ErrorText <> '' then
        AddLine(Runner.ErrorText);
    end;
  except
    on E: Exception do
    begin
      Runner.ErrorText := E.ClassName + ': ' + E.Message;
      Runner.ExitCode := 1;
      AddLine(Runner.ErrorText);
    end;
  end;
  FLock.Enter;
  FFinished := True;
  FLock.Leave;
end;

function TScriptJob.GetLines(AFrom: Integer; ADest: TStrings): Integer;
var
  I, First: Integer;
begin
  FLock.Enter;
  try
    First := Max(AFrom - FDropped, 0);
    for I := First to FLines.Count - 1 do
      ADest.Add(FLines[I]);
    Result := FLines.Count + FDropped;
  finally
    FLock.Leave;
  end;
end;

function TScriptJob.Finished: Boolean;
begin
  FLock.Enter;
  Result := FFinished;
  FLock.Leave;
end;

function TScriptJob.ProgressPercent: Integer;
begin
  FLock.Enter;
  Result := FPercent;
  FLock.Leave;
end;

function TScriptJob.ProgressText: string;
begin
  FLock.Enter;
  Result := FProgressText;
  FLock.Leave;
end;

function ScriptSlotFree: Boolean;
begin
  if (CurrentScriptJob <> nil) and CurrentScriptJob.Finished then
    FreeAndNil(CurrentScriptJob);
  Result := CurrentScriptJob = nil;
end;

function ScriptJobStatusJSON(AJob: TScriptJob; AFrom: Integer): string;
var
  O: TJSONObject;
  Arr: TJSONArray;
  L: TStringList;
  I, Next: Integer;
begin
  O := TJSONObject.Create;
  L := TStringList.Create;
  try
    O.Add('ok', True);
    if AJob = nil then
      O.Add('state', 'idle')
    else
    begin
      Next := AJob.GetLines(AFrom, L);
      if AJob.Finished then
      begin
        O.Add('state', 'finished');
        O.Add('exit_code', AJob.Runner.ExitCode);
        O.Add('stopped', AJob.Runner.Stopped);
        O.Add('error', AJob.Runner.ErrorText);
        O.Add('error_row', AJob.Runner.ErrorRow);
      end
      else if AJob.Runner.PausedRow > 0 then
      begin
        O.Add('state', 'paused');
        O.Add('paused_row', AJob.Runner.PausedRow);
      end
      else
        O.Add('state', 'running');
      if AJob.ProgressPercent >= 0 then
      begin
        O.Add('progress', AJob.ProgressPercent);
        O.Add('progress_text', AJob.ProgressText);
      end;
      Arr := TJSONArray.Create;
      for I := 0 to L.Count - 1 do
        Arr.Add(L[I]);
      O.Add('output', Arr);
      O.Add('next', Next);
    end;
    Result := O.AsJSON;
  finally
    L.Free;
    O.Free;
  end;
end;

initialization
  BuildTable;

end.
