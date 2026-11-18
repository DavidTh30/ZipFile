unit uEffects;

{ Decorative particle effects for BGRA Zip events, drawn with BGRABitmap.

  They play in a separate layered window above the main form: it has per-pixel
  alpha, lets every click through, never takes focus and is hidden whenever
  nothing is playing. Effects are decoration only, so any failure here logs and
  switches the engine off instead of reaching the user. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows, ExtCtrls, BGRABitmap, BGRABitmapTypes;

type
  TFxEvent = (feStart, feOpen, feAdd, feRemove, feProgress, feCreate, feExtract, feDrag,
    feTestOk, feTestFail, feError, feScriptOk, feScriptFail);
  TFxStyle = (fsSparkle, fsConfetti, fsFireworks, fsBubbles, fsHearts, fsFountain, fsPuff, fsAlarm);
  TFxPalette = (fpRainbow, fpGold, fpPastel, fpNeon, fpOcean);

  TFxKind = (fkSpark, fkDot, fkHeart, fkBubble, fkConfetti, fkRing, fkFrame);

  TFxParticle = record
    X, Y, VX, VY, Gravity, Drag: Single;
    Age, Life, Delay: Single;
    Size, Angle, Spin, Wobble: Single;
    Color: Byte;
    Kind: TFxKind;
    Twinkle: Boolean;
  end;

  TFxEventOption = record
    Enabled: Boolean;
    Style: TFxStyle;
  end;

  { TFxEngine }

  TFxEngine = class
  private
    FOwner: HWND;
    FWnd: HWND;
    FBmp: TBGRABitmap;
    FDIB: HBITMAP;
    FDibBits: PByte;
    FDibW, FDibH: Integer;
    FMemDC: HDC;
    FOldBmp: HGDIOBJ;
    FTimer: TTimer;
    FParts: array of TFxParticle;
    FCount: Integer;
    FLastTick: QWord;
    FLastProgress: QWord;
    FDirty: TRect;
    FSprites: array[fkSpark..fkBubble, 0..31, 0..5] of TBGRABitmap;
    FBroken: Boolean;
    FIniFile: string;
    FFrames: Int64;
    FFrameMs: Double;
    FPeak: Integer;
    procedure Tick(Sender: TObject);
    function EnsureWindow: Boolean;
    function EnsureSurface(AW, AH: Integer): Boolean;
    procedure FreeSurface;
    procedure Fail(const AWhere: string; E: Exception);
    procedure Update(ADt: Single);
    procedure Render(AW, AH: Integer);
    procedure Present(const AOrigin: TPoint; AW, AH: Integer);
    function Sprite(AKind: TFxKind; AColor: Byte; ASize: Single): TBGRABitmap;
    function NewPart: Integer;
    function RandColor: Byte;
    procedure Burst(AX, AY: Single; ACount: Integer; ASpeed, AGravity, ALife: Single; AKind: TFxKind;
      ADelay: Single; AColor: Integer);
    procedure Ring(AX, AY, ASpeed, ALife: Single; AColor: Byte);
    procedure Spawn(AStyle: TFxStyle; AX, AY: Single; AW, AH: Integer);
    procedure Start;
    function ClientSize(out AW, AH: Integer): Boolean;
  public
    Enabled: Boolean;
    FollowWindows: Boolean;     // stay still when Windows has animations turned off
    Intensity: Integer;         // percent, 25..200
    Palette: TFxPalette;
    Options: array[TFxEvent] of TFxEventOption;
    constructor Create(AOwnerWnd: HWND; const AIniFile: string);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    { False when it does not play; WhyNot says why. AForce ignores the settings (preview). }
    function Play(AEvent: TFxEvent; AX, AY: Integer; AForce: Boolean = False): Boolean;
    function PlayStyle(AStyle: TFxStyle; AX, AY: Integer): Boolean;
    { Sparkles on the progress bar's moving edge, at most a few times a second. }
    procedure ProgressSpark(AX, AY: Integer);
    function WhyNot: string;
    function ActiveCount: Integer;
    { The current frame, without what is underneath. }
    procedure SaveSnapshot(const AFileName: string);
    function Stats: string;
    function WindowHandle: HWND;
  end;

const
  FxEventNames: array[TFxEvent] of string = ('start', 'open', 'add', 'remove', 'progress', 'create',
    'extract', 'drag', 'test_ok', 'test_fail', 'error', 'script_ok', 'script_fail');
  FxEventCaptions: array[TFxEvent] of string = ('Program start', 'Archive opened', 'Files added',
    'Files removed from the list', 'Work in progress', 'Archive created', 'Extraction finished',
    'Dragged out to a folder', 'Test passed', 'Test failed', 'An operation failed',
    'Script finished', 'Script failed');
  FxStyleNames: array[TFxStyle] of string = ('Sparkle', 'Confetti', 'Fireworks', 'Bubbles', 'Hearts',
    'Fountain', 'Puff', 'Alarm');
  FxPaletteNames: array[TFxPalette] of string = ('Rainbow', 'Gold', 'Pastel', 'Neon', 'Ocean');

function FxEventByName(const AName: string; out AEvent: TFxEvent): Boolean;
function FxStyleByName(const AName: string; out AStyle: TFxStyle): Boolean;

var
  Fx: TFxEngine = nil;

implementation

uses
  Math, IniFiles, uDevLog;

const
  CLASS_NAME: PWideChar = 'BGRAZipFxOverlay';
  ULW_ALPHA_ = 2;
  SPI_GETCLIENTAREAANIMATION_ = $1042;
  MAX_PARTS = 2400;
  FRAME_MS = 16;
  SIZE_BUCKETS: array[0..5] of Integer = (6, 9, 13, 18, 26, 38);
  DefaultOptions: array[TFxEvent] of TFxEventOption = (
    (Enabled: True; Style: fsSparkle),    // start
    (Enabled: True; Style: fsSparkle),    // open
    (Enabled: True; Style: fsBubbles),    // add
    (Enabled: True; Style: fsPuff),       // remove
    (Enabled: True; Style: fsSparkle),    // progress
    (Enabled: True; Style: fsConfetti),   // create
    (Enabled: True; Style: fsFountain),   // extract
    (Enabled: True; Style: fsSparkle),    // drag
    (Enabled: True; Style: fsFireworks),  // test ok
    (Enabled: True; Style: fsAlarm),      // test failed
    (Enabled: True; Style: fsAlarm),      // error
    (Enabled: True; Style: fsHearts),     // script ok
    (Enabled: True; Style: fsAlarm));     // script failed

  // the palettes share one table so sprites can be cached by index
  PALETTE_FIRST: array[TFxPalette] of Byte = (0, 7, 12, 17, 22);
  PALETTE_COUNT: array[TFxPalette] of Byte = (7, 5, 5, 5, 5);
  COLOR_RED = 27;
  COLOR_GREY = 28;
  COLOR_WHITE = 29;
  Colors: array[0..29] of array[0..2] of Byte = (
    (255, 80, 90), (255, 165, 40), (255, 225, 60), (90, 220, 110), (60, 190, 255), (120, 110, 255), (235, 90, 230),
    (255, 215, 70), (255, 240, 150), (255, 190, 40), (255, 250, 210), (240, 160, 30),
    (255, 180, 200), (190, 225, 255), (205, 245, 205), (255, 240, 180), (225, 200, 255),
    (0, 255, 230), (255, 40, 200), (170, 255, 30), (90, 120, 255), (255, 240, 40),
    (0, 200, 220), (60, 150, 255), (150, 235, 255), (0, 230, 180), (225, 250, 255),
    (235, 50, 50), (190, 195, 205), (255, 255, 255));

function UpdateLayeredWindow(AWnd: HWND; ADstDC: HDC; ADst, ASize: Pointer; ASrcDC: HDC; ASrc: Pointer;
  AKey: COLORREF; ABlend: Pointer; AFlags: DWORD): BOOL; stdcall; external 'user32.dll';

function FxEventByName(const AName: string; out AEvent: TFxEvent): Boolean;
var
  E: TFxEvent;
begin
  for E := Low(TFxEvent) to High(TFxEvent) do
    if SameText(FxEventNames[E], AName) then
    begin
      AEvent := E;
      Exit(True);
    end;
  Result := False;
end;

function FxStyleByName(const AName: string; out AStyle: TFxStyle): Boolean;
var
  S: TFxStyle;
begin
  for S := Low(TFxStyle) to High(TFxStyle) do
    if SameText(FxStyleNames[S], AName) then
    begin
      AStyle := S;
      Exit(True);
    end;
  Result := False;
end;

function WindowsAnimationsOn: Boolean;
var
  B: BOOL;
begin
  B := True;
  if SystemParametersInfo(SPI_GETCLIENTAREAANIMATION_, 0, @B, 0) then
    Result := B
  else
    Result := True;
end;

{ ---------- life cycle ---------- }

constructor TFxEngine.Create(AOwnerWnd: HWND; const AIniFile: string);
var
  E: TFxEvent;
begin
  FOwner := AOwnerWnd;
  FIniFile := AIniFile;
  Enabled := True;
  FollowWindows := True;
  Intensity := 100;
  Palette := fpRainbow;
  for E := Low(TFxEvent) to High(TFxEvent) do
    Options[E] := DefaultOptions[E];
  SetLength(FParts, MAX_PARTS);
  FTimer := TTimer.Create(nil);
  FTimer.Enabled := False;
  FTimer.Interval := FRAME_MS;
  FTimer.OnTimer := @Tick;
end;

destructor TFxEngine.Destroy;
var
  K: TFxKind;
  C, S: Integer;
begin
  FTimer.Free;
  FreeSurface;
  if FWnd <> 0 then
    DestroyWindow(FWnd);
  FBmp.Free;
  for K := Low(FSprites) to High(FSprites) do
    for C := 0 to 31 do
      for S := 0 to 5 do
        FSprites[K, C, S].Free;
  inherited Destroy;
end;

procedure TFxEngine.Load;
var
  Ini: TIniFile;
  E: TFxEvent;
  S: TFxStyle;
  P: TFxPalette;
begin
  Ini := TIniFile.Create(FIniFile);
  try
    Enabled := Ini.ReadBool('Effects', 'Enabled', True);
    FollowWindows := Ini.ReadBool('Effects', 'FollowWindows', True);
    Intensity := EnsureRange(Ini.ReadInteger('Effects', 'Intensity', 100), 25, 200);
    for P := Low(TFxPalette) to High(TFxPalette) do
      if SameText(FxPaletteNames[P], Ini.ReadString('Effects', 'Palette', FxPaletteNames[fpRainbow])) then
        Palette := P;
    for E := Low(TFxEvent) to High(TFxEvent) do
    begin
      Options[E].Enabled := Ini.ReadBool('Effects', FxEventNames[E], DefaultOptions[E].Enabled);
      if FxStyleByName(Ini.ReadString('Effects', FxEventNames[E] + '_style', ''), S) then
        Options[E].Style := S;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFxEngine.Save;
var
  Ini: TIniFile;
  E: TFxEvent;
begin
  Ini := TIniFile.Create(FIniFile);
  try
    Ini.WriteBool('Effects', 'Enabled', Enabled);
    Ini.WriteBool('Effects', 'FollowWindows', FollowWindows);
    Ini.WriteInteger('Effects', 'Intensity', Intensity);
    Ini.WriteString('Effects', 'Palette', FxPaletteNames[Palette]);
    for E := Low(TFxEvent) to High(TFxEvent) do
    begin
      Ini.WriteBool('Effects', FxEventNames[E], Options[E].Enabled);
      Ini.WriteString('Effects', FxEventNames[E] + '_style', FxStyleNames[Options[E].Style]);
    end;
  finally
    Ini.Free;
  end;
end;

procedure TFxEngine.Fail(const AWhere: string; E: Exception);
begin
  FBroken := True;
  FCount := 0;
  FTimer.Enabled := False;
  if FWnd <> 0 then
    ShowWindow(FWnd, SW_HIDE);
  DevLogFmt(llWarn, 'Effects switched off (%s): %s', [AWhere, E.Message]);
end;

{ ---------- window and surface ---------- }

function TFxEngine.EnsureWindow: Boolean;
var
  WC: TWndClassW;
begin
  Result := FWnd <> 0;
  if Result then
    Exit;
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc := @DefWindowProcW;
  WC.hInstance := HInstance;
  WC.lpszClassName := CLASS_NAME;
  Windows.RegisterClassW(WC);
  FWnd := CreateWindowExW(WS_EX_LAYERED or WS_EX_TRANSPARENT or WS_EX_NOACTIVATE or WS_EX_TOOLWINDOW,
    CLASS_NAME, '', WS_POPUP, 0, 0, 16, 16, FOwner, 0, HInstance, nil);
  Result := FWnd <> 0;
  if not Result then
    raise Exception.CreateFmt('CreateWindowEx failed (%d)', [GetLastError]);
end;

function TFxEngine.EnsureSurface(AW, AH: Integer): Boolean;
var
  BI: TBitmapInfo;
  Bits: Pointer;
begin
  if (FDIB <> 0) and (AW = FDibW) and (AH = FDibH) then
    Exit(True);
  FreeSurface;
  FillChar(BI, SizeOf(BI), 0);
  BI.bmiHeader.biSize := SizeOf(BI.bmiHeader);
  BI.bmiHeader.biWidth := AW;
  BI.bmiHeader.biHeight := -AH;   // top-down
  BI.bmiHeader.biPlanes := 1;
  BI.bmiHeader.biBitCount := 32;
  BI.bmiHeader.biCompression := BI_RGB;
  FMemDC := CreateCompatibleDC(0);
  FDIB := CreateDIBSection(FMemDC, BI, DIB_RGB_COLORS, Bits, 0, 0);
  if FDIB = 0 then
    raise Exception.CreateFmt('CreateDIBSection %dx%d failed', [AW, AH]);
  FDibBits := Bits;
  FOldBmp := SelectObject(FMemDC, FDIB);
  FDibW := AW;
  FDibH := AH;
  FreeAndNil(FBmp);
  FBmp := TBGRABitmap.Create(AW, AH, BGRAPixelTransparent);
  FDirty := Classes.Rect(0, 0, 0, 0);
  Result := True;
end;

procedure TFxEngine.FreeSurface;
begin
  if FMemDC <> 0 then
  begin
    SelectObject(FMemDC, FOldBmp);
    DeleteDC(FMemDC);
    FMemDC := 0;
  end;
  if FDIB <> 0 then
  begin
    DeleteObject(FDIB);
    FDIB := 0;
  end;
  FDibBits := nil;
  FDibW := 0;
  FDibH := 0;
end;

function TFxEngine.ClientSize(out AW, AH: Integer): Boolean;
var
  R: TRect;
begin
  AW := 0;
  AH := 0;
  Result := IsWindow(FOwner) and IsWindowVisible(FOwner) and not IsIconic(FOwner) and GetClientRect(FOwner, R);
  if Result then
  begin
    AW := R.Right;
    AH := R.Bottom;
    Result := (AW > 0) and (AH > 0);
  end;
end;

{ ---------- sprites ---------- }

function TFxEngine.Sprite(AKind: TFxKind; AColor: Byte; ASize: Single): TBGRABitmap;
var
  B, S: Integer;
  C, Glow: TBGRAPixel;
  R, Mid: Single;
  Star: array[0..7] of TPointF;
  I: Integer;
  A: Single;
begin
  B := 0;
  while (B < 5) and (SIZE_BUCKETS[B] < ASize) do
    Inc(B);
  Result := FSprites[AKind, AColor, B];
  if Result <> nil then
    Exit;
  S := SIZE_BUCKETS[B] * 2;
  Mid := S / 2 - 0.5;
  R := SIZE_BUCKETS[B];
  C := BGRA(Colors[AColor][0], Colors[AColor][1], Colors[AColor][2]);
  Result := TBGRABitmap.Create(S, S, BGRAPixelTransparent);
  case AKind of
    fkSpark:
      begin
        // soft halo with a four-point star over it
        Glow := C;
        Glow.alpha := 70;
        Result.FillEllipseAntialias(Mid, Mid, R * 0.55, R * 0.55, Glow);
        for I := 0 to 7 do
        begin
          A := I * Pi / 4;
          if Odd(I) then
            Star[I] := PointF(Mid + Cos(A) * R * 0.14, Mid + Sin(A) * R * 0.14)
          else
            Star[I] := PointF(Mid + Cos(A) * R * 0.95, Mid + Sin(A) * R * 0.95);
        end;
        Result.FillPolyAntialias(Star, C);
        Result.FillEllipseAntialias(Mid, Mid, Max(R * 0.16, 0.8), Max(R * 0.16, 0.8), BGRAWhite);
      end;
    fkDot:
      begin
        Glow := C;
        Glow.alpha := 80;
        Result.FillEllipseAntialias(Mid, Mid, R * 0.8, R * 0.8, Glow);
        Result.FillEllipseAntialias(Mid, Mid, R * 0.38, R * 0.38, C);
      end;
    fkHeart:
      begin
        Result.FillEllipseAntialias(Mid - R * 0.34, Mid - R * 0.2, R * 0.42, R * 0.42, C);
        Result.FillEllipseAntialias(Mid + R * 0.34, Mid - R * 0.2, R * 0.42, R * 0.42, C);
        Result.FillPolyAntialias([PointF(Mid - R * 0.74, Mid - R * 0.04), PointF(Mid + R * 0.74, Mid - R * 0.04),
          PointF(Mid, Mid + R * 0.82)], C);
        Result.FillEllipseAntialias(Mid - R * 0.38, Mid - R * 0.3, R * 0.12, R * 0.12, BGRA(255, 255, 255, 190));
      end;
    fkBubble:
      begin
        Glow := C;
        Glow.alpha := 45;
        Result.FillEllipseAntialias(Mid, Mid, R * 0.82, R * 0.82, Glow);
        Glow.alpha := 200;
        Result.EllipseAntialias(Mid, Mid, R * 0.82, R * 0.82, Glow, Max(R * 0.07, 1));
        Result.FillEllipseAntialias(Mid - R * 0.3, Mid - R * 0.32, R * 0.15, R * 0.15, BGRA(255, 255, 255, 220));
      end;
  end;
  FSprites[AKind, AColor, B] := Result;
end;

{ ---------- spawning ---------- }

function TFxEngine.NewPart: Integer;
begin
  if FCount >= MAX_PARTS then
    Exit(-1);
  Result := FCount;
  Inc(FCount);
  FillChar(FParts[Result], SizeOf(TFxParticle), 0);
  FParts[Result].Drag := 1;
end;

function TFxEngine.RandColor: Byte;
begin
  Result := PALETTE_FIRST[Palette] + Random(PALETTE_COUNT[Palette]);
end;

procedure TFxEngine.Burst(AX, AY: Single; ACount: Integer; ASpeed, AGravity, ALife: Single; AKind: TFxKind;
  ADelay: Single; AColor: Integer);
var
  I, N: Integer;
  A, V: Single;
begin
  for I := 1 to ACount do
  begin
    N := NewPart;
    if N < 0 then
      Exit;
    A := Random * 2 * Pi;
    V := ASpeed * (0.25 + Random * 0.75);
    with FParts[N] do
    begin
      X := AX;
      Y := AY;
      VX := Cos(A) * V;
      VY := Sin(A) * V;
      Gravity := AGravity;
      Drag := 0.2;
      Life := ALife * (0.6 + Random * 0.6);
      Delay := ADelay;
      Size := 5 + Random * 11;
      Kind := AKind;
      Twinkle := AKind = fkSpark;
      Wobble := Random * 6;
      if AColor >= 0 then
        Color := AColor
      else
        Color := RandColor;
    end;
  end;
end;

procedure TFxEngine.Ring(AX, AY, ASpeed, ALife: Single; AColor: Byte);
var
  N: Integer;
begin
  N := NewPart;
  if N < 0 then
    Exit;
  with FParts[N] do
  begin
    X := AX;
    Y := AY;
    VX := ASpeed;
    Life := ALife;
    Kind := fkRing;
    Color := AColor;
  end;
end;

procedure TFxEngine.Spawn(AStyle: TFxStyle; AX, AY: Single; AW, AH: Integer);
var
  Scale: Single;
  I, N, Total, Shells, C: Integer;
  SX, SY: Single;

  function Cnt(ABase: Integer): Integer;
  begin
    Result := Max(1, Round(ABase * Scale));
  end;

begin
  Scale := Intensity / 100;
  case AStyle of
    fsSparkle:
      begin
        Burst(AX, AY, Cnt(70), 300, 70, 1.25, fkSpark, 0, -1);
        Ring(AX, AY, 420, 0.6, RandColor);
      end;
    fsFireworks:
      begin
        Shells := Max(2, Round(4 * Scale));
        for I := 0 to Shells - 1 do
        begin
          SX := AW * (0.15 + Random * 0.7);
          SY := AH * (0.15 + Random * 0.4);
          C := RandColor;
          Burst(SX, SY, Cnt(60), 340, 110, 1.3, fkDot, I * 0.24, C);
          Burst(SX, SY, Cnt(14), 180, 60, 1.0, fkSpark, I * 0.24, COLOR_WHITE);
        end;
      end;
    fsConfetti:
      begin
        Total := Cnt(170);
        for I := 1 to Total do
        begin
          N := NewPart;
          if N < 0 then
            Break;
          with FParts[N] do
          begin
            X := Random * AW;
            Y := -20 - Random * 40;
            VX := -30 + Random * 60;
            VY := 130 + Random * 190;
            Gravity := 40;
            Life := (AH + 80) / VY + 0.5;
            Delay := Random * 0.9;
            Size := 5 + Random * 6;
            Angle := Random * 2 * Pi;
            Spin := -9 + Random * 18;
            Wobble := Random * 6;
            Kind := fkConfetti;
            Color := RandColor;
          end;
        end;
      end;
    fsBubbles:
      for I := 1 to Cnt(30) do
      begin
        N := NewPart;
        if N < 0 then
          Break;
        with FParts[N] do
        begin
          X := AX + (-110 + Random * 220);
          Y := AY + Random * 60;
          VX := -12 + Random * 24;
          VY := -55 - Random * 120;
          Life := 1.2 + Random * 1.1;
          Delay := Random * 0.5;
          Size := 7 + Random * 22;
          Wobble := Random * 6;
          Kind := fkBubble;
          Color := RandColor;
        end;
      end;
    fsHearts:
      for I := 1 to Cnt(26) do
      begin
        N := NewPart;
        if N < 0 then
          Break;
        with FParts[N] do
        begin
          X := AX + (-130 + Random * 260);
          Y := AY + Random * 70;
          VX := -15 + Random * 30;
          VY := -70 - Random * 110;
          Life := 1.3 + Random * 0.9;
          Delay := Random * 0.6;
          Size := 8 + Random * 18;
          Wobble := Random * 6;
          Kind := fkHeart;
          if Palette = fpRainbow then
            Color := 0
          else
            Color := RandColor;
        end;
      end;
    fsFountain:
      for I := 1 to Cnt(130) do
      begin
        N := NewPart;
        if N < 0 then
          Break;
        with FParts[N] do
        begin
          X := AX + (-12 + Random * 24);
          Y := AY;
          VX := -170 + Random * 340;
          VY := -300 - Random * 370;
          Gravity := 720;
          Life := 1.1 + Random * 0.7;
          Delay := Random * 0.55;
          Size := 5 + Random * 10;
          Twinkle := True;
          Kind := fkSpark;
          Color := RandColor;
        end;
      end;
    fsPuff:
      begin
        Burst(AX, AY, Cnt(32), 130, -35, 0.7, fkDot, 0, COLOR_GREY);
        Ring(AX, AY, 170, 0.4, COLOR_GREY);
      end;
    fsAlarm:
      begin
        for I := 0 to 1 do
        begin
          N := NewPart;
          if N < 0 then
            Break;
          with FParts[N] do
          begin
            Life := 0.55;
            Delay := I * 0.45;
            Kind := fkFrame;
            Color := COLOR_RED;
          end;
        end;
        Burst(AX, AY, Cnt(26), 170, 340, 0.9, fkDot, 0, COLOR_RED);
      end;
  end;
  if FCount > FPeak then
    FPeak := FCount;
end;

function TFxEngine.WhyNot: string;
begin
  Result := '';
  if FBroken then
    Result := 'effects stopped after an error (see the log)'
  else if not Enabled then
    Result := 'effects are turned off'
  else if FollowWindows and not WindowsAnimationsOn then
    Result := 'Windows animations are turned off';
end;

procedure TFxEngine.Start;
begin
  if not FTimer.Enabled then
  begin
    FLastTick := GetTickCount64;
    FTimer.Enabled := True;
  end;
end;

function TFxEngine.Play(AEvent: TFxEvent; AX, AY: Integer; AForce: Boolean): Boolean;
begin
  Result := False;
  if AForce then
  begin
    if FBroken then
      Exit;
  end
  else if (WhyNot <> '') or not Options[AEvent].Enabled then
    Exit;
  Result := PlayStyle(Options[AEvent].Style, AX, AY);
end;

function TFxEngine.PlayStyle(AStyle: TFxStyle; AX, AY: Integer): Boolean;
var
  W, H: Integer;
begin
  Result := False;
  if FBroken or not ClientSize(W, H) then
    Exit;
  try
    EnsureWindow;
    Spawn(AStyle, AX, AY, W, H);
    Start;
    Result := True;
  except
    on E: Exception do
      Fail('play', E);
  end;
end;

procedure TFxEngine.ProgressSpark(AX, AY: Integer);
var
  T: QWord;
  W, H, I, N: Integer;
begin
  if (WhyNot <> '') or not Options[feProgress].Enabled then
    Exit;
  T := GetTickCount64;
  if (T - FLastProgress < 90) or not ClientSize(W, H) then
    Exit;
  FLastProgress := T;
  try
    EnsureWindow;
    for I := 1 to Max(1, Round(3 * Intensity / 100)) do
    begin
      N := NewPart;
      if N < 0 then
        Exit;
      with FParts[N] do
      begin
        X := AX;
        Y := AY + (-8 + Random * 16);
        VX := -30 + Random * 90;
        VY := -40 - Random * 80;
        Gravity := 150;
        Life := 0.4 + Random * 0.4;
        Size := 5 + Random * 7;
        Twinkle := True;
        Kind := fkSpark;
        Color := RandColor;
      end;
    end;
    Start;
  except
    on E: Exception do
      Fail('progress', E);
  end;
end;

function TFxEngine.ActiveCount: Integer;
begin
  Result := FCount;
end;

{ ---------- frame ---------- }

procedure TFxEngine.Update(ADt: Single);
var
  I, N: Integer;
begin
  N := 0;
  for I := 0 to FCount - 1 do
    with FParts[I] do
    begin
      if Delay > 0 then
      begin
        Delay := Delay - ADt;
        FParts[N] := FParts[I];
        Inc(N);
        Continue;
      end;
      Age := Age + ADt;
      if Age >= Life then
        Continue;
      VY := VY + Gravity * ADt;
      if Drag < 1 then
      begin
        VX := VX * (1 - Drag * ADt * 2);
        VY := VY * (1 - Drag * ADt * 2);
      end;
      if Kind <> fkRing then
      begin
        X := X + VX * ADt;
        Y := Y + VY * ADt;
      end;
      Angle := Angle + Spin * ADt;
      Wobble := Wobble + ADt * 3;
      FParts[N] := FParts[I];
      Inc(N);
    end;
  FCount := N;
end;

procedure TFxEngine.Render(AW, AH: Integer);
var
  I, IX, IY, HalfW: Integer;
  F, A, Op, CA, SA, DX: Single;
  Sp: TBGRABitmap;
  C: TBGRAPixel;
  B, Now_: TRect;
  Q: array[0..3] of TPointF;
  W2, H2: Single;

  procedure Grow(AL, AT, AR, AB: Integer);
  begin
    if Now_.Right <= Now_.Left then
      Now_ := Classes.Rect(AL, AT, AR, AB)
    else
    begin
      if AL < Now_.Left then Now_.Left := AL;
      if AT < Now_.Top then Now_.Top := AT;
      if AR > Now_.Right then Now_.Right := AR;
      if AB > Now_.Bottom then Now_.Bottom := AB;
    end;
  end;

begin
  // only what changed is redrawn, so a small effect on a big window stays cheap
  if FDirty.Right > FDirty.Left then
    FBmp.FillRect(FDirty.Left, FDirty.Top, FDirty.Right, FDirty.Bottom, BGRAPixelTransparent, dmSet);
  Now_ := Classes.Rect(0, 0, 0, 0);
  for I := 0 to FCount - 1 do
    with FParts[I] do
    begin
      if Delay > 0 then
        Continue;
      F := Age / Life;
      A := 1 - F * F;
      C := BGRA(Colors[Color][0], Colors[Color][1], Colors[Color][2]);
      case Kind of
        fkSpark, fkDot, fkHeart, fkBubble:
          begin
            Op := A;
            if Twinkle then
              Op := Op * (0.55 + 0.45 * Sin(Age * 22 + Wobble));
            if Op <= 0.01 then
              Continue;
            DX := 0;
            if Kind in [fkHeart, fkBubble] then
              DX := Sin(Wobble) * 9;
            Sp := Sprite(Kind, Color, Size);
            HalfW := Sp.Width div 2;
            IX := Round(X + DX) - HalfW;
            IY := Round(Y) - HalfW;
            FBmp.PutImage(IX, IY, Sp, dmDrawWithTransparency, Round(255 * Min(Op, 1)));
            Grow(IX, IY, IX + Sp.Width, IY + Sp.Height);
          end;
        fkConfetti:
          begin
            IX := Round(X + Sin(Wobble) * 16);
            IY := Round(Y);
            CA := Cos(Angle);
            SA := Sin(Angle);
            // squashing one axis with time looks like a paper flake turning over
            W2 := Size * (0.35 + 0.65 * Abs(Sin(Angle * 0.7)));
            H2 := Size * 0.55;
            Q[0] := PointF(IX + (-W2 * CA + H2 * SA), IY + (-W2 * SA - H2 * CA));
            Q[1] := PointF(IX + (W2 * CA + H2 * SA), IY + (W2 * SA - H2 * CA));
            Q[2] := PointF(IX + (W2 * CA - H2 * SA), IY + (W2 * SA + H2 * CA));
            Q[3] := PointF(IX + (-W2 * CA - H2 * SA), IY + (-W2 * SA + H2 * CA));
            C.alpha := Round(255 * Min(1, A * 2.2));
            FBmp.FillPolyAntialias(Q, C);
            Grow(IX - 16, IY - 16, IX + 16, IY + 16);
          end;
        fkRing:
          begin
            W2 := VX * Age;
            C.alpha := Round(190 * A);
            FBmp.EllipseAntialias(X, Y, W2, W2, C, Max(1, 5 * A));
            Grow(Round(X - W2) - 6, Round(Y - W2) - 6, Round(X + W2) + 6, Round(Y + W2) + 6);
          end;
        fkFrame:
          begin
            // a red edge that fades in and out, leaving the middle readable
            Op := Sin(F * Pi);
            C.alpha := Round(70 * Op);
            FBmp.RectangleAntialias(11, 11, AW - 12, AH - 12, C, 22);
            C.alpha := Round(150 * Op);
            FBmp.RectangleAntialias(4, 4, AW - 5, AH - 5, C, 8);
            Grow(0, 0, AW, AH);
          end;
      end;
    end;
  B := FDirty;
  // both the area cleared above and the area drawn must reach the screen
  if Now_.Right > Now_.Left then
  begin
    if B.Right <= B.Left then
      B := Now_
    else
    begin
      if Now_.Left < B.Left then B.Left := Now_.Left;
      if Now_.Top < B.Top then B.Top := Now_.Top;
      if Now_.Right > B.Right then B.Right := Now_.Right;
      if Now_.Bottom > B.Bottom then B.Bottom := Now_.Bottom;
    end;
  end;
  B.Left := Max(B.Left, 0);
  B.Top := Max(B.Top, 0);
  B.Right := Min(B.Right, AW);
  B.Bottom := Min(B.Bottom, AH);
  for IY := B.Top to B.Bottom - 1 do
  begin
    // UpdateLayeredWindow wants premultiplied alpha, BGRABitmap keeps it straight
    Move(FBmp.ScanLine[IY][B.Left], (FDibBits + (IY * AW + B.Left) * 4)^, (B.Right - B.Left) * 4);
    for IX := B.Left to B.Right - 1 do
      with PBGRAPixel(FDibBits + (IY * AW + IX) * 4)^ do
        if alpha = 0 then
          DWord(PBGRAPixel(FDibBits + (IY * AW + IX) * 4)^) := 0
        else if alpha < 255 then
        begin
          red := (Word(red) * alpha + 127) div 255;
          green := (Word(green) * alpha + 127) div 255;
          blue := (Word(blue) * alpha + 127) div 255;
        end;
  end;
  FDirty := Now_;
end;

procedure TFxEngine.Present(const AOrigin: TPoint; AW, AH: Integer);
var
  Dst, Src: Windows.TPoint;
  Sz: Windows.TSize;
  Bl: TBlendFunction;
begin
  Dst.X := AOrigin.X;
  Dst.Y := AOrigin.Y;
  Src.X := 0;
  Src.Y := 0;
  Sz.cx := AW;
  Sz.cy := AH;
  Bl.BlendOp := AC_SRC_OVER;
  Bl.BlendFlags := 0;
  Bl.SourceConstantAlpha := 255;
  Bl.AlphaFormat := AC_SRC_ALPHA;
  if not UpdateLayeredWindow(FWnd, 0, @Dst, @Sz, FMemDC, @Src, 0, @Bl, ULW_ALPHA_) then
    raise Exception.CreateFmt('UpdateLayeredWindow failed (%d)', [GetLastError]);
  if not IsWindowVisible(FWnd) then
    SetWindowPos(FWnd, 0, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_SHOWWINDOW);
end;

procedure TFxEngine.Tick(Sender: TObject);
var
  T: QWord;
  Dt: Single;
  W, H: Integer;
  Origin: TPoint;
  T0: QWord;
begin
  try
    T := GetTickCount64;
    Dt := Min((T - FLastTick) / 1000, 0.05);
    FLastTick := T;
    if not ClientSize(W, H) then
    begin
      // minimized or closing: nothing to draw over, and these would be stale later
      FCount := 0;
      FTimer.Enabled := False;
      if FWnd <> 0 then
        ShowWindow(FWnd, SW_HIDE);
      FDirty := Classes.Rect(0, 0, 0, 0);
      Exit;
    end;
    T0 := GetTickCount64;
    Update(Dt);
    EnsureSurface(W, H);
    Render(W, H);
    Origin := Classes.Point(0, 0);
    Windows.ClientToScreen(FOwner, Origin);
    Present(Origin, W, H);
    Inc(FFrames);
    FFrameMs := FFrameMs * 0.95 + (GetTickCount64 - T0) * 0.05;
    if FCount = 0 then
    begin
      FTimer.Enabled := False;
      ShowWindow(FWnd, SW_HIDE);
    end;
  except
    on E: Exception do
      Fail('frame', E);
  end;
end;

procedure TFxEngine.SaveSnapshot(const AFileName: string);
begin
  if FBmp = nil then
    raise Exception.Create('nothing has played yet');
  FBmp.SaveToFile(AFileName);
end;

function TFxEngine.Stats: string;
begin
  Result := Format('%d playing, peak %d, %d frames, about %.1f ms per frame', [FCount, FPeak, FFrames, FFrameMs]);
end;

function TFxEngine.WindowHandle: HWND;
begin
  Result := FWnd;
end;

end.
