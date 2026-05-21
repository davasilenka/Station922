#include once "CgiProcess.bi"
#include once "crt.bi"
#include once "Logger.bi"

Constructor CgiProcess()
    hProcess = INVALID_HANDLE_VALUE
    hStdinWrite = INVALID_HANDLE_VALUE
    hStdoutRead = INVALID_HANDLE_VALUE
    hStderrRead = INVALID_HANDLE_VALUE
    dwProcessId = 0
    dwExitCode = 0
End Constructor

Destructor CgiProcess()
    If hProcess <> INVALID_HANDLE_VALUE Then
        TerminateProcess(hProcess, 1)
    End If
    CloseHandles()
End Destructor

Function CgiProcess.StartProcess( _
    ByVal pszExe As LPCWSTR, _
    ByVal pszArgs As LPWSTR, _
    ByVal pszEnv As LPVOID, _
    ByVal pszWorkDir As LPCWSTR _
) As HRESULT

    Dim sa As SECURITY_ATTRIBUTES
    sa.nLength = SizeOf(SECURITY_ATTRIBUTES)
    sa.lpSecurityDescriptor = NULL
    sa.bInheritHandle = TRUE

    Dim hReadStdin As HANDLE
    Dim hWriteStdout As HANDLE
    Dim hWriteStderr As HANDLE

    Dim hWriteStdinLocal As HANDLE
    Dim hReadStdoutLocal As HANDLE
    Dim hReadStderrLocal As HANDLE

    If CreatePipe(@hReadStdin, @hWriteStdinLocal, @sa, 0) = 0 Then
        Dim errCode As DWORD = GetLastError()
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stdin failed, error %u", errCode)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        Return E_FAIL
    End If

    If CreatePipe(@hReadStdoutLocal, @hWriteStdout, @sa, 0) = 0 Then
        Dim errCode As DWORD = GetLastError()
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stdout failed, error %u", errCode)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        Return E_FAIL
    End If

    If CreatePipe(@hReadStderrLocal, @hWriteStderr, @sa, 0) = 0 Then
        Dim errCode As DWORD = GetLastError()
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stderr failed, error %u", errCode)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        CloseHandle(hReadStdoutLocal)
        CloseHandle(hWriteStdout)
        Return E_FAIL
    End If

    SetHandleInformation(hWriteStdinLocal, HANDLE_FLAG_INHERIT, 0)
    SetHandleInformation(hReadStdoutLocal, HANDLE_FLAG_INHERIT, 0)
    SetHandleInformation(hReadStderrLocal, HANDLE_FLAG_INHERIT, 0)

    Dim si As STARTUPINFOW
    ZeroMemory(@si, SizeOf(STARTUPINFOW))
    si.cb = SizeOf(STARTUPINFOW)
    si.dwFlags = STARTF_USESTDHANDLES
    si.hStdInput = hReadStdin
    si.hStdOutput = hWriteStdout
    si.hStdError = hWriteStderr

    Dim pi As PROCESS_INFORMATION

    If CreateProcessW(pszExe, pszArgs, NULL, NULL, TRUE, _
        CREATE_NO_WINDOW Or CREATE_UNICODE_ENVIRONMENT, _
        pszEnv, pszWorkDir, @si, @pi) = 0 Then

        Dim errCode As DWORD = GetLastError()
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreateProcessW failed, error %u", errCode)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)

        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        CloseHandle(hReadStdoutLocal)
        CloseHandle(hWriteStdout)
        CloseHandle(hReadStderrLocal)
        CloseHandle(hWriteStderr)
        Return E_FAIL
    End If

    CloseHandle(hReadStdin)
    CloseHandle(hWriteStdout)
    CloseHandle(hWriteStderr)

    hProcess = pi.hProcess
    hStdinWrite = hWriteStdinLocal
    hStdoutRead = hReadStdoutLocal
    hStderrRead = hReadStderrLocal
    dwProcessId = pi.dwProcessId
    dwExitCode = STILL_ACTIVE
    CloseHandle(pi.hThread)

    Return S_OK
End Function

Function CgiProcess.IsRunning() As Boolean
    Dim dwCode As DWORD
    If hProcess = INVALID_HANDLE_VALUE Then Return FALSE
    If GetExitCodeProcess(hProcess, @dwCode) = 0 Then Return FALSE
    Return (dwCode = STILL_ACTIVE)
End Function

Function CgiProcess.WaitForExit(ByVal dwMilliseconds As DWORD) As Boolean
    If hProcess = INVALID_HANDLE_VALUE Then Return TRUE
    Dim dwWait As DWORD = WaitForSingleObject(hProcess, dwMilliseconds)
    If dwWait = WAIT_OBJECT_0 Then
        GetExitCodeProcess(hProcess, @dwExitCode)
        Return TRUE
    ElseIf dwWait = WAIT_TIMEOUT Then
        Return FALSE
    Else
        Return FALSE
    End If
End Function

Sub CgiProcess.Terminate()
    If hProcess <> INVALID_HANDLE_VALUE Then
        TerminateProcess(hProcess, 1)
    End If
End Sub

Function CgiProcess.GetExitCode() As DWORD
    Dim dwCode As DWORD
    If hProcess <> INVALID_HANDLE_VALUE Then
        If GetExitCodeProcess(hProcess, @dwCode) Then
            dwExitCode = dwCode
        End If
    End If
    Return dwExitCode
End Function

Sub CgiProcess.CloseHandles()
    If hProcess <> INVALID_HANDLE_VALUE Then
        CloseHandle(hProcess)
        hProcess = INVALID_HANDLE_VALUE
    End If
    If hStdinWrite <> INVALID_HANDLE_VALUE Then
        CloseHandle(hStdinWrite)
        hStdinWrite = INVALID_HANDLE_VALUE
    End If
    If hStdoutRead <> INVALID_HANDLE_VALUE Then
        CloseHandle(hStdoutRead)
        hStdoutRead = INVALID_HANDLE_VALUE
    End If
    If hStderrRead <> INVALID_HANDLE_VALUE Then
        CloseHandle(hStderrRead)
        hStderrRead = INVALID_HANDLE_VALUE
    End If
End Sub
