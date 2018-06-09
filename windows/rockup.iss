#define MyAppName "Rockup"
#define MyPkgName "rockup"
#define MyAppPublisher "Oleg A. Khlybov"
#define MyVersion "0.1.0"
#define MyBuild "1"

[Setup]
AppName="{#MyAppName}"
AppVersion="{#MyVersion}-{#MyBuild}"
AppPublisher="{#MyAppPublisher}"
DefaultDirName="{pf}\{#MyAppName}"
OutputBaseFilename="{#MyPkgName}-{#MyVersion}-{#MyBuild}"
DisableProgramGroupPage=yes
SolidCompression=yes
ChangesEnvironment=True
AppId={{E23C81E7-F7B1-4B4A-9896-465DAB75482B}
OutputDir=.
Compression=lzma2/max
LZMANumBlockThreads=4
MinVersion=0,5.01

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Dirs]
Name: "{app}"; Flags: setntfscompression

[Files]
Source: "dist\*"; DestDir: "{app}"; Flags: recursesubdirs;

[Code]
#include "path.iss"
procedure RegisterPaths;
begin
  RegisterPath('{app}\bin', SystemPath, Append);
end;