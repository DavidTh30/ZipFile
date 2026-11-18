# BGRA Zip scripts

Scripts are `.bzs` text files in PascalScript (Pascal syntax), UTF-8:

```pascal
begin
  Print('Hello');
end.
```

## Ways to run

| Where | How |
|---|---|
| Script editor | **Script > Script editor** (Ctrl+Shift+E): F9 run, Ctrl+F2 stop, Ctrl+F9 check syntax, F5 breakpoint (or click the margin), F7 step into, F8 step over |
| Console | `bin\bzscript.exe file.bzs arg1 arg2`, `--check file.bzs`, `--functions` |
| Start the window with a script | `BGRAZip.exe --script file.bzs` |
| IPC | `{"cmd":"script_run","file":"C:\\a.bzs","args":["x"]}`, also `script_status`, `script_stop`, `script_check`, `script_functions` |
| HTTP API | `POST /api/v1/script/run` and friends, after turning on **Allow scripts** in Developer > HTTP API |
| MCP | tools `run_script`, `check_script`, `script_functions` |

Exit codes from `bzscript`: `0` done or `Halt(0)`, `Halt(n)` gives `n`, `1` runtime error, `2` does not compile or bad usage.

## Functions

Run `bzscript --functions` for the full list, or see the panel on the right of the editor. In short:

- **Output:** `Print`, `PrintErr`, `Log`, `Progress`, `Input`, `Confirm`, `Message`
- **Script:** `Arg`, `ArgCount`, `Halt`, `Stopped`, `ScriptDir`, `AppDir`, `TempDir`, `GetEnv`, `Sleep`, `Tick`
- **Files:** `ReadFile`, `WriteFile`, `AppendFile`, `FindFiles`, `FindDirs`, `CopyFile`, `RenameFile`, `DeleteFile`, `DeleteDir`, `ForceDirs`, `FileSize`, `FileDate`...
- **Text and dates:** `Format`, `Replace`, `Split`, `StartsWith`, `RegexMatch`, `RegexFind`, `RegexReplace`, `FormatDateTime`, `Now`...
- **Data:** `MD5File`, `SHA1File`, `CRC32File`, `Base64Encode`, `JsonGet`, `JsonQuote`, `HexDump`
- **Archives:** `OpenArchive` (gives a `TArchive`), `ExtractArchive`, `TestArchive`, `CreateZip`, `CreateRar`, `IsArchive`, `RarTool`
- **Programs:** `RunCommand`
- **The window:** `GuiRunning`, `GuiOpen`, `GuiStatus`, `GuiTest`, `GuiExtract`, `GuiEffect`, `GuiCall` (any IPC command)...
- **From PascalScript:** `TStringList`, `TFileStream`, `TMemoryStream`, `try`/`except`, `IntToStr`, `Copy`, `Pos`...

`{$I other.bzs}` includes a file from the script's folder.

## Good to know

- A script can do anything your Windows account can, including deleting files and starting programs. Only run scripts you trust.
- `Stop` takes effect between statements. A long `CreateZip` or `RunCommand` call finishes first, except that `RunCommand` and `Sleep` notice it.
- Debug runs (the editor's F9) are slower in tight loops. Ctrl+Shift+F9 runs without the debugger.
- When nobody can answer (console without input, API, MCP, IPC), `Input` returns its default, `Confirm` returns False and `Message` prints.
- Lists returned by `FindFiles`, `FindDirs` and `Split`, and archives from `OpenArchive`, are yours to `Free`.
- `out` is a reserved word in PascalScript, so it can't be a variable name.
- Sizes above 2 GB work in `FileSize`, `A.Size(i)` and `IntToStr`, but keep them in `Int64` variables.

## Examples

See [examples](examples): `inspect_archive`, `backup_folder`, `batch_test`, `zip_each_subfolder`, `checksums`, `window_demo`.
