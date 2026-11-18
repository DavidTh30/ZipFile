unit uScriptWindow;

{ Script editor: SynEdit with Pascal highlighting and completion, run / stop,
  breakpoints and stepping, output, problems, variables, call stack and the
  function reference. It shows whichever job holds CurrentScriptJob, so a script
  started over IPC or the HTTP API appears here too. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Menus, Dialogs, Graphics,
  LCLType, SynEdit, SynEditMarks, SynEditMiscClasses, SynHighlighterPas, SynCompletion, uScriptEngine;

type
  TfrmScript = class(TForm)
  private
    FEditor: TSynEdit;
    FHighlighter: TSynPasSyn;
    FCompletion: TSynCompletion;
    FPages: TPageControl;
    FOutput, FProblems, FVars, FStack: TMemo;
    FSearch: TEdit;
    FRefList: TListBox;
    FRefDoc: TMemo;
    FArgs: TEdit;
    FStatus: TStatusBar;
    FTimer: TTimer;
    FFile: string;
    FErrorLine, FPausedLine: Integer;
    FShownJobId: Integer;
    FNextLine: Integer;
    FJobReported: Boolean;
    FOpen, FSave: TFileDialog;
    miRun, miRunNoDebug, miStop, miPause, miStepInto, miStepOver, miExamples: TMenuItem;
    btnRun, btnStop, btnStepOver, btnStepInto: TButton;
    procedure BuildUI;
    procedure BuildMenu;
    procedure FillReference;
    procedure FillExamples;
    procedure UpdateTitle;
    procedure UpdateState;
    procedure Poll(Sender: TObject);
    function ConfirmDiscard: Boolean;
    function SaveNow(AForceAsk: Boolean): Boolean;
    procedure LoadFile(const AName: string);
    function BreakpointRows: specialize TArray<Integer>;
    function HasBreakpoint(ALine: Integer): Boolean;
    procedure ToggleBreakpoint(ALine: Integer);
    procedure SendBreakpoints;
    procedure GoToLine(ALine, ACol: Integer);
    procedure StartRun(ADebug, ABreakOnStart: Boolean);
    function DoDialog(AKind: TScriptDialogKind; const AText, ADefault: string): string;
    procedure SpecialLine(Sender: TObject; Line: Integer; var Special: Boolean; Markup: TSynSelectedColor);
    procedure GutterClick(Sender: TObject; X, Y, Line: Integer; Mark: TSynEditMark);
    procedure EditorChange(Sender: TObject);
    procedure CompletionSearch(var APosition: Integer);
    procedure CompletionExecute(Sender: TObject);
    procedure SearchChange(Sender: TObject);
    procedure RefSelect(Sender: TObject; User: Boolean);
    procedure RefDblClick(Sender: TObject);
    procedure FormCloseQueryEvent(Sender: TObject; var CanClose: Boolean);
    procedure NewClick(Sender: TObject);
    procedure OpenClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SaveAsClick(Sender: TObject);
    procedure ExampleClick(Sender: TObject);
    procedure OpenFolderClick(Sender: TObject);
    procedure CloseClick(Sender: TObject);
    procedure CheckClick(Sender: TObject);
    procedure RunClick(Sender: TObject);
    procedure RunNoDebugClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure PauseClick(Sender: TObject);
    procedure StepIntoClick(Sender: TObject);
    procedure StepOverClick(Sender: TObject);
    procedure ToggleBreakClick(Sender: TObject);
    procedure ClearBreaksClick(Sender: TObject);
    procedure ReferenceClick(Sender: TObject);
  public
    constructor CreateEditor;
  end;

{ Opens the editor; with a file it loads it, and ARun starts it. }
procedure ShowScriptEditor(const AFile: string = ''; ARun: Boolean = False);
{ Folder with the example scripts, '' if not found. }
function ScriptExamplesDir: string;

var
  ScriptExamplesFolder: string = 'examples';       // under script\ next to the program
  ScriptLocalHandler: TScriptRequestEvent = nil;   // set by the main form
  frmScript: TfrmScript = nil;

implementation

uses
  Math, LCLIntf, LazFileUtils, LazUTF8;

const
  NEW_SCRIPT =
    '{ BGRA Zip script. F9 runs it, F5 sets a breakpoint, F1 lists the functions. }' + LineEnding +
    LineEnding +
    'begin' + LineEnding +
    '  Print(''Hello from BGRA Zip'');' + LineEnding +
    'end.' + LineEnding;
  COLOR_BREAK = $00C8C8FF;
  COLOR_PAUSED = $00FFE0A0;
  COLOR_ERROR = $00A0E8FF;

function ScriptExamplesDir: string;
var
  App: string;
begin
  App := ExtractFilePath(ParamStr(0));
  Result := App + 'script' + PathDelim + ScriptExamplesFolder + PathDelim;
  if DirectoryExistsUTF8(Result) then
    Exit;
  Result := ExpandFileNameUTF8(App + '..' + PathDelim + 'script' + PathDelim + ScriptExamplesFolder) + PathDelim;
  if not DirectoryExistsUTF8(Result) then
    Result := '';
end;

procedure ShowScriptEditor(const AFile: string; ARun: Boolean);
begin
  if frmScript = nil then
    frmScript := TfrmScript.CreateEditor;
  frmScript.Show;
  frmScript.BringToFront;
  if (AFile <> '') and frmScript.ConfirmDiscard then
  begin
    frmScript.LoadFile(AFile);
    if ARun then
      frmScript.StartRun(True, False);
  end;
end;

constructor TfrmScript.CreateEditor;
begin
  inherited CreateNew(Application);
  Caption := ScriptAppName + ' - Script Editor';
  Position := poMainFormCenter;
  Width := 1120;
  Height := 760;
  OnCloseQuery := @FormCloseQueryEvent;
  BuildMenu;
  BuildUI;
  FillReference;
  FillExamples;
  FEditor.Text := StringReplace(NEW_SCRIPT, 'BGRA Zip', ScriptAppName, [rfReplaceAll]);
  FEditor.Modified := False;
  UpdateTitle;
  FTimer := TTimer.Create(Self);
  FTimer.Interval := 80;
  FTimer.OnTimer := @Poll;
  UpdateState;
end;

procedure TfrmScript.BuildMenu;
var
  Main: TMainMenu;
  M: TMenuItem;

  function TopItem(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Main.Items.Add(Result);
  end;

  function Item(AParent: TMenuItem; const ACaption: string; AClick: TNotifyEvent; AKey: TShortCut = 0): TMenuItem;
  begin
    Result := TMenuItem.Create(Self);
    Result.Caption := ACaption;
    Result.OnClick := AClick;
    Result.ShortCut := AKey;
    AParent.Add(Result);
  end;

begin
  Main := TMainMenu.Create(Self);
  Menu := Main;
  M := TopItem('&File');
  Item(M, '&New', @NewClick, ShortCut(VK_N, [ssCtrl]));
  Item(M, '&Open...', @OpenClick, ShortCut(VK_O, [ssCtrl]));
  miExamples := Item(M, 'E&xamples', nil);
  Item(M, '-', nil);
  Item(M, '&Save', @SaveClick, ShortCut(VK_S, [ssCtrl]));
  Item(M, 'Save &as...', @SaveAsClick, ShortCut(VK_S, [ssCtrl, ssShift]));
  Item(M, '-', nil);
  Item(M, 'Open script &folder', @OpenFolderClick);
  Item(M, '-', nil);
  Item(M, '&Close', @CloseClick);
  M := TopItem('&Run');
  miRun := Item(M, '&Run / Continue', @RunClick, ShortCut(VK_F9, []));
  miRunNoDebug := Item(M, 'Run &without debugging (faster)', @RunNoDebugClick, ShortCut(VK_F9, [ssCtrl, ssShift]));
  miStop := Item(M, '&Stop', @StopClick, ShortCut(VK_F2, [ssCtrl]));
  miPause := Item(M, '&Pause', @PauseClick);
  Item(M, '-', nil);
  Item(M, 'Check s&yntax', @CheckClick, ShortCut(VK_F9, [ssCtrl]));
  Item(M, '-', nil);
  miStepInto := Item(M, 'Step &into', @StepIntoClick, ShortCut(VK_F7, []));
  miStepOver := Item(M, 'Step &over', @StepOverClick, ShortCut(VK_F8, []));
  Item(M, '-', nil);
  Item(M, 'Toggle &breakpoint', @ToggleBreakClick, ShortCut(VK_F5, []));
  Item(M, 'Clear all break&points', @ClearBreaksClick);
  M := TopItem('&Help');
  Item(M, '&Function reference', @ReferenceClick, ShortCut(VK_F1, []));
end;

procedure TfrmScript.BuildUI;
var
  Bar, Side: TPanel;
  Split: TSplitter;
  Tab: TTabSheet;
  Lbl: TLabel;

  function AddButton(const ACaption: string; AWidth: Integer; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bar;
    Result.Caption := ACaption;
    Result.Align := alLeft;
    Result.Width := AWidth;
    Result.BorderSpacing.Right := 4;
    Result.OnClick := AClick;
    // alLeft controls stack in creation order only when each starts past the last
    Result.Left := Bar.ControlCount * 200;
  end;

  function AddPage(const ACaption: string): TMemo;
  begin
    Tab := FPages.AddTabSheet;
    Tab.Caption := ACaption;
    Result := TMemo.Create(Self);
    Result.Parent := Tab;
    Result.Align := alClient;
    Result.ReadOnly := True;
    Result.ScrollBars := ssAutoBoth;
    Result.WordWrap := False;
    Result.Font.Name := 'Consolas';
    Result.Font.Size := 10;
  end;

begin
  FStatus := TStatusBar.Create(Self);
  FStatus.Parent := Self;
  FStatus.SimplePanel := True;

  Bar := TPanel.Create(Self);
  Bar.Parent := Self;
  Bar.Align := alTop;
  Bar.Height := 38;
  Bar.BevelOuter := bvNone;
  Bar.BorderSpacing.Around := 4;
  btnRun := AddButton('Run (F9)', 90, @RunClick);
  btnStop := AddButton('Stop', 70, @StopClick);
  btnStepInto := AddButton('Into (F7)', 80, @StepIntoClick);
  btnStepOver := AddButton('Over (F8)', 80, @StepOverClick);
  AddButton('Check', 70, @CheckClick);
  Lbl := TLabel.Create(Self);
  Lbl.Parent := Bar;
  Lbl.Caption := 'Arguments';
  Lbl.Align := alLeft;
  Lbl.Layout := tlCenter;
  Lbl.Left := Bar.ControlCount * 200;
  Lbl.BorderSpacing.Left := 8;
  FArgs := TEdit.Create(Self);
  FArgs.Parent := Bar;
  FArgs.Align := alClient;
  FArgs.BorderSpacing.Left := 6;
  FArgs.BorderSpacing.Top := 5;
  FArgs.BorderSpacing.Bottom := 5;
  FArgs.Hint := 'Passed to the script, read them with Arg(0), Arg(1)... Use "quotes" around spaces';
  FArgs.ShowHint := True;

  Side := TPanel.Create(Self);
  Side.Parent := Self;
  Side.Align := alRight;
  Side.Width := 320;
  Side.BevelOuter := bvNone;
  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alRight;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := Side;
  FSearch.Align := alTop;
  FSearch.BorderSpacing.Around := 4;
  FSearch.TextHint := 'Search functions';
  FSearch.OnChange := @SearchChange;
  FRefDoc := TMemo.Create(Self);
  FRefDoc.Parent := Side;
  FRefDoc.Align := alBottom;
  FRefDoc.Height := 110;
  FRefDoc.ReadOnly := True;
  FRefDoc.Font.Name := 'Consolas';
  FRefDoc.BorderSpacing.Around := 4;
  FRefList := TListBox.Create(Self);
  FRefList.Parent := Side;
  FRefList.Align := alClient;
  FRefList.BorderSpacing.Left := 4;
  FRefList.BorderSpacing.Right := 4;
  FRefList.OnSelectionChange := @RefSelect;
  FRefList.OnDblClick := @RefDblClick;
  FRefList.Hint := 'Double-click to insert';
  FRefList.ShowHint := True;

  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alBottom;
  FPages.Height := 200;
  FOutput := AddPage('Output');
  FProblems := AddPage('Problems');
  FVars := AddPage('Variables');
  FStack := AddPage('Call stack');
  Split := TSplitter.Create(Self);
  Split.Parent := Self;
  Split.Align := alBottom;

  FHighlighter := TSynPasSyn.Create(Self);
  FStatus.Top := ClientHeight;   // below the output tabs
  FEditor := TSynEdit.Create(Self);
  FEditor.Parent := Self;
  FEditor.Align := alClient;
  FEditor.Highlighter := FHighlighter;
  FEditor.Font.Name := 'Consolas';
  FEditor.Font.Size := 11;
  FEditor.TabWidth := 2;
  FEditor.OnSpecialLineMarkup := @SpecialLine;
  FEditor.OnGutterClick := @GutterClick;
  FEditor.OnChange := @EditorChange;

  FCompletion := TSynCompletion.Create(Self);
  FCompletion.Editor := FEditor;
  FCompletion.OnSearchPosition := @CompletionSearch;
  FCompletion.OnExecute := @CompletionExecute;

  FOpen := TOpenDialog.Create(Self);
  FOpen.Filter := ScriptAppName + ' scripts (*' + ScriptFileExt + ')|*' + ScriptFileExt + '|All files (*.*)|*.*';
  FSave := TSaveDialog.Create(Self);
  FSave.Filter := FOpen.Filter;
  FSave.DefaultExt := Copy(ScriptFileExt, 2, MaxInt);
  TSaveDialog(FSave).Options := TSaveDialog(FSave).Options + [ofOverwritePrompt];
end;

procedure TfrmScript.FillReference;
var
  F: specialize TArray<TScriptFunc>;
  I: Integer;
  Q, N: string;
begin
  Q := LowerCase(Trim(FSearch.Text));
  F := ScriptFunctions;
  FRefList.Items.BeginUpdate;
  try
    FRefList.Clear;
    for I := 0 to High(F) do
    begin
      N := ScriptFuncName(F[I].Decl);
      if (Q = '') or (Pos(Q, LowerCase(N + ' ' + F[I].Category + ' ' + F[I].Doc)) > 0) then
        FRefList.Items.AddObject(N, TObject(PtrInt(I)));
    end;
  finally
    FRefList.Items.EndUpdate;
  end;
end;

procedure TfrmScript.FillExamples;
var
  Dir: string;
  Found: TSearchRec;
  It: TMenuItem;
begin
  miExamples.Clear;
  Dir := ScriptExamplesDir;
  if (Dir <> '') and (FindFirstUTF8(Dir + '*' + ScriptFileExt, faAnyFile, Found) = 0) then
  begin
    repeat
      It := TMenuItem.Create(Self);
      It.Caption := Found.Name;
      It.Hint := Dir + Found.Name;
      It.OnClick := @ExampleClick;
      miExamples.Add(It);
    until FindNextUTF8(Found) <> 0;
    FindCloseUTF8(Found);
  end;
  miExamples.Enabled := miExamples.Count > 0;
end;

procedure TfrmScript.UpdateTitle;
var
  N: string;
begin
  if FFile = '' then
    N := 'Untitled'
  else
    N := ExtractFileName(FFile);
  if FEditor.Modified then
    N := N + ' *';
  Caption := N + ' - ' + ScriptAppName + ' Script Editor';
end;

procedure TfrmScript.UpdateState;
var
  Job: TScriptJob;
  Running, Paused: Boolean;
begin
  Job := CurrentScriptJob;
  Running := (Job <> nil) and not Job.Finished;
  Paused := Running and (Job.Runner.PausedRow > 0);
  miRun.Enabled := (not Running) or Paused;
  btnRun.Enabled := miRun.Enabled;
  miRunNoDebug.Enabled := not Running;
  miStop.Enabled := Running;
  btnStop.Enabled := Running;
  miPause.Enabled := Running and not Paused and Job.Runner.Debug;
  miStepInto.Enabled := Paused or not Running;
  btnStepInto.Enabled := miStepInto.Enabled;
  miStepOver.Enabled := Paused or not Running;
  btnStepOver.Enabled := miStepOver.Enabled;
  if Paused then
    btnRun.Caption := 'Continue (F9)'
  else
    btnRun.Caption := 'Run (F9)';
end;

procedure TfrmScript.Poll(Sender: TObject);
var
  Job: TScriptJob;
  L: TStringList;
  Row, Pct: Integer;
begin
  Job := CurrentScriptJob;
  if (Job <> nil) and (Job.Id <> FShownJobId) then
  begin
    FShownJobId := Job.Id;
    FNextLine := 0;
    FJobReported := False;
    begin
      FOutput.Clear;
      FVars.Clear;
      FStack.Clear;
      FErrorLine := 0;
    end;
  end;
  if Job = nil then
    Exit;
  L := TStringList.Create;
  try
    FNextLine := Job.GetLines(FNextLine, L);
    if L.Count > 0 then
    begin
      FOutput.Lines.BeginUpdate;
      FOutput.Lines.AddStrings(L);
      FOutput.Lines.EndUpdate;
      FOutput.SelStart := Length(FOutput.Text);
    end;
  finally
    L.Free;
  end;
  Row := Job.Runner.PausedRow;
  if Row <> FPausedLine then
  begin
    FPausedLine := Row;
    if Row > 0 then
    begin
      FVars.Text := Job.Runner.VarsText;
      FStack.Text := Job.Runner.CallStackText;
      GoToLine(Row, 1);
      FPages.ActivePageIndex := 2;
    end;
    FEditor.Invalidate;
    UpdateState;
  end;
  Pct := Job.ProgressPercent;
  if Job.Finished then
  begin
    if not FJobReported then
    begin
      FJobReported := True;
      FPausedLine := 0;
      if Job.Runner.ErrorText <> '' then
      begin
        FProblems.Text := Job.Runner.Messages.Text;
        if FProblems.Lines.IndexOf(Job.Runner.ErrorText) < 0 then
          FProblems.Lines.Add(Job.Runner.ErrorText);
        FPages.ActivePageIndex := 1;
        FErrorLine := Job.Runner.ErrorRow;
        if FErrorLine > 0 then
          GoToLine(FErrorLine, Job.Runner.ErrorCol);
        FStatus.SimpleText := Job.Runner.ErrorText;
      end
      else if Job.Runner.Stopped and (Job.Runner.ExitCode = 0) then
        FStatus.SimpleText := 'Stopped'
      else
      begin
        FPages.ActivePageIndex := 0;
        FProblems.Text := Job.Runner.Messages.Text;
        FStatus.SimpleText := Format('Finished, exit code %d', [Job.Runner.ExitCode]);
      end;
      FEditor.Invalidate;
      UpdateState;
    end;
  end
  else if Row > 0 then
    FStatus.SimpleText := Format('Paused at line %d', [Row])
  else if Pct >= 0 then
    FStatus.SimpleText := Format('Running... %d%% %s', [Pct, Job.ProgressText])
  else
  begin
    FStatus.SimpleText := 'Running...';
    UpdateState;
  end;
end;

function TfrmScript.ConfirmDiscard: Boolean;
begin
  Result := True;
  if FEditor.Modified then
    case MessageDlg('Script Editor', 'Save the changes to ' + BoolToStr(FFile <> '', ExtractFileName(FFile), 'this script') + '?',
      mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
      mrYes: Result := SaveNow(False);
      mrNo: Result := True;
    else
      Result := False;
    end;
end;

function TfrmScript.SaveNow(AForceAsk: Boolean): Boolean;
var
  F: TFileStream;
  S: string;
begin
  Result := False;
  if AForceAsk or (FFile = '') then
  begin
    if not FSave.Execute then
      Exit;
    FFile := FSave.FileName;
  end;
  S := FEditor.Text;
  F := TFileStream.Create(FFile, fmCreate);
  try
    if S <> '' then
      F.WriteBuffer(S[1], Length(S));
  finally
    F.Free;
  end;
  FEditor.Modified := False;
  UpdateTitle;
  Result := True;
end;

procedure TfrmScript.LoadFile(const AName: string);
var
  F: TFileStream;
  S: string;
begin
  F := TFileStream.Create(AName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(S, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(S[1], F.Size);
  finally
    F.Free;
  end;
  if Copy(S, 1, 3) = #$EF#$BB#$BF then
    Delete(S, 1, 3);
  FEditor.Marks.ClearLine(0);
  while FEditor.Marks.Count > 0 do
    FEditor.Marks.Delete(0);
  FEditor.Text := S;
  FEditor.Modified := False;
  FFile := AName;
  FErrorLine := 0;
  UpdateTitle;
end;

function TfrmScript.BreakpointRows: specialize TArray<Integer>;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, FEditor.Marks.Count);
  for I := 0 to FEditor.Marks.Count - 1 do
    Result[I] := FEditor.Marks[I].Line;
end;

function TfrmScript.HasBreakpoint(ALine: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FEditor.Marks.Count - 1 do
    if FEditor.Marks[I].Line = ALine then
      Exit(True);
end;

procedure TfrmScript.ToggleBreakpoint(ALine: Integer);
var
  I: Integer;
  M: TSynEditMark;
begin
  for I := FEditor.Marks.Count - 1 downto 0 do
    if FEditor.Marks[I].Line = ALine then
    begin
      FEditor.Marks.Delete(I);
      SendBreakpoints;
      FEditor.Invalidate;
      Exit;
    end;
  M := TSynEditMark.Create(FEditor);
  M.Line := ALine;
  M.Column := 1;
  M.Visible := True;
  FEditor.Marks.Add(M);
  SendBreakpoints;
  FEditor.Invalidate;
end;

procedure TfrmScript.SendBreakpoints;
begin
  if (CurrentScriptJob <> nil) and not CurrentScriptJob.Finished then
    CurrentScriptJob.Runner.SetBreakpoints(BreakpointRows);
end;

procedure TfrmScript.GoToLine(ALine, ACol: Integer);
begin
  if ALine < 1 then
    Exit;
  FEditor.CaretXY := Classes.Point(Max(ACol, 1), ALine);
  FEditor.TopLine := Max(1, ALine - FEditor.LinesInWindow div 2);
end;

procedure TfrmScript.StartRun(ADebug, ABreakOnStart: Boolean);
var
  Job: TScriptJob;
  A: TStringList;
begin
  if not ScriptSlotFree then
  begin
    MessageDlg('Script Editor', 'A script is already running. Stop it first.', mtInformation, [mbOK], 0);
    Exit;
  end;
  A := TStringList.Create;
  try
    A.Delimiter := ' ';
    A.QuoteChar := '"';
    A.StrictDelimiter := True;
    A.DelimitedText := Trim(FArgs.Text);
    Job := TScriptJob.Create(FEditor.Text, FFile, A, ADebug);
  finally
    A.Free;
  end;
  Job.LocalHandler := ScriptLocalHandler;
  Job.OnDialog := @DoDialog;
  Job.Runner.BreakOnStart := ABreakOnStart;
  Job.Runner.SetBreakpoints(BreakpointRows);
  CurrentScriptJob := Job;
  FProblems.Clear;
  FPages.ActivePageIndex := 0;
  Job.Go;
  Poll(nil);
  UpdateState;
end;

function TfrmScript.DoDialog(AKind: TScriptDialogKind; const AText, ADefault: string): string;
begin
  Result := '';
  case AKind of
    sdInput:
      Result := InputBox('Script', AText, ADefault);
    sdConfirm:
      if MessageDlg('Script', AText, mtConfirmation, [mbYes, mbNo], 0) = mrYes then
        Result := '1';
    sdMessage:
      MessageDlg('Script', AText, mtInformation, [mbOK], 0);
  end;
end;

procedure TfrmScript.SpecialLine(Sender: TObject; Line: Integer; var Special: Boolean; Markup: TSynSelectedColor);
begin
  if Line = FPausedLine then
    Markup.Background := COLOR_PAUSED
  else if Line = FErrorLine then
    Markup.Background := COLOR_ERROR
  else if HasBreakpoint(Line) then
    Markup.Background := COLOR_BREAK
  else
    Exit;
  Markup.Foreground := clBlack;
  Special := True;
end;

procedure TfrmScript.GutterClick(Sender: TObject; X, Y, Line: Integer; Mark: TSynEditMark);
begin
  ToggleBreakpoint(Line);
end;

procedure TfrmScript.EditorChange(Sender: TObject);
begin
  if FErrorLine > 0 then
  begin
    FErrorLine := 0;
    FEditor.Invalidate;
  end;
  UpdateTitle;
  SendBreakpoints;
end;

procedure TfrmScript.CompletionSearch(var APosition: Integer);
begin
  CompletionExecute(nil);
  if FCompletion.ItemList.Count > 0 then
    APosition := 0
  else
    APosition := -1;
end;

procedure TfrmScript.CompletionExecute(Sender: TObject);
var
  F: specialize TArray<TScriptFunc>;
  I: Integer;
  Q, N: string;
begin
  Q := LowerCase(FCompletion.CurrentString);
  F := ScriptFunctions;
  FCompletion.ItemList.BeginUpdate;
  try
    FCompletion.ItemList.Clear;
    for I := 0 to High(F) do
    begin
      N := ScriptFuncName(F[I].Decl);
      if Pos(Q, LowerCase(N)) = 1 then
        FCompletion.ItemList.Add(N);
    end;
  finally
    FCompletion.ItemList.EndUpdate;
  end;
end;

procedure TfrmScript.SearchChange(Sender: TObject);
begin
  FillReference;
end;

procedure TfrmScript.RefSelect(Sender: TObject; User: Boolean);
var
  F: specialize TArray<TScriptFunc>;
  I: Integer;
begin
  if FRefList.ItemIndex < 0 then
    Exit;
  F := ScriptFunctions;
  I := PtrInt(FRefList.Items.Objects[FRefList.ItemIndex]);
  FRefDoc.Text := F[I].Category + LineEnding + F[I].Decl + LineEnding + F[I].Doc;
end;

procedure TfrmScript.RefDblClick(Sender: TObject);
begin
  if FRefList.ItemIndex < 0 then
    Exit;
  FEditor.SelText := FRefList.Items[FRefList.ItemIndex];
  FEditor.SetFocus;
end;

procedure TfrmScript.FormCloseQueryEvent(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := ConfirmDiscard;
end;

procedure TfrmScript.NewClick(Sender: TObject);
begin
  if not ConfirmDiscard then
    Exit;
  while FEditor.Marks.Count > 0 do
    FEditor.Marks.Delete(0);
  FEditor.Text := StringReplace(NEW_SCRIPT, 'BGRA Zip', ScriptAppName, [rfReplaceAll]);
  FEditor.Modified := False;
  FFile := '';
  FErrorLine := 0;
  UpdateTitle;
end;

procedure TfrmScript.OpenClick(Sender: TObject);
begin
  if ConfirmDiscard and FOpen.Execute then
    LoadFile(FOpen.FileName);
end;

procedure TfrmScript.SaveClick(Sender: TObject);
begin
  SaveNow(False);
end;

procedure TfrmScript.SaveAsClick(Sender: TObject);
begin
  SaveNow(True);
end;

procedure TfrmScript.ExampleClick(Sender: TObject);
begin
  if ConfirmDiscard then
    LoadFile(TMenuItem(Sender).Hint);
end;

procedure TfrmScript.OpenFolderClick(Sender: TObject);
begin
  if FFile <> '' then
    OpenDocument(ExtractFilePath(FFile))
  else if ScriptExamplesDir <> '' then
    OpenDocument(ScriptExamplesDir);
end;

procedure TfrmScript.CloseClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmScript.CheckClick(Sender: TObject);
var
  R: TScriptRunner;
begin
  R := TScriptRunner.Create;
  try
    R.Source := FEditor.Text;
    R.FileName := FFile;
    if R.Check then
    begin
      FErrorLine := 0;
      FStatus.SimpleText := 'Syntax OK';
    end
    else
    begin
      FErrorLine := R.ErrorRow;
      FStatus.SimpleText := R.ErrorText;
      GoToLine(R.ErrorRow, R.ErrorCol);
    end;
    FProblems.Text := R.Messages.Text;
    FPages.ActivePageIndex := 1;
    FEditor.Invalidate;
  finally
    R.Free;
  end;
end;

procedure TfrmScript.RunClick(Sender: TObject);
var
  Job: TScriptJob;
begin
  Job := CurrentScriptJob;
  if (Job <> nil) and not Job.Finished then
  begin
    if Job.Runner.PausedRow > 0 then
      Job.Runner.DebugContinue;
  end
  else
    StartRun(True, False);
  UpdateState;
end;

procedure TfrmScript.RunNoDebugClick(Sender: TObject);
begin
  StartRun(False, False);
end;

procedure TfrmScript.StopClick(Sender: TObject);
begin
  if CurrentScriptJob <> nil then
    CurrentScriptJob.Runner.Stop;
end;

procedure TfrmScript.PauseClick(Sender: TObject);
begin
  if CurrentScriptJob <> nil then
    CurrentScriptJob.Runner.DebugPause;
end;

procedure TfrmScript.StepIntoClick(Sender: TObject);
var
  Job: TScriptJob;
begin
  Job := CurrentScriptJob;
  if (Job <> nil) and not Job.Finished then
    Job.Runner.DebugStepInto
  else
    StartRun(True, True);
end;

procedure TfrmScript.StepOverClick(Sender: TObject);
var
  Job: TScriptJob;
begin
  Job := CurrentScriptJob;
  if (Job <> nil) and not Job.Finished then
    Job.Runner.DebugStepOver
  else
    StartRun(True, True);
end;

procedure TfrmScript.ToggleBreakClick(Sender: TObject);
begin
  ToggleBreakpoint(FEditor.CaretY);
end;

procedure TfrmScript.ClearBreaksClick(Sender: TObject);
begin
  while FEditor.Marks.Count > 0 do
    FEditor.Marks.Delete(0);
  SendBreakpoints;
  FEditor.Invalidate;
end;

procedure TfrmScript.ReferenceClick(Sender: TObject);
begin
  FSearch.SetFocus;
end;

end.
