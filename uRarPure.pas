unit uRarPure;

{ rar_pure.exe, the archive engine shipped next to BGRA Zip (pure Pascal):
  extracts and creates ZIP and RAR5 archives, including AES passwords.
  No LCL dependency, so the MCP server and the script runner use it too.

  It reads its command line in the ANSI code page, so a path with other
  characters (Thai...) reaches it as '?'. Paths are therefore passed as 8.3
  short names, it always writes into an ASCII staging folder whose result is
  then moved into place, and passwords must be ASCII. Names *inside* archives
  and folders it walks itself are fine in any language. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, uRarBackend;

type
  TRarPureResult = record
    ExitCode: Integer;
    Cancelled: Boolean;
    Files, Skipped, Failed, CrcErrors: Integer;
    Bytes: Int64;
    Message: string;     // the tool's failure line ("Wrong password: a.txt"), '' when fine
    Output: string;
  end;

  { Bytes written so far (extracted files or the new archive); return True to cancel }
  TRarPureProgress = function(ABytes: Int64): Boolean of object;

  ERarPure = class(Exception);
  { A path rar_pure cannot receive (a non-ASCII name it would have to store) }
  ERarPureName = class(ERarPure);

{ Full path of rar_pure.exe next to the running program, '' when it is missing }
function RarPureExe: string;
function IsAsciiText(const S: string): Boolean;
{ Raises ERarPure for a password rar_pure cannot receive }
procedure CheckRarPurePassword(const APassword: string);
{ True when the failure is a wrong (or missing) password }
function IsPasswordFailure(const R: TRarPureResult): Boolean;

{ Extracts everything (ANames nil/empty) or the listed entries (a folder name
  takes its contents) to ADest, overwriting. Entries rar_pure skipped because
  they need a password are counted in Skipped. }
function RarPureExtract(const AArchive, ADest, APassword: string; ANames: TStrings;
  AOnProgress: TRarPureProgress): TRarPureResult;
{ Extracts into a temporary folder, checking every CRC, and deletes it again }
function RarPureTest(const AArchive, APassword: string; AOnProgress: TRarPureProgress): TRarPureResult;
{ Writes AOut (.zip, .rar or .7z, from the extension), replacing it. Every
  source is a file or folder stored under its own name, which must be ASCII
  (ERarPure otherwise). ALevel 0 (store) .. 9. }
function RarPureCreate(const AOut: string; ASources: TStrings; ALevel: Integer; const APassword: string;
  AZipCrypto, AEncryptNames: Boolean; AOnProgress: TRarPureProgress): TRarPureResult;

{ Staging helpers: an empty ASCII temp folder (with trailing delimiter), a hard
  link of ASource at ADest (a copy across drives), and removal of the folder.
  Removing hard links never touches the original files. }
function NewStageDir: string;
procedure StageFile(const ASource, ADest: string);
procedure RemoveStageDir(const ADir: string);

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF} LazFileUtils, LazUTF8, FileUtil;

{$IFDEF WINDOWS}
function CreateHardLinkW(lpFileName, lpExistingFileName: PWideChar; lpSecurityAttributes: Pointer): BOOL;
  stdcall; external 'kernel32.dll';
{$ENDIF}

type
  { Turns RunTool's frequent polls into "bytes written so far" reports }
  TPureWatch = class
  private
    FPath: string;
    FOnProgress: TRarPureProgress;
    FLast: QWord;
    FCancel: Boolean;
  public
    constructor Create(const APath: string; AOnProgress: TRarPureProgress);
    function Poll(ABytesOut: Int64): Boolean;
  end;

function SizeOfPath(const APath: string): Int64;
var
  SR: TSearchRec;
begin
  Result := 0;
  if FileExistsUTF8(APath) and not DirectoryExistsUTF8(APath) then
    Exit(FileSizeUtf8(APath));
  if FindFirstUTF8(IncludeTrailingPathDelimiter(APath) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      if (SR.Attr and faDirectory) <> 0 then
        Inc(Result, SizeOfPath(IncludeTrailingPathDelimiter(APath) + SR.Name))
      else
        Inc(Result, SR.Size);
    until FindNextUTF8(SR) <> 0;
  finally
    FindCloseUTF8(SR);
  end;
end;

constructor TPureWatch.Create(const APath: string; AOnProgress: TRarPureProgress);
begin
  FPath := APath;
  FOnProgress := AOnProgress;
end;

function TPureWatch.Poll(ABytesOut: Int64): Boolean;
begin
  if Assigned(FOnProgress) and (GetTickCount64 - FLast >= 300) then
  begin
    FLast := GetTickCount64;
    FCancel := FOnProgress(SizeOfPath(FPath));
  end;
  Result := FCancel;
end;

function RarPureExe: string;
begin
  Result := ExtractFilePath(ParamStrUTF8(0)) + 'rar_pure.exe';
  if not FileExistsUTF8(Result) then
    Result := '';
end;

function IsAsciiText(const S: string): Boolean;
var
  I: Integer;
begin
  for I := 1 to Length(S) do
    if Ord(S[I]) > 126 then
      Exit(False);
  Result := True;
end;

procedure CheckRarPurePassword(const APassword: string);
begin
  if not IsAsciiText(APassword) then
    raise ERarPure.Create('the password may only use English letters, digits and symbols ' +
      '(rar_pure.exe cannot receive other characters)');
end;

function IsPasswordFailure(const R: TRarPureResult): Boolean;
begin
  Result := (Pos('password', LowerCase(R.Message)) > 0);
end;

function ShortPath(const APath: string): string;
{$IFDEF WINDOWS}
var
  W, S: UnicodeString;
  N: DWORD;
begin
  Result := APath;
  W := UTF8Decode(APath);
  N := GetShortPathNameW(PWideChar(W), nil, 0);
  if N = 0 then
    Exit;
  SetLength(S, N);
  N := GetShortPathNameW(PWideChar(W), PWideChar(S), N);
  if N > 0 then
  begin
    SetLength(S, N);
    Result := UTF8Encode(S);
  end;
end;
{$ELSE}
begin
  Result := APath;
end;
{$ENDIF}

{ An existing path in a form rar_pure can receive, or '' }
function Passable(const APath: string): string;
begin
  if IsAsciiText(APath) then
    Exit(APath);
  Result := ShortPath(APath);
  if not IsAsciiText(Result) then
    Result := '';
end;

function NewStageDir: string;
var
  Base: string;
begin
  Base := GetTempDir(False);
  if not IsAsciiText(Base) then
    Base := IncludeTrailingPathDelimiter(ShortPath(ExcludeTrailingPathDelimiter(Base)));
  Result := Format('%sbgrazip-%x-%d%s', [Base, GetTickCount64, Random(1000000), PathDelim]);
  if not ForceDirectoriesUTF8(Result) then
    raise ERarPure.Create('cannot create a temporary folder in ' + Base);
end;

procedure StageFile(const ASource, ADest: string);
begin
  ForceDirectoriesUTF8(ExtractFileDir(ADest));
  {$IFDEF WINDOWS}
  if CreateHardLinkW(PWideChar(UTF8Decode(ADest)), PWideChar(UTF8Decode(ASource)), nil) then
    Exit;
  {$ENDIF}
  if not CopyFile(ASource, ADest, [cffPreserveTime]) then
    raise ERarPure.Create('cannot stage ' + ASource);
end;

procedure RemoveStageDir(const ADir: string);
begin
  if (ADir <> '') and DirectoryExistsUTF8(ADir) then
    DeleteDirectory(ExcludeTrailingPathDelimiter(ADir), False);
end;

{ The number after "AKey=" in ALine, or 0 }
function KeyNum(const ALine, AKey: string): Int64;
var
  P, E: Integer;
begin
  Result := 0;
  P := Pos(AKey + '=', ALine);
  if P = 0 then
    Exit;
  Inc(P, Length(AKey) + 1);
  E := P;
  while (E <= Length(ALine)) and (ALine[E] in ['0'..'9']) do
    Inc(E);
  Result := StrToInt64Def(Copy(ALine, P, E - P), 0);
end;

function RunPure(AArgs: TStrings; const AWatch: string; AOnProgress: TRarPureProgress): TRarPureResult;
var
  Tool: TRarTool;
  Watch: TPureWatch;
  R: TToolResult;
  Lines: TStringList;
  L: string;
  I: Integer;
begin
  Result := Default(TRarPureResult);
  Tool := Default(TRarTool);
  Tool.Kind := rtkRar;
  Tool.Exe := RarPureExe;
  if Tool.Exe = '' then
    raise ERarPure.Create('rar_pure.exe was not found next to the program');
  Watch := TPureWatch.Create(AWatch, AOnProgress);
  try
    R := RunTool(Tool, AArgs, '', nil, nil, @Watch.Poll);
  finally
    Watch.Free;
  end;
  Result.ExitCode := R.ExitCode;
  Result.Cancelled := R.Cancelled;
  Result.Output := R.Output;
  Lines := TStringList.Create;
  try
    Lines.Text := R.Output;
    for I := 0 to Lines.Count - 1 do
    begin
      L := Trim(Lines[I]);
      if (Pos('files=', L) = 1) then
      begin
        Result.Files := KeyNum(L, 'files');
        Result.Skipped := KeyNum(L, 'skipped');
        Result.Failed := KeyNum(L, 'failed');
        Result.CrcErrors := KeyNum(L, 'crcErrors');
        Result.Bytes := KeyNum(L, 'bytes');
      end
      else if Result.Message = '' then
        if Pos('Extraction: FAILED - ', L) = 1 then
          Result.Message := Copy(L, Length('Extraction: FAILED - ') + 1, MaxInt)
        else if Pos('Error: ', L) = 1 then
          Result.Message := Copy(L, Length('Error: ') + 1, MaxInt)
        else if Pos('encrypted headers', L) > 0 then
          Result.Message := 'the file names are encrypted, a password is needed';
    end;
  finally
    Lines.Free;
  end;
  if (Result.ExitCode <> 0) and (Result.Message = '') and not Result.Cancelled then
    Result.Message := Format('rar_pure exit code %d', [Result.ExitCode]);
end;

{ The archive as a path rar_pure can open: as is, its short name, or a link in AStage }
function InputPath(const AArchive, AStage: string): string;
var
  Ext: string;
begin
  Result := Passable(AArchive);
  if Result <> '' then
    Exit;
  Ext := LowerCase(ExtractFileExt(AArchive));
  if not IsAsciiText(Ext) then
    Ext := '';
  Result := AStage + 'input' + Ext;
  StageFile(AArchive, Result);
end;

{ ARel is wanted when it is listed, or lies inside a listed folder ("docs" or "docs/") }
function Wanted(const ARel: string; ANames: TStrings): Boolean;
var
  I: Integer;
  N: string;
begin
  if (ANames = nil) or (ANames.Count = 0) then
    Exit(True);
  for I := 0 to ANames.Count - 1 do
  begin
    N := StringReplace(ANames[I], '\', '/', [rfReplaceAll]);
    while (N <> '') and (N[Length(N)] = '/') do
      Delete(N, Length(N), 1);
    if SameText(ARel, N) or SameText(Copy(ARel, 1, Length(N) + 1), N + '/') then
      Exit(True);
  end;
  Result := False;
end;

procedure MoveInto(const ASrcFile, ADestFile: string);
begin
  ForceDirectoriesUTF8(ExtractFileDir(ADestFile));
  if FileExistsUTF8(ADestFile) then
    DeleteFileUTF8(ADestFile);
  if not RenameFileUTF8(ASrcFile, ADestFile) then
    if not CopyFile(ASrcFile, ADestFile, [cffOverwriteFile, cffPreserveTime]) then
      raise ERarPure.Create('cannot write ' + ADestFile);
end;

{ Moves the wanted files of the extracted tree ASrc into ADest; returns the file count }
function MoveTree(const ASrc, ADest, ARel: string; ANames: TStrings): Integer;
var
  SR: TSearchRec;
  Rel, Dir: string;
begin
  Result := 0;
  Dir := IncludeTrailingPathDelimiter(ASrc);
  if FindFirstUTF8(Dir + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then
        Continue;
      if ARel = '' then
        Rel := SR.Name
      else
        Rel := ARel + '/' + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if Wanted(Rel, ANames) then
          ForceDirectoriesUTF8(IncludeTrailingPathDelimiter(ADest) + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]));
        Inc(Result, MoveTree(Dir + SR.Name, ADest, Rel, ANames));
      end
      else if Wanted(Rel, ANames) then
      begin
        MoveInto(Dir + SR.Name, IncludeTrailingPathDelimiter(ADest) + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]));
        Inc(Result);
      end;
    until FindNextUTF8(SR) <> 0;
  finally
    FindCloseUTF8(SR);
  end;
end;

function RunExtract(const AArchive, AOutDir, AStage, APassword: string;
  AOnProgress: TRarPureProgress): TRarPureResult;
var
  Args: TStringList;
begin
  CheckRarPurePassword(APassword);
  Args := TStringList.Create;
  try
    Args.Add(InputPath(AArchive, AStage));
    Args.Add(AOutDir);
    if APassword <> '' then
      Args.Add('-p' + APassword);
    Result := RunPure(Args, AOutDir, AOnProgress);
  finally
    Args.Free;
  end;
end;

function RarPureExtract(const AArchive, ADest, APassword: string; ANames: TStrings;
  AOnProgress: TRarPureProgress): TRarPureResult;
var
  Stage, OutDir: string;
begin
  if not ForceDirectoriesUTF8(ADest) then
    raise ERarPure.Create('cannot create destination folder: ' + ADest);
  Stage := NewStageDir;
  try
    OutDir := Stage + 'out';
    ForceDirectoriesUTF8(OutDir);
    Result := RunExtract(AArchive, OutDir, Stage, APassword, AOnProgress);
    // what was extracted is delivered even when other entries failed
    if not Result.Cancelled then
      Result.Files := MoveTree(OutDir, ADest, '', ANames);
  finally
    RemoveStageDir(Stage);
  end;
end;

function RarPureTest(const AArchive, APassword: string; AOnProgress: TRarPureProgress): TRarPureResult;
var
  Stage: string;
begin
  Stage := NewStageDir;
  try
    ForceDirectoriesUTF8(Stage + 'out');
    Result := RunExtract(AArchive, Stage + 'out', Stage, APassword, AOnProgress);
  finally
    RemoveStageDir(Stage);
  end;
end;

{ A source as rar_pure can take it: its own name must stay readable, since that is the stored name }
function SourcePath(const ASource: string): string;
var
  Src, Name, Dir: string;
begin
  Src := ExcludeTrailingPathDelimiter(ASource);
  if not (FileExistsUTF8(Src) or DirectoryExistsUTF8(Src)) then
    raise ERarPure.Create('not found: ' + ASource);
  Name := ExtractFileName(Src);
  if not IsAsciiText(Name) then
    raise ERarPureName.CreateFmt('"%s": rar_pure.exe cannot take a name with non-English letters on its ' +
      'command line (names inside folders are fine)', [Name]);
  Dir := Passable(ExcludeTrailingPathDelimiter(ExtractFilePath(Src)));
  if Dir = '' then
    raise ERarPureName.Create('rar_pure.exe cannot reach ' + ASource + ' (no short name for its folder)');
  Result := IncludeTrailingPathDelimiter(Dir) + Name;
end;

function RarPureCreate(const AOut: string; ASources: TStrings; ALevel: Integer; const APassword: string;
  AZipCrypto, AEncryptNames: Boolean; AOnProgress: TRarPureProgress): TRarPureResult;
var
  Stage, Ext, Tmp: string;
  Args: TStringList;
  I: Integer;
begin
  CheckRarPurePassword(APassword);
  Ext := LowerCase(ExtractFileExt(AOut));
  if (Ext <> '.zip') and (Ext <> '.rar') and (Ext <> '.7z') then
    raise ERarPure.Create('rar_pure.exe writes .zip, .rar or .7z, not "' + Ext + '"');
  if (ASources = nil) or (ASources.Count = 0) then
    raise ERarPure.Create('nothing to compress');
  Stage := NewStageDir;
  Args := TStringList.Create;
  try
    Tmp := Stage + 'new' + Ext;
    Args.Add('a');
    Args.Add(Tmp);
    for I := 0 to ASources.Count - 1 do
      Args.Add(SourcePath(ASources[I]));
    if ALevel < 0 then
      ALevel := 0;
    if ALevel > 9 then
      ALevel := 9;
    Args.Add('-mx' + IntToStr(ALevel));
    if APassword <> '' then
    begin
      Args.Add('-p' + APassword);
      if AZipCrypto and (Ext = '.zip') then
        Args.Add('-zc');
      if AEncryptNames then
        if Ext = '.rar' then
          Args.Add('-hp')
        else if Ext = '.7z' then
          Args.Add('-mhe');
    end;
    ForceDirectoriesUTF8(Stage + 'tmp');
    Args.Add('-tmp' + Stage + 'tmp');
    Result := RunPure(Args, Tmp, AOnProgress);
    if (Result.ExitCode = 0) and not Result.Cancelled then
    begin
      if not FileExistsUTF8(Tmp) then
        raise ERarPure.Create('rar_pure.exe reported success but wrote no archive');
      MoveInto(Tmp, AOut);
    end;
  finally
    Args.Free;
    RemoveStageDir(Stage);
  end;
end;

end.
