unit uIPC;

{ Inter-process communication for BGRA Zip (no LCL dependency, so the MCP
  server can use it too).

  Transport: a local named pipe \\.\pipe\BGRAZip-<user>. One request per
  connection: the client writes one line of JSON, the server answers with one
  line of JSON and disconnects. Remote (network) clients are rejected and the
  default pipe security only lets the same user write to it.

  Requests look like {"cmd":"open","path":"C:\\a.zip"}; responses always
  carry "ok": true/false and, on failure, "error". The GUI's command list is
  implemented in uMain (TfrmMain.HandleIPC). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson;

type
  { Called on the main thread with the raw request line; returns the JSON reply. }
  TIPCRequestEvent = function(const ARequest: string): string of object;

  { TIPCServer }

  TIPCServer = class(TThread)
  private
    FPipe: THandle;
    FOnRequest: TIPCRequestEvent;
    FRequest: string;
    FResponse: string;
    procedure DoRequest;
  protected
    procedure Execute; override;
  public
    { Fails (Active = False) when another instance already owns the pipe. }
    constructor Create(AOnRequest: TIPCRequestEvent);
    destructor Destroy; override;
    procedure Stop;
    function Active: Boolean;
  end;

var
  { Pipe name prefix. }
  IPCAppName: string = 'BGRAZip';

function IPCPipeName: string;
{ Sends one request line and waits for the reply line. }
function IPCRequest(const ARequest: string; out AResponse: string; ATimeoutMs: Cardinal = 30000): Boolean;
{ True when a BGRA Zip window answers a ping. APid receives its process id. }
function IPCServerRunning(out APid: Cardinal): Boolean;
{ Single instance: hands the command line to a running window. Returns True
  when it did (the caller should then exit). }
function ForwardToRunningInstance: Boolean;
function JSONQuote(const S: string): string;
{ GetJSON for text from outside: tolerates a UTF-8 BOM and works around FPC 3.2.2's
  scanner, which loses bytes on adjacent \uXXXX escapes ("กข"). }
function ParseJSON(const AText: string): TJSONData;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF} jsonparser;

function ParseJSON(const AText: string): TJSONData;

  function Hex4(const S: string; AIndex: Integer): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    if AIndex + 3 > Length(S) then
      Exit;
    for K := AIndex to AIndex + 3 do
      if not (S[K] in ['0'..'9', 'a'..'f', 'A'..'F']) then
        Exit;
    Result := StrToInt('$' + Copy(S, AIndex, 4));
  end;

var
  S, O: string;
  I, V, V2: Integer;
begin
  S := AText;
  if Copy(S, 1, 3) = #$EF#$BB#$BF then
    Delete(S, 1, 3);
  if Pos('\u', S) = 0 then
    Exit(GetJSON(S));
  // rewrite the escapes as plain UTF-8; ASCII ones may be quotes or controls, so they stay
  O := '';
  I := 1;
  while I <= Length(S) do
  begin
    if S[I] <> '\' then
    begin
      O := O + S[I];
      Inc(I);
      Continue;
    end;
    V := -1;
    if (I < Length(S)) and (S[I + 1] = 'u') then
      V := Hex4(S, I + 2);
    if V < $80 then
    begin
      // not a \u escape, or an ASCII one: keep as written
      if V >= 0 then
      begin
        O := O + Copy(S, I, 6);
        Inc(I, 6);
      end
      else
      begin
        O := O + Copy(S, I, 2);
        Inc(I, 2);
      end;
    end
    else if (V >= $D800) and (V <= $DFFF) then
    begin
      V2 := -1;
      if (V <= $DBFF) and (Copy(S, I + 6, 2) = '\u') then
        V2 := Hex4(S, I + 8);
      if (V2 >= $DC00) and (V2 <= $DFFF) then
      begin
        O := O + UTF8Encode(UnicodeString(WideChar(V)) + UnicodeString(WideChar(V2)));
        Inc(I, 12);
      end
      else
      begin
        O := O + Copy(S, I, 6);  // lone surrogate
        Inc(I, 6);
      end;
    end
    else
    begin
      O := O + UTF8Encode(UnicodeString(WideChar(V)));
      Inc(I, 6);
    end;
  end;
  Result := GetJSON(O);
end;

{$IFDEF WINDOWS}
const
  PIPE_REJECT_REMOTE_CLIENTS = $00000008;
  FILE_FLAG_FIRST_PIPE_INSTANCE = $00080000;
  BUF_SIZE = 65536;

function AllowSetForegroundWindow(dwProcessId: DWORD): BOOL; stdcall; external 'user32.dll';
function CancelSynchronousIo(hThread: THandle): BOOL; stdcall; external 'kernel32.dll';

function IPCPipeName: string;
var
  U: string;
  I: Integer;
begin
  U := SysUtils.GetEnvironmentVariable('USERNAME');
  for I := 1 to Length(U) do
    if not (U[I] in ['A'..'Z', 'a'..'z', '0'..'9', '_', '-', '.']) then
      U[I] := '_';
  Result := '\\.\pipe\' + IPCAppName + '-' + U;
end;

function JSONQuote(const S: string): string;
begin
  Result := '"' + StringToJSONString(S) + '"';
end;

function ReadLine(H: THandle; out ALine: string; AMax: Integer = 64 * 1024 * 1024): Boolean;
var
  Buf: array[0..4095] of Char;
  Got: DWORD;
  P: Integer;
begin
  ALine := '';
  Result := False;
  repeat
    if not ReadFile(H, Buf, SizeOf(Buf), Got, nil) or (Got = 0) then
      Break;
    SetLength(ALine, Length(ALine) + Integer(Got));
    Move(Buf, ALine[Length(ALine) - Integer(Got) + 1], Got);
    P := Pos(#10, ALine);
    if P > 0 then
    begin
      SetLength(ALine, P - 1);
      Exit(True);
    end;
  until Length(ALine) > AMax;
  Result := ALine <> '';
end;

function WriteAll(H: THandle; const S: string): Boolean;
var
  Done, W: DWORD;
begin
  Done := 0;
  while Done < DWORD(Length(S)) do
  begin
    if not WriteFile(H, S[Done + 1], DWORD(Length(S)) - Done, W, nil) then
      Exit(False);
    Inc(Done, W);
  end;
  Result := True;
end;

{ TIPCServer }

constructor TIPCServer.Create(AOnRequest: TIPCRequestEvent);
var
  W: UnicodeString;
begin
  FOnRequest := AOnRequest;
  W := UnicodeString(IPCPipeName);
  FPipe := CreateNamedPipeW(PWideChar(W),
    PIPE_ACCESS_DUPLEX or FILE_FLAG_FIRST_PIPE_INSTANCE,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or PIPE_REJECT_REMOTE_CLIENTS,
    1, BUF_SIZE, BUF_SIZE, 0, nil);
  inherited Create(FPipe = INVALID_HANDLE_VALUE);   // suspended if there is no pipe
  FreeOnTerminate := False;
end;

destructor TIPCServer.Destroy;
begin
  Stop;
  if FPipe <> INVALID_HANDLE_VALUE then
    CloseHandle(FPipe);
  inherited Destroy;
end;

function TIPCServer.Active: Boolean;
begin
  Result := FPipe <> INVALID_HANDLE_VALUE;
end;

procedure TIPCServer.Stop;
var
  W: UnicodeString;
  H: THandle;
begin
  if not Active or Finished or Suspended then
    Exit;
  Terminate;
  // unblock ConnectNamedPipe with a dummy connection
  W := UnicodeString(IPCPipeName);
  H := CreateFileW(PWideChar(W), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  if H <> INVALID_HANDLE_VALUE then
    CloseHandle(H);
  // a client that connected but never sent its line would otherwise block us forever
  CancelSynchronousIo(Handle);
  WaitFor;
end;

procedure TIPCServer.DoRequest;
begin
  try
    FResponse := FOnRequest(FRequest);
  except
    on E: Exception do
      FResponse := '{"ok":false,"error":' + JSONQuote(E.ClassName + ': ' + E.Message) + '}';
  end;
end;

procedure TIPCServer.Execute;
var
  Connected: Boolean;
begin
  while not Terminated do
  begin
    Connected := ConnectNamedPipe(FPipe, nil) or (GetLastError = ERROR_PIPE_CONNECTED);
    if Terminated then
      Break;
    if Connected and ReadLine(FPipe, FRequest) then
    begin
      FResponse := '';
      Synchronize(@DoRequest);
      WriteAll(FPipe, FResponse + #10);
      FlushFileBuffers(FPipe);
    end;
    DisconnectNamedPipe(FPipe);
  end;
end;

{ client }

function IPCRequest(const ARequest: string; out AResponse: string; ATimeoutMs: Cardinal): Boolean;
var
  W: UnicodeString;
  H: THandle;
begin
  Result := False;
  AResponse := '';
  W := UnicodeString(IPCPipeName);
  H := CreateFileW(PWideChar(W), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  if (H = INVALID_HANDLE_VALUE) and (GetLastError = ERROR_PIPE_BUSY) then
  begin
    // the server is answering someone else: wait for the pipe, then retry once
    if not WaitNamedPipeW(PWideChar(W), ATimeoutMs) then
      Exit;
    H := CreateFileW(PWideChar(W), GENERIC_READ or GENERIC_WRITE, 0, nil, OPEN_EXISTING, 0, 0);
  end;
  if H = INVALID_HANDLE_VALUE then
    Exit;
  try
    if not WriteAll(H, StringReplace(ARequest, #10, ' ', [rfReplaceAll]) + #10) then
      Exit;
    Result := ReadLine(H, AResponse);
  finally
    CloseHandle(H);
  end;
end;

function IPCServerRunning(out APid: Cardinal): Boolean;
var
  R: string;
  D: TJSONData;
begin
  APid := 0;
  Result := IPCRequest('{"cmd":"ping"}', R, 2000);
  if not Result then
    Exit;
  try
    D := GetJSON(R);
    try
      if D is TJSONObject then
        APid := TJSONObject(D).Get('pid', 0);
    finally
      D.Free;
    end;
  except
    Result := False;
  end;
end;

function ForwardToRunningInstance: Boolean;
var
  Pid: Cardinal;
  I: Integer;
  P, R, Ext: string;
  Files: TJSONArray;
  Req: TJSONObject;
  Sent: Boolean;
begin
  Result := False;
  for I := 1 to ParamCount do
    if (ParamStr(I) = '--new-instance') or (ParamStr(I) = '--script') or (Copy(ParamStr(I), 1, 5) = '--dev') then
      Exit;
  if not IPCServerRunning(Pid) then
    Exit;
  // the user just started us, so we may hand the foreground to the window
  if Pid <> 0 then
    AllowSetForegroundWindow(Pid);
  Sent := False;
  Files := TJSONArray.Create;
  try
    for I := 1 to ParamCount do
    begin
      P := ExpandFileName(ParamStr(I));
      if not (FileExists(P) or DirectoryExists(P)) then
        Continue;
      Ext := LowerCase(ExtractFileExt(P));
      if (not Sent) and FileExists(P) and ((Ext = '.zip') or (Ext = '.rar')) then
      begin
        Sent := IPCRequest('{"cmd":"open","path":' + JSONQuote(P) + '}', R);
      end
      else
        Files.Add(P);
    end;
    if Files.Count > 0 then
    begin
      Req := TJSONObject.Create(['cmd', 'add']);
      try
        Req.Add('files', Files.Clone);
        Sent := IPCRequest(Req.AsJSON, R) or Sent;
      finally
        Req.Free;
      end;
    end;
    if not Sent then
      Sent := IPCRequest('{"cmd":"show"}', R);
  finally
    Files.Free;
  end;
  Result := Sent;
end;

{$ELSE}

function IPCPipeName: string;
begin
  Result := '';
end;

function JSONQuote(const S: string): string;
begin
  Result := '"' + S + '"';
end;

constructor TIPCServer.Create(AOnRequest: TIPCRequestEvent);
begin
  inherited Create(True);
end;

destructor TIPCServer.Destroy;
begin
  inherited Destroy;
end;

function TIPCServer.Active: Boolean;
begin
  Result := False;
end;

procedure TIPCServer.Stop;
begin
end;

procedure TIPCServer.DoRequest;
begin
end;

procedure TIPCServer.Execute;
begin
end;

function IPCRequest(const ARequest: string; out AResponse: string; ATimeoutMs: Cardinal): Boolean;
begin
  AResponse := '';
  Result := False;
end;

function IPCServerRunning(out APid: Cardinal): Boolean;
begin
  APid := 0;
  Result := False;
end;

function ForwardToRunningInstance: Boolean;
begin
  Result := False;
end;
{$ENDIF}

end.
