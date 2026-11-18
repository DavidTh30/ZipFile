unit uDragOut;

{ OLE drag source for dragging archive items out to Explorer / the desktop.

  The data object offers CF_HDROP (a list of file paths). The files do not
  exist yet when the drag starts: the first time the drop target asks for the
  data (normally when the user releases the mouse) the OnRender callback
  extracts the items to a temporary folder and returns their paths. Explorer
  then copies them to the folder they were dropped on. Rendering is cached,
  so it happens at most once per drag. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { Extract the dragged items and fill APaths with the top-level paths to drop.
    Return False to fail the drop (error or cancel). }
  TRenderFilesEvent = function(APaths: TStrings): Boolean of object;

  TDragOutResult = (droCancelled, droDropped, droFailed);

function OleReady: Boolean;
{ Runs the modal OLE drag loop. Returns when the user drops or cancels. }
function StartFileDragOut(ARender: TRenderFilesEvent; out ARendered: Boolean): TDragOutResult;

implementation

{$IFDEF WINDOWS}
uses
  Windows, ActiveX, uDevLog;

const
  DRAGDROP_S_DROP = HRESULT($00040100);
  DRAGDROP_S_CANCEL = HRESULT($00040101);
  DRAGDROP_S_USEDEFAULTCURSORS = HRESULT($00040102);
  DV_E_FORMATETC = HRESULT($80040064);
  OLE_E_ADVISENOTSUPPORTED = HRESULT($80040003);
  CF_HDROP_ = 15;
  DATA_S_SAMEFORMATETC_ = HRESULT($00040130);

type
  TDropFilesHeader = packed record
    pFiles: DWORD;
    pt: TPoint;
    fNC: BOOL;
    fWide: BOOL;
  end;

  { TFileDataObject }

  TFileDataObject = class(TInterfacedObject, IDataObject)
  private
    FRender: TRenderFilesEvent;
    FPaths: TStringList;
    FRendered: Boolean;
    FRenderOK: Boolean;
    function MakeHDrop: HGLOBAL;
  public
    constructor Create(ARender: TRenderFilesEvent);
    destructor Destroy; override;
    function GetData(const formatetcIn: FORMATETC; out medium: STGMEDIUM): HRESULT; stdcall;
    function GetDataHere(const pformatetc: FORMATETC; out medium: STGMEDIUM): HRESULT; stdcall;
    function QueryGetData(const pformatetc: FORMATETC): HRESULT; stdcall;
    function GetCanonicalFormatEtc(const pformatetcIn: FORMATETC; out pformatetcOut: FORMATETC): HRESULT; stdcall;
    function SetData(const pformatetc: FORMATETC; var medium: STGMEDIUM; FRelease: BOOL): HRESULT; stdcall;
    function EnumFormatEtc(dwDirection: DWORD; out enumformatetcpara: IENUMFORMATETC): HRESULT; stdcall;
    function DAdvise(const formatetc: FORMATETC; advf: DWORD; const AdvSink: IAdviseSink;
      out dwConnection: DWORD): HRESULT; stdcall;
    function DUnadvise(dwconnection: DWORD): HRESULT; stdcall;
    function EnumDAdvise(out enumAdvise: IEnumStatData): HRESULT; stdcall;
    property Rendered: Boolean read FRendered;
  end;

  { TFileDropSource }

  TFileDropSource = class(TInterfacedObject, IDropSource)
  public
    function QueryContinueDrag(fEscapePressed: BOOL; grfKeyState: DWORD): HRESULT; stdcall;
    function GiveFeedback(dwEffect: DWORD): HRESULT; stdcall;
  end;

function SHCreateStdEnumFmtEtc(cfmt: UINT; afmt: PFormatEtc; out ppenumFormatEtc: IEnumFORMATETC): HRESULT;
  stdcall; external 'shell32.dll';

var
  GOleState: Integer = 0;   // 0 = not tried, 1 = ready, -1 = failed

function OleReady: Boolean;
var
  R: HRESULT;
begin
  if GOleState = 0 then
  begin
    R := OleInitialize(nil);
    if Succeeded(R) then
      GOleState := 1
    else
      GOleState := -1;
    DevLogFmt(llDebug, 'OleInitialize: 0x%.8x', [R]);
  end;
  Result := GOleState = 1;
end;

function HDropFormat: FORMATETC;
begin
  Result.CfFormat := CF_HDROP_;
  Result.Ptd := nil;
  Result.dwAspect := DVASPECT_CONTENT;
  Result.lindex := -1;
  Result.tymed := TYMED_HGLOBAL;
end;

{ TFileDataObject }

constructor TFileDataObject.Create(ARender: TRenderFilesEvent);
begin
  inherited Create;
  FRender := ARender;
  FPaths := TStringList.Create;
end;

destructor TFileDataObject.Destroy;
begin
  FPaths.Free;
  inherited Destroy;
end;

function TFileDataObject.MakeHDrop: HGLOBAL;
var
  W: UnicodeString;
  I: Integer;
  Size: PtrUInt;
  P: PByte;
  Hdr: TDropFilesHeader;
begin
  // DROPFILES header followed by a double-NUL terminated list of UTF-16 paths
  W := '';
  for I := 0 to FPaths.Count - 1 do
    W := W + UTF8Decode(FPaths[I]) + #0;
  W := W + #0;
  Size := SizeOf(Hdr) + Length(W) * SizeOf(WideChar);
  Result := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, Size);
  if Result = 0 then
    Exit;
  P := GlobalLock(Result);
  try
    FillChar(Hdr, SizeOf(Hdr), 0);
    Hdr.pFiles := SizeOf(Hdr);
    Hdr.fWide := True;
    Move(Hdr, P^, SizeOf(Hdr));
    Move(W[1], (P + SizeOf(Hdr))^, Length(W) * SizeOf(WideChar));
  finally
    GlobalUnlock(Result);
  end;
end;

function TFileDataObject.GetData(const formatetcIn: FORMATETC; out medium: STGMEDIUM): HRESULT; stdcall;
begin
  FillChar(medium, SizeOf(medium), 0);
  if (formatetcIn.CfFormat <> CF_HDROP_) or ((formatetcIn.tymed and TYMED_HGLOBAL) = 0) then
    Exit(DV_E_FORMATETC);
  if not FRendered then
  begin
    FRendered := True;
    DevLog(llInfo, 'Drop target requested the files - extracting now');
    try
      FRenderOK := FRender(FPaths) and (FPaths.Count > 0);
    except
      on E: Exception do
      begin
        DevLogFmt(llError, 'Drag-out extraction failed: %s', [E.Message]);
        FRenderOK := False;
      end;
    end;
  end;
  if not FRenderOK then
    Exit(E_FAIL);
  medium.Tymed := TYMED_HGLOBAL;
  medium.HGLOBAL := MakeHDrop;
  medium.PUnkForRelease := nil;
  if medium.HGLOBAL = 0 then
    Exit(E_OUTOFMEMORY);
  Result := S_OK;
end;

function TFileDataObject.GetDataHere(const pformatetc: FORMATETC; out medium: STGMEDIUM): HRESULT; stdcall;
begin
  Result := E_NOTIMPL;
end;

function TFileDataObject.QueryGetData(const pformatetc: FORMATETC): HRESULT; stdcall;
begin
  if (pformatetc.CfFormat = CF_HDROP_) and ((pformatetc.tymed and TYMED_HGLOBAL) <> 0) then
    Result := S_OK
  else
    Result := DV_E_FORMATETC;
end;

function TFileDataObject.GetCanonicalFormatEtc(const pformatetcIn: FORMATETC;
  out pformatetcOut: FORMATETC): HRESULT; stdcall;
begin
  pformatetcOut := pformatetcIn;
  pformatetcOut.Ptd := nil;
  Result := DATA_S_SAMEFORMATETC_;
end;

function TFileDataObject.SetData(const pformatetc: FORMATETC; var medium: STGMEDIUM;
  FRelease: BOOL): HRESULT; stdcall;
begin
  // Explorer offers extra shell formats (drag image info etc.); not needed
  Result := E_NOTIMPL;
end;

function TFileDataObject.EnumFormatEtc(dwDirection: DWORD; out enumformatetcpara: IENUMFORMATETC): HRESULT; stdcall;
var
  F: FORMATETC;
begin
  if dwDirection <> DATADIR_GET then
  begin
    enumformatetcpara := nil;
    Exit(E_NOTIMPL);
  end;
  F := HDropFormat;
  Result := SHCreateStdEnumFmtEtc(1, @F, enumformatetcpara);
end;

function TFileDataObject.DAdvise(const formatetc: FORMATETC; advf: DWORD; const AdvSink: IAdviseSink;
  out dwConnection: DWORD): HRESULT; stdcall;
begin
  dwConnection := 0;
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TFileDataObject.DUnadvise(dwconnection: DWORD): HRESULT; stdcall;
begin
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

function TFileDataObject.EnumDAdvise(out enumAdvise: IEnumStatData): HRESULT; stdcall;
begin
  enumAdvise := nil;
  Result := OLE_E_ADVISENOTSUPPORTED;
end;

{ TFileDropSource }

function TFileDropSource.QueryContinueDrag(fEscapePressed: BOOL; grfKeyState: DWORD): HRESULT; stdcall;
begin
  if fEscapePressed then
    Result := DRAGDROP_S_CANCEL
  else if (grfKeyState and MK_LBUTTON) = 0 then
    Result := DRAGDROP_S_DROP
  else
    Result := S_OK;
end;

function TFileDropSource.GiveFeedback(dwEffect: DWORD): HRESULT; stdcall;
begin
  Result := DRAGDROP_S_USEDEFAULTCURSORS;
end;

function StartFileDragOut(ARender: TRenderFilesEvent; out ARendered: Boolean): TDragOutResult;
var
  DataObj: TFileDataObject;
  DataIntf: IDataObject;
  SourceIntf: IDropSource;
  Effect: DWORD;
  R: HRESULT;
begin
  ARendered := False;
  Result := droFailed;
  if not OleReady then
    Exit;
  DataObj := TFileDataObject.Create(ARender);
  DataIntf := DataObj;
  SourceIntf := TFileDropSource.Create;
  Effect := DROPEFFECT_NONE;
  // copy only: the temporary files must stay put until Explorer has read them
  R := DoDragDrop(DataIntf, SourceIntf, DROPEFFECT_COPY, @Effect);
  ARendered := DataObj.Rendered;
  DevLogFmt(llDebug, 'DoDragDrop result 0x%.8x, effect %d, rendered %s',
    [R, Effect, BoolToStr(ARendered, True)]);
  if (R = DRAGDROP_S_DROP) and (Effect <> DROPEFFECT_NONE) then
    Result := droDropped
  else if R = DRAGDROP_S_CANCEL then
    Result := droCancelled
  else if R = DRAGDROP_S_DROP then
    Result := droCancelled     // dropped somewhere that refused the files
  else
    Result := droFailed;
end;

initialization

finalization
  if GOleState = 1 then
    OleUninitialize;

{$ELSE}

function OleReady: Boolean;
begin
  Result := False;
end;

function StartFileDragOut(ARender: TRenderFilesEvent; out ARendered: Boolean): TDragOutResult;
begin
  ARendered := False;
  Result := droFailed;
end;
{$ENDIF}

end.
