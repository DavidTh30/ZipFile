program BGRAZip;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // this includes the LCL widgetset
  Classes, SysUtils, Forms, uMain, uDevInfo, uZipInspector, uDevLog, uBGRAUI, uArchiveBase,
  uRarInspector, uRarBackend, uDevInfoRar, uArchiveTree, uDragOut, uFileAssoc, uIPC, uMcpSetup, uHttpApi, uApiDialog, uArchiveOps, uScriptEngine, uScriptWindow, uEffects, uEffectsDialog;

{$R *.res}

{ Writes a crash report (message + stack trace + developer log) to
  %TEMP%\bgrazip-crash.txt for errors that escape the LCL's own handler. }
procedure WriteCrashReport(E: Exception);
var
  F: TextFile;
  I: Integer;
  Frames: PCodePointer;
begin
  AssignFile(F, GetTempDir(False) + 'bgrazip-crash.txt');
  Rewrite(F);
  try
    WriteLn(F, 'BGRA Zip crash ', FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    WriteLn(F, E.ClassName, ': ', E.Message);
    WriteLn(F, BackTraceStrFunc(ExceptAddr));
    Frames := ExceptFrames;
    for I := 0 to ExceptFrameCount - 1 do
      WriteLn(F, BackTraceStrFunc(Frames[I]));
    WriteLn(F);
    WriteLn(F, '--- log ---');
    for I := 0 to Log.Lines.Count - 1 do
      WriteLn(F, Log.Lines[I]);
  finally
    CloseFile(F);
  end;
end;

{ --register-claude-desktop / --unregister-claude-desktop: edit the Claude
  Desktop config without showing a window (for installers and scripts).
  Exit code 0 = done, 1 = failed. }
function HandleSetupSwitch: Boolean;
var
  Msg: string;
  Ok: Boolean;
begin
  Result := True;
  if (ParamCount = 1) and SameText(ParamStr(1), '--register-claude-desktop') then
    Ok := RegisterClaudeDesktop(Msg)
  else if (ParamCount = 1) and SameText(ParamStr(1), '--unregister-claude-desktop') then
    Ok := UnregisterClaudeDesktop(Msg)
  else
    Exit(False);
  if not Ok then
    ExitCode := 1;
end;

begin
  try
    if HandleSetupSwitch then
      Exit;
    // single instance: a running window takes over the command line (see uIPC)
    if ForwardToRunningInstance then
      Exit;
    RequireDerivedFormResource := True;
    Application.Title := 'BGRA Zip';
    Application.Scaled := True;
    Application.Initialize;
    Application.CreateForm(TfrmMain, frmMain);
    // frmDevInfo is created on demand by uMain.DevForm
    Application.Run;
  except
    on E: Exception do
    begin
      WriteCrashReport(E);
      raise;
    end;
  end;
end.
