' ============================================================
'  RunNotify.vbs - launch DingBootNotify.ps1 without a console
' ------------------------------------------------------------
'  The 0 in shell.Run means "hidden window"; there is no black
'  PowerShell window popping up at boot.
'  Keep this file saved as ANSI (or pure ASCII) on Windows.
' ============================================================
Option Explicit

Dim fso, shell, scriptDir, ps1Path, cmdLine

Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = fso.BuildPath(scriptDir, "DingBootNotify.ps1")

If Not fso.FileExists(ps1Path) Then
    WScript.Quit 1
End If

cmdLine = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1Path & """"

' 0 = hidden, False = do not wait for the script to finish
shell.Run cmdLine, 0, False
