unit uScriptConsole;

{ Console runner of bzscript.exe.

    <exe> script [arguments...]     run; the exit code is the script's
    <exe> --check script            compile only
    <exe> --functions               print the function reference

  Exit codes: 0 done, 1 runtime error, 2 does not compile or bad usage. }

{$mode objfpc}{$H+}

interface

{ Runs what the command line asks for and sets ExitCode. }
procedure RunScriptConsole(const AExeName: string);

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF}
  Classes, SysUtils, LazUTF8, LazFileUtils, uScriptEngine;

type
  TConsoleHost = class(TScriptHost)
  public
    procedure Output(const S: string; AIsError: Boolean); override;
    procedure Progress(APercent: Integer; const AText: string); override;
    function Input(const APrompt, ADefault: string): string; override;
    function Confirm(const AMessage: string): Boolean; override;
  end;

var
  StdOut, StdErr: THandleStream;

procedure Put(AStream: THandleStream; const S: string);
var
  L: string;
begin
  L := S + LineEnding;
  AStream.WriteBuffer(L[1], Length(L));
end;

procedure TConsoleHost.Output(const S: string; AIsError: Boolean);
begin
  if AIsError then
    Put(StdErr, S)
  else
    Put(StdOut, S);
end;

procedure TConsoleHost.Progress(APercent: Integer; const AText: string);
begin
  Put(StdErr, Format('[%3d%%] %s', [APercent, AText]));
end;

function TConsoleHost.Input(const APrompt, ADefault: string): string;
begin
  Put(StdErr, APrompt + ' [' + ADefault + ']');
  if Eof(System.Input) then
    Exit(ADefault);
  ReadLn(System.Input, Result);
  if Result = '' then
    Result := ADefault;
end;

function TConsoleHost.Confirm(const AMessage: string): Boolean;
begin
  Result := SameText(Copy(Trim(Input(AMessage + ' (y/n)', 'n')), 1, 1), 'y');
end;

function ReadAll(const APath: string): string;
var
  F: TFileStream;
begin
  F := TFileStream.Create(UTF8ToSys(APath), fmOpenRead or fmShareDenyWrite);
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

procedure RunScriptConsole(const AExeName: string);
var
  Runner: TScriptRunner;
  Host: TConsoleHost;
  I, First: Integer;
  CheckOnly: Boolean;
begin
  {$IFDEF WINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  {$ENDIF}
  StdOut := THandleStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));
  StdErr := THandleStream.Create(GetStdHandle(STD_ERROR_HANDLE));
  if ParamStr(1) = '--functions' then
  begin
    Put(StdOut, ScriptReferenceText);
    ExitCode := 0;
    Exit;
  end;
  CheckOnly := ParamStr(1) = '--check';
  First := 1;
  if CheckOnly then
    First := 2;
  if ParamCount < First then
  begin
    Put(StdErr, 'usage: ' + AExeName + ' [--check] script' + ScriptFileExt + ' [arguments...]');
    Put(StdErr, '       ' + AExeName + ' --functions');
    ExitCode := 2;
    Exit;
  end;
  Host := TConsoleHost.Create;
  Runner := TScriptRunner.Create;
  try
    Runner.Host := Host;
    Runner.FileName := ExpandFileNameUTF8(ParamStrUTF8(First));
    if not FileExistsUTF8(Runner.FileName) then
    begin
      Put(StdErr, 'script not found: ' + Runner.FileName);
      ExitCode := 2;
      Exit;
    end;
    Runner.Source := ReadAll(Runner.FileName);
    for I := First + 1 to ParamCount do
      Runner.Args.Add(ParamStrUTF8(I));
    if CheckOnly then
    begin
      if Runner.Check then
        ExitCode := 0
      else
        ExitCode := 2;
      for I := 0 to Runner.Messages.Count - 1 do
        Put(StdErr, Runner.Messages[I]);
      Put(StdErr, BoolToStr(ExitCode = 0, 'OK', 'FAILED'));
    end
    else
    begin
      Runner.Run;
      for I := 0 to Runner.Messages.Count - 1 do
        if Pos('Error', Runner.Messages[I]) = 1 then
          Put(StdErr, Runner.Messages[I]);
      if (Runner.ErrorText <> '') and (Runner.Messages.IndexOf(Runner.ErrorText) < 0) then
        Put(StdErr, Runner.ErrorText);
      ExitCode := Runner.ExitCode;
    end;
  finally
    Runner.Free;
    Host.Free;
  end;
end;

end.
