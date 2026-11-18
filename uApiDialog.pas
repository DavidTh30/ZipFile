unit uApiDialog;

{ Developer > HTTP API...: start/stop the local REST API (uHttpApi), choose the
  port, copy or replace the token, and read the endpoint reference. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

procedure ShowApiDialog;

implementation

uses
  Forms, Controls, StdCtrls, ExtCtrls, Graphics, Dialogs, Clipbrd, uHttpApi;

type
  TApiDialog = class(TForm)
  private
    FMemo: TMemo;
    FStatus: TLabel;
    FPort: TEdit;
    FScripts: TCheckBox;
    btnToggle: TButton;
    procedure Fill;
    procedure ScriptsClick(Sender: TObject);
    function ApplyPort: Boolean;
    procedure ToggleClick(Sender: TObject);
    procedure CopyTokenClick(Sender: TObject);
    procedure NewTokenClick(Sender: TObject);
    procedure CopyCurlClick(Sender: TObject);
  public
    constructor CreateDialog;
  end;

constructor TApiDialog.CreateDialog;
var
  Bottom: TPanel;
  Lbl: TLabel;

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
  Caption := 'BGRA Zip - HTTP API';
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
  Lbl := TLabel.Create(Self);
  Lbl.Parent := Bottom;
  Lbl.Align := alRight;
  Lbl.Layout := tlCenter;
  Lbl.Caption := 'Port';
  Lbl.Left := Bottom.ControlCount * 300;

  FPort := TEdit.Create(Self);
  FPort.Parent := Bottom;
  FPort.Align := alRight;
  FPort.Width := 60;
  FPort.NumbersOnly := True;
  FPort.BorderSpacing.Left := 6;
  FPort.BorderSpacing.Top := 8;
  FPort.BorderSpacing.Bottom := 8;
  FPort.Text := IntToStr(ApiCtl.Port);
  FPort.Left := Bottom.ControlCount * 300;

  btnToggle := AddButton('Start', 80, @ToggleClick);
  AddButton('Copy token', 90, @CopyTokenClick);
  AddButton('New token', 90, @NewTokenClick);
  AddButton('Copy curl test', 110, @CopyCurlClick);
  with AddButton('Close', 80, nil) do
  begin
    ModalResult := mrClose;
    Cancel := True;
  end;

  FScripts := TCheckBox.Create(Self);
  FScripts.Parent := Self;
  FScripts.Align := alBottom;
  FScripts.BorderSpacing.Left := 8;
  FScripts.Caption := 'Allow scripts over the API (anyone with the token can then do anything you can)';
  FScripts.Checked := ApiCtl.AllowScripts;
  FScripts.OnClick := @ScriptsClick;

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

procedure TApiDialog.Fill;
var
  L: TStrings;
  I: Integer;
begin
  L := FMemo.Lines;
  L.BeginUpdate;
  try
    L.Clear;
    L.Add('HTTP API - LOCAL REST SERVER');
    L.Add('============================');
    L.Add('');
    L.Add('Base URL : ' + ApiCtl.BaseUrl + '   (' + BoolToStr(ApiCtl.Active, 'running', 'stopped') + ')');
    L.Add('Access   : this computer only (127.0.0.1)');
    L.Add('Auth     : Authorization: Bearer <token>   - use "Copy token"');
    L.Add('Format   : JSON, UTF-8. Replies carry "ok": true or "ok": false + "error".');
    L.Add('Spec     : GET ' + API_PREFIX + '/openapi.json  (OpenAPI 3.0)');
    L.Add('');
    L.Add('');
    L.Add('NO TOKEN NEEDED');
    L.Add('---------------');
    L.Add('  GET   ' + API_PREFIX + '/health');
    L.Add('  GET   ' + API_PREFIX + '/openapi.json');
    L.Add('');
    L.Add('');
    L.Add('TOKEN NEEDED');
    L.Add('------------');
    for I := Low(ApiRoutes) to High(ApiRoutes) do
      L.Add(Format('  %-5s %-25s %s', [ApiRoutes[I].Method, API_PREFIX + ApiRoutes[I].Path, ApiRoutes[I].Summary]));
    L.Add('');
    L.Add('  open and add leave the window where it is; send "activate": true to raise it.');
    L.Add('  Paths are absolute Windows paths. Requests run one at a time.');
    L.Add('');
    L.Add('');
    L.Add('HTTP STATUS');
    L.Add('-----------');
    L.Add('  200 done   400 bad request   401 wrong token   403 foreign Host/Origin');
    L.Add('  404 unknown path or file     405 wrong method  409 busy or no archive open');
    L.Add('  413 body over 1 MB           500 extraction failed');
    L.Add('');
    L.Add('');
    L.Add('EXAMPLES  (PowerShell)');
    L.Add('----------------------');
    L.Add('  $h = @{ Authorization = "Bearer <token>" }');
    L.Add('  $u = "' + ApiCtl.BaseUrl + '"');
    L.Add('  Invoke-RestMethod $u/status -Headers $h');
    L.Add('  $b = @{ path = "C:\data\a.zip" } | ConvertTo-Json');
    L.Add('  Invoke-RestMethod $u/open -Method Post -Headers $h -ContentType application/json -Body $b');
    L.Add('  Invoke-RestMethod "$u/entries?limit=20" -Headers $h');
    L.Add('');
    L.Add('');
    L.Add('NOTES');
    L.Add('-----');
    L.Add('  Works while BGRA Zip is open. Start here to keep it on for the next runs,');
    L.Add('  or use  BGRAZip.exe --api  for one run. The token is stored in bgrazip.ini');
    L.Add('  in your user profile; "New token" replaces it and old clients stop working.');
  finally
    L.EndUpdate;
  end;
  FStatus.Caption := 'API: ' + BoolToStr(ApiCtl.Active, 'ON', 'OFF');
  btnToggle.Caption := BoolToStr(ApiCtl.Active, 'Stop', 'Start');
end;

procedure TApiDialog.ScriptsClick(Sender: TObject);
begin
  if FScripts.Checked <> ApiCtl.AllowScripts then
    ApiCtl.SetAllowScripts(FScripts.Checked);
  Fill;
end;

function TApiDialog.ApplyPort: Boolean;
begin
  Result := ApiCtl.SetPort(StrToIntDef(FPort.Text, -1));
  if not Result then
    MessageDlg('HTTP API', ApiCtl.LastError, mtError, [mbOK], 0);
end;

procedure TApiDialog.ToggleClick(Sender: TObject);
begin
  if ApiCtl.Active and (StrToIntDef(FPort.Text, -1) = ApiCtl.Port) then
    ApiCtl.SetEnabled(False)
  else if ApplyPort and not ApiCtl.SetEnabled(True) then
    MessageDlg('HTTP API', ApiCtl.LastError, mtError, [mbOK], 0);
  FPort.Text := IntToStr(ApiCtl.Port);
  Fill;
end;

procedure TApiDialog.CopyTokenClick(Sender: TObject);
begin
  Clipboard.AsText := ApiCtl.Token;
end;

procedure TApiDialog.NewTokenClick(Sender: TObject);
begin
  if MessageDlg('HTTP API', 'Replace the token? Clients using the old one stop working.',
    mtConfirmation, [mbYes, mbNo], 0) = mrYes then
  begin
    ApiCtl.NewToken;
    Fill;
  end;
end;

procedure TApiDialog.CopyCurlClick(Sender: TObject);
begin
  Clipboard.AsText := 'curl -H "Authorization: Bearer ' + ApiCtl.Token + '" ' + ApiCtl.BaseUrl + '/status';
end;

procedure ShowApiDialog;
var
  F: TApiDialog;
begin
  F := TApiDialog.CreateDialog;
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
