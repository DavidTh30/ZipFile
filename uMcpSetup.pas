unit uMcpSetup;

{ "MCP server & IPC" help window and MCP client registration.

  Claude Code    : HTTP is not offered (BGRAZipMCP.exe is stdio only), so the
                   window shows the `claude mcp add` command to copy.
  Claude Desktop : stdio entry in %APPDATA%\Claude\claude_desktop_config.json.
                   RegisterClaudeDesktop merges "bgrazip" into mcpServers and
                   keeps every other key; the previous file is saved as .bak. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  MCP_SERVER_NAME = 'bgrazip';

function McpExePath: string;
function ClaudeCodeCommand: string;
function ClaudeDesktopConfigPath: string;
{ The mcpServers snippet to paste into claude_desktop_config.json by hand. }
function ClaudeDesktopSnippet: string;
{ True when the Desktop config has a "bgrazip" entry pointing at McpExePath. }
function IsRegisteredClaudeDesktop: Boolean;
function RegisterClaudeDesktop(out AMessage: string): Boolean;
function UnregisterClaudeDesktop(out AMessage: string): Boolean;

procedure ShowMcpDialog(const APipeName: string; APipeActive: Boolean);

implementation

uses
  Forms, Controls, StdCtrls, ExtCtrls, Graphics, Dialogs, Clipbrd, LCLIntf,
  fpjson, jsonparser, LazFileUtils, LazUTF8, FileUtil, uDevLog;

function McpExePath: string;
begin
  Result := ExtractFilePath(ParamStr(0)) + 'BGRAZipMCP.exe';
end;

function ClaudeCodeCommand: string;
begin
  Result := 'claude mcp add ' + MCP_SERVER_NAME + ' -- "' + McpExePath + '"';
end;

function ClaudeDesktopConfigPath: string;
begin
  Result := IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('APPDATA')) +
    'Claude' + PathDelim + 'claude_desktop_config.json';
end;

function ServerEntry: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('command', McpExePath);
  Result.Add('args', TJSONArray.Create);
end;

function ClaudeDesktopSnippet: string;
var
  Root, Servers: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Servers := TJSONObject.Create;
    Servers.Add(MCP_SERVER_NAME, ServerEntry);
    Root.Add('mcpServers', Servers);
    Result := Root.FormatJSON([], 2);
  finally
    Root.Free;
  end;
end;

{ Loads the config as an object; a missing or empty file gives an empty object.
  Returns nil (and AMessage) when the file exists but is not a JSON object,
  so it is never overwritten by mistake. }
function LoadConfig(out AMessage: string): TJSONObject;
var
  S: TStringList;
  Data: TJSONData;
begin
  Result := nil;
  AMessage := '';
  if not FileExistsUTF8(ClaudeDesktopConfigPath) then
    Exit(TJSONObject.Create);
  S := TStringList.Create;
  try
    S.LoadFromFile(ClaudeDesktopConfigPath);
    if Trim(S.Text) = '' then
      Exit(TJSONObject.Create);
    try
      Data := GetJSON(S.Text);
    except
      on E: Exception do
      begin
        AMessage := 'Cannot parse ' + ClaudeDesktopConfigPath + ': ' + E.Message;
        Exit;
      end;
    end;
    if Data is TJSONObject then
      Result := TJSONObject(Data)
    else
    begin
      Data.Free;
      AMessage := ClaudeDesktopConfigPath + ' is not a JSON object.';
    end;
  finally
    S.Free;
  end;
end;

function SaveConfig(ARoot: TJSONObject; out AMessage: string): Boolean;
var
  S: TStringList;
  Path: string;
begin
  Result := False;
  Path := ClaudeDesktopConfigPath;
  try
    ForceDirectoriesUTF8(ExtractFilePath(Path));
    if FileExistsUTF8(Path) then
      CopyFile(Path, Path + '.bak', [cffOverwriteFile]);
    S := TStringList.Create;
    try
      S.Text := ARoot.FormatJSON([], 2);
      S.WriteBOM := False;
      S.SaveToFile(Path);
    finally
      S.Free;
    end;
    Result := True;
  except
    on E: Exception do
      AMessage := 'Cannot write ' + Path + ': ' + E.Message;
  end;
end;

function IsRegisteredClaudeDesktop: Boolean;
var
  Root: TJSONObject;
  Msg: string;
  D: TJSONData;
begin
  Result := False;
  Root := LoadConfig(Msg);
  if Root = nil then
    Exit;
  try
    D := Root.FindPath('mcpServers.' + MCP_SERVER_NAME + '.command');
    Result := (D <> nil) and (D.JSONType = jtString) and SameText(D.AsString, McpExePath);
  finally
    Root.Free;
  end;
end;

function RegisterClaudeDesktop(out AMessage: string): Boolean;
var
  Root, Servers: TJSONObject;
  I: Integer;
begin
  Result := False;
  if not FileExistsUTF8(McpExePath) then
  begin
    AMessage := McpExePath + ' not found - build mcp\BGRAZipMCP.lpi first.';
    Exit;
  end;
  Root := LoadConfig(AMessage);
  if Root = nil then
    Exit;
  try
    I := Root.IndexOfName('mcpServers');
    if (I >= 0) and (Root.Items[I] is TJSONObject) then
      Servers := TJSONObject(Root.Items[I])
    else
    begin
      if I >= 0 then
        Root.Delete(I);
      Servers := TJSONObject.Create;
      Root.Add('mcpServers', Servers);
    end;
    I := Servers.IndexOfName(MCP_SERVER_NAME);
    if I >= 0 then
      Servers.Delete(I);
    Servers.Add(MCP_SERVER_NAME, ServerEntry);
    Result := SaveConfig(Root, AMessage);
    if Result then
    begin
      AMessage := 'Registered "' + MCP_SERVER_NAME + '" in ' + ClaudeDesktopConfigPath +
        LineEnding + 'Quit and restart Claude Desktop to load it.';
      DevLog(llInfo, 'MCP: registered in Claude Desktop config ' + ClaudeDesktopConfigPath);
    end;
  finally
    Root.Free;
  end;
end;

function UnregisterClaudeDesktop(out AMessage: string): Boolean;
var
  Root, Servers: TJSONObject;
  I: Integer;
begin
  Result := False;
  Root := LoadConfig(AMessage);
  if Root = nil then
    Exit;
  try
    I := Root.IndexOfName('mcpServers');
    if (I < 0) or not (Root.Items[I] is TJSONObject) then
    begin
      AMessage := 'Not registered.';
      Exit(True);
    end;
    Servers := TJSONObject(Root.Items[I]);
    I := Servers.IndexOfName(MCP_SERVER_NAME);
    if I < 0 then
    begin
      AMessage := 'Not registered.';
      Exit(True);
    end;
    Servers.Delete(I);
    Result := SaveConfig(Root, AMessage);
    if Result then
    begin
      AMessage := 'Removed "' + MCP_SERVER_NAME + '" from ' + ClaudeDesktopConfigPath +
        LineEnding + 'Restart Claude Desktop to apply.';
      DevLog(llInfo, 'MCP: removed from Claude Desktop config');
    end;
  finally
    Root.Free;
  end;
end;

{ ---------- dialog ---------- }

type
  TMcpDialog = class(TForm)
  private
    FMemo: TMemo;
    FStatus: TLabel;
    FPipeName: string;
    FPipeActive: Boolean;
    btnRegister: TButton;
    procedure Fill;
    procedure CopyCodeClick(Sender: TObject);
    procedure CopyJsonClick(Sender: TObject);
    procedure RegisterClick(Sender: TObject);
    procedure OpenConfigClick(Sender: TObject);
  public
    constructor CreateDialog(const APipeName: string; APipeActive: Boolean);
  end;

constructor TMcpDialog.CreateDialog(const APipeName: string; APipeActive: Boolean);
var
  Bottom: TPanel;

  function AddButton(const ACaption: string; AWidth: Integer; AClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Bottom;
    Result.Caption := ACaption;
    Result.Align := alRight;
    Result.Left := Bottom.ControlCount * 300;   // alRight keeps controls in Left order
    Result.Width := AWidth;
    Result.BorderSpacing.Left := 6;
    Result.OnClick := AClick;
  end;

begin
  inherited CreateNew(nil);
  FPipeName := APipeName;
  FPipeActive := APipeActive;
  Caption := 'BGRA Zip - MCP server & IPC';
  Position := poMainFormCenter;
  Width := 820;
  Height := 620;
  BorderIcons := [biSystemMenu, biMaximize];

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := 44;
  Bottom.BevelOuter := bvNone;
  Bottom.BorderSpacing.Around := 8;

  FStatus := TLabel.Create(Self);
  FStatus.Parent := Bottom;
  FStatus.Align := alLeft;
  FStatus.Layout := tlCenter;

  // AddButton places each one to the right of the last, so Close comes last
  AddButton('Copy Code command', 140, @CopyCodeClick);
  AddButton('Copy Desktop JSON', 135, @CopyJsonClick);
  btnRegister := AddButton('Register Desktop', 130, @RegisterClick);
  AddButton('Open config', 90, @OpenConfigClick);
  with AddButton('Close', 70, nil) do
  begin
    ModalResult := mrClose;
    Cancel := True;
  end;

  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := alClient;
  FMemo.BorderSpacing.Around := 8;
  FMemo.ReadOnly := True;
  FMemo.ScrollBars := ssAutoBoth;
  FMemo.WordWrap := False;
  FMemo.Font.Name := 'Consolas';
  FMemo.Font.Size := 10;
  Fill;
end;

procedure TMcpDialog.Fill;
var
  L: TStrings;
  Registered: Boolean;

  procedure Indented(const AText: string; const APrefix: string);
  var
    T: TStringList;
    I: Integer;
  begin
    T := TStringList.Create;
    try
      T.Text := AText;
      for I := 0 to T.Count - 1 do
        L.Add(APrefix + T[I]);
    finally
      T.Free;
    end;
  end;

begin
  Registered := IsRegisteredClaudeDesktop;
  L := FMemo.Lines;
  L.BeginUpdate;
  try
    L.Clear;
    L.Add('MCP SERVER - HOW TO CONNECT');
    L.Add('===========================');
    L.Add('');
    L.Add('Server : ' + McpExePath + BoolToStr(FileExistsUTF8(McpExePath), '',
      '   (NOT BUILT - build mcp\BGRAZipMCP.lpi)'));
    L.Add('Type   : stdio, JSON-RPC 2.0 (one JSON message per line)');
    L.Add('Tools  : archive_info, list_entries, test_archive, extract_archive, create_zip,');
    L.Add('         hex_dump, rar_tools, gui_status, gui_open, gui_extract, gui_test,');
    L.Add('         gui_show_developer, gui_get_log, run_script, check_script,');
    L.Add('         script_functions');
    L.Add('The archive tools work on their own; the gui_* tools talk to this window');
    L.Add('over IPC (gui_open starts BGRA Zip if it is not running).');
    L.Add('');
    L.Add('');
    L.Add('1. Claude Code  (stdio)');
    L.Add('   ---------------------');
    L.Add('     ' + ClaudeCodeCommand);
    L.Add('');
    L.Add('   Add "--scope user" to make it available in every project.');
    L.Add('   Then, in Claude Code, run /mcp to check that "' + MCP_SERVER_NAME + '" is connected.');
    L.Add('');
    L.Add('');
    L.Add('2. Claude Desktop  (stdio)');
    L.Add('   ------------------------');
    L.Add('   Click "Register Desktop", or Settings > Developer > Edit Config');
    L.Add('   and add to claude_desktop_config.json:');
    L.Add('');
    Indented(ClaudeDesktopSnippet, '     ');
    L.Add('');
    L.Add('   Config : ' + ClaudeDesktopConfigPath);
    L.Add('   Status : ' + BoolToStr(Registered, 'registered', 'not registered'));
    L.Add('   Quit and restart Claude Desktop after changing it.');
    L.Add('');
    L.Add('');
    L.Add('3. Any other MCP client');
    L.Add('   --------------------');
    L.Add('   Launch as a stdio server:  command "' + McpExePath + '", no arguments.');
    L.Add('   Protocol versions: 2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05.');
    L.Add('   Logs go to stderr; stdout carries only JSON-RPC.');
    L.Add('');
    L.Add('');
    L.Add('IPC - NAMED PIPE');
    L.Add('================');
    L.Add('');
    L.Add('Pipe     : ' + FPipeName + '   (' + BoolToStr(FPipeActive, 'listening', 'NOT listening') + ')');
    L.Add('Access   : this user only, local machine only');
    L.Add('Protocol : one connection per request; write one JSON line, read one JSON line');
    L.Add('Example  : {"cmd":"status"}   ->   {"ok":true,...}');
    L.Add('Commands : ping status show open add new list extract test dev log quit');
    L.Add('');
    L.Add('PowerShell test:');
    L.Add('  $p = New-Object IO.Pipes.NamedPipeClientStream(".", "' +
      ExtractFileName(FPipeName) + '", "InOut")');
    L.Add('  $p.Connect(2000); $w = New-Object IO.StreamWriter($p); $w.AutoFlush = $true');
    L.Add('  $w.WriteLine(''{"cmd":"status"}''); (New-Object IO.StreamReader($p)).ReadLine()');
  finally
    L.EndUpdate;
  end;
  FStatus.Caption := 'IPC: ' + BoolToStr(FPipeActive, 'ON', 'OFF') +
    '   Desktop: ' + BoolToStr(Registered, 'registered', 'not registered');
  btnRegister.Caption := BoolToStr(Registered, 'Unregister Desktop', 'Register Desktop');
end;

procedure TMcpDialog.CopyCodeClick(Sender: TObject);
begin
  Clipboard.AsText := ClaudeCodeCommand;
end;

procedure TMcpDialog.CopyJsonClick(Sender: TObject);
begin
  Clipboard.AsText := ClaudeDesktopSnippet;
end;

procedure TMcpDialog.RegisterClick(Sender: TObject);
var
  Msg: string;
  Ok: Boolean;
begin
  if IsRegisteredClaudeDesktop then
    Ok := UnregisterClaudeDesktop(Msg)
  else
    Ok := RegisterClaudeDesktop(Msg);
  if Ok then
    MessageDlg('Claude Desktop', Msg, mtInformation, [mbOK], 0)
  else
    MessageDlg('Claude Desktop', Msg, mtError, [mbOK], 0);
  Fill;
end;

procedure TMcpDialog.OpenConfigClick(Sender: TObject);
begin
  if FileExistsUTF8(ClaudeDesktopConfigPath) then
    OpenDocument(ClaudeDesktopConfigPath)
  else
    OpenDocument(ExtractFilePath(ClaudeDesktopConfigPath));
end;

procedure ShowMcpDialog(const APipeName: string; APipeActive: Boolean);
var
  F: TMcpDialog;
begin
  F := TMcpDialog.CreateDialog(APipeName, APipeActive);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
