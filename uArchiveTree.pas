unit uArchiveTree;

{ Virtual folder tree built from flat archive paths ("docs/sub/a.txt").
  Archives don't always store directory entries, so folders are derived
  from the paths; explicit directory entries are remembered in DirEntry. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type
  TVFolder = class;
  TVFolderList = specialize TFPGObjectList<TVFolder>;

  { TVFolder }

  TVFolder = class
  public
    Name: string;
    Path: string;              // 'docs/sub' ('' for the root)
    Parent: TVFolder;
    Folders: TVFolderList;     // owned
    Files: array of Integer;   // item indexes (archive entry or staged file)
    DirEntry: Integer;         // index of an explicit directory entry, or -1
    TotalSize: Int64;          // recursive totals, filled by TVTree.Finish
    TotalPacked: Int64;
    FileCountDeep: Integer;
    Latest: TDateTime;
    constructor Create(AParent: TVFolder; const AName: string);
    destructor Destroy; override;
    function FindFolder(const AName: string): TVFolder;
    function GetFolder(const AName: string): TVFolder;
    { Adds every file index (and explicit directory entry) below this folder. }
    procedure CollectItems(AList: TFPList);
    function Depth: Integer;
  end;

  TItemInfoEvent = procedure(AIndex: Integer; out ASize, APacked: Int64; out ATime: TDateTime) of object;

  { TVTree }

  TVTree = class
  private
    procedure SortFolder(F: TVFolder);
    procedure Totals(F: TVFolder);
  public
    Root: TVFolder;
    OnItemInfo: TItemInfoEvent;
    constructor Create;
    destructor Destroy; override;
    procedure Clear(const ARootName: string);
    procedure AddItem(const APath: string; AIndex: Integer; AIsDir: Boolean);
    procedure Finish;
    function FolderByPath(const APath: string): TVFolder;
  end;

function NormalizeArchivePath(const S: string): string;

implementation

function NormalizeArchivePath(const S: string): string;
begin
  Result := StringReplace(S, '\', '/', [rfReplaceAll]);
  while (Result <> '') and (Result[1] = '/') do
    Delete(Result, 1, 1);
  while (Result <> '') and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

{ TVFolder }

constructor TVFolder.Create(AParent: TVFolder; const AName: string);
begin
  Parent := AParent;
  Name := AName;
  DirEntry := -1;
  Folders := TVFolderList.Create(True);
  if AParent = nil then
    Path := ''
  else if AParent.Path = '' then
    Path := AName
  else
    Path := AParent.Path + '/' + AName;
end;

destructor TVFolder.Destroy;
begin
  Folders.Free;
  inherited Destroy;
end;

function TVFolder.FindFolder(const AName: string): TVFolder;
var
  F: TVFolder;
begin
  for F in Folders do
    if SameText(F.Name, AName) then
      Exit(F);
  Result := nil;
end;

function TVFolder.GetFolder(const AName: string): TVFolder;
begin
  Result := FindFolder(AName);
  if Result = nil then
  begin
    Result := TVFolder.Create(Self, AName);
    Folders.Add(Result);
  end;
end;

procedure TVFolder.CollectItems(AList: TFPList);
var
  I: Integer;
  F: TVFolder;
begin
  if DirEntry >= 0 then
    AList.Add(Pointer(PtrInt(DirEntry)));
  for I := 0 to High(Files) do
    AList.Add(Pointer(PtrInt(Files[I])));
  for F in Folders do
    F.CollectItems(AList);
end;

function TVFolder.Depth: Integer;
var
  F: TVFolder;
begin
  Result := 0;
  F := Parent;
  while F <> nil do
  begin
    Inc(Result);
    F := F.Parent;
  end;
end;

{ TVTree }

constructor TVTree.Create;
begin
  Root := TVFolder.Create(nil, '');
end;

destructor TVTree.Destroy;
begin
  Root.Free;
  inherited Destroy;
end;

procedure TVTree.Clear(const ARootName: string);
begin
  Root.Free;
  Root := TVFolder.Create(nil, ARootName);
end;

procedure TVTree.AddItem(const APath: string; AIndex: Integer; AIsDir: Boolean);
var
  P, Part: string;
  F: TVFolder;
  K: Integer;
begin
  P := NormalizeArchivePath(APath);
  if P = '' then
    Exit;
  F := Root;
  repeat
    K := Pos('/', P);
    if K = 0 then
      Break;
    Part := Copy(P, 1, K - 1);
    Delete(P, 1, K);
    if Part <> '' then
      F := F.GetFolder(Part);
  until False;
  if AIsDir then
  begin
    F := F.GetFolder(P);
    F.DirEntry := AIndex;
  end
  else
  begin
    SetLength(F.Files, Length(F.Files) + 1);
    F.Files[High(F.Files)] := AIndex;
  end;
end;

function CompareFolders(const A, B: TVFolder): Integer;
begin
  Result := CompareText(A.Name, B.Name);
end;

procedure TVTree.SortFolder(F: TVFolder);
var
  Sub: TVFolder;
begin
  F.Folders.Sort(@CompareFolders);
  for Sub in F.Folders do
    SortFolder(Sub);
end;

procedure TVTree.Totals(F: TVFolder);
var
  Sub: TVFolder;
  I: Integer;
  S, P: Int64;
  T: TDateTime;
begin
  F.TotalSize := 0;
  F.TotalPacked := 0;
  F.FileCountDeep := Length(F.Files);
  F.Latest := 0;
  if Assigned(OnItemInfo) then
    for I := 0 to High(F.Files) do
    begin
      OnItemInfo(F.Files[I], S, P, T);
      Inc(F.TotalSize, S);
      Inc(F.TotalPacked, P);
      if T > F.Latest then
        F.Latest := T;
    end;
  for Sub in F.Folders do
  begin
    Totals(Sub);
    Inc(F.TotalSize, Sub.TotalSize);
    Inc(F.TotalPacked, Sub.TotalPacked);
    Inc(F.FileCountDeep, Sub.FileCountDeep);
    if Sub.Latest > F.Latest then
      F.Latest := Sub.Latest;
  end;
end;

procedure TVTree.Finish;
begin
  SortFolder(Root);
  Totals(Root);
end;

function TVTree.FolderByPath(const APath: string): TVFolder;
var
  P, Part: string;
  K: Integer;
begin
  Result := Root;
  P := NormalizeArchivePath(APath);
  while (P <> '') and (Result <> nil) do
  begin
    K := Pos('/', P);
    if K = 0 then
    begin
      Part := P;
      P := '';
    end
    else
    begin
      Part := Copy(P, 1, K - 1);
      Delete(P, 1, K);
    end;
    Result := Result.FindFolder(Part);
  end;
end;

end.
