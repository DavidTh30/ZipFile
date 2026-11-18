unit uDevLog;

{ Central developer log. Every unit writes here; the developer window
  subscribes to OnLine and shows the lines live. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TLogLevel = (llInfo, llDebug, llWarn, llError, llTiming);

  TLogLineEvent = procedure(const ALine: string) of object;

  TDevLog = class
  private
    FLines: TStringList;
    FOnLine: TLogLineEvent;
    FStart: QWord;
    FLock: TCriticalSection;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(ALevel: TLogLevel; const AMsg: string);
    procedure Clear;
    { A copy of the lines; script threads may be adding while Lines is read. }
    procedure CopyLines(ADest: TStrings);
    function ElapsedMs: QWord;
    property Lines: TStringList read FLines;
    property OnLine: TLogLineEvent read FOnLine write FOnLine;
  end;

procedure DevLog(ALevel: TLogLevel; const AMsg: string);
procedure DevLogFmt(ALevel: TLogLevel; const AFmt: string; const AArgs: array of const);
function Log: TDevLog;

const
  LogLevelNames: array[TLogLevel] of string = ('INFO ', 'DEBUG', 'WARN ', 'ERROR', 'TIME ');

implementation

var
  GLog: TDevLog = nil;

function Log: TDevLog;
begin
  if GLog = nil then
    GLog := TDevLog.Create;
  Result := GLog;
end;

procedure DevLog(ALevel: TLogLevel; const AMsg: string);
begin
  Log.Add(ALevel, AMsg);
end;

procedure DevLogFmt(ALevel: TLogLevel; const AFmt: string; const AArgs: array of const);
begin
  Log.Add(ALevel, Format(AFmt, AArgs));
end;

constructor TDevLog.Create;
begin
  FLines := TStringList.Create;
  FLock := TCriticalSection.Create;
  FStart := GetTickCount64;
end;

destructor TDevLog.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDevLog.Add(ALevel: TLogLevel; const AMsg: string);
var
  S: string;
begin
  S := Format('%s  +%8.3fs  [%s]  %s',
    [FormatDateTime('hh:nn:ss.zzz', Now), ElapsedMs / 1000, LogLevelNames[ALevel], AMsg]);
  FLock.Enter;
  try
    FLines.Add(S);
    if Assigned(FOnLine) then
      FOnLine(S);
  finally
    FLock.Leave;
  end;
end;

procedure TDevLog.Clear;
begin
  FLock.Enter;
  try
    FLines.Clear;
  finally
    FLock.Leave;
  end;
end;

procedure TDevLog.CopyLines(ADest: TStrings);
begin
  FLock.Enter;
  try
    ADest.Assign(FLines);
  finally
    FLock.Leave;
  end;
end;

function TDevLog.ElapsedMs: QWord;
begin
  Result := GetTickCount64 - FStart;
end;

finalization
  FreeAndNil(GLog);

end.
