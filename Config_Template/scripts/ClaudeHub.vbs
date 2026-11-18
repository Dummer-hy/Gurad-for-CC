' Claude protection launcher (no console window).
' Usage: wscript.exe ClaudeHub.vbs [-Tray] [-Legacy]
'   default : cg-hub.exe (Rust + Tauri UI) when present, otherwise SecurityHub.ps1
'   -Tray   : start in the tray only (used at logon)
'   -Legacy : force the old PowerShell console (fallback / troubleshooting)
Option Explicit
Dim sh, fso, dir, args, i, a, tray, legacy, hub
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
args = "" : tray = False : legacy = False
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If LCase(a) = "-legacy" Then
        legacy = True
    Else
        If LCase(a) = "-tray" Then tray = True
        args = args & " " & a
    End If
Next
hub = dir & "\cg-hub.exe"
If (Not legacy) And fso.FileExists(hub) Then
    If tray Then
        sh.Run """" & hub & """ --tray", 0, False
    Else
        sh.Run """" & hub & """", 1, False
    End If
Else
    sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & dir & "\SecurityHub.ps1""" & args, 0, False
End If
