program makeicon;

{ Renders the BGRA Zip logo with BGRABitmap at every standard icon size and
  writes a multi-resolution .ico (32-bit BMP frames with alpha).
  Usage: makeicon <output.ico> [preview.png] }

{$mode objfpc}{$H+}

uses
  Interfaces, Classes, SysUtils, Math, BGRABitmap, BGRABitmapTypes, BGRAGradientScanner, uBGRAUI;

const
  Sizes: array[0..8] of Integer = (16, 20, 24, 32, 40, 48, 64, 128, 256);

function RenderLogo(S: Integer): TBGRABitmap;
var
  G: TBGRAGradientScanner;
  R, M: Single;
begin
  Result := TBGRABitmap.Create(S, S, BGRAPixelTransparent);
  if S <= 20 then
  begin
    // tiny sizes: just the archive box, maximum contrast
    DrawToolIcon(Result, tiZip, 0, 0, S);
    Exit;
  end;
  // rounded tile with the header's blue -> teal gradient, archive box on top
  M := S * 0.03;
  R := S * 0.2;
  G := TBGRAGradientScanner.Create(BGRA(18, 40, 90), BGRA(16, 150, 170), gtLinear,
    PointF(0, 0), PointF(S, S));
  try
    Result.FillRoundRectAntialias(M, M, S - M, S - M, R, R, G);
  finally
    G.Free;
  end;
  Result.FillEllipseAntialias(S * 0.8, S * 0.15, S * 0.32, S * 0.32, BGRA(255, 255, 255, 22));
  Result.RoundRectAntialias(M + 0.5, M + 0.5, S - M - 0.5, S - M - 0.5, R, R, BGRA(255, 255, 255, 60),
    Max(1, S / 64));
  DrawToolIcon(Result, tiZip, S * 0.14, S * 0.12, S * 0.76);
end;

{ Classic ICO frame: BITMAPINFOHEADER (height doubled for the AND mask),
  32-bit straight-alpha BGRA rows bottom-up, then an all-zero AND mask.
  The LCL's resource icon loader cannot read PNG-compressed frames. }
procedure WriteDibFrame(ABmp: TBGRABitmap; AStream: TStream);
var
  S, Y, MaskRow: Integer;
  D: LongWord;
  W: Word;
  Zero: array of Byte;
begin
  S := ABmp.Width;
  MaskRow := ((S + 31) div 32) * 4;
  D := 40; AStream.WriteBuffer(D, 4);            // biSize
  D := S; AStream.WriteBuffer(D, 4);             // biWidth
  D := S * 2; AStream.WriteBuffer(D, 4);         // biHeight (XOR + AND)
  W := 1; AStream.WriteBuffer(W, 2);             // biPlanes
  W := 32; AStream.WriteBuffer(W, 2);            // biBitCount
  D := 0; AStream.WriteBuffer(D, 4);             // biCompression = BI_RGB
  D := S * S * 4 + MaskRow * S; AStream.WriteBuffer(D, 4);
  D := 0;
  AStream.WriteBuffer(D, 4); AStream.WriteBuffer(D, 4);
  AStream.WriteBuffer(D, 4); AStream.WriteBuffer(D, 4);
  for Y := S - 1 downto 0 do                      // bottom-up
    AStream.WriteBuffer(ABmp.ScanLine[Y]^, S * 4);  // TBGRAPixel is B,G,R,A in memory on Windows
  SetLength(Zero, MaskRow);
  FillChar(Zero[0], MaskRow, 0);
  for Y := 0 to S - 1 do
    AStream.WriteBuffer(Zero[0], MaskRow);
end;

var
  Png: array of TMemoryStream;
  Bmp: TBGRABitmap;
  Ico: TFileStream;
  I: Integer;
  Ofs: LongWord;
  W: Word;
  D: LongWord;
  B: Byte;
begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: makeicon <output.ico> [preview.png]');
    Halt(1);
  end;
  SetLength(Png, Length(Sizes));
  for I := 0 to High(Sizes) do
  begin
    Bmp := RenderLogo(Sizes[I]);
    try
      Png[I] := TMemoryStream.Create;
      WriteDibFrame(Bmp, Png[I]);
      if (I = High(Sizes)) and (ParamCount >= 2) then
        Bmp.SaveToFile(ParamStr(2));
    finally
      Bmp.Free;
    end;
  end;

  Ico := TFileStream.Create(ParamStr(1), fmCreate);
  try
    // ICONDIR
    W := 0; Ico.WriteBuffer(W, 2);
    W := 1; Ico.WriteBuffer(W, 2);
    W := Length(Sizes); Ico.WriteBuffer(W, 2);
    // ICONDIRENTRY x n
    Ofs := 6 + 16 * Length(Sizes);
    for I := 0 to High(Sizes) do
    begin
      B := Sizes[I] mod 256; Ico.WriteBuffer(B, 1);   // 256 is stored as 0
      Ico.WriteBuffer(B, 1);
      B := 0; Ico.WriteBuffer(B, 1);                    // palette
      Ico.WriteBuffer(B, 1);                            // reserved
      W := 1; Ico.WriteBuffer(W, 2);                    // planes
      W := 32; Ico.WriteBuffer(W, 2);                   // bpp
      D := Png[I].Size; Ico.WriteBuffer(D, 4);
      Ico.WriteBuffer(Ofs, 4);
      Inc(Ofs, Png[I].Size);
    end;
    for I := 0 to High(Sizes) do
    begin
      Png[I].Position := 0;
      Ico.CopyFrom(Png[I], Png[I].Size);
      Png[I].Free;
    end;
  finally
    Ico.Free;
  end;
  WriteLn('wrote ', ParamStr(1), ' (', Length(Sizes), ' sizes)');
end.
