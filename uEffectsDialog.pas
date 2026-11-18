unit uEffectsDialog;

{ View > Effect options: turn effects on or off, choose how strong they are and
  pick a style per event, with a preview button on each line. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Plays a preview from the place the event normally starts. }
  TFxPreviewEvent = procedure(AEvent: Integer) of object;

procedure ShowEffectsDialog(APreview: TFxPreviewEvent);

implementation

uses
  Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Graphics, uEffects;

type
  TEffectsDialog = class(TForm)
  private
    FPreview: TFxPreviewEvent;
    FLoading: Boolean;   // setting the controls fires their change events
    FEnabled, FFollow: TCheckBox;
    FIntensity: TTrackBar;
    FIntensityLabel: TLabel;
    FPalette: TComboBox;
    FRowChecks: array[TFxEvent] of TCheckBox;
    FRowStyles: array[TFxEvent] of TComboBox;
    procedure Changed(Sender: TObject);
    procedure PreviewClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure LoadValues;
  public
    constructor CreateDialog(APreview: TFxPreviewEvent);
  end;

constructor TEffectsDialog.CreateDialog(APreview: TFxPreviewEvent);
var
  Top_, Bottom, Row: TPanel;
  Box: TScrollBox;
  E: TFxEvent;
  S: TFxStyle;
  P: TFxPalette;
  Btn: TButton;
  Lbl: TLabel;
begin
  inherited CreateNew(nil);
  FLoading := True;
  FPreview := APreview;
  Caption := 'BGRA Zip - Effect options';
  Position := poMainFormCenter;
  Width := 560;
  Height := 680;
  BorderIcons := [biSystemMenu];

  Top_ := TPanel.Create(Self);
  Top_.Parent := Self;
  Top_.Align := alTop;
  Top_.Height := 132;
  Top_.BevelOuter := bvNone;

  FEnabled := TCheckBox.Create(Self);
  FEnabled.Parent := Top_;
  FEnabled.SetBounds(12, 10, 500, 24);
  FEnabled.Caption := 'Play effects';
  FEnabled.OnClick := @Changed;

  FFollow := TCheckBox.Create(Self);
  FFollow.Parent := Top_;
  FFollow.SetBounds(12, 36, 500, 24);
  FFollow.Caption := 'Stay still when Windows has animation effects turned off';
  FFollow.OnClick := @Changed;

  Lbl := TLabel.Create(Self);
  Lbl.Parent := Top_;
  Lbl.SetBounds(12, 70, 80, 20);
  Lbl.Caption := 'Amount';
  FIntensity := TTrackBar.Create(Self);
  FIntensity.Parent := Top_;
  FIntensity.SetBounds(92, 62, 340, 34);
  FIntensity.Min := 25;
  FIntensity.Max := 200;
  FIntensity.Frequency := 25;
  FIntensity.OnChange := @Changed;
  FIntensityLabel := TLabel.Create(Self);
  FIntensityLabel.Parent := Top_;
  FIntensityLabel.SetBounds(440, 70, 80, 20);

  Lbl := TLabel.Create(Self);
  Lbl.Parent := Top_;
  Lbl.SetBounds(12, 104, 80, 20);
  Lbl.Caption := 'Colors';
  FPalette := TComboBox.Create(Self);
  FPalette.Parent := Top_;
  FPalette.SetBounds(92, 100, 160, 24);
  FPalette.Style := csDropDownList;
  for P := Low(TFxPalette) to High(TFxPalette) do
    FPalette.Items.Add(FxPaletteNames[P]);
  FPalette.OnChange := @Changed;

  Bottom := TPanel.Create(Self);
  Bottom.Parent := Self;
  Bottom.Align := alBottom;
  Bottom.Height := 44;
  Bottom.BevelOuter := bvNone;
  Bottom.BorderSpacing.Around := 8;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.Align := alRight;
  Btn.Width := 90;
  Btn.Caption := 'Close';
  Btn.ModalResult := mrClose;
  Btn.Cancel := True;
  Btn := TButton.Create(Self);
  Btn.Parent := Bottom;
  Btn.Align := alLeft;
  Btn.Width := 130;
  Btn.Caption := 'Reset to defaults';
  Btn.OnClick := @ResetClick;

  Box := TScrollBox.Create(Self);
  Box.Parent := Self;
  Box.Align := alClient;
  Box.BorderSpacing.Left := 8;
  Box.BorderSpacing.Right := 8;
  Box.HorzScrollBar.Visible := False;

  for E := High(TFxEvent) downto Low(TFxEvent) do
  begin
    // alTop stacks the newest on top, hence the reverse order
    Row := TPanel.Create(Self);
    Row.Parent := Box;
    Row.Align := alTop;
    Row.Height := 34;
    Row.BevelOuter := bvNone;
    Row.Top := 0;

    FRowChecks[E] := TCheckBox.Create(Self);
    FRowChecks[E].Parent := Row;
    FRowChecks[E].SetBounds(6, 6, 240, 22);
    FRowChecks[E].Caption := FxEventCaptions[E];
    FRowChecks[E].OnClick := @Changed;

    FRowStyles[E] := TComboBox.Create(Self);
    FRowStyles[E].Parent := Row;
    FRowStyles[E].SetBounds(250, 4, 130, 24);
    FRowStyles[E].Style := csDropDownList;
    for S := Low(TFxStyle) to High(TFxStyle) do
      FRowStyles[E].Items.Add(FxStyleNames[S]);
    FRowStyles[E].OnChange := @Changed;

    Btn := TButton.Create(Self);
    Btn.Parent := Row;
    Btn.SetBounds(390, 3, 110, 26);
    Btn.Caption := 'Preview';
    Btn.Tag := Ord(E);
    Btn.OnClick := @PreviewClick;
  end;
  LoadValues;
end;

procedure TEffectsDialog.LoadValues;
var
  E: TFxEvent;
begin
  FLoading := True;
  FEnabled.Checked := Fx.Enabled;
  FFollow.Checked := Fx.FollowWindows;
  FIntensity.Position := Fx.Intensity;
  FIntensityLabel.Caption := IntToStr(Fx.Intensity) + '%';
  FPalette.ItemIndex := Ord(Fx.Palette);
  for E := Low(TFxEvent) to High(TFxEvent) do
  begin
    FRowChecks[E].Checked := Fx.Options[E].Enabled;
    FRowStyles[E].ItemIndex := Ord(Fx.Options[E].Style);
  end;
  FLoading := False;
end;

procedure TEffectsDialog.Changed(Sender: TObject);
var
  E: TFxEvent;
begin
  if FLoading then
    Exit;
  Fx.Enabled := FEnabled.Checked;
  Fx.FollowWindows := FFollow.Checked;
  Fx.Intensity := FIntensity.Position;
  FIntensityLabel.Caption := IntToStr(Fx.Intensity) + '%';
  if FPalette.ItemIndex >= 0 then
    Fx.Palette := TFxPalette(FPalette.ItemIndex);
  for E := Low(TFxEvent) to High(TFxEvent) do
    if FRowChecks[E] <> nil then
    begin
      Fx.Options[E].Enabled := FRowChecks[E].Checked;
      if FRowStyles[E].ItemIndex >= 0 then
        Fx.Options[E].Style := TFxStyle(FRowStyles[E].ItemIndex);
    end;
  Fx.Save;
end;

procedure TEffectsDialog.PreviewClick(Sender: TObject);
begin
  FPreview(TButton(Sender).Tag);
end;

procedure TEffectsDialog.ResetClick(Sender: TObject);
var
  Fresh: TFxEngine;
  E: TFxEvent;
begin
  // a new engine holds the defaults; its empty settings file name is never read here
  Fresh := TFxEngine.Create(0, '');
  try
    Fx.Enabled := Fresh.Enabled;
    Fx.FollowWindows := Fresh.FollowWindows;
    Fx.Intensity := Fresh.Intensity;
    Fx.Palette := Fresh.Palette;
    for E := Low(TFxEvent) to High(TFxEvent) do
      Fx.Options[E] := Fresh.Options[E];
  finally
    Fresh.Free;
  end;
  LoadValues;
  Fx.Save;
end;

procedure ShowEffectsDialog(APreview: TFxPreviewEvent);
var
  F: TEffectsDialog;
begin
  F := TEffectsDialog.CreateDialog(APreview);
  try
    F.ShowModal;
  finally
    F.Free;
  end;
end;

end.
