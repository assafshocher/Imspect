#define AppName "Imspect"
#define AppVersion "0.3.0"
#ifndef SourceDir
  #define SourceDir "dist\Imspect"
#endif
#ifndef OutputDir
  #define OutputDir "release"
#endif

[Setup]
AppId={{DFB3B96B-0DA4-4773-8C10-F29F15C06BBA}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} Windows Preview
AppPublisher=Assaf Shocher
AppPublisherURL=https://github.com/assafshocher/Imspect
AppSupportURL=https://github.com/assafshocher/Imspect/issues
AppUpdatesURL=https://github.com/assafshocher/Imspect/releases
DefaultDirName={localappdata}\Programs\Imspect
DefaultGroupName=Imspect
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Imspect-{#AppVersion}-Windows-x64-Setup
SetupIconFile=assets\imspect.ico
UninstallDisplayIcon={app}\Imspect.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ChangesAssociations=no
DisableWelcomePage=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Imspect"; Filename: "{app}\Imspect.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Imspect"; Filename: "{app}\Imspect.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\Imspect.exe"; Description: "Open Imspect"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
