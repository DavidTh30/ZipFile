unit uBGRAUI;

{ All custom-drawn UI pieces rendered with BGRABitmap:
  header banner, toolbar with vector icons, progress bar and list icons. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Graphics, Controls, ExtCtrls, ImgList,
  BGRABitmap, BGRABitmapTypes;

type
  TToolIcon = (tiNew, tiAddFile, tiAddFolder, tiRemove, tiCreate, tiOpen,
    tiExtract, tiExtractSel, tiTest, tiDev, tiFile, tiFolder, tiZip,
    tiLock, tiFileLocked, tiZipLocked);

  TToolButtonInfo = record
    Tag: Integer;
    Caption: string;
    Hint: string;
    Icon: TToolIcon;
    Enabled: Boolean;
    Separator: Boolean;
    Rect: TRect;
  end;

  TToolClickEvent = procedure(Sender: TObject; ATag: Integer) of object;

  { TBGRAToolbar - owner-drawn toolbar on top of a TPaintBox }

  TBGRAToolbar = class
  private
    FBox: TPaintBox;
    FButtons: array of TToolButtonInfo;
    FHot: Integer;
    FDown: Integer;
    FOnClick: TToolClickEvent;
    procedure DoPaint(Sender: TObject);
    procedure DoMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure DoMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure DoMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    procedure DoMouseLeave(Sender: TObject);
    procedure DoResize(Sender: TObject);
    function HitTest(X, Y: Integer): Integer;
    function IndexOfTag(ATag: Integer): Integer;
    procedure Layout;
  public
    constructor Create(ABox: TPaintBox);
    procedure AddButton(ATag: Integer; const ACaption, AHint: string; AIcon: TToolIcon);
    procedure AddSeparator;
    procedure SetEnabled(ATag: Integer; AEnabled: Boolean);
    property OnClick: TToolClickEvent read FOnClick write FOnClick;
  end;

const
  clrAccent: TBGRAPixel = (blue: 230; green: 140; red: 30; alpha: 255);
  clrAccent2: TBGRAPixel = (blue: 190; green: 200; red: 20; alpha: 255);
  clrText: TBGRAPixel = (blue: 60; green: 45; red: 35; alpha: 255);
  clrMuted: TBGRAPixel = (blue: 140; green: 125; red: 115; alpha: 255);

procedure DrawToolIcon(ABmp: TBGRABitmap; AIcon: TToolIcon; X, Y, S: Single; AEnabled: Boolean = True);
{ ABadge: an amber "locked" pill left of the stats (password-protected archives), '' for none }
procedure PaintHeader(ABox: TPaintBox; const ATitle, ASubtitle: string; const AStats: array of string;
  const ABadge: string = '');
procedure PaintProgress(ABox: TPaintBox; AFraction: Double; const AText: string; AActive: Boolean);
procedure AddIconToImageList(AList: TCustomImageList; AIcon: TToolIcon);

implementation

uses
  Forms, Math, LazUTF8, BGRAGradientScanner;

{ ---------- icons ---------- }

function Dim(C: TBGRAPixel; AEnabled: Boolean): TBGRAPixel;
begin
  if AEnabled then
    Result := C
  else
  begin
    Result := BGRA(170, 170, 175, 200);
  end;
end;

procedure DrawDoc(B: TBGRABitmap; X, Y, S: Single; Fill, Line: TBGRAPixel);
begin
  B.FillPolyAntialias([PointF(X + 0.18 * S, Y + 0.06 * S), PointF(X + 0.6 * S, Y + 0.06 * S),
    PointF(X + 0.82 * S, Y + 0.28 * S), PointF(X + 0.82 * S, Y + 0.94 * S),
    PointF(X + 0.18 * S, Y + 0.94 * S)], Fill);
  B.DrawPolygonAntialias([PointF(X + 0.18 * S, Y + 0.06 * S), PointF(X + 0.6 * S, Y + 0.06 * S),
    PointF(X + 0.82 * S, Y + 0.28 * S), PointF(X + 0.82 * S, Y + 0.94 * S),
    PointF(X + 0.18 * S, Y + 0.94 * S)], Line, S * 0.07);
  B.DrawPolyLineAntialias([PointF(X + 0.6 * S, Y + 0.06 * S), PointF(X + 0.6 * S, Y + 0.28 * S),
    PointF(X + 0.82 * S, Y + 0.28 * S)], Line, S * 0.07);
end;

procedure DrawFolder(B: TBGRABitmap; X, Y, S: Single; Fill, Line: TBGRAPixel);
begin
  B.FillRoundRectAntialias(X + 0.06 * S, Y + 0.16 * S, X + 0.46 * S, Y + 0.4 * S, S * 0.06, S * 0.06, Line);
  B.FillRoundRectAntialias(X + 0.06 * S, Y + 0.26 * S, X + 0.94 * S, Y + 0.86 * S, S * 0.08, S * 0.08, Fill);
  B.RoundRectAntialias(X + 0.06 * S, Y + 0.26 * S, X + 0.94 * S, Y + 0.86 * S, S * 0.08, S * 0.08, Line, S * 0.06);
end;

procedure DrawBox(B: TBGRABitmap; X, Y, S: Single; Fill, Line: TBGRAPixel);
var
  I: Integer;
  CY: Single;
begin
  B.FillRoundRectAntialias(X + 0.14 * S, Y + 0.08 * S, X + 0.86 * S, Y + 0.92 * S, S * 0.1, S * 0.1, Fill);
  B.RoundRectAntialias(X + 0.14 * S, Y + 0.08 * S, X + 0.86 * S, Y + 0.92 * S, S * 0.1, S * 0.1, Line, S * 0.07);
  // zipper teeth
  for I := 0 to 3 do
  begin
    CY := Y + (0.16 + I * 0.1) * S;
    B.FillRectAntialias(X + 0.42 * S, CY, X + 0.5 * S, CY + 0.05 * S, Line);
    B.FillRectAntialias(X + 0.5 * S, CY + 0.05 * S, X + 0.58 * S, CY + 0.1 * S, Line);
  end;
  B.FillRoundRectAntialias(X + 0.38 * S, Y + 0.58 * S, X + 0.62 * S, Y + 0.8 * S, S * 0.04, S * 0.04, Line);
end;

procedure DrawBadge(B: TBGRABitmap; X, Y, S: Single; C: TBGRAPixel; APlus: Boolean);
var
  CX, CY, R: Single;
begin
  CX := X + 0.74 * S;
  CY := Y + 0.74 * S;
  R := 0.24 * S;
  B.FillEllipseAntialias(CX, CY, R, R, C);
  B.EllipseAntialias(CX, CY, R, R, BGRAWhite, S * 0.05);
  if APlus then
  begin
    B.DrawLineAntialias(CX - R * 0.55, CY, CX + R * 0.55, CY, BGRAWhite, S * 0.08);
    B.DrawLineAntialias(CX, CY - R * 0.55, CX, CY + R * 0.55, BGRAWhite, S * 0.08);
  end
  else
  begin
    B.DrawLineAntialias(CX, CY - R * 0.6, CX, CY + R * 0.45, BGRAWhite, S * 0.08);
    B.DrawPolyLineAntialias([PointF(CX - R * 0.45, CY), PointF(CX, CY + R * 0.5),
      PointF(CX + R * 0.45, CY)], BGRAWhite, S * 0.08);
  end;
end;

procedure DrawPadlock(B: TBGRABitmap; X, Y, S: Single; Body, Line: TBGRAPixel);
begin
  // shackle first, the body covers its lower half
  B.RoundRectAntialias(X + 0.28 * S, Y + 0.08 * S, X + 0.72 * S, Y + 0.64 * S, 0.22 * S, 0.22 * S, Line, 0.11 * S);
  B.FillRoundRectAntialias(X + 0.12 * S, Y + 0.42 * S, X + 0.88 * S, Y + 0.94 * S, 0.1 * S, 0.1 * S, Body);
  B.RoundRectAntialias(X + 0.12 * S, Y + 0.42 * S, X + 0.88 * S, Y + 0.94 * S, 0.1 * S, 0.1 * S, Line, 0.06 * S);
  // keyhole
  B.FillEllipseAntialias(X + 0.5 * S, Y + 0.62 * S, 0.075 * S, 0.075 * S, Line);
  B.DrawLineAntialias(X + 0.5 * S, Y + 0.64 * S, X + 0.5 * S, Y + 0.8 * S, Line, 0.07 * S);
end;

procedure DrawLockBadge(B: TBGRABitmap; X, Y, S: Single; AEnabled: Boolean);
begin
  DrawPadlock(B, X + 0.44 * S, Y + 0.4 * S, 0.58 * S, Dim(BGRA(255, 190, 40), AEnabled),
    Dim(BGRA(110, 60, 0), AEnabled));
end;

procedure DrawToolIcon(ABmp: TBGRABitmap; AIcon: TToolIcon; X, Y, S: Single; AEnabled: Boolean);
var
  Blue, Yellow, Paper, Line, Green, Red, Purple: TBGRAPixel;
  CX, CY, R: Single;
begin
  Blue := Dim(BGRA(30, 140, 230), AEnabled);
  Yellow := Dim(BGRA(255, 200, 70), AEnabled);
  Paper := Dim(BGRA(250, 252, 255), AEnabled);
  Line := Dim(BGRA(70, 90, 120), AEnabled);
  Green := Dim(BGRA(40, 180, 100), AEnabled);
  Red := Dim(BGRA(230, 70, 70), AEnabled);
  Purple := Dim(BGRA(140, 90, 220), AEnabled);
  CX := X + S / 2;
  CY := Y + S / 2;
  R := S * 0.4;
  case AIcon of
    tiNew, tiFile:
      DrawDoc(ABmp, X, Y, S, Paper, Line);
    tiAddFile:
      begin
        DrawDoc(ABmp, X - 0.08 * S, Y, S, Paper, Line);
        DrawBadge(ABmp, X, Y, S, Green, True);
      end;
    tiAddFolder:
      begin
        DrawFolder(ABmp, X - 0.06 * S, Y - 0.04 * S, S, Yellow, Dim(BGRA(200, 140, 30), AEnabled));
        DrawBadge(ABmp, X, Y, S, Green, True);
      end;
    tiFolder, tiOpen:
      DrawFolder(ABmp, X, Y, S, Yellow, Dim(BGRA(200, 140, 30), AEnabled));
    tiRemove:
      begin
        ABmp.FillEllipseAntialias(CX, CY, R, R, Red);
        ABmp.DrawLineAntialias(CX - R * 0.45, CY - R * 0.45, CX + R * 0.45, CY + R * 0.45, BGRAWhite, S * 0.1);
        ABmp.DrawLineAntialias(CX + R * 0.45, CY - R * 0.45, CX - R * 0.45, CY + R * 0.45, BGRAWhite, S * 0.1);
      end;
    tiCreate:
      begin
        DrawBox(ABmp, X - 0.06 * S, Y, S, Blue, Dim(BGRA(15, 70, 140), AEnabled));
        DrawBadge(ABmp, X, Y, S, Green, True);
      end;
    tiZip:
      DrawBox(ABmp, X, Y, S, Blue, Dim(BGRA(15, 70, 140), AEnabled));
    tiLock:
      DrawPadlock(ABmp, X, Y, S, Dim(BGRA(255, 190, 40), AEnabled), Dim(BGRA(110, 60, 0), AEnabled));
    tiFileLocked:
      begin
        DrawDoc(ABmp, X - 0.08 * S, Y, S, Paper, Line);
        DrawLockBadge(ABmp, X, Y, S, AEnabled);
      end;
    tiZipLocked:
      begin
        DrawBox(ABmp, X - 0.08 * S, Y, S, Blue, Dim(BGRA(15, 70, 140), AEnabled));
        DrawLockBadge(ABmp, X, Y, S, AEnabled);
      end;
    tiExtract, tiExtractSel:
      begin
        DrawBox(ABmp, X - 0.06 * S, Y, S, Blue, Dim(BGRA(15, 70, 140), AEnabled));
        if AIcon = tiExtract then
          DrawBadge(ABmp, X, Y, S, Purple, False)
        else
          DrawBadge(ABmp, X, Y, S, Dim(BGRA(240, 140, 30), AEnabled), False);
      end;
    tiTest:
      begin
        ABmp.FillEllipseAntialias(CX, CY, R, R, Green);
        ABmp.DrawPolyLineAntialias([PointF(CX - R * 0.5, CY), PointF(CX - R * 0.1, CY + R * 0.4),
          PointF(CX + R * 0.55, CY - R * 0.4)], BGRAWhite, S * 0.11);
      end;
    tiDev:
      begin
        ABmp.FillRoundRectAntialias(X + 0.04 * S, Y + 0.12 * S, X + 0.96 * S, Y + 0.88 * S, S * 0.12, S * 0.12,
          Dim(BGRA(40, 44, 60), AEnabled));
        ABmp.DrawPolyLineAntialias([PointF(X + 0.36 * S, Y + 0.32 * S), PointF(X + 0.2 * S, Y + 0.5 * S),
          PointF(X + 0.36 * S, Y + 0.68 * S)], Dim(BGRA(120, 220, 255), AEnabled), S * 0.08);
        ABmp.DrawPolyLineAntialias([PointF(X + 0.64 * S, Y + 0.32 * S), PointF(X + 0.8 * S, Y + 0.5 * S),
          PointF(X + 0.64 * S, Y + 0.68 * S)], Dim(BGRA(120, 220, 255), AEnabled), S * 0.08);
        ABmp.DrawLineAntialias(X + 0.56 * S, Y + 0.28 * S, X + 0.44 * S, Y + 0.72 * S,
          Dim(BGRA(255, 200, 90), AEnabled), S * 0.07);
      end;
  end;
end;

procedure AddIconToImageList(AList: TCustomImageList; AIcon: TToolIcon);
var
  B: TBGRABitmap;
begin
  B := TBGRABitmap.Create(AList.Width, AList.Height, BGRAPixelTransparent);
  try
    DrawToolIcon(B, AIcon, 0, 0, AList.Width);
    AList.Add(B.Bitmap, nil);
  finally
    B.Free;
  end;
end;

{ ---------- header ---------- }

function FitText(B: TBGRABitmap; const S: string; AMaxW: Single): string;
var
  N: Integer;
begin
  Result := S;
  if B.TextSize(Result).cx <= AMaxW then
    Exit;
  N := UTF8Length(S);
  while (N > 0) and (B.TextSize(UTF8Copy(S, 1, N) + '...').cx > AMaxW) do
    Dec(N);
  Result := UTF8Copy(S, 1, N) + '...';
end;

procedure PaintHeader(ABox: TPaintBox; const ATitle, ASubtitle: string; const AStats: array of string;
  const ABadge: string);
var
  B: TBGRABitmap;
  W, H, I: Integer;
  X, PW, PH, LS: Single;
  TS: TSize;
begin
  W := ABox.Width;
  H := ABox.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  B := TBGRABitmap.Create(W, H);
  try
    B.GradientFill(0, 0, W, H, BGRA(18, 40, 90), BGRA(16, 150, 170), gtLinear,
      PointF(0, 0), PointF(W, H), dmSet);
    // decorative bubbles
    B.FillEllipseAntialias(W - 60, -10, 90, 90, BGRA(255, 255, 255, 18));
    B.FillEllipseAntialias(W - 200, H + 20, 70, 70, BGRA(255, 255, 255, 14));
    B.FillEllipseAntialias(W * 0.45, -40, 60, 60, BGRA(255, 255, 255, 10));
    B.DrawLineAntialias(0, H - 1, W, H - 1, BGRA(255, 255, 255, 60), 1);

    // logo
    B.FillRoundRectAntialias(14, (H - 52) / 2, 66, (H + 52) / 2, 12, 12, BGRA(255, 255, 255, 40));
    if ABadge <> '' then
      DrawToolIcon(B, tiZipLocked, 20, (H - 44) / 2, 44)
    else
      DrawToolIcon(B, tiZip, 18, (H - 44) / 2, 44);

    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;

    // stat pills, right-aligned
    B.FontHeight := Round(H * 0.19);
    X := W - 14;
    PH := H * 0.36;
    for I := High(AStats) downto 0 do
    begin
      if AStats[I] = '' then
        Continue;
      TS := B.TextSize(AStats[I]);
      PW := TS.cx + 20;
      X := X - PW;
      B.FillRoundRectAntialias(X, (H - PH) / 2, X + PW, (H + PH) / 2, PH / 2, PH / 2, BGRA(255, 255, 255, 38));
      B.RoundRectAntialias(X, (H - PH) / 2, X + PW, (H + PH) / 2, PH / 2, PH / 2, BGRA(255, 255, 255, 90), 1);
      B.TextOut(X + 10, (H - TS.cy) / 2, AStats[I], BGRAWhite);
      X := X - 8;
    end;

    // amber "locked" pill: solid, so it stands out from the translucent stats
    if ABadge <> '' then
    begin
      B.FontStyle := [fsBold];
      TS := B.TextSize(ABadge);
      LS := PH * 0.62;
      PW := TS.cx + LS + 26;
      X := X - PW;
      B.FillRoundRectAntialias(X, (H - PH) / 2, X + PW, (H + PH) / 2, PH / 2, PH / 2, BGRA(255, 190, 40));
      B.RoundRectAntialias(X, (H - PH) / 2, X + PW, (H + PH) / 2, PH / 2, PH / 2, BGRA(255, 230, 150), 1);
      DrawPadlock(B, X + 10, (H - LS) / 2, LS, BGRA(255, 245, 210), BGRA(110, 60, 0));
      B.TextOut(X + 16 + LS, (H - TS.cy) / 2, ABadge, BGRA(80, 40, 0));
      B.FontStyle := [];
      X := X - 8;
    end;

    // title + subtitle, shortened so they never run under the pills
    B.FontStyle := [fsBold];
    B.FontHeight := Round(H * 0.34);
    B.TextOut(80, H * 0.14, FitText(B, ATitle, X - 90), BGRAWhite);
    B.FontStyle := [];
    B.FontHeight := Round(H * 0.2);
    B.TextOut(81, H * 0.56, FitText(B, ASubtitle, X - 90), BGRA(220, 240, 255));
    B.Draw(ABox.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

{ ---------- progress ---------- }

procedure PaintProgress(ABox: TPaintBox; AFraction: Double; const AText: string; AActive: Boolean);
var
  B: TBGRABitmap;
  W, H: Integer;
  X1, Y1, X2, Y2, FX: Single;
  TS: TSize;
  G: TBGRAGradientScanner;
begin
  W := ABox.Width;
  H := ABox.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  if AFraction < 0 then AFraction := 0;
  if AFraction > 1 then AFraction := 1;
  B := TBGRABitmap.Create(W, H, BGRA(240, 243, 248));
  try
    X1 := 8; Y1 := 4; X2 := W - 8; Y2 := H - 4;
    B.FillRoundRectAntialias(X1, Y1, X2, Y2, (Y2 - Y1) / 2, (Y2 - Y1) / 2, BGRA(222, 228, 238));
    if AFraction > 0 then
    begin
      FX := X1 + (X2 - X1) * AFraction;
      if FX < X1 + (Y2 - Y1) then
        FX := X1 + (Y2 - Y1);
      if AActive then
        G := TBGRAGradientScanner.Create(BGRA(30, 140, 230), BGRA(20, 200, 190), gtLinear,
          PointF(X1, 0), PointF(FX, 0))
      else
        G := TBGRAGradientScanner.Create(BGRA(40, 180, 100), BGRA(90, 210, 130), gtLinear,
          PointF(X1, 0), PointF(FX, 0));
      try
        B.FillRoundRectAntialias(X1, Y1, FX, Y2, (Y2 - Y1) / 2, (Y2 - Y1) / 2, G);
      finally
        G.Free;
      end;
    end;
    B.RoundRectAntialias(X1, Y1, X2, Y2, (Y2 - Y1) / 2, (Y2 - Y1) / 2, BGRA(190, 200, 215), 1);
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := Round(H * 0.5);
    TS := B.TextSize(AText);
    B.TextOut((W - TS.cx) / 2, (H - TS.cy) / 2, AText, BGRA(30, 40, 60));
    B.Draw(ABox.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

{ ---------- toolbar ---------- }

constructor TBGRAToolbar.Create(ABox: TPaintBox);
begin
  FBox := ABox;
  FHot := -1;
  FDown := -1;
  FBox.OnPaint := @DoPaint;
  FBox.OnMouseMove := @DoMouseMove;
  FBox.OnMouseDown := @DoMouseDown;
  FBox.OnMouseUp := @DoMouseUp;
  FBox.OnMouseLeave := @DoMouseLeave;
  FBox.OnResize := @DoResize;
  FBox.ShowHint := True;
end;

procedure TBGRAToolbar.AddButton(ATag: Integer; const ACaption, AHint: string; AIcon: TToolIcon);
var
  N: Integer;
begin
  N := Length(FButtons);
  SetLength(FButtons, N + 1);
  FButtons[N].Tag := ATag;
  FButtons[N].Caption := ACaption;
  FButtons[N].Hint := AHint;
  FButtons[N].Icon := AIcon;
  FButtons[N].Enabled := True;
  FButtons[N].Separator := False;
  Layout;
end;

procedure TBGRAToolbar.AddSeparator;
var
  N: Integer;
begin
  N := Length(FButtons);
  SetLength(FButtons, N + 1);
  FButtons[N].Separator := True;
  FButtons[N].Enabled := False;
  FButtons[N].Tag := -1;
  Layout;
end;

function TBGRAToolbar.IndexOfTag(ATag: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FButtons) do
    if (not FButtons[I].Separator) and (FButtons[I].Tag = ATag) then
      Exit(I);
  Result := -1;
end;

procedure TBGRAToolbar.SetEnabled(ATag: Integer; AEnabled: Boolean);
var
  I: Integer;
begin
  I := IndexOfTag(ATag);
  if (I >= 0) and (FButtons[I].Enabled <> AEnabled) then
  begin
    FButtons[I].Enabled := AEnabled;
    FBox.Invalidate;
  end;
end;

procedure TBGRAToolbar.Layout;
var
  B: TBGRABitmap;
  I, X, H, IconS: Integer;
begin
  H := FBox.Height;
  if H <= 0 then
    H := 56;
  // icon on top, caption below: keeps the whole toolbar narrow
  IconS := Round(H * 0.42);
  B := TBGRABitmap.Create(1, 1);
  try
    B.FontName := 'Segoe UI';
    B.FontHeight := Round(H * 0.24);
    X := 4;
    for I := 0 to High(FButtons) do
    begin
      if FButtons[I].Separator then
      begin
        FButtons[I].Rect := Rect(X, 6, X + 10, H - 6);
        Inc(X, 10);
      end
      else
      begin
        FButtons[I].Rect := Rect(X, 3, X + Max(IconS, B.TextSize(FButtons[I].Caption).cx) + 16, H - 3);
        X := FButtons[I].Rect.Right + 1;
      end;
    end;
  finally
    B.Free;
  end;
  FBox.Invalidate;
end;

procedure TBGRAToolbar.DoResize(Sender: TObject);
begin
  Layout;
end;

function TBGRAToolbar.HitTest(X, Y: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FButtons) do
    if (not FButtons[I].Separator) and PtInRect(FButtons[I].Rect, Point(X, Y)) then
      Exit(I);
  Result := -1;
end;

procedure TBGRAToolbar.DoPaint(Sender: TObject);
var
  B: TBGRABitmap;
  I, W, H, IconS: Integer;
  R: TRect;
  TS: TSize;
  TextC: TBGRAPixel;
begin
  W := FBox.Width;
  H := FBox.Height;
  if (W <= 0) or (H <= 0) then
    Exit;
  IconS := Round(H * 0.42);
  B := TBGRABitmap.Create(W, H);
  try
    B.GradientFill(0, 0, W, H, BGRA(252, 253, 255), BGRA(232, 237, 245), gtLinear,
      PointF(0, 0), PointF(0, H), dmSet);
    B.DrawLineAntialias(0, H - 0.5, W, H - 0.5, BGRA(200, 208, 222), 1);
    B.FontName := 'Segoe UI';
    B.FontQuality := fqFineAntialiasing;
    B.FontHeight := Round(H * 0.24);
    for I := 0 to High(FButtons) do
    begin
      R := FButtons[I].Rect;
      if FButtons[I].Separator then
      begin
        B.DrawLineAntialias(R.Left + 5, R.Top + 4, R.Left + 5, R.Bottom - 4, BGRA(200, 208, 222), 1);
        Continue;
      end;
      if FButtons[I].Enabled and (I = FHot) then
      begin
        if I = FDown then
          B.FillRoundRectAntialias(R.Left, R.Top, R.Right, R.Bottom, 7, 7, BGRA(190, 215, 245))
        else
          B.FillRoundRectAntialias(R.Left, R.Top, R.Right, R.Bottom, 7, 7, BGRA(220, 235, 252));
        B.RoundRectAntialias(R.Left + 0.5, R.Top + 0.5, R.Right - 0.5, R.Bottom - 0.5, 7, 7,
          BGRA(120, 170, 230), 1);
      end;
      DrawToolIcon(B, FButtons[I].Icon, (R.Left + R.Right - IconS) / 2, R.Top + 3, IconS, FButtons[I].Enabled);
      if FButtons[I].Enabled then
        TextC := clrText
      else
        TextC := BGRA(160, 165, 175);
      TS := B.TextSize(FButtons[I].Caption);
      B.TextOut((R.Left + R.Right - TS.cx) / 2, R.Bottom - TS.cy - 2, FButtons[I].Caption, TextC);
    end;
    B.Draw(FBox.Canvas, 0, 0, True);
  finally
    B.Free;
  end;
end;

procedure TBGRAToolbar.DoMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  I := HitTest(X, Y);
  if I <> FHot then
  begin
    FHot := I;
    if I >= 0 then
      FBox.Hint := FButtons[I].Hint
    else
      FBox.Hint := '';
    Application.CancelHint;
    FBox.Invalidate;
  end;
end;

procedure TBGRAToolbar.DoMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then
  begin
    FDown := HitTest(X, Y);
    FBox.Invalidate;
  end;
end;

procedure TBGRAToolbar.DoMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var
  I: Integer;
begin
  if Button <> mbLeft then
    Exit;
  I := HitTest(X, Y);
  if (I >= 0) and (I = FDown) and FButtons[I].Enabled then
  begin
    FDown := -1;
    FBox.Invalidate;
    if Assigned(FOnClick) then
      FOnClick(Self, FButtons[I].Tag);
  end
  else
  begin
    FDown := -1;
    FBox.Invalidate;
  end;
end;

procedure TBGRAToolbar.DoMouseLeave(Sender: TObject);
begin
  FHot := -1;
  FDown := -1;
  FBox.Invalidate;
end;

end.
