unit uArchiveOps;

{ Archive operations without any UI: used by the MCP server and by scripts.
  The GUI keeps its own versions because they report progress and can be
  cancelled. Errors are raised as exceptions. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Zipper, zstream, uArchiveBase;

function OpenArchiveInfo(const APath: string): TArchiveInfo;
{ Decompresses every entry without writing files; problems go to ABad. With a
  password, rar_pure.exe tests the protected entries too. }
procedure TestArchiveInfo(A: TArchiveInfo; ABad: TStrings; const APassword: string = '');
{ ANames empty = all entries. Uses rar_pure.exe when it is next to the program
  (ZIP and RAR; APassword opens protected entries), otherwise the built-in
  unzipper / the RAR tools. Entries that need a password and did not get one
  are reported in the exception raised after the rest has been extracted. }
procedure ExtractArchiveInfo(A: TArchiveInfo; const ADest: string; ANames: TStrings;
  const APassword: string = '');
{ Fills AU.Files with the entries to extract (ANames empty = all), leaving out
  password-protected ones, which go to ASkipped. False when nothing is left:
  then do not call UnZipAllFiles, which treats an empty list as "everything". }
function SelectZipEntries(AU: TUnZipper; ANames, ASkipped: TStrings): Boolean;
{ ALevel: store, fastest, default, maximum. Folders are added under their own
  name. rar_pure.exe when available (APassword = AES-256; AZipCrypto = the
  older encryption Windows Explorer can open), the built-in zipper otherwise. }
procedure CreateZipFile(const AOut: string; ASources: TStrings; const ALevel: string;
  AOverwrite: Boolean; out ACount: Integer; out ATotal: Int64; const APassword: string = '';
  AZipCrypto: Boolean = False);
{ rar_pure.exe, or WinRAR's rar.exe without it. AEncryptNames hides the file names too. }
procedure CreateRarFile(const AOut: string; ASources: TStrings; const ALevel: string; AOverwrite: Boolean;
  const APassword: string = ''; AEncryptNames: Boolean = False);

implementation

uses
  LazUTF8, LazFileUtils, FileUtil, uZipInspector, uRarInspector, uRarBackend, uRarPure;

function PureLevel(const ALevel: string): Integer;
var
  L: string;
begin
  L := LowerCase(ALevel);
  if L = 'store' then Result := 0
  else if L = 'fastest' then Result := 1
  else if L = 'maximum' then Result := 9
  else Result := 5;
end;

type
  { Output sink for testing ZIP entries }
  TDiscardStream = class(TStream)
  private
    FSize: Int64;
  public
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  TZipTestHelper = class
    procedure CreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
    procedure DoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
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

procedure TZipTestHelper.CreateStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  AStream := TDiscardStream.Create;
end;

procedure TZipTestHelper.DoneStream(Sender: TObject; var AStream: TStream; AItem: TFullZipFileEntry);
begin
  FreeAndNil(AStream);
end;

function ChunkArgs(ANames: TStrings; AStart: Integer; out ANext: Integer): TStringList;
var
  Len: Integer;
begin
  // Windows command lines are limited to 32767 characters
  Result := TStringList.Create;
  Len := 0;
  ANext := AStart;
  while (ANext < ANames.Count) and ((Result.Count = 0) or (Len + Length(ANames[ANext]) < 24000)) do
  begin
    Result.Add(ANames[ANext]);
    Inc(Len, Length(ANames[ANext]) + 3);
    Inc(ANext);
  end;
end;

function OpenArchiveInfo(const APath: string): TArchiveInfo;
var
  Fmt: TArchiveFormat;
  Sig: Int64;
begin
  if not FileExistsUTF8(APath) then
    raise Exception.Create('file not found: ' + APath);
  DetectArchiveFormat(APath, Fmt, Sig);
  if Fmt in [afRar4, afRar5] then
    Result := TRarArchiveInfo.Create
  else
    Result := TZipArchiveInfo.Create;
  try
    Result.LoadFromFile(APath);
  except
    Result.Free;
    raise;
  end;
end;

procedure TestArchiveInfo(A: TArchiveInfo; ABad: TStrings; const APassword: string);
const
  SNeedsPassword = 'encrypted - cannot test without the password';
var
  U: TUnZipper;
  H: TZipTestHelper;
  Names, Chunk, ToolArgs, Locked: TStringList;
  V: TStreamVerifier;
  T: TRarTool;
  R: TToolResult;
  P: TRarPureResult;
  Streams: Boolean;
  E: TArchiveEntry;
  I, Next: Integer;
begin
  if APassword <> '' then
  begin
    // only rar_pure can open protected entries; it checks every CRC while extracting
    if RarPureExe = '' then
      raise Exception.Create('testing with a password needs rar_pure.exe next to the program');
    P := RarPureTest(A.FileName, APassword, nil);
    if P.Message <> '' then
      ABad.Add(P.Message)
    else if P.CrcErrors > 0 then
      ABad.Add(Format('%d CRC error(s)', [P.CrcErrors]));
    if P.Skipped > 0 then
      ABad.Add(Format('%d entries could not be opened with this password', [P.Skipped]));
    Exit;
  end;
  if A is TZipArchiveInfo then
  begin
    H := TZipTestHelper.Create;
    Locked := TStringList.Create;
    try
      U := TUnZipper.Create;
      try
        U.FileName := A.FileName;
        U.UseUTF8 := True;
        U.OnCreateStream := @H.CreateStream;
        U.OnDoneStream := @H.DoneStream;
        // password-protected entries cannot be checked: report them, test the rest
        if SelectZipEntries(U, nil, Locked) then
        try
          U.UnZipAllFiles;
        except
          // find every broken entry, not only the first
          for I := 0 to A.Count - 1 do
          begin
            E := A.Entry[I];
            if E.IsDirectory or E.IsEncrypted then
              Continue;
            U.Free;
            U := TUnZipper.Create;
            U.FileName := A.FileName;
            U.UseUTF8 := True;
            U.OnCreateStream := @H.CreateStream;
            U.OnDoneStream := @H.DoneStream;
            try
              U.UnZipFile(E.FileName);
            except
              on Ex: Exception do
                ABad.Add(E.FileName + ': ' + Ex.Message);
            end;
          end;
        end;
      finally
        U.Free;
      end;
      for I := 0 to Locked.Count - 1 do
        ABad.Add(Locked[I] + ': ' + SNeedsPassword);
    finally
      Locked.Free;
      H.Free;
    end;
    Exit;
  end;

  if (A is TRarArchiveInfo) and TRarArchiveInfo(A).HeadersEncrypted then
  begin
    ABad.Add('file names are ' + SNeedsPassword);
    Exit;
  end;
  if not FindRarExtractor(T) then
    raise Exception.Create('no RAR tool found (rar.exe, unrar.exe, 7z.exe or tar.exe)');
  Names := TStringList.Create;
  ToolArgs := TStringList.Create;
  V := TStreamVerifier.Create;
  try
    for I := 0 to A.Count - 1 do
    begin
      E := A.Entry[I];
      if E.IsDirectory then
        Continue;
      if E.IsEncrypted then
      begin
        ABad.Add(E.FileName + ': ' + SNeedsPassword);
        Continue;
      end;
      Names.Add(E.FileName);
      V.AddEntry(E.FileName, E.UncompressedSize, E.CRC32);
    end;
    BuildTestArgs(T, A.FileName, nil, ToolArgs, Streams);
    if not Streams then
    begin
      if A.EncryptedCount = 0 then
      begin
        R := RunTool(T, ToolArgs, '', nil, nil, nil);
        if R.ExitCode > 1 then
          ABad.Add(Format('%s exit code %d: %s', [RarToolNames[T.Kind], R.ExitCode, Trim(R.Output)]));
      end
      else
      begin
        // name only the plain files, or rar fails on the encrypted ones
        Next := 0;
        while Next < Names.Count do
        begin
          Chunk := ChunkArgs(Names, Next, Next);
          try
            BuildTestArgs(T, A.FileName, Chunk, ToolArgs, Streams);
            R := RunTool(T, ToolArgs, '', nil, nil, nil);
            if R.ExitCode > 1 then
              ABad.Add(Format('%s exit code %d: %s', [RarToolNames[T.Kind], R.ExitCode, Trim(R.Output)]));
          finally
            Chunk.Free;
          end;
        end;
      end;
    end
    else
    begin
      V.Start;
      Next := 0;
      while Next < Names.Count do
      begin
        Chunk := ChunkArgs(Names, Next, Next);
        try
          BuildTestArgs(T, A.FileName, Chunk, ToolArgs, Streams);
          R := RunTool(T, ToolArgs, '', @V.Feed, nil, nil);
          if R.ExitCode <> 0 then
            ABad.Add(Format('tar exit code %d: %s', [R.ExitCode, Trim(R.Output)]));
        finally
          Chunk.Free;
        end;
      end;
      V.Finish;
      ABad.AddStrings(V.Bad);
    end;
  finally
    V.Free;
    ToolArgs.Free;
    Names.Free;
  end;
end;

function SelectZipEntries(AU: TUnZipper; ANames, ASkipped: TStrings): Boolean;
var
  E: TFullZipFileEntry;
  Name: string;
  I: Integer;
begin
  AU.Files.Clear;
  AU.Examine;
  for I := 0 to AU.Entries.Count - 1 do
  begin
    E := AU.Entries[I];
    // the same name TUnZipper matches AU.Files against
    if AU.UseUTF8 then
      Name := E.UTF8ArchiveFileName
    else
      Name := E.ArchiveFileName;
    if (ANames <> nil) and (ANames.Count > 0) and (ANames.IndexOf(Name) < 0) then
      Continue;
    if (E.BitFlags and 1) <> 0 then
      ASkipped.Add(Name)
    else
      AU.Files.Add(Name);
  end;
  Result := AU.Files.Count > 0;
end;

procedure RaiseSkipped(ASkipped: TStringList);
begin
  ASkipped.Delimiter := ',';
  ASkipped.StrictDelimiter := True;
  raise Exception.CreateFmt('%d password-protected entries were not extracted: %s',
    [ASkipped.Count, ASkipped.DelimitedText]);
end;

procedure ExtractWithRarPure(A: TArchiveInfo; const ADest: string; ANames: TStrings; const APassword: string);
var
  R: TRarPureResult;
  Skipped: TStringList;
  E: TArchiveEntry;
  I: Integer;
begin
  R := RarPureExtract(A.FileName, ADest, APassword, ANames, nil);
  if R.ExitCode <> 0 then
    raise Exception.Create(R.Message);
  if R.Skipped = 0 then
    Exit;
  // rar_pure reads the whole archive; complain only about wanted entries
  Skipped := TStringList.Create;
  try
    for I := 0 to A.Count - 1 do
    begin
      E := A.Entry[I];
      if E.IsEncrypted and not E.IsDirectory and
        ((ANames = nil) or (ANames.Count = 0) or (ANames.IndexOf(E.FileName) >= 0)) then
        Skipped.Add(E.FileName);
    end;
    if Skipped.Count > 0 then
      RaiseSkipped(Skipped);
  finally
    Skipped.Free;
  end;
end;

procedure ExtractArchiveInfo(A: TArchiveInfo; const ADest: string; ANames: TStrings; const APassword: string);
var
  Chunk, ToolArgs, Skipped, Plain: TStringList;
  U: TUnZipper;
  T: TRarTool;
  R: TToolResult;
  E: TArchiveEntry;
  I, Next: Integer;
  HasNames: Boolean;
begin
  if not ForceDirectoriesUTF8(ADest) then
    raise Exception.Create('cannot create destination folder: ' + ADest);
  if RarPureExe <> '' then
  begin
    ExtractWithRarPure(A, ADest, ANames, APassword);
    Exit;
  end;
  if APassword <> '' then
    raise Exception.Create('opening password-protected entries needs rar_pure.exe next to the program');
  HasNames := (ANames <> nil) and (ANames.Count > 0);
  if A is TZipArchiveInfo then
  begin
    Skipped := TStringList.Create;
    U := TUnZipper.Create;
    try
      U.FileName := A.FileName;
      U.OutputPath := ADest;
      U.UseUTF8 := True;
      if SelectZipEntries(U, ANames, Skipped) then
        U.UnZipAllFiles;
      if Skipped.Count > 0 then
        RaiseSkipped(Skipped);
    finally
      U.Free;
      Skipped.Free;
    end;
    Exit;
  end;

  if (A is TRarArchiveInfo) and TRarArchiveInfo(A).HeadersEncrypted then
    raise Exception.Create('the file names are encrypted - nothing can be extracted without the password');
  if not FindRarExtractor(T) then
    raise Exception.Create('no RAR tool found (rar.exe, unrar.exe, 7z.exe or tar.exe)');
  ToolArgs := TStringList.Create;
  Skipped := TStringList.Create;
  Plain := TStringList.Create;
  try
    // name only the plain entries, or the tool fails on the protected ones
    if A.EncryptedCount > 0 then
    begin
      for I := 0 to A.Count - 1 do
      begin
        E := A.Entry[I];
        if HasNames and (ANames.IndexOf(E.FileName) < 0) then
          Continue;
        // a folder named to rar brings its (encrypted) contents along: make it here
        if E.IsDirectory then
          ForceDirectoriesUTF8(IncludeTrailingPathDelimiter(ADest) +
            StringReplace(E.FileName, '/', PathDelim, [rfReplaceAll]))
        else if E.IsEncrypted then
          Skipped.Add(E.FileName)
        else
          Plain.Add(E.FileName);
      end;
      ANames := Plain;
      HasNames := True;
    end;
    R := Default(TToolResult);
    if not HasNames then
    begin
      BuildExtractArgs(T, A.FileName, ADest, nil, ToolArgs);
      R := RunTool(T, ToolArgs, '', nil, nil, nil);
    end
    else
    begin
      Next := 0;
      while Next < ANames.Count do
      begin
        Chunk := ChunkArgs(ANames, Next, Next);
        try
          BuildExtractArgs(T, A.FileName, ADest, Chunk, ToolArgs);
          R := RunTool(T, ToolArgs, '', nil, nil, nil);
        finally
          Chunk.Free;
        end;
        if R.ExitCode > 1 then
          Break;
      end;
    end;
    if R.ExitCode <> 0 then
      raise Exception.CreateFmt('%s exit code %d: %s', [RarToolNames[T.Kind], R.ExitCode, Trim(R.Output)]);
    if Skipped.Count > 0 then
      RaiseSkipped(Skipped);
  finally
    Plain.Free;
    Skipped.Free;
    ToolArgs.Free;
  end;
end;

{ True when rar_pure wrote AOut; False when it is missing or cannot take a
  source name and there is no password, so the caller's own tool may try }
function CreateWithRarPure(const AOut: string; ASources: TStrings; const ALevel, APassword: string;
  AZipCrypto, AEncryptNames: Boolean; out R: TRarPureResult): Boolean;
begin
  Result := False;
  R := Default(TRarPureResult);
  if RarPureExe = '' then
  begin
    if APassword <> '' then
      raise Exception.Create('a password needs rar_pure.exe next to the program');
    Exit;
  end;
  try
    R := RarPureCreate(AOut, ASources, PureLevel(ALevel), APassword, AZipCrypto, AEncryptNames, nil);
  except
    on E: ERarPureName do
      if APassword <> '' then
        raise
      else
        Exit;
  end;
  if R.ExitCode <> 0 then
    raise Exception.Create(R.Message);
  Result := True;
end;

procedure CreateZipFile(const AOut: string; ASources: TStrings; const ALevel: string;
  AOverwrite: Boolean; out ACount: Integer; out ATotal: Int64; const APassword: string;
  AZipCrypto: Boolean);
var
  Src, Base, Root, Lvl: string;
  Found: TStringList;
  Z: TZipper;
  Level: TCompressionLevel;
  I, J: Integer;
  P: TRarPureResult;
begin
  ACount := 0;
  ATotal := 0;
  if (ASources = nil) or (ASources.Count = 0) then
    raise Exception.Create('"sources" must list at least one file or folder');
  if FileExistsUTF8(AOut) and not AOverwrite then
    raise Exception.Create('output exists; pass "overwrite": true to replace it');
  if CreateWithRarPure(AOut, ASources, ALevel, APassword, AZipCrypto, False, P) then
  begin
    ACount := P.Files;
    ATotal := P.Bytes;
    Exit;
  end;
  Lvl := LowerCase(ALevel);
  if Lvl = 'store' then Level := clnone
  else if Lvl = 'fastest' then Level := clfastest
  else if Lvl = 'maximum' then Level := clmax
  else Level := cldefault;
  Z := TZipper.Create;
  try
    Z.FileName := AOut;
    Z.UseLanguageEncoding := True;
    for I := 0 to ASources.Count - 1 do
    begin
      Src := ExcludeTrailingPathDelimiter(ASources[I]);
      if DirectoryExistsUTF8(Src) then
      begin
        Base := IncludeTrailingPathDelimiter(Src);
        Root := ExtractFileName(Src);
        Found := FindAllFiles(Src, '', True);
        try
          for J := 0 to Found.Count - 1 do
          begin
            Z.Entries.AddFileEntry(Found[J], Root + '/' +
              StringReplace(ExtractRelativePath(Base, Found[J]), '\', '/', [rfReplaceAll])).CompressionLevel := Level;
            Inc(ATotal, FileSizeUtf8(Found[J]));
            Inc(ACount);
          end;
        finally
          Found.Free;
        end;
      end
      else if FileExistsUTF8(Src) then
      begin
        Z.Entries.AddFileEntry(Src, ExtractFileName(Src)).CompressionLevel := Level;
        Inc(ATotal, FileSizeUtf8(Src));
        Inc(ACount);
      end
      else
        raise Exception.Create('source not found: ' + Src);
    end;
    Z.ZipAllFiles;
  finally
    Z.Free;
  end;
end;

procedure CreateRarFile(const AOut: string; ASources: TStrings; const ALevel: string; AOverwrite: Boolean;
  const APassword: string; AEncryptNames: Boolean);
var
  T: TRarTool;
  R: TToolResult;
  P: TRarPureResult;
  Names, ToolArgs: TStringList;
  Src, Lvl: string;
  I, Level: Integer;
begin
  if (ASources = nil) or (ASources.Count = 0) then
    raise Exception.Create('"sources" must list at least one file or folder');
  if FileExistsUTF8(AOut) and not AOverwrite then
    raise Exception.Create('output exists; pass overwrite to replace it');
  if CreateWithRarPure(AOut, ASources, ALevel, APassword, False, AEncryptNames, P) then
    Exit;
  if not FindRarCreator(T) then
    raise Exception.Create('creating .rar needs rar_pure.exe or WinRAR''s rar.exe');
  if FileExistsUTF8(AOut) then
    DeleteFileUTF8(AOut);
  Lvl := LowerCase(ALevel);
  if Lvl = 'store' then Level := 0
  else if Lvl = 'fastest' then Level := 1
  else if Lvl = 'maximum' then Level := 5
  else Level := 3;
  Names := TStringList.Create;
  ToolArgs := TStringList.Create;
  try
    // rar keeps the paths it is given, so each source runs from its own parent
    for I := 0 to ASources.Count - 1 do
    begin
      Src := ExcludeTrailingPathDelimiter(ASources[I]);
      if not (FileExistsUTF8(Src) or DirectoryExistsUTF8(Src)) then
        raise Exception.Create('source not found: ' + Src);
      Names.Clear;
      Names.Add(ExtractFileName(Src));
      BuildCreateArgs(T, ExpandFileNameUTF8(AOut), Level, Names, ToolArgs);
      R := RunTool(T, ToolArgs, ExtractFilePath(Src), nil, nil, nil);
      if R.ExitCode <> 0 then
        raise Exception.CreateFmt('rar exit code %d: %s', [R.ExitCode, Trim(R.Output)]);
    end;
  finally
    ToolArgs.Free;
    Names.Free;
  end;
end;

end.
