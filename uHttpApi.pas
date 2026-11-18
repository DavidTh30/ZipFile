unit uHttpApi;

{ Local HTTP REST API for BGRA Zip (no LCL dependency).

  The routes in ApiRoutes are a thin layer over the IPC commands: each request
  becomes one JSON command for TfrmMain.HandleIPC, run on the main thread.

  Safety: off by default, listens on 127.0.0.1 only, needs a bearer token,
  rejects foreign Host headers (DNS rebinding) and foreign Origin headers
  (web pages), and sends no CORS headers. One connection at a time; the GUI
  serialises the commands anyway. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  API_DEFAULT_PORT = 8771;
  API_PREFIX = '/api/v1';

type
  TApiRequestEvent = function(const ARequest: string): string of object;

  TApiRoute = record
    Method, Path, Cmd, Required, Summary: string;
  end;

const
  ApiRoutes: array[0..17] of TApiRoute = (
    (Method: 'GET';  Path: '/status';    Cmd: 'status'; Required: '';            Summary: 'Current mode and archive totals'),
    (Method: 'GET';  Path: '/entries';   Cmd: 'list';   Required: '';            Summary: 'Entries of the open archive. Query: limit'),
    (Method: 'GET';  Path: '/log';       Cmd: 'log';    Required: '';            Summary: 'Developer log lines. Query: lines'),
    (Method: 'POST'; Path: '/open';      Cmd: 'open';   Required: 'path';        Summary: 'Open an archive. Body: path, activate'),
    (Method: 'POST'; Path: '/add';       Cmd: 'add';    Required: 'files';       Summary: 'Add files to a new archive list. Body: files[], activate'),
    (Method: 'POST'; Path: '/new';       Cmd: 'new';    Required: '';            Summary: 'Start a new empty archive list'),
    (Method: 'POST'; Path: '/extract';   Cmd: 'extract'; Required: 'destination'; Summary: 'Extract the open archive. Body: destination, entries[]'),
    (Method: 'POST'; Path: '/test';      Cmd: 'test';   Required: '';            Summary: 'Verify the open archive'),
    (Method: 'POST'; Path: '/show';      Cmd: 'show';   Required: '';            Summary: 'Bring the window to the front'),
    (Method: 'POST'; Path: '/developer'; Cmd: 'dev';    Required: '';            Summary: 'Show the Developer window. Body: tab'),
    (Method: 'POST'; Path: '/quit';      Cmd: 'quit';   Required: '';            Summary: 'Close BGRA Zip'),
    (Method: 'POST'; Path: '/effect';    Cmd: 'effect'; Required: '';            Summary: 'Play an effect. Body: event or style, x, y, force'),
    (Method: 'GET';  Path: '/effect/status'; Cmd: 'effect_status'; Required: ''; Summary: 'Effect settings and what is playing'),
    // the script routes answer 403 until "Allow scripts" is on: a script can do anything this user can
    (Method: 'POST'; Path: '/script/run';    Cmd: 'script_run';    Required: ''; Summary: 'Start a script. Body: source or file, args[]'),
    (Method: 'GET';  Path: '/script/status'; Cmd: 'script_status'; Required: ''; Summary: 'State and output of the script. Query: from'),
    (Method: 'POST'; Path: '/script/stop';   Cmd: 'script_stop';   Required: ''; Summary: 'Stop the running script'),
    (Method: 'POST'; Path: '/script/check';  Cmd: 'script_check';  Required: 'source'; Summary: 'Compile without running. Body: source'),
    (Method: 'GET';  Path: '/script/functions'; Cmd: 'script_functions'; Required: ''; Summary: 'Functions scripts can call')
  );

type
  TApiServer = class;

  { Settings ([API] in bgrazip.ini) and the running server. Main thread only. }
  TApiController = class
  private
    FIniFile: string;
    FOnRequest: TApiRequestEvent;
    FServer: TApiServer;
    FPort: Integer;
    FToken: string;
    FEnabled: Boolean;
    FAllowScripts: Boolean;
    FLastError: string;
  public
    constructor Create(const AIniFile: string; AOnRequest: TApiRequestEvent);
    destructor Destroy; override;
    procedure Load;
    procedure Save;
    { Starts for this run only; does not change the saved Enabled setting. }
    function Start: Boolean;
    procedure Stop;
    function Active: Boolean;
    { Starts or stops and remembers the choice for the next run. }
    function SetEnabled(AValue: Boolean): Boolean;
    function SetPort(AValue: Integer): Boolean;
    procedure NewToken;
    procedure SetAllowScripts(AValue: Boolean);
    function BaseUrl: string;
    property AllowScripts: Boolean read FAllowScripts;
    property Port: Integer read FPort;
    property Token: string read FToken;
    property Enabled: Boolean read FEnabled;
    property LastError: string read FLastError;
  end;

  { TApiServer }

  TApiServer = class(TThread)
  private
    FSock, FClient: PtrUInt;
    FPort: Integer;
    FToken: string;
    FAllowScripts: Boolean;
    FOnRequest: TApiRequestEvent;
    FRequest, FResponse: string;
    procedure DoRequest;
    procedure HandleClient(AClient: PtrUInt);
    function HostAllowed(const AHost: string): Boolean;
    function OriginAllowed(const AOrigin: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: PtrUInt; APort: Integer; const AToken: string; AAllowScripts: Boolean;
      AOnRequest: TApiRequestEvent);
    procedure Shutdown;
  end;

function ApiOpenApiJson(APort: Integer): string;

var
  ApiCtl: TApiController = nil;

implementation

uses
  WinSock2, IniFiles, fpjson, jsonparser, uDevLog, uIPC;

const
  MAX_HEADERS = 16 * 1024;
  MAX_BODY = 1024 * 1024;
  MAX_DRAIN = 8 * 1024 * 1024;
  CLIENT_TIMEOUT_MS = 10000;
  DRAIN_TIMEOUT_MS = 1000;
  EXCLUSIVE_ADDR_USE = not LongInt(4);  // SO_EXCLUSIVEADDRUSE = ~SO_REUSEADDR
  BAD_SOCKET = PtrUInt(INVALID_SOCKET);

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: Pointer; cbBuffer: LongWord; dwFlags: LongWord): LongInt;
  stdcall; external 'bcrypt.dll';

function RandomToken: string;
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2;
var
  B: array[0..23] of Byte;
  I: Integer;
begin
  if BCryptGenRandom(nil, @B[0], SizeOf(B), BCRYPT_USE_SYSTEM_PREFERRED_RNG) <> 0 then
    raise Exception.Create('Cannot get random bytes for the API token');
  Result := '';
  for I := 0 to High(B) do
    Result := Result + LowerCase(IntToHex(B[I], 2));
end;

{ Compares without stopping at the first difference. }
function TokenEquals(const A, B: string): Boolean;
var
  I: Integer;
  Diff: Byte;
begin
  if (A = '') or (Length(A) <> Length(B)) then
    Exit(False);
  Diff := 0;
  for I := 1 to Length(A) do
    Diff := Diff or (Byte(A[I]) xor Byte(B[I]));
  Result := Diff = 0;
end;

function JsonError(const AMsg: string): string;
begin
  Result := '{"ok":false,"error":"' + StringToJSONString(AMsg) + '"}';
end;

function StatusText(ACode: Integer): string;
begin
  case ACode of
    200: Result := 'OK';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    409: Result := 'Conflict';
    411: Result := 'Length Required';
    413: Result := 'Payload Too Large';
    431: Result := 'Request Header Fields Too Large';
    500: Result := 'Internal Server Error';
  else
    Result := 'Error';
  end;
end;

{ HTTP status for a HandleIPC reply. }
function StatusForReply(const AReply: string): Integer;
var
  D: TJSONData;
  Err: string;
begin
  Result := 500;
  D := nil;
  try
    try
      D := GetJSON(AReply);
    except
      Exit;
    end;
    if not (D is TJSONObject) then
      Exit;
    if TJSONObject(D).Get('ok', False) then
      Exit(200);
    Err := LowerCase(TJSONObject(D).Get('error', ''));
    if (Pos('busy', Err) = 1) or (Pos('no archive open', Err) = 1) then
      Result := 409
    else if Pos('file not found', Err) = 1 then
      Result := 404
    else if Pos('extraction failed', Err) = 1 then
      Result := 500
    else
      Result := 400;
  finally
    D.Free;
  end;
end;

function ApiOpenApiJson(APort: Integer): string;
var
  Root, Paths, Item, Op, Sec, Comps, Schemes, Bearer, Resp, RespOk: TJSONObject;
  Servers: TJSONArray;
  I: Integer;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('openapi', '3.0.3');
    Root.Add('info', TJSONObject.Create(['title', 'BGRA Zip local API', 'version', '1.0.0']));
    Servers := TJSONArray.Create;
    Servers.Add(TJSONObject.Create(['url', Format('http://127.0.0.1:%d%s', [APort, API_PREFIX])]));
    Root.Add('servers', Servers);
    Paths := TJSONObject.Create;
    for I := Low(ApiRoutes) to High(ApiRoutes) do
    begin
      Op := TJSONObject.Create;
      Op.Add('summary', ApiRoutes[I].Summary);
      RespOk := TJSONObject.Create(['description', 'JSON with "ok": true']);
      Resp := TJSONObject.Create;
      Resp.Add('200', RespOk);
      Resp.Add('default', TJSONObject.Create(['description', 'JSON with "ok": false and "error"']));
      Op.Add('responses', Resp);
      Item := TJSONObject.Create;
      Item.Add(LowerCase(ApiRoutes[I].Method), Op);
      Paths.Add(ApiRoutes[I].Path, Item);
    end;
    Root.Add('paths', Paths);
    Bearer := TJSONObject.Create(['type', 'http', 'scheme', 'bearer']);
    Schemes := TJSONObject.Create;
    Schemes.Add('bearer', Bearer);
    Comps := TJSONObject.Create;
    Comps.Add('securitySchemes', Schemes);
    Root.Add('components', Comps);
    Sec := TJSONObject.Create;
    Sec.Add('bearer', TJSONArray.Create);
    Root.Add('security', TJSONArray.Create([Sec]));
    Result := Root.AsJSON;
  finally
    Root.Free;
  end;
end;

{ ---------- TApiServer ---------- }

constructor TApiServer.Create(ASock: PtrUInt; APort: Integer; const AToken: string; AAllowScripts: Boolean;
  AOnRequest: TApiRequestEvent);
begin
  FSock := ASock;
  FClient := BAD_SOCKET;
  FPort := APort;
  FToken := AToken;
  FAllowScripts := AAllowScripts;
  FOnRequest := AOnRequest;
  inherited Create(False);
  FreeOnTerminate := False;
end;

procedure TApiServer.Shutdown;
var
  C: PtrUInt;
begin
  Terminate;
  closesocket(TSocket(FSock));    // unblocks accept
  C := FClient;
  if C <> BAD_SOCKET then
    WinSock2.shutdown(TSocket(C), SD_BOTH);   // unblocks recv
  WaitFor;
end;

procedure TApiServer.DoRequest;
begin
  try
    FResponse := FOnRequest(FRequest);
  except
    on E: Exception do
      FResponse := JsonError(E.ClassName + ': ' + E.Message);
  end;
end;

procedure TApiServer.Execute;
var
  C: TSocket;
  Timeout, Got, Drained: LongInt;
  Sink: array[0..4095] of Char;
begin
  while not Terminated do
  begin
    C := accept(TSocket(FSock), nil, nil);
    if C = INVALID_SOCKET then
    begin
      if not Terminated then
        Sleep(50);
      Continue;
    end;
    FClient := PtrUInt(C);
    try
      Timeout := CLIENT_TIMEOUT_MS;
      setsockopt(C, SOL_SOCKET, SO_RCVTIMEO, PChar(@Timeout), SizeOf(Timeout));
      setsockopt(C, SOL_SOCKET, SO_SNDTIMEO, PChar(@Timeout), SizeOf(Timeout));
      if not Terminated then
        HandleClient(PtrUInt(C));
    except
      on E: Exception do
        DevLog(llWarn, 'API: ' + E.Message);
    end;
    // closing with unread data resets the connection and the client loses the
    // reply (413, 401 before the body arrived...), so finish sending and drain
    WinSock2.shutdown(C, SD_SEND);
    Timeout := DRAIN_TIMEOUT_MS;
    setsockopt(C, SOL_SOCKET, SO_RCVTIMEO, PChar(@Timeout), SizeOf(Timeout));
    Drained := 0;
    repeat
      Got := recv(C, Sink, SizeOf(Sink), 0);
      if Got > 0 then
        Inc(Drained, Got);
    until (Got <= 0) or (Drained > MAX_DRAIN) or Terminated;
    FClient := BAD_SOCKET;
    closesocket(C);
  end;
end;

function TApiServer.HostAllowed(const AHost: string): Boolean;
var
  H, P: string;
begin
  H := LowerCase(AHost);
  P := ':' + IntToStr(FPort);
  Result := (H = '127.0.0.1' + P) or (H = 'localhost' + P);
end;

function TApiServer.OriginAllowed(const AOrigin: string): Boolean;
begin
  Result := (AOrigin = '') or HostAllowed(StringReplace(LowerCase(AOrigin), 'http://', '', []));
end;

procedure TApiServer.HandleClient(AClient: PtrUInt);
var
  Data, Body, Line, Method, Target, Path, Query, Extra, Reply: string;
  Lines, Headers: TStringList;
  Buf: array[0..4095] of Char;
  Got, P, I, Code, BodyLen, ReqLen: Integer;

  function ReadMore: Boolean;
  begin
    Got := recv(TSocket(AClient), Buf, SizeOf(Buf), 0);
    Result := Got > 0;
    if Result then
    begin
      SetLength(Data, Length(Data) + Got);
      Move(Buf[0], Data[Length(Data) - Got + 1], Got);
    end;
  end;

  procedure Answer(ACode: Integer; const AJson: string);
  var
    S: string;
    Done, N: Integer;
  begin
    Code := ACode;
    S := Format('HTTP/1.1 %d %s'#13#10, [ACode, StatusText(ACode)]) +
      'Content-Type: application/json; charset=utf-8'#13#10 +
      'Content-Length: ' + IntToStr(Length(AJson)) + #13#10 +
      'Cache-Control: no-store'#13#10 +
      'X-Content-Type-Options: nosniff'#13#10 +
      Extra +
      'Connection: close'#13#10#13#10;
    if Method <> 'HEAD' then
      S := S + AJson;
    Done := 0;
    while Done < Length(S) do
    begin
      N := send(TSocket(AClient), S[Done + 1], Length(S) - Done, 0);
      if N <= 0 then
        Break;
      Inc(Done, N);
    end;
  end;

  { Turns the route, query and body into the command for HandleIPC. False = answered. }
  function BuildCommand(const ARoute: TApiRoute; out ACommand: string): Boolean;
  var
    D: TJSONData;
    O: TJSONObject;
    Pairs: TStringList;
    J, V: Integer;
    N: string;
  begin
    Result := False;
    D := nil;
    if Trim(Body) <> '' then
    begin
      try
        D := ParseJSON(Body);
      except
        on E: Exception do
        begin
          Answer(400, JsonError('invalid JSON body: ' + E.Message));
          Exit;
        end;
      end;
      if not (D is TJSONObject) then
      begin
        D.Free;
        Answer(400, JsonError('body must be a JSON object'));
        Exit;
      end;
      O := TJSONObject(D);
    end
    else
      O := TJSONObject.Create;
    try
      Pairs := TStringList.Create;
      try
        Pairs.Delimiter := '&';
        Pairs.StrictDelimiter := True;
        Pairs.DelimitedText := Query;
        for J := 0 to Pairs.Count - 1 do
        begin
          N := LowerCase(Pairs.Names[J]);
          if (N = 'limit') or (N = 'lines') or (N = 'from') then
          begin
            if not TryStrToInt(Pairs.ValueFromIndex[J], V) or (V < 0) then
            begin
              Answer(400, JsonError(N + ' must be a non-negative integer'));
              Exit;
            end;
            O.Delete(N);
            O.Add(N, V);
          end;
        end;
      finally
        Pairs.Free;
      end;
      if (ARoute.Required <> '') and (O.IndexOfName(ARoute.Required) < 0) then
      begin
        Answer(400, JsonError('"' + ARoute.Required + '" is required'));
        Exit;
      end;
      // API calls leave the window where it is unless they ask otherwise
      if ((ARoute.Cmd = 'open') or (ARoute.Cmd = 'add')) and (O.IndexOfName('activate') < 0) then
        O.Add('activate', False);
      O.Delete('cmd');
      O.Add('cmd', ARoute.Cmd);
      ACommand := O.AsJSON;
      Result := True;
    finally
      O.Free;
    end;
  end;

var
  Auth, Rel, Command: string;
  PathKnown: Boolean;
begin
  Data := '';
  Method := '';
  Extra := '';
  Code := 0;
  repeat
    P := Pos(#13#10#13#10, Data);
    if P > 0 then
      Break;
    if Length(Data) > MAX_HEADERS then
    begin
      Answer(431, JsonError('headers too large'));
      Exit;
    end;
    if not ReadMore then
      Exit;
  until False;

  Lines := TStringList.Create;
  Headers := TStringList.Create;
  try
    Lines.Text := Copy(Data, 1, P - 1);
    Body := Copy(Data, P + 4, MaxInt);
    if Lines.Count = 0 then
    begin
      Answer(400, JsonError('empty request'));
      Exit;
    end;
    Line := Lines[0];
    I := Pos(' ', Line);
    Method := Copy(Line, 1, I - 1);
    Target := Copy(Line, I + 1, MaxInt);
    I := Pos(' ', Target);
    if (Method = '') or (I = 0) then
    begin
      Answer(400, JsonError('bad request line'));
      Exit;
    end;
    Target := Copy(Target, 1, I - 1);
    Headers.NameValueSeparator := ':';
    for I := 1 to Lines.Count - 1 do
      if Pos(':', Lines[I]) > 0 then
        Headers.Add(LowerCase(Trim(Copy(Lines[I], 1, Pos(':', Lines[I]) - 1))) + ':' +
          Trim(Copy(Lines[I], Pos(':', Lines[I]) + 1, MaxInt)));

    if not HostAllowed(Headers.Values['host']) or not OriginAllowed(Headers.Values['origin']) then
    begin
      Answer(403, JsonError('forbidden host or origin'));
      Exit;
    end;
    if Headers.Values['transfer-encoding'] <> '' then
    begin
      Answer(411, JsonError('send Content-Length, chunked bodies are not supported'));
      Exit;
    end;

    // the rest of the body
    BodyLen := 0;
    if (Headers.Values['content-length'] <> '') and
      not TryStrToInt(Headers.Values['content-length'], BodyLen) then
      BodyLen := -1;
    if BodyLen < 0 then
    begin
      Answer(400, JsonError('bad Content-Length'));
      Exit;
    end;
    if BodyLen > MAX_BODY then
    begin
      Answer(413, JsonError('body too large'));
      Exit;
    end;
    while Length(Body) < BodyLen do
    begin
      ReqLen := Length(Data);
      if not ReadMore then
        Exit;
      Body := Body + Copy(Data, ReqLen + 1, MaxInt);
    end;
    SetLength(Body, BodyLen);

    P := Pos('?', Target);
    if P > 0 then
    begin
      Path := Copy(Target, 1, P - 1);
      Query := Copy(Target, P + 1, MaxInt);
    end
    else
    begin
      Path := Target;
      Query := '';
    end;
    if (Length(Path) > 1) and (Path[Length(Path)] = '/') then
      SetLength(Path, Length(Path) - 1);

    // open routes: nothing here touches the archive or the file system
    if (Method = 'GET') and (Path = API_PREFIX + '/health') then
    begin
      Answer(200, '{"ok":true,"app":"BGRA Zip","api":"v1"}');
      Exit;
    end;
    if (Method = 'GET') and (Path = API_PREFIX + '/openapi.json') then
    begin
      Answer(200, ApiOpenApiJson(FPort));
      Exit;
    end;

    Auth := Headers.Values['authorization'];
    if (LowerCase(Copy(Auth, 1, 7)) <> 'bearer ') or not TokenEquals(Trim(Copy(Auth, 8, MaxInt)), FToken) then
    begin
      Extra := 'WWW-Authenticate: Bearer'#13#10;
      Answer(401, JsonError('missing or wrong bearer token'));
      Exit;
    end;

    if Copy(Path, 1, Length(API_PREFIX) + 1) <> API_PREFIX + '/' then
    begin
      Answer(404, JsonError('unknown path: ' + Path));
      Exit;
    end;
    Rel := Copy(Path, Length(API_PREFIX) + 1, MaxInt);
    PathKnown := False;
    for I := Low(ApiRoutes) to High(ApiRoutes) do
      if ApiRoutes[I].Path = Rel then
      begin
        PathKnown := True;
        if ApiRoutes[I].Method <> Method then
        begin
          Extra := 'Allow: ' + ApiRoutes[I].Method + #13#10;
          Answer(405, JsonError('use ' + ApiRoutes[I].Method));
          Exit;
        end;
        if (Copy(ApiRoutes[I].Cmd, 1, 6) = 'script') and not FAllowScripts then
        begin
          Answer(403, JsonError('scripts over the API are off: turn on "Allow scripts" in Developer > HTTP API'));
          Exit;
        end;
        if not BuildCommand(ApiRoutes[I], Command) then
          Exit;
        FRequest := Command;
        FResponse := '';
        Synchronize(@DoRequest);
        Reply := FResponse;
        Answer(StatusForReply(Reply), Reply);
        DevLogFmt(llDebug, 'API %s %s -> %d', [Method, Path, Code]);
        Exit;
      end;
    if not PathKnown then
      Answer(404, JsonError('unknown path: ' + Path));
  finally
    Lines.Free;
    Headers.Free;
  end;
end;

{ ---------- TApiController ---------- }

var
  WsaDone: Boolean = False;

constructor TApiController.Create(const AIniFile: string; AOnRequest: TApiRequestEvent);
begin
  FIniFile := AIniFile;
  FOnRequest := AOnRequest;
  FPort := API_DEFAULT_PORT;
end;

destructor TApiController.Destroy;
begin
  Stop;
  inherited Destroy;
end;

procedure TApiController.Load;
var
  Ini: TIniFile;
begin
  Ini := TIniFile.Create(FIniFile);
  try
    FEnabled := Ini.ReadBool('API', 'Enabled', False);
    FPort := Ini.ReadInteger('API', 'Port', API_DEFAULT_PORT);
    if (FPort < 1024) or (FPort > 65535) then
      FPort := API_DEFAULT_PORT;
    FToken := Ini.ReadString('API', 'Token', '');
    FAllowScripts := Ini.ReadBool('API', 'AllowScripts', False);
  finally
    Ini.Free;
  end;
  if FToken = '' then
  begin
    FToken := RandomToken;
    Save;
  end;
end;

procedure TApiController.Save;
var
  Ini: TIniFile;
begin
  ForceDirectories(ExtractFileDir(FIniFile));
  Ini := TIniFile.Create(FIniFile);
  try
    Ini.WriteBool('API', 'Enabled', FEnabled);
    Ini.WriteInteger('API', 'Port', FPort);
    Ini.WriteString('API', 'Token', FToken);
    Ini.WriteBool('API', 'AllowScripts', FAllowScripts);
  finally
    Ini.Free;
  end;
end;

function TApiController.Active: Boolean;
begin
  Result := FServer <> nil;
end;

function TApiController.BaseUrl: string;
begin
  Result := Format('http://127.0.0.1:%d%s', [FPort, API_PREFIX]);
end;

function TApiController.Start: Boolean;
var
  S: TSocket;
  Addr: TSockAddrIn;
  Opt: LongInt;
  W: TWSAData;
begin
  Result := Active;
  if Result then
    Exit;
  FLastError := '';
  if not WsaDone then
  begin
    if WSAStartup($0202, W) <> 0 then
    begin
      FLastError := 'WSAStartup failed';
      Exit;
    end;
    WsaDone := True;
  end;
  S := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if S = INVALID_SOCKET then
  begin
    FLastError := Format('socket() failed (%d)', [WSAGetLastError]);
    Exit;
  end;
  // no other program may share or take over the port while we hold it
  Opt := 1;
  setsockopt(S, SOL_SOCKET, EXCLUSIVE_ADDR_USE, PChar(@Opt), SizeOf(Opt));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(FPort);
  Addr.sin_addr.S_addr := htonl($7F000001);  // 127.0.0.1 only
  if (bind(S, PSockAddr(@Addr), SizeOf(Addr)) <> 0) or (listen(S, 8) <> 0) then
  begin
    FLastError := Format('Cannot listen on 127.0.0.1:%d (error %d) - is the port in use?',
      [FPort, WSAGetLastError]);
    closesocket(S);
    DevLog(llWarn, 'API: ' + FLastError);
    Exit;
  end;
  FServer := TApiServer.Create(PtrUInt(S), FPort, FToken, FAllowScripts, FOnRequest);
  DevLogFmt(llInfo, 'HTTP API listening on %s', [BaseUrl]);
  Result := True;
end;

procedure TApiController.Stop;
begin
  if FServer = nil then
    Exit;
  FServer.Shutdown;
  FreeAndNil(FServer);
  DevLog(llInfo, 'HTTP API stopped');
end;

function TApiController.SetEnabled(AValue: Boolean): Boolean;
begin
  if AValue then
    Result := Start
  else
  begin
    Stop;
    Result := True;
  end;
  if Result then
  begin
    FEnabled := AValue;
    Save;
  end;
end;

function TApiController.SetPort(AValue: Integer): Boolean;
var
  WasActive: Boolean;
begin
  Result := (AValue >= 1024) and (AValue <= 65535);
  if not Result then
  begin
    FLastError := 'The port must be between 1024 and 65535';
    Exit;
  end;
  if AValue = FPort then
    Exit;
  WasActive := Active;
  Stop;
  FPort := AValue;
  Save;
  if WasActive then
    Result := Start;
end;

procedure TApiController.SetAllowScripts(AValue: Boolean);
var
  WasActive: Boolean;
begin
  WasActive := Active;
  Stop;
  FAllowScripts := AValue;
  Save;
  if WasActive then
    Start;
end;

procedure TApiController.NewToken;
var
  WasActive: Boolean;
begin
  WasActive := Active;
  Stop;
  FToken := RandomToken;
  Save;
  if WasActive then
    Start;
end;

end.
