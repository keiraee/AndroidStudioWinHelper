; AndroidStudioWinHelper Inno Setup Script
; 用 Inno Setup 7.x 编译生成安装包
; 下载 Inno Setup: https://jrsoftware.org/isdl.php

#define MyAppName "AndroidStudioWinHelper"
#define MyAppVersion "1.4.2"
#define MyAppPublisher "ASWH"
#define MyAppExeName "androidstudiowinhelper.exe"

[Setup]
AppId={{A8C5D3E2-1F4B-4A6C-9E7D-2B3C4D5E6F7A}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
OutputDir=.\installer
OutputBaseFilename=AndroidStudioWinHelper_{#MyAppVersion}_Setup
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
PrivilegesRequired=admin
WizardStyle=modern
DisableProgramGroupPage=yes

; 如需中文界面，从 https://jrsoftware.org/files/istrans/ 下载 ChineseSimplified.isl
; 放到 D:\Inno Setup 7\Languages\ 目录，然后取消下方注释:
; [Languages]
; Name: "chinesesimp"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; 复制整个 Release 目录
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; VC++ 运行时 DLL 直接拷贝到安装目录（兜底，确保即使 VC++ 未安装也能运行）
Source: "C:\Windows\System32\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Windows\System32\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "C:\Windows\System32\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
; VC++ 运行时安装包（安装后自动静默安装，注册系统级依赖）
Source: "installer\VC_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 静默安装 VC++ Redistributable（如未安装）
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装运行时组件..."; Flags: skipifnotsilent skipifdoesntexist waituntilterminated
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装运行时组件..."; Flags: skipifsilent skipifdoesntexist waituntilterminated
; 启动应用
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent

[Code]
// 检查 VC++ 2015-2022 Redistributable x64 是否已安装
function IsVCRedistInstalled(): Boolean;
var
  Installed: Cardinal;
begin
  Result := RegQueryDWordValue(HKEY_LOCAL_MACHINE,
    'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64',
    'Installed', Installed) and (Installed = 1);
end;
