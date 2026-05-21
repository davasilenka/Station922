#ifndef CGIPROCESS_BI
#define CGIPROCESS_BI

#include once "windows.bi"
#include once "win\ole2.bi"

Type CgiProcess
    hProcess As HANDLE
    hStdinWrite As HANDLE
    hStdoutRead As HANDLE
    hStderrRead As HANDLE
    dwProcessId As DWORD
    dwExitCode As DWORD
    Declare Constructor()
    Declare Destructor()
    Declare Function StartProcess( _
        ByVal pszExe As LPCWSTR, _
        ByVal pszArgs As LPWSTR, _
        ByVal pszEnv As LPVOID, _
        ByVal pszWorkDir As LPCWSTR _
    ) As HRESULT
    Declare Function IsRunning() As Boolean
    Declare Function WaitForExit( _
        ByVal dwMilliseconds As DWORD _
    ) As Boolean
    Declare Sub Terminate()
    Declare Function GetExitCode() As DWORD
    Declare Sub CloseHandles()
End Type

#endif
