program BGRAZipMCP;

{ BGRA Zip MCP server (Model Context Protocol, stdio transport).

  Speaks JSON-RPC 2.0, one message per line on stdin/stdout; logs go to
  stderr only. Archive tools work on their own (same parser / backends as the
  GUI, no window needed); gui_* tools drive a running BGRA Zip window through
  the named-pipe IPC in uIPC and start the GUI when it is not running.

  Register with Claude Code:
    claude mcp add bgrazip -- "<path>\bin\BGRAZipMCP.exe" }

{$mode objfpc}{$H+}

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, Math, fpjson, jsonparser, Zipper, zstream, crc,
  LazUTF8, LazFileUtils, FileUtil,
  uArchiveBase, uArchiveOps, uZipInspector, uRarInspector, uRarBackend, uRarPure, uIPC, uDevLog, uScriptEngine;

const
  ServerVersion = '1.2.0';
  SupportedProtocols: array[0..3] of string = ('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05');

type
  ETool = class(Exception);

var
  StdOut, StdErr: THandleStream;

{ ---------- stdio ---------- }

procedure LogErr(const S: string);
var
  L: string;
begin
  L := '[bgrazip-mcp] ' + S + LineEnding;
  StdErr.WriteBuffer(L[1], Length(L));
end;

procedure SendLine(const S: string);
var
  L: string;
begin
  L := S + #10;
  StdOut.WriteBuffer(L[1], Length(L));
end;

{ ---------- helpers ---------- }

function ArgStr(Args: TJSONObject; const AName: string; ARequired: Boolean = True): string;
begin
  Result := '';
  if Args <> nil then
    Result := Args.Get(AName, '');
  if ARequired and (Result = '') then
    raise ETool.CreateFmt('missing required argument "%s"', [AName]);
end;

function ArgArray(Args: TJSONObject; const AName: string): TStringList;
var
  A: TJSONArray;
  I: Integer;
begin
  Result := TStringList.Create;
  if Args = nil then
    Exit;
  A := Args.Get(AName, TJSONArray(nil));
  if A <> nil then
    for I := 0 to A.Count - 1 do
      Result.Add(A.Strings[I]);
end;

function EntryJSON(E: TArchiveEntry): TJSONObject;
var
  RE: TRarEntryInfo;
  ZE: TZipEntryInfo;
begin
  Result := TJSONObject.Create;
  Result.Add('name', E.FileName);
  Result.Add('dir', E.IsDirectory);
  Result.Add('size', E.UncompressedSize);
  Result.Add('packed', E.CompressedSize);
  Result.Add('saved_percent', Round(E.SavedPercent * 10) / 10);
  Result.Add('method', E.MethodText);
  Result.Add('crc32', IntToHex(E.CRC32, 8));
  Result.Add('modified', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', E.DateTime));
  Result.Add('encrypted', E.IsEncrypted);
  if E.IsEncrypted then
    Result.Add('encryption', E.EncryptionText);
  if E is TZipEntryInfo then
  begin
    ZE := TZipEntryInfo(E);
    Result.Add('local_header_offset', ZE.LocalHeaderOffset);
    Result.Add('data_offset', ZE.DataOffset);
    Result.Add('flags', Hex16(ZE.Flags));
    Result.Add('host_os', HostOSName(ZE.VersionMadeBy));
  end
  else if E is TRarEntryInfo then
  begin
    RE := TRarEntryInfo(E);
    Result.Add('header_offset', RE.Block.Offset);
    Result.Add('data_offset', RE.Block.DataOffset);
    Result.Add('header_crc_ok', RE.Block.CRCOk);
    Result.Add('solid', RE.Solid);
    Result.Add('dictionary', RE.DictSize);
    Result.Add('host_os', RarHostOSName(RE.IsRar5, RE.HostOS));
  end;
end;

{ ---------- tools ---------- }

function ToolArchiveInfo(Args: TJSONObject): TJSONObject;
var
  A: TArchiveInfo;
  R: TRarArchiveInfo;
  Z: TZipArchiveInfo;
  W: TJSONArray;
  I: Integer;
begin
  A := OpenArchiveInfo(ArgStr(Args, 'path'));
  try
    Result := TJSONObject.Create;
    Result.Add('path', A.FileName);
    Result.Add('format', A.FormatName);
    Result.Add('file_size', A.FileSize);
    Result.Add('entries', A.Count);
    Result.Add('files', A.FileCount);
    Result.Add('folders', A.DirCount);
    Result.Add('unpacked_size', A.TotalUncompressed);
    Result.Add('packed_size', A.TotalCompressed);
    Result.Add('saved_percent', Round(A.OverallSavedPercent * 100) / 100);
    Result.Add('encrypted_entries', A.EncryptedCount);
    Result.Add('encryption', A.EncryptionSummary);
    Result.Add('parse_ms', A.ParseTimeMs);
    if A is TZipArchiveInfo then
    begin
      Z := TZipArchiveInfo(A);
      Result.Add('zip64', Z.IsZip64);
      Result.Add('eocd_offset', Z.EOCDOffset);
      Result.Add('central_directory_offset', Z.CDOffset);
      Result.Add('central_directory_size', Z.CDSize);
      Result.Add('prefix_bytes', Z.PrefixBytes);
      Result.Add('comment', Z.Comment);
    end
    else
    begin
      R := TRarArchiveInfo(A);
      Result.Add('signature_offset', R.SigOffset);
      Result.Add('solid', R.IsSolid);
      Result.Add('multi_volume', R.IsVolume);
      Result.Add('locked', R.IsLocked);
      Result.Add('recovery_record', R.HasRecovery);
      Result.Add('headers_encrypted', R.HeadersEncrypted);
      Result.Add('blocks', R.Blocks.Count);
      Result.Add('service_blocks', R.ServiceNames);
    end;
    W := TJSONArray.Create;
    for I := 0 to A.Warnings.Count - 1 do
      W.Add(A.Warnings[I]);
    Result.Add('warnings', W);
  finally
    A.Free;
  end;
end;

function ToolListEntries(Args: TJSONObject): TJSONObject;
var
  A: TArchiveInfo;
  Arr: TJSONArray;
  Folder, N: string;
  I, Limit, Matched: Integer;
  Recursive: Boolean;
begin
  A := OpenArchiveInfo(ArgStr(Args, 'path'));
  try
    Folder := StringReplace(Args.Get('folder', ''), '\', '/', [rfReplaceAll]);
    while (Folder <> '') and (Folder[Length(Folder)] = '/') do
      Delete(Folder, Length(Folder), 1);
    Recursive := Args.Get('recursive', True);
    Limit := Args.Get('limit', 1000);
    Arr := TJSONArray.Create;
    Matched := 0;
    for I := 0 to A.Count - 1 do
    begin
      N := A.Entry[I].FileName;
      if Folder <> '' then
      begin
        if not SameText(Copy(N, 1, Length(Folder) + 1), Folder + '/') then
          Continue;
        N := Copy(N, Length(Folder) + 2, MaxInt);
      end;
      while (N <> '') and (N[Length(N)] = '/') do
        Delete(N, Length(N), 1);
      if (N = '') or (not Recursive and (Pos('/', N) > 0)) then
        Continue;
      Inc(Matched);
      if Arr.Count < Limit then
        Arr.Add(EntryJSON(A.Entry[I]));
    end;
    Result := TJSONObject.Create;
    Result.Add('path', A.FileName);
    Result.Add('format', A.FormatName);
    Result.Add('matched', Matched);
    Result.Add('returned', Arr.Count);
    Result.Add('entries', Arr);
    // e.g. a RAR with encrypted file names lists nothing; say why
    if A.Warnings.Count > 0 then
    begin
      Arr := TJSONArray.Create;
      for I := 0 to A.Warnings.Count - 1 do
        Arr.Add(A.Warnings[I]);
      Result.Add('warnings', Arr);
    end;
  finally
    A.Free;
  end;
end;

function ToolTestArchive(Args: TJSONObject): TJSONObject;
var
  A: TArchiveInfo;
  Bad: TStringList;
  I: Integer;
  T0: QWord;
  Arr: TJSONArray;
begin
  A := OpenArchiveInfo(ArgStr(Args, 'path'));
  Bad := TStringList.Create;
  T0 := GetTickCount64;
  try
    TestArchiveInfo(A, Bad, ArgStr(Args, 'password', False));
    Result := TJSONObject.Create;
    Result.Add('path', A.FileName);
    Result.Add('format', A.FormatName);
    Result.Add('passed', Bad.Count = 0);
    Result.Add('entries_tested', A.FileCount);
    Arr := TJSONArray.Create;
    for I := 0 to Bad.Count - 1 do
      Arr.Add(Bad[I]);
    Result.Add('problems', Arr);
    Result.Add('ms', GetTickCount64 - T0);
  finally
    Bad.Free;
    A.Free;
  end;
end;

function ToolExtract(Args: TJSONObject): TJSONObject;
var
  A: TArchiveInfo;
  Dest: string;
  Names: TStringList;
  T0: QWord;
begin
  A := OpenArchiveInfo(ArgStr(Args, 'path'));
  Names := ArgArray(Args, 'entries');
  T0 := GetTickCount64;
  try
    Dest := ArgStr(Args, 'destination');
    ExtractArchiveInfo(A, Dest, Names, ArgStr(Args, 'password', False));
    Result := TJSONObject.Create;
    Result.Add('path', A.FileName);
    Result.Add('destination', Dest);
    if Names.Count > 0 then
      Result.Add('extracted', Names.Count)
    else
      Result.Add('extracted', A.Count);
    Result.Add('ms', GetTickCount64 - T0);
  finally
    Names.Free;
    A.Free;
  end;
end;

function ToolCreateZip(Args: TJSONObject): TJSONObject;
var
  OutName, Lvl: string;
  Sources: TStringList;
  Count: Integer;
  Total: Int64;
  T0: QWord;
begin
  OutName := ArgStr(Args, 'output');
  Sources := ArgArray(Args, 'sources');
  T0 := GetTickCount64;
  try
    Lvl := LowerCase(Args.Get('level', 'default'));
    CreateZipFile(OutName, Sources, Lvl, Args.Get('overwrite', False), Count, Total,
      ArgStr(Args, 'password', False), Args.Get('zipcrypto', False));
    Result := TJSONObject.Create;
    Result.Add('output', OutName);
    Result.Add('files', Count);
    Result.Add('unpacked_size', Total);
    Result.Add('zip_size', FileSizeUtf8(OutName));
    Result.Add('level', Lvl);
    Result.Add('encrypted', ArgStr(Args, 'password', False) <> '');
    Result.Add('ms', GetTickCount64 - T0);
  finally
    Sources.Free;
  end;
end;

function ToolCreateRar(Args: TJSONObject): TJSONObject;
var
  OutName, Lvl: string;
  Sources: TStringList;
  T0: QWord;
begin
  OutName := ArgStr(Args, 'output');
  Sources := ArgArray(Args, 'sources');
  T0 := GetTickCount64;
  try
    Lvl := LowerCase(Args.Get('level', 'default'));
    CreateRarFile(OutName, Sources, Lvl, Args.Get('overwrite', False),
      ArgStr(Args, 'password', False), Args.Get('encrypt_names', False));
    Result := TJSONObject.Create;
    Result.Add('output', OutName);
    Result.Add('rar_size', FileSizeUtf8(OutName));
    Result.Add('level', Lvl);
    Result.Add('encrypted', ArgStr(Args, 'password', False) <> '');
    Result.Add('ms', GetTickCount64 - T0);
  finally
    Sources.Free;
  end;
end;

{ --- scripts --- }

{ Script text from "source" or the file named by "path". }
function ScriptSource(Args: TJSONObject; out AFileName: string): string;
var
  F: TFileStream;
begin
  AFileName := ArgStr(Args, 'path', False);
  Result := ArgStr(Args, 'source', False);
  if (Result = '') = (AFileName = '') then
    raise ETool.Create('pass either "source" or "path"');
  if AFileName = '' then
    Exit;
  if not FileExistsUTF8(AFileName) then
    raise ETool.Create('script not found: ' + AFileName);
  F := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[1], F.Size);
  finally
    F.Free;
  end;
  if Copy(Result, 1, 3) = #$EF#$BB#$BF then
    Delete(Result, 1, 3);
end;

function ToolRunScript(Args: TJSONObject): TJSONObject;
var
  Job: TScriptJob;
  Src, FileName: string;
  ScriptArgs: TStringList;
  Limit: Integer;
  T0, Grace: QWord;
  TimedOut: Boolean;
begin
  Src := ScriptSource(Args, FileName);
  Limit := Max(1, Args.Get('timeout_seconds', 120));
  ScriptArgs := ArgArray(Args, 'args');
  Job := TScriptJob.Create(Src, FileName, ScriptArgs, False);
  ScriptArgs.Free;
  T0 := GetTickCount64;
  Job.Go;
  TimedOut := False;
  while not Job.Finished do
  begin
    if GetTickCount64 - T0 > QWord(Limit) * 1000 then
    begin
      TimedOut := True;
      Job.Runner.Stop;
      Grace := GetTickCount64;
      while not Job.Finished and (GetTickCount64 - Grace < 5000) do
        Sleep(20);
      Break;
    end;
    Sleep(10);
  end;
  Result := TJSONObject(ParseJSON(ScriptJobStatusJSON(Job, 0)));
  Result.Delete('ok');
  Result.Delete('next');
  Result.Add('timed_out', TimedOut);
  Result.Add('ms', GetTickCount64 - T0);
  // a native call that ignores Stop keeps its thread; it ends with this process
  if Job.Finished then
    Job.Free;
end;

function ToolCheckScript(Args: TJSONObject): TJSONObject;
var
  R: TScriptRunner;
  Arr: TJSONArray;
  I: Integer;
  FileName: string;
begin
  R := TScriptRunner.Create;
  try
    R.Source := ScriptSource(Args, FileName);
    R.FileName := FileName;
    Result := TJSONObject.Create;
    Result.Add('compiles', R.Check);
    Result.Add('error', R.ErrorText);
    Result.Add('error_row', R.ErrorRow);
    Result.Add('error_col', R.ErrorCol);
    Arr := TJSONArray.Create;
    for I := 0 to R.Messages.Count - 1 do
      Arr.Add(R.Messages[I]);
    Result.Add('messages', Arr);
  finally
    R.Free;
  end;
end;

function ToolScriptFunctions(Args: TJSONObject): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('language', 'PascalScript: Pascal syntax, a script is "begin ... end."');
  Result.Add('functions', ParseJSON(ScriptFunctionsJSON));
  Result.Add('reference', ScriptReferenceText);
end;

function ToolHexDump(Args: TJSONObject): TJSONObject;
var
  P: string;
  Ofs: Int64;
  Len: Integer;
  B: TBytes;
begin
  P := ArgStr(Args, 'path');
  if not FileExistsUTF8(P) then
    raise ETool.Create('file not found: ' + P);
  Ofs := Args.Get('offset', Int64(0));
  Len := EnsureRange(Args.Get('length', 256), 1, 4096);
  B := ReadFileRegion(P, Ofs, Len);
  Result := TJSONObject.Create;
  Result.Add('path', P);
  Result.Add('offset', Ofs);
  Result.Add('length', Length(B));
  Result.Add('dump', HexDump(B, Ofs));
end;

function ToolRarTools(Args: TJSONObject): TJSONObject;
var
  T: TRarTools;
  Tool: TRarTool;
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
begin
  T := FindRarTools;
  Arr := TJSONArray.Create;
  for I := 0 to High(T) do
  begin
    O := TJSONObject.Create;
    O.Add('kind', RarToolNames[T[I].Kind]);
    O.Add('exe', T[I].Exe);
    O.Add('version', T[I].Version);
    Arr.Add(O);
  end;
  Result := TJSONObject.Create;
  Result.Add('tools', Arr);
  // rar_pure.exe (next to the server) comes first: ZIP + RAR, with passwords
  Result.Add('rar_pure', RarPureExe);
  if RarPureExe <> '' then
  begin
    Result.Add('extract_with', 'rar_pure.exe (ZIP and RAR)');
    Result.Add('create_rar_with', 'rar_pure.exe');
  end
  else
  begin
    if FindRarExtractor(Tool) then
      Result.Add('extract_with', RarToolNames[Tool.Kind])
    else
      Result.Add('extract_with', TJSONNull.Create);
    if FindRarCreator(Tool) then
      Result.Add('create_rar_with', RarToolNames[Tool.Kind])
    else
      Result.Add('create_rar_with', TJSONNull.Create);
  end;
  if FindRarExtractor(Tool) then
    Result.Add('test_rar_with', RarToolNames[Tool.Kind])
  else
    Result.Add('test_rar_with', TJSONNull.Create);
end;

{ --- GUI tools over IPC --- }

function GuiExe: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'BGRAZip.exe';
end;

{ Starts the window and returns at once; ExecuteProcess would wait for it to close. }
procedure StartGui(const APath: string);
{$IFDEF WINDOWS}
var
  Exe, Line: UnicodeString;
  SI: TStartupInfoW;
  PI: TProcessInformation;
begin
  Exe := UTF8ToUTF16(GuiExe);
  Line := '"' + Exe + '" "' + UTF8ToUTF16(APath) + '"';
  FillChar(SI, SizeOf(SI), 0);
  SI.cb := SizeOf(SI);
  FillChar(PI, SizeOf(PI), 0);
  if not CreateProcessW(PWideChar(Exe), PWideChar(Line), nil, nil, False, 0, nil, nil, SI, PI) then
    raise ETool.CreateFmt('could not start %s (error %d)', [GuiExe, GetLastError]);
  CloseHandle(PI.hThread);
  CloseHandle(PI.hProcess);
end;
{$ELSE}
begin
  raise ETool.Create('starting the window is only supported on Windows');
end;
{$ENDIF}

function GuiCall(const ARequest: string): TJSONObject;
var
  R: string;
  D: TJSONData;
begin
  if not IPCRequest(ARequest, R, 120000) then
    raise ETool.Create('BGRA Zip window is not running (use gui_open to start it)');
  D := GetJSON(R);
  if not (D is TJSONObject) then
  begin
    D.Free;
    raise ETool.Create('invalid reply from BGRA Zip: ' + R);
  end;
  Result := TJSONObject(D);
  if not Result.Get('ok', False) then
  begin
    R := Result.Get('error', 'unknown error');
    Result.Free;
    raise ETool.Create(R);
  end;
end;

function ToolGuiStatus(Args: TJSONObject): TJSONObject;
var
  Pid: Cardinal;
begin
  if not IPCServerRunning(Pid) then
  begin
    Result := TJSONObject.Create;
    Result.Add('running', False);
    Exit;
  end;
  Result := GuiCall('{"cmd":"status"}');
  Result.Add('running', True);
  Result.Add('pid', Pid);
end;

function ToolGuiOpen(Args: TJSONObject): TJSONObject;
var
  P: string;
  Pid: Cardinal;
  I: Integer;
begin
  P := ExpandFileNameUTF8(ArgStr(Args, 'path'));
  if not FileExistsUTF8(P) then
    raise ETool.Create('file not found: ' + P);
  if IPCServerRunning(Pid) then
    Exit(GuiCall('{"cmd":"open","path":' + JSONQuote(P) + '}'));
  if not FileExistsUTF8(GuiExe) then
    raise ETool.Create('BGRA Zip GUI not found next to the MCP server: ' + GuiExe);
  // start the window with the archive and wait until its IPC server answers
  StartGui(P);
  for I := 1 to 50 do
  begin
    Sleep(200);
    if IPCServerRunning(Pid) then
    begin
      Result := GuiCall('{"cmd":"status"}');
      Result.Add('started', True);
      Exit;
    end;
  end;
  raise ETool.Create('BGRA Zip was started but did not answer on ' + IPCPipeName);
end;

function ToolGuiExtract(Args: TJSONObject): TJSONObject;
var
  Req: TJSONObject;
  E: TStringList;
  A: TJSONArray;
  I: Integer;
begin
  Req := TJSONObject.Create(['cmd', 'extract', 'destination', ArgStr(Args, 'destination')]);
  E := ArgArray(Args, 'entries');
  try
    if E.Count > 0 then
    begin
      A := TJSONArray.Create;
      for I := 0 to E.Count - 1 do
        A.Add(E[I]);
      Req.Add('entries', A);
    end;
    Result := GuiCall(Req.AsJSON);
  finally
    E.Free;
    Req.Free;
  end;
end;

function ToolGuiTest(Args: TJSONObject): TJSONObject;
begin
  Result := GuiCall('{"cmd":"test"}');
end;

function ToolGuiDeveloper(Args: TJSONObject): TJSONObject;
begin
  Result := GuiCall(Format('{"cmd":"dev","tab":%d}', [EnsureRange(Args.Get('tab', 0), 0, 5)]));
end;

function ToolGuiLog(Args: TJSONObject): TJSONObject;
begin
  Result := GuiCall(Format('{"cmd":"log","lines":%d}', [EnsureRange(Args.Get('lines', 100), 1, 5000)]));
end;

{ ---------- tool registry ---------- }

type
  TToolFunc = function(Args: TJSONObject): TJSONObject;

  TToolDef = record
    Name: string;
    Title: string;
    Description: string;
    Schema: string;
    ReadOnly: Boolean;
    Func: TToolFunc;
  end;

const
  PathProp = '"path":{"type":"string","description":"Full path of a .zip or .rar file (SFX .exe also works)"}';
  PasswordProp = '"password":{"type":"string","description":"Archive password (English letters, digits and ' +
    'symbols only); needs rar_pure.exe next to the server"}';

var
  Tools: array of TToolDef;

procedure Reg(const AName, ATitle, ADesc, ASchema: string; AReadOnly: Boolean; AFunc: TToolFunc);
var
  N: Integer;
begin
  N := Length(Tools);
  SetLength(Tools, N + 1);
  Tools[N].Name := AName;
  Tools[N].Title := ATitle;
  Tools[N].Description := ADesc;
  Tools[N].Schema := ASchema;
  Tools[N].ReadOnly := AReadOnly;
  Tools[N].Func := AFunc;
end;

procedure RegisterTools;
begin
  Reg('archive_info', 'Archive info',
    'Parse a ZIP or RAR (4.x / 5.0) archive and return its structure: format, totals, compression ratio, ' +
    'EOCD / Zip64 or RAR main-header details and integrity warnings.',
    '{"type":"object","properties":{' + PathProp + '},"required":["path"]}', True, @ToolArchiveInfo);
  Reg('list_entries', 'List entries',
    'List the entries of a ZIP or RAR archive with sizes, method, CRC32, dates and raw header offsets.',
    '{"type":"object","properties":{' + PathProp + ',' +
    '"folder":{"type":"string","description":"Only entries below this folder inside the archive (\"docs/sub\")"},' +
    '"recursive":{"type":"boolean","description":"Include sub-folders (default true)"},' +
    '"limit":{"type":"integer","description":"Maximum entries returned (default 1000)"}},"required":["path"]}',
    True, @ToolListEntries);
  Reg('test_archive', 'Test archive',
    'Decompress every entry without writing files and verify each CRC32. RAR uses rar/unrar/7-Zip or ' +
    'Windows tar.exe; with tar the CRCs are checked by this server. With "password", rar_pure.exe ' +
    'also tests the password-protected entries.',
    '{"type":"object","properties":{' + PathProp + ',' + PasswordProp + '},"required":["path"]}', True,
    @ToolTestArchive);
  Reg('extract_archive', 'Extract archive',
    'Extract all entries, or only the listed ones, to a destination folder (created if needed). ' +
    'Existing files are overwritten. Uses rar_pure.exe (ZIP and RAR) when it is next to the server; ' +
    'entries that need a password and did not get one are reported as an error after the rest is extracted.',
    '{"type":"object","properties":{' + PathProp + ',' +
    '"destination":{"type":"string","description":"Folder to extract into"},' +
    '"entries":{"type":"array","items":{"type":"string"},"description":"Entry names as listed by list_entries; omit for all"},' +
    PasswordProp + '},"required":["path","destination"]}', False, @ToolExtract);
  Reg('create_zip', 'Create ZIP',
    'Create a .zip from files and/or folders (folders are added recursively under their own name). ' +
    'Names are stored as UTF-8. With "password" the files are encrypted (AES-256, or ZipCrypto with "zipcrypto").',
    '{"type":"object","properties":{"output":{"type":"string","description":"Path of the .zip to write"},' +
    '"sources":{"type":"array","items":{"type":"string"},"description":"Files and folders to add"},' +
    '"level":{"type":"string","enum":["store","fastest","default","maximum"]},' +
    '"overwrite":{"type":"boolean","description":"Replace an existing output file (default false)"},' +
    PasswordProp + ',' +
    '"zipcrypto":{"type":"boolean","description":"Use the older ZipCrypto that Windows Explorer can open instead of AES-256"}},' +
    '"required":["output","sources"]}', False, @ToolCreateZip);
  Reg('create_rar', 'Create RAR',
    'Create a RAR5 archive from files and/or folders (folders are added recursively under their own name) ' +
    'with rar_pure.exe, or WinRAR''s rar.exe without it. With "password" the files are encrypted with AES-256.',
    '{"type":"object","properties":{"output":{"type":"string","description":"Path of the .rar to write"},' +
    '"sources":{"type":"array","items":{"type":"string"},"description":"Files and folders to add"},' +
    '"level":{"type":"string","enum":["store","fastest","default","maximum"]},' +
    '"overwrite":{"type":"boolean","description":"Replace an existing output file (default false)"},' +
    PasswordProp + ',' +
    '"encrypt_names":{"type":"boolean","description":"Encrypt the file names too, so the list needs the password"}},' +
    '"required":["output","sources"]}', False, @ToolCreateRar);
  Reg('hex_dump', 'Hex dump',
    'Hex + ASCII dump of a byte range of any file (max 4096 bytes), e.g. to look at a header offset ' +
    'reported by list_entries.',
    '{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer"},' +
    '"length":{"type":"integer","description":"1..4096, default 256"}},"required":["path"]}', True, @ToolHexDump);
  Reg('rar_tools', 'RAR backends',
    'Show which external RAR tools were found and which one is used for extract/test and for creating .rar.',
    '{"type":"object","properties":{}}', True, @ToolRarTools);
  Reg('run_script', 'Run script',
    'Run a BGRA Zip script (PascalScript) from "source" text or a "path" and return its output and exit code. ' +
    'Scripts have full access to this user''s files and can start programs. See script_functions.',
    '{"type":"object","properties":{"source":{"type":"string","description":"Script text"},' +
    '"path":{"type":"string","description":"Script file (.bzs); use instead of source"},' +
    '"args":{"type":"array","items":{"type":"string"},"description":"Read in the script with Arg(i)"},' +
    '"timeout_seconds":{"type":"integer","description":"Stop the script after this long (default 120)"}}}',
    False, @ToolRunScript);
  Reg('check_script', 'Check script',
    'Compile a BGRA Zip script without running it and return errors with row and column.',
    '{"type":"object","properties":{"source":{"type":"string"},"path":{"type":"string"}}}', True, @ToolCheckScript);
  Reg('script_functions', 'Script functions',
    'List every function a BGRA Zip script can call, with declarations and notes.',
    '{"type":"object","properties":{}}', True, @ToolScriptFunctions);
  Reg('gui_status', 'GUI status',
    'Whether the BGRA Zip window is running and what it shows (open archive, totals, current folder, busy).',
    '{"type":"object","properties":{}}', True, @ToolGuiStatus);
  Reg('gui_open', 'Open in GUI',
    'Open an archive in the BGRA Zip window, starting the window if it is not running.',
    '{"type":"object","properties":{' + PathProp + '},"required":["path"]}', False, @ToolGuiOpen);
  Reg('gui_extract', 'Extract in GUI',
    'Extract the archive currently open in the BGRA Zip window (progress is shown there).',
    '{"type":"object","properties":{"destination":{"type":"string"},' +
    '"entries":{"type":"array","items":{"type":"string"}}},"required":["destination"]}', False, @ToolGuiExtract);
  Reg('gui_test', 'Test in GUI', 'Test the archive currently open in the BGRA Zip window.',
    '{"type":"object","properties":{}}', True, @ToolGuiTest);
  Reg('gui_show_developer', 'Show developer window',
    'Open the BGRA Zip developer window on a tab: 0 Overview, 1 Entries, 2 Hex, 3 Chart, 4 Log, 5 Environment.',
    '{"type":"object","properties":{"tab":{"type":"integer","minimum":0,"maximum":5}}}', False, @ToolGuiDeveloper);
  Reg('gui_get_log', 'GUI log', 'Return the last lines of the BGRA Zip developer log.',
    '{"type":"object","properties":{"lines":{"type":"integer","description":"default 100"}}}', True, @ToolGuiLog);
end;

function ToolsListJSON: TJSONObject;
var
  Arr: TJSONArray;
  T: TJSONObject;
  Ann: TJSONObject;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  for I := 0 to High(Tools) do
  begin
    T := TJSONObject.Create;
    T.Add('name', Tools[I].Name);
    T.Add('title', Tools[I].Title);
    T.Add('description', Tools[I].Description);
    T.Add('inputSchema', GetJSON(Tools[I].Schema));
    Ann := TJSONObject.Create;
    Ann.Add('readOnlyHint', Tools[I].ReadOnly);
    Ann.Add('destructiveHint', False);
    Ann.Add('openWorldHint', False);
    T.Add('annotations', Ann);
    Arr.Add(T);
  end;
  Result := TJSONObject.Create;
  Result.Add('tools', Arr);
end;

function CallTool(const AName: string; Args: TJSONObject): TJSONObject;
var
  I: Integer;
  Data: TJSONObject;
  Content: TJSONArray;
  Item: TJSONObject;
  IsErr: Boolean;
  Text: string;
begin
  Data := nil;
  IsErr := False;
  Text := '';
  for I := 0 to High(Tools) do
    if Tools[I].Name = AName then
    begin
      try
        Data := Tools[I].Func(Args);
        Text := Data.FormatJSON;
      except
        on E: Exception do
        begin
          IsErr := True;
          Text := 'Error: ' + E.Message;
        end;
      end;
      Break;
    end;
  if (Data = nil) and not IsErr then
  begin
    IsErr := True;
    Text := 'Unknown tool: ' + AName;
  end;
  Result := TJSONObject.Create;
  Content := TJSONArray.Create;
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', Text);
  Content.Add(Item);
  Result.Add('content', Content);
  if Data <> nil then
    Result.Add('structuredContent', Data);
  Result.Add('isError', IsErr);
end;

{ ---------- JSON-RPC ---------- }

procedure SendResult(AId: TJSONData; AResult: TJSONData);
var
  M: TJSONObject;
begin
  M := TJSONObject.Create;
  try
    M.Add('jsonrpc', '2.0');
    if AId <> nil then
      M.Add('id', AId.Clone)
    else
      M.Add('id', TJSONNull.Create);
    M.Add('result', AResult);
    SendLine(M.AsJSON);
  finally
    M.Free;
  end;
end;

procedure SendError(AId: TJSONData; ACode: Integer; const AMsg: string);
var
  M, E: TJSONObject;
begin
  M := TJSONObject.Create;
  try
    M.Add('jsonrpc', '2.0');
    if AId <> nil then
      M.Add('id', AId.Clone)
    else
      M.Add('id', TJSONNull.Create);
    E := TJSONObject.Create;
    E.Add('code', ACode);
    E.Add('message', AMsg);
    M.Add('error', E);
    SendLine(M.AsJSON);
  finally
    M.Free;
  end;
end;

procedure HandleMessage(Msg: TJSONObject);
var
  Method, Ver: string;
  Id: TJSONData;
  Params, Args, R, Caps, Info: TJSONObject;
  I: Integer;
begin
  Method := Msg.Get('method', '');
  Id := Msg.Find('id');
  Params := Msg.Get('params', TJSONObject(nil));
  if Method = '' then
    Exit;                                   // a response to something we never send
  if Copy(Method, 1, 14) = 'notifications/' then
  begin
    LogErr('notification ' + Method);
    Exit;
  end;
  if Id = nil then
    Exit;

  if Method = 'initialize' then
  begin
    Ver := SupportedProtocols[1];
    if Params <> nil then
      for I := 0 to High(SupportedProtocols) do
        if Params.Get('protocolVersion', '') = SupportedProtocols[I] then
          Ver := SupportedProtocols[I];
    R := TJSONObject.Create;
    R.Add('protocolVersion', Ver);
    Caps := TJSONObject.Create;
    Caps.Add('tools', TJSONObject.Create(['listChanged', False]));
    R.Add('capabilities', Caps);
    Info := TJSONObject.Create;
    Info.Add('name', 'bgrazip');
    Info.Add('title', 'BGRA Zip');
    Info.Add('version', ServerVersion);
    R.Add('serverInfo', Info);
    R.Add('instructions',
      'Tools for ZIP and RAR archives: inspect structure (archive_info, list_entries, hex_dump), verify ' +
      '(test_archive), extract (extract_archive), create ZIP (create_zip) and automate with scripts (run_script, ' +
    'check_script, script_functions). gui_* tools control the BGRA Zip ' +
      'desktop window. Paths are absolute Windows paths.');
    SendResult(Id, R);
    LogErr('initialized, protocol ' + Ver);
  end
  else if Method = 'ping' then
    SendResult(Id, TJSONObject.Create)
  else if Method = 'tools/list' then
    SendResult(Id, ToolsListJSON)
  else if Method = 'tools/call' then
  begin
    if Params = nil then
    begin
      SendError(Id, -32602, 'missing params');
      Exit;
    end;
    Args := Params.Get('arguments', TJSONObject(nil));
    if Args = nil then
    begin
      Args := TJSONObject.Create;
      Params.Add('arguments', Args);
    end;
    LogErr('call ' + Params.Get('name', ''));
    SendResult(Id, CallTool(Params.Get('name', ''), Args));
  end
  else if (Method = 'resources/list') then
    SendResult(Id, TJSONObject.Create(['resources', TJSONArray.Create]))
  else if (Method = 'prompts/list') then
    SendResult(Id, TJSONObject.Create(['prompts', TJSONArray.Create]))
  else
    SendError(Id, -32601, 'method not found: ' + Method);
end;

procedure HandleLine(const ALine: string);
var
  D: TJSONData;
  I: Integer;
begin
  if Trim(ALine) = '' then
    Exit;
  try
    D := ParseJSON(ALine);
  except
    on E: Exception do
    begin
      SendError(nil, -32700, 'parse error: ' + E.Message);
      Exit;
    end;
  end;
  try
    if D is TJSONObject then
      HandleMessage(TJSONObject(D))
    else if D is TJSONArray then
    begin
      for I := 0 to TJSONArray(D).Count - 1 do
        if TJSONArray(D).Items[I] is TJSONObject then
          HandleMessage(TJSONObject(TJSONArray(D).Items[I]));
    end
    else
      SendError(nil, -32600, 'invalid request');
  finally
    D.Free;
  end;
end;

var
  StdIn: THandleStream;
  Buf: array[0..65535] of Char;
  Pending: string;
  N, P: Integer;
begin
  StdIn := THandleStream.Create(StdInputHandle);
  StdOut := THandleStream.Create(StdOutputHandle);
  StdErr := THandleStream.Create(StdErrorHandle);
  RegisterTools;
  LogErr(Format('BGRA Zip MCP server %s ready (%d tools, IPC pipe %s)', [ServerVersion, Length(Tools), IPCPipeName]));
  Pending := '';
  repeat
    N := StdIn.Read(Buf, SizeOf(Buf));
    if N <= 0 then
      Break;
    SetLength(Pending, Length(Pending) + N);
    Move(Buf, Pending[Length(Pending) - N + 1], N);
    repeat
      P := Pos(#10, Pending);
      if P = 0 then
        Break;
      HandleLine(TrimRight(Copy(Pending, 1, P - 1)));
      Delete(Pending, 1, P);
    until False;
  until False;
  if Trim(Pending) <> '' then
    HandleLine(Pending);
  LogErr('stdin closed, exiting');
end.
