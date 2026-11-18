unit uRarBackend;

{ RAR decompression / compression through external command-line tools.
  RAR's compression algorithm is proprietary, so instead of an in-process
  decoder the app drives whichever tool is installed, in this order:

    rar.exe     WinRAR console   - list / test / extract / CREATE
    unrar.exe   freeware UnRAR   - test / extract
    7z.exe      7-Zip            - test / extract
    tar.exe     bsdtar/libarchive (built into Windows 10 1803+ / 11) - test / extract

  Creating .rar files is only possible with rar.exe (WinRAR licence). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TRarToolKind = (rtkRar, rtkUnRar, rtk7Zip, rtkBsdTar);

  TRarTool = record
    Kind: TRarToolKind;
    Exe: string;
    Version: string;
  end;
  TRarTools = array of TRarTool;

  TToolLineEvent = procedure(const ALine: string) of object;
  { Receives raw stdout bytes when a command streams file data (tar -O). }
  TToolDataEvent = procedure(const ABuf; ACount: Integer) of object;
  { Called frequently while the tool runs; return True to cancel. }
  TToolPollEvent = function(ABytesOut: Int64): Boolean of object;

  TToolResult = record
    ExitCode: Integer;
    Cancelled: Boolean;
    BytesOut: Int64;          // stdout bytes (used by "test" to measure decompressed data)
    Output: string;           // collected text (stdout unless discarded, plus stderr)
    CommandLine: string;
    Ms: QWord;
  end;

  { Splits a stream of concatenated file contents (in archive order) back into
    entries by their known sizes and checks each entry's CRC32. }
  TStreamVerifier = class
  private
    FNames: TStringList;
    FSizes: array of Int64;
    FCRCs: array of LongWord;
    FCur: Integer;
    FRemaining: Int64;
    FCRC: LongWord;
    procedure Advance;
  public
    Bad: TStringList;
    Verified: Integer;
    ExtraBytes: Int64;
    constructor Create;
    destructor Destroy; override;
    procedure AddEntry(const AName: string; ASize: Int64; ACRC: LongWord);
    procedure Start;
    procedure Feed(const ABuf; ACount: Integer);
    procedure Finish;
    function CurrentName: string;
  end;

const
  RarToolNames: array[TRarToolKind] of string = ('WinRAR rar.exe', 'UnRAR', '7-Zip', 'bsdtar (libarchive)');

function FindRarTools(ARefresh: Boolean = False): TRarTools;
function FindRarExtractor(out ATool: TRarTool): Boolean;
function FindRarCreator(out ATool: TRarTool): Boolean;

procedure BuildExtractArgs(const ATool: TRarTool; const AArchive, AOutDir: string;
  ANames: TStrings; AArgs: TStrings);
procedure BuildTestArgs(const ATool: TRarTool; const AArchive: string; AFileNames: TStrings;
  AArgs: TStrings; out AStreamsData: Boolean);
procedure BuildCreateArgs(const ATool: TRarTool; const AArchive: string; ALevel: Integer;
  ANames: TStrings; AArgs: TStrings);

function RunTool(const ATool: TRarTool; AArgs: TStrings; const AWorkDir: string;
  AOnData: TToolDataEvent; AOnLine: TToolLineEvent; AOnPoll: TToolPollEvent): TToolResult;

{ Strips tool-specific decoration ("x ", "Extracting  ", "- ", trailing "OK")
  from a progress line and returns the archive name it mentions, or ''. }
function ProgressLineName(const ATool: TRarTool; const ALine: string): string;

implementation

uses
  Process, LazUTF8, LazFileUtils, FileUtil, crc, uDevLog;

var
  GTools: TRarTools;
  GToolsScanned: Boolean = False;

function QuoteArg(const S: string): string;
begin
  if (S = '') or (Pos(' ', S) > 0) or (Pos(#9, S) > 0) then
    Result := '"' + S + '"'
  else
    Result := S;
end;

function FirstLines(const AExe: string; const AArgs: array of string): string;
var
  P: TProcess;
  SL: TStringList;
  Buf: array[0..4095] of Byte;
  N: Integer;
  S: string;
  T0: QWord;
  I: Integer;
begin
  Result := '';
  P := TProcess.Create(nil);
  SL := TStringList.Create;
  try
    P.Executable := AExe;
    for I := 0 to High(AArgs) do
      P.Parameters.Add(AArgs[I]);
    P.Options := [poUsePipes, poNoConsole, poStderrToOutPut];
    P.ShowWindow := swoHide;
    try
      P.Execute;
    except
      Exit;
    end;
    S := '';
    T0 := GetTickCount64;
    while (P.Running or (P.Output.NumBytesAvailable > 0)) and (GetTickCount64 - T0 < 3000) do
    begin
      if P.Output.NumBytesAvailable > 0 then
      begin
        N := P.Output.Read(Buf, SizeOf(Buf));
        SetLength(S, Length(S) + N);
        Move(Buf, S[Length(S) - N + 1], N);
        if Length(S) > 4096 then
          Break;
      end
      else
        Sleep(10);
    end;
    if P.Running then
      P.Terminate(0);
    SL.Text := ConsoleToUTF8(S);
    for I := 0 to SL.Count - 1 do
      if Trim(SL[I]) <> '' then
        Exit(Trim(SL[I]));
  finally
    SL.Free;
    P.Free;
  end;
end;

function FindRarTools(ARefresh: Boolean): TRarTools;

  procedure Check(AKind: TRarToolKind; const AExe: string);
  var
    I, N: Integer;
    V: string;
  begin
    if (AExe = '') or not FileExistsUTF8(AExe) then
      Exit;
    for I := 0 to High(GTools) do
      if SameText(GTools[I].Exe, AExe) or (GTools[I].Kind = AKind) then
        Exit;
    case AKind of
      rtkBsdTar: V := FirstLines(AExe, ['--version']);
      rtk7Zip: V := FirstLines(AExe, ['i']);
    else
      V := FirstLines(AExe, ['-?']);
    end;
    N := Length(GTools);
    SetLength(GTools, N + 1);
    GTools[N].Kind := AKind;
    GTools[N].Exe := AExe;
    GTools[N].Version := V;
    DevLogFmt(llDebug, 'RAR tool found: %s = %s  [%s]', [RarToolNames[AKind], AExe, V]);
  end;

var
  Roots: array[0..1] of string;
  R: string;
begin
  if GToolsScanned and not ARefresh then
    Exit(GTools);
  SetLength(GTools, 0);
  // 32-bit build on 64-bit Windows: %ProgramFiles% is the x86 folder, so check both
  Roots[0] := GetEnvironmentVariableUTF8('ProgramW6432');
  Roots[1] := GetEnvironmentVariableUTF8('ProgramFiles');
  for R in Roots do
    if R <> '' then
    begin
      Check(rtkRar, AppendPathDelim(R) + 'WinRAR\Rar.exe');
      Check(rtkUnRar, AppendPathDelim(R) + 'WinRAR\UnRAR.exe');
      Check(rtk7Zip, AppendPathDelim(R) + '7-Zip\7z.exe');
    end;
  R := GetEnvironmentVariableUTF8('ProgramFiles(x86)');
  if R <> '' then
  begin
    Check(rtkRar, AppendPathDelim(R) + 'WinRAR\Rar.exe');
    Check(rtkUnRar, AppendPathDelim(R) + 'WinRAR\UnRAR.exe');
    Check(rtk7Zip, AppendPathDelim(R) + '7-Zip\7z.exe');
  end;
  Check(rtkRar, FindDefaultExecutablePath('rar.exe'));
  Check(rtkUnRar, FindDefaultExecutablePath('unrar.exe'));
  Check(rtk7Zip, FindDefaultExecutablePath('7z.exe'));
  {$IFDEF WINDOWS}
  // Sysnative reaches the real System32 from a 32-bit process
  Check(rtkBsdTar, GetEnvironmentVariableUTF8('WINDIR') + '\Sysnative\tar.exe');
  Check(rtkBsdTar, GetEnvironmentVariableUTF8('WINDIR') + '\System32\tar.exe');
  {$ENDIF}
  Check(rtkBsdTar, FindDefaultExecutablePath('bsdtar.exe'));
  GToolsScanned := True;
  Result := GTools;
end;

function FindRarExtractor(out ATool: TRarTool): Boolean;
var
  T: TRarTools;
  K: TRarToolKind;
  I: Integer;
begin
  T := FindRarTools;
  for K := Low(TRarToolKind) to High(TRarToolKind) do
    for I := 0 to High(T) do
      if T[I].Kind = K then
      begin
        ATool := T[I];
        Exit(True);
      end;
  Result := False;
end;

function FindRarCreator(out ATool: TRarTool): Boolean;
var
  T: TRarTools;
  I: Integer;
begin
  T := FindRarTools;
  for I := 0 to High(T) do
    if T[I].Kind = rtkRar then
    begin
      ATool := T[I];
      Exit(True);
    end;
  Result := False;
end;

function WinName(const S: string): string;
begin
  Result := StringReplace(S, '/', '\', [rfReplaceAll]);
end;

procedure BuildExtractArgs(const ATool: TRarTool; const AArchive, AOutDir: string;
  ANames: TStrings; AArgs: TStrings);
var
  I: Integer;
begin
  AArgs.Clear;
  case ATool.Kind of
    rtkRar, rtkUnRar:
      begin
        // x = keep paths, -y yes to all, -o+ overwrite, -p- never ask for a password
        AArgs.AddStrings(['x', '-y', '-o+', '-p-', AArchive]);
        if ANames <> nil then
          for I := 0 to ANames.Count - 1 do
            AArgs.Add(WinName(ANames[I]));
        AArgs.Add(IncludeTrailingPathDelimiter(AOutDir));
      end;
    rtk7Zip:
      begin
        AArgs.AddStrings(['x', '-y', '-bb1', '-o' + AOutDir, AArchive]);
        if ANames <> nil then
          for I := 0 to ANames.Count - 1 do
            AArgs.Add(WinName(ANames[I]));
      end;
    rtkBsdTar:
      begin
        AArgs.AddStrings(['-x', '-v', '-f', AArchive, '-C', AOutDir]);
        if ANames <> nil then
          AArgs.AddStrings(ANames);
      end;
  end;
end;

procedure BuildTestArgs(const ATool: TRarTool; const AArchive: string; AFileNames: TStrings;
  AArgs: TStrings; out AStreamsData: Boolean);
var
  I: Integer;
begin
  AArgs.Clear;
  AStreamsData := False;
  case ATool.Kind of
    // rar / 7z test the whole archive unless names are given (used to leave
    // password-protected entries out)
    rtkRar, rtkUnRar, rtk7Zip:
      begin
        if ATool.Kind = rtk7Zip then
          AArgs.AddStrings(['t', '-bb1', AArchive])
        else
          AArgs.AddStrings(['t', '-p-', AArchive]);
        if AFileNames <> nil then
          for I := 0 to AFileNames.Count - 1 do
            AArgs.Add(WinName(AFileNames[I]));
      end;
    rtkBsdTar:
      begin
        // libarchive does not verify CRC of stored RAR entries and rejects
        // directories with -O, so stream the named files to stdout and let the
        // caller check every entry's CRC32 itself (files arrive in archive order).
        AArgs.AddStrings(['-x', '-O', '-f', AArchive]);
        AArgs.AddStrings(AFileNames);
        AStreamsData := True;
      end;
  end;
end;

procedure BuildCreateArgs(const ATool: TRarTool; const AArchive: string; ALevel: Integer;
  ANames: TStrings; AArgs: TStrings);
begin
  // a = add, -ma5 RAR5 format, -m0..-m5 method, -y yes to all, -ep? not used:
  // names are passed relative to the working directory so paths are kept.
  AArgs.Clear;
  AArgs.AddStrings(['a', '-ma5', '-m' + IntToStr(ALevel), '-y', AArchive]);
  AArgs.AddStrings(ANames);
end;

function RunTool(const ATool: TRarTool; AArgs: TStrings; const AWorkDir: string;
  AOnData: TToolDataEvent; AOnLine: TToolLineEvent; AOnPoll: TToolPollEvent): TToolResult;
var
  P: TProcess;
  Buf: array[0..65535] of Byte;
  OutPending, ErrPending, AllText: string;
  I: Integer;
  T0: QWord;
  BytesOut: Int64;
  Cancelled: Boolean;

  procedure Lines(var APending: string; AFlush: Boolean);
  var
    K: Integer;
    L: string;
  begin
    repeat
      K := 1;
      while (K <= Length(APending)) and not (APending[K] in [#10, #13]) do
        Inc(K);
      if (K > Length(APending)) and not AFlush then
        Break;
      L := Copy(APending, 1, K - 1);
      Delete(APending, 1, K);
      // rar redraws percentages with backspaces
      L := Trim(StringReplace(L, #8, '', [rfReplaceAll]));
      if L <> '' then
      begin
        L := ConsoleToUTF8(L);
        AllText := AllText + L + LineEnding;
        if Assigned(AOnLine) then
          AOnLine(L);
      end;
    until APending = '';
  end;

  function Drain: Boolean;
  var
    N: Integer;
  begin
    Result := False;
    if P.Output.NumBytesAvailable > 0 then
    begin
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then
        Result := True;
      Inc(BytesOut, N);
      if Assigned(AOnData) then
      begin
        if N > 0 then
          AOnData(Buf, N);
      end
      else
      begin
        SetLength(OutPending, Length(OutPending) + N);
        Move(Buf, OutPending[Length(OutPending) - N + 1], N);
        Lines(OutPending, False);
      end;
    end;
    if P.Stderr.NumBytesAvailable > 0 then
    begin
      N := P.Stderr.Read(Buf, SizeOf(Buf));
      if N > 0 then
        Result := True;
      SetLength(ErrPending, Length(ErrPending) + N);
      Move(Buf, ErrPending[Length(ErrPending) - N + 1], N);
      Lines(ErrPending, False);
    end;
  end;

begin
  Result := Default(TToolResult);
  BytesOut := 0;
  Cancelled := False;
  OutPending := '';
  ErrPending := '';
  AllText := '';
  Result.CommandLine := QuoteArg(ATool.Exe);
  for I := 0 to AArgs.Count - 1 do
    // never log a password ("-pSecret"); "-p-" (no password) is harmless
    if (Copy(AArgs[I], 1, 2) = '-p') and (Length(AArgs[I]) > 2) and (AArgs[I] <> '-p-') then
      Result.CommandLine := Result.CommandLine + ' -p***'
    else
      Result.CommandLine := Result.CommandLine + ' ' + QuoteArg(AArgs[I]);
  DevLog(llDebug, 'Run: ' + Result.CommandLine);
  T0 := GetTickCount64;
  P := TProcess.Create(nil);
  try
    P.Executable := ATool.Exe;
    P.Parameters.Assign(AArgs);
    if AWorkDir <> '' then
      P.CurrentDirectory := AWorkDir;
    P.Options := [poUsePipes, poNoConsole];
    P.ShowWindow := swoHide;
    P.Execute;
    // stdin is not used: closing it makes any password prompt fail instead of hanging
    P.CloseInput;
    while P.Running do
    begin
      if not Drain then
        Sleep(5);
      if Assigned(AOnPoll) and AOnPoll(BytesOut) then
      begin
        Cancelled := True;
        P.Terminate(255);
        Break;
      end;
    end;
    while Drain do ;
    Lines(OutPending, True);
    Lines(ErrPending, True);
    if not Cancelled then
      Result.ExitCode := P.ExitStatus
    else
      Result.ExitCode := -1;
  finally
    P.Free;
  end;
  Result.Cancelled := Cancelled;
  Result.BytesOut := BytesOut;
  Result.Output := AllText;
  Result.Ms := GetTickCount64 - T0;
  DevLogFmt(llTiming, '%s exited with code %d in %d ms (%d bytes on stdout)',
    [ExtractFileName(ATool.Exe), Result.ExitCode, Result.Ms, Result.BytesOut]);
end;

{ TStreamVerifier }

constructor TStreamVerifier.Create;
begin
  FNames := TStringList.Create;
  Bad := TStringList.Create;
end;

destructor TStreamVerifier.Destroy;
begin
  FNames.Free;
  Bad.Free;
  inherited Destroy;
end;

procedure TStreamVerifier.AddEntry(const AName: string; ASize: Int64; ACRC: LongWord);
var
  N: Integer;
begin
  FNames.Add(AName);
  N := Length(FSizes);
  SetLength(FSizes, N + 1);
  SetLength(FCRCs, N + 1);
  FSizes[N] := ASize;
  FCRCs[N] := ACRC;
end;

procedure TStreamVerifier.Advance;
begin
  // close every entry whose bytes are complete (zero-length entries close at once)
  while (FCur < FNames.Count) and (FRemaining = 0) do
  begin
    if FCRC = FCRCs[FCur] then
      Inc(Verified)
    else
      Bad.Add(Format('%s: CRC mismatch (expected %.8x, got %.8x)', [FNames[FCur], FCRCs[FCur], FCRC]));
    Inc(FCur);
    FCRC := 0;
    if FCur < FNames.Count then
      FRemaining := FSizes[FCur];
  end;
end;

procedure TStreamVerifier.Start;
begin
  FCur := 0;
  FCRC := 0;
  Verified := 0;
  ExtraBytes := 0;
  Bad.Clear;
  if FNames.Count > 0 then
    FRemaining := FSizes[0];
  Advance;
end;

procedure TStreamVerifier.Feed(const ABuf; ACount: Integer);
var
  P: PByte;
  Take: Integer;
begin
  P := @ABuf;
  while ACount > 0 do
  begin
    if FCur >= FNames.Count then
    begin
      Inc(ExtraBytes, ACount);
      Exit;
    end;
    if FRemaining < ACount then
      Take := FRemaining
    else
      Take := ACount;
    FCRC := crc.crc32(FCRC, P, Take);
    Dec(FRemaining, Take);
    Inc(P, Take);
    Dec(ACount, Take);
    Advance;
  end;
end;

procedure TStreamVerifier.Finish;
begin
  while FCur < FNames.Count do
  begin
    Bad.Add(Format('%s: data missing (%d of %d bytes not received)',
      [FNames[FCur], FRemaining, FSizes[FCur]]));
    Inc(FCur);
    if FCur < FNames.Count then
      FRemaining := FSizes[FCur];
  end;
  if ExtraBytes > 0 then
    Bad.Add(Format('%d unexpected extra bytes in the decompressed stream', [ExtraBytes]));
end;

function TStreamVerifier.CurrentName: string;
begin
  if FCur < FNames.Count then
    Result := FNames[FCur]
  else
    Result := '';
end;

function ProgressLineName(const ATool: TRarTool; const ALine: string): string;
var
  S: string;

  function StripPrefix(const APrefix: string): Boolean;
  begin
    Result := Copy(S, 1, Length(APrefix)) = APrefix;
    if Result then
      S := Trim(Copy(S, Length(APrefix) + 1, MaxInt));
  end;

begin
  Result := '';
  S := Trim(ALine);
  case ATool.Kind of
    rtkBsdTar:
      if not StripPrefix('x ') then
        Exit;
    rtk7Zip:
      if not (StripPrefix('- ') or StripPrefix('T ')) then
        Exit;
    rtkRar, rtkUnRar:
      begin
        // "Extracting from <archive>" / "Testing archive <archive>" name the archive, not an entry
        if StripPrefix('Extracting from') or StripPrefix('Testing archive') then
          Exit;
        if not (StripPrefix('Extracting') or StripPrefix('Testing') or
          StripPrefix('Adding') or StripPrefix('Updating') or StripPrefix('Creating')) then
          Exit;
        if Copy(S, Length(S) - 1, 2) = 'OK' then
          S := Trim(Copy(S, 1, Length(S) - 2));
        // trailing percentage left over from redraws
        while (S <> '') and (S[Length(S)] in ['0'..'9', '%', ' ']) and (Pos('%', S) > 0) do
          Delete(S, Length(S), 1);
      end;
  end;
  Result := StringReplace(Trim(S), '\', '/', [rfReplaceAll]);
end;

end.
