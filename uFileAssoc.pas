unit uFileAssoc;

{ Per-user file associations ("Set default open") for .zip / .rar.

  Everything is written under HKEY_CURRENT_USER, so no administrator rights
  are needed:
    Software\Classes\BGRAZip<.ext>            ProgID (icon + open command)
    Software\Classes\<.ext>\OpenWithProgids   adds BGRA Zip to "Open with"
    Software\Classes\<.ext> (default)         class default (previous value backed up)
    Software\BGRAZip\Capabilities             app capabilities for Default Apps
    Software\RegisteredApplications           makes BGRA Zip appear in Settings

  Since Windows 8 the final choice lives in a hash-protected UserChoice key
  that apps may not write. If Windows already has a UserChoice for the
  extension, the user has to confirm BGRA Zip in Settings > Default apps;
  OpenDefaultAppsSettings jumps straight to the app's page there. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

const
  AssocAppName = 'BGRA Zip';

function AssocProgId(const AExt: string): string;
function RegisterFileType(const AExt, ADescription: string): Boolean;
function UnregisterFileType(const AExt: string): Boolean;
{ Full path of the program Windows currently opens AExt with ('' if none). }
function CurrentDefaultExe(const AExt: string): string;
function IsDefaultFor(const AExt: string): Boolean;
function IsRegisteredFor(const AExt: string): Boolean;
{ ProgID stored in the protected UserChoice key, '' if there is none. }
function UserChoiceProgId(const AExt: string): string;
procedure NotifyAssocChanged;
procedure OpenDefaultAppsSettings;

implementation

{$IFDEF WINDOWS}
uses
  Windows, Registry, uDevLog;

const
  AppKey = 'Software\BGRAZip';
  ASSOCF_NONE = 0;
  ASSOCSTR_EXECUTABLE = 2;
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST = 0;

function AssocQueryStringW(flags: DWORD; str: DWORD; pszAssoc, pszExtra: PWideChar;
  pszOut: PWideChar; var pcchOut: DWORD): HRESULT; stdcall; external 'shlwapi.dll';
procedure SHChangeNotify(wEventId: LONG; uFlags: UINT; dwItem1, dwItem2: Pointer); stdcall;
  external 'shell32.dll';
function ShellExecuteW(hwnd: HWND; lpOperation, lpFile, lpParameters, lpDirectory: PWideChar;
  nShowCmd: Integer): HINST; stdcall; external 'shell32.dll';

function ExePath: string;
begin
  Result := ExpandFileName(ParamStr(0));
end;

function AssocProgId(const AExt: string): string;
begin
  // '.zip' -> 'BGRAZip.zip'
  Result := 'BGRAZip' + LowerCase(AExt);
end;

function NewReg: TRegistry;
begin
  Result := TRegistry.Create(KEY_READ or KEY_WRITE);
  Result.RootKey := HKEY_CURRENT_USER;
end;

function RegisterFileType(const AExt, ADescription: string): Boolean;
var
  R: TRegistry;
  ProgId, Prev, Cmd: string;
begin
  Result := False;
  ProgId := AssocProgId(AExt);
  Cmd := '"' + ExePath + '" "%1"';
  R := NewReg;
  try
    // ProgID: what "open" does and which icon to show
    if not R.OpenKey('Software\Classes\' + ProgId, True) then
      Exit;
    R.WriteString('', ADescription);
    R.WriteString('FriendlyTypeName', ADescription);
    R.CloseKey;
    if R.OpenKey('Software\Classes\' + ProgId + '\DefaultIcon', True) then
    begin
      R.WriteString('', '"' + ExePath + '",0');
      R.CloseKey;
    end;
    if not R.OpenKey('Software\Classes\' + ProgId + '\shell\open\command', True) then
      Exit;
    R.WriteString('', Cmd);
    R.CloseKey;

    // the extension: Open-with list + class default (remember the old one)
    if R.OpenKey('Software\Classes\' + AExt, True) then
    begin
      Prev := '';
      if R.ValueExists('') then
        Prev := R.ReadString('');
      R.WriteString('', ProgId);
      R.CloseKey;
      if (Prev <> '') and (Prev <> ProgId) and R.OpenKey(AppKey + '\Backup', True) then
      begin
        if not R.ValueExists(AExt) then
          R.WriteString(AExt, Prev);
        R.CloseKey;
      end;
    end;
    if R.OpenKey('Software\Classes\' + AExt + '\OpenWithProgids', True) then
    begin
      R.WriteString(ProgId, '');
      R.CloseKey;
    end;

    // Default Apps / Open-with registration
    if R.OpenKey('Software\Classes\Applications\' + ExtractFileName(ExePath), True) then
    begin
      R.WriteString('FriendlyAppName', AssocAppName);
      R.CloseKey;
    end;
    if R.OpenKey('Software\Classes\Applications\' + ExtractFileName(ExePath) + '\SupportedTypes', True) then
    begin
      R.WriteString(AExt, '');
      R.CloseKey;
    end;
    if R.OpenKey(AppKey + '\Capabilities', True) then
    begin
      R.WriteString('ApplicationName', AssocAppName);
      R.WriteString('ApplicationDescription', 'ZIP / RAR archiver built with Lazarus + BGRABitmap');
      R.CloseKey;
    end;
    if R.OpenKey(AppKey + '\Capabilities\FileAssociations', True) then
    begin
      R.WriteString(AExt, ProgId);
      R.CloseKey;
    end;
    if R.OpenKey('Software\RegisteredApplications', True) then
    begin
      R.WriteString(AssocAppName, AppKey + '\Capabilities');
      R.CloseKey;
    end;
    Result := True;
    DevLogFmt(llInfo, 'Registered %s for %s (command %s)', [ProgId, AExt, Cmd]);
  finally
    R.Free;
  end;
  NotifyAssocChanged;
end;

function UnregisterFileType(const AExt: string): Boolean;
var
  R: TRegistry;
  ProgId, Prev: string;
  Names: TStringList;
begin
  Result := False;
  ProgId := AssocProgId(AExt);
  R := NewReg;
  Names := TStringList.Create;
  try
    Prev := '';
    if R.OpenKey(AppKey + '\Backup', False) then
    begin
      if R.ValueExists(AExt) then
      begin
        Prev := R.ReadString(AExt);
        R.DeleteValue(AExt);
      end;
      R.CloseKey;
    end;
    if R.OpenKey('Software\Classes\' + AExt, False) then
    begin
      if R.ValueExists('') and SameText(R.ReadString(''), ProgId) then
      begin
        if Prev <> '' then
          R.WriteString('', Prev)
        else
          R.DeleteValue('');
      end;
      R.CloseKey;
    end;
    if R.OpenKey('Software\Classes\' + AExt + '\OpenWithProgids', False) then
    begin
      R.DeleteValue(ProgId);
      R.CloseKey;
    end;
    R.DeleteKey('Software\Classes\' + ProgId + '\shell\open\command');
    R.DeleteKey('Software\Classes\' + ProgId + '\shell\open');
    R.DeleteKey('Software\Classes\' + ProgId + '\shell');
    R.DeleteKey('Software\Classes\' + ProgId + '\DefaultIcon');
    R.DeleteKey('Software\Classes\' + ProgId);
    if R.OpenKey('Software\Classes\Applications\' + ExtractFileName(ExePath) + '\SupportedTypes', False) then
    begin
      R.DeleteValue(AExt);
      R.CloseKey;
    end;
    if R.OpenKey(AppKey + '\Capabilities\FileAssociations', False) then
    begin
      R.DeleteValue(AExt);
      R.GetValueNames(Names);
      R.CloseKey;
      // last association gone: drop the app registration as well
      if Names.Count = 0 then
      begin
        R.DeleteKey(AppKey + '\Capabilities\FileAssociations');
        R.DeleteKey(AppKey + '\Capabilities');
        if R.OpenKey('Software\RegisteredApplications', False) then
        begin
          R.DeleteValue(AssocAppName);
          R.CloseKey;
        end;
      end;
    end;
    Result := True;
    DevLogFmt(llInfo, 'Removed %s association for %s (restored class default "%s")', [ProgId, AExt, Prev]);
  finally
    Names.Free;
    R.Free;
  end;
  NotifyAssocChanged;
end;

function CurrentDefaultExe(const AExt: string): string;
var
  Buf: array[0..MAX_PATH * 2] of WideChar;
  Len: DWORD;
  W: UnicodeString;
begin
  Result := '';
  W := UnicodeString(AExt);
  Len := Length(Buf);
  if AssocQueryStringW(ASSOCF_NONE, ASSOCSTR_EXECUTABLE, PWideChar(W), 'open', @Buf[0], Len) = S_OK then
    Result := UTF8Encode(UnicodeString(PWideChar(@Buf[0])));
end;

function IsDefaultFor(const AExt: string): Boolean;
begin
  Result := SameText(ExpandFileName(CurrentDefaultExe(AExt)), ExePath);
end;

function IsRegisteredFor(const AExt: string): Boolean;
var
  R: TRegistry;
begin
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    Result := R.KeyExists('Software\Classes\' + AssocProgId(AExt) + '\shell\open\command');
  finally
    R.Free;
  end;
end;

function UserChoiceProgId(const AExt: string): string;
var
  R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ);
  try
    R.RootKey := HKEY_CURRENT_USER;
    if R.OpenKeyReadOnly('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + AExt + '\UserChoice') then
    begin
      if R.ValueExists('ProgId') then
        Result := R.ReadString('ProgId');
      R.CloseKey;
    end;
  finally
    R.Free;
  end;
end;

procedure NotifyAssocChanged;
begin
  SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nil, nil);
end;

procedure OpenDefaultAppsSettings;
var
  W: UnicodeString;
begin
  // Windows 11 opens the app's own page; older builds fall back to the general page
  W := 'ms-settings:defaultapps?registeredAppUser=' + UnicodeString(StringReplace(AssocAppName, ' ', '%20', [rfReplaceAll]));
  if PtrUInt(ShellExecuteW(0, 'open', PWideChar(W), nil, nil, SW_SHOWNORMAL)) <= 32 then
    ShellExecuteW(0, 'open', 'ms-settings:defaultapps', nil, nil, SW_SHOWNORMAL);
end;

{$ELSE}

function AssocProgId(const AExt: string): string;
begin
  Result := 'BGRAZip' + LowerCase(AExt);
end;

function RegisterFileType(const AExt, ADescription: string): Boolean;
begin
  Result := False;
end;

function UnregisterFileType(const AExt: string): Boolean;
begin
  Result := False;
end;

function CurrentDefaultExe(const AExt: string): string;
begin
  Result := '';
end;

function IsDefaultFor(const AExt: string): Boolean;
begin
  Result := False;
end;

function IsRegisteredFor(const AExt: string): Boolean;
begin
  Result := False;
end;

function UserChoiceProgId(const AExt: string): string;
begin
  Result := '';
end;

procedure NotifyAssocChanged;
begin
end;

procedure OpenDefaultAppsSettings;
begin
end;
{$ENDIF}

end.
