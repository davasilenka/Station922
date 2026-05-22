#include once "CgiProcess.bi"
#include once "crt.bi"
#include once "Logger.bi"

' Serialize CreateProcessW + pipe handle creation across worker threads.
' Without this, concurrent CGI launches can leak inheritable pipe handles between
' processes, which keeps unrelated pipes from closing and corrupts stdout/stderr.
' Lazy initialization via InterlockedCompareExchange: 0=fresh, 1=initializing, 2=ready.
Dim Shared gCgiCreateProcessCs As CRITICAL_SECTION
Dim Shared gCgiCsState As Long = 0

Private Sub EnsureCgiCsInit()
    Do
        Dim oldState As Long = InterlockedCompareExchange(@gCgiCsState, 1, 0)
        If oldState = 0 Then
            InitializeCriticalSection(@gCgiCreateProcessCs)
            InterlockedExchange(@gCgiCsState, 2)
            Exit Do
        ElseIf oldState = 2 Then
            Exit Do
        Else
            Sleep(0)
        End If
    Loop
End Sub

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

    EnsureCgiCsInit()

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

    Dim pi As PROCESS_INFORMATION
    Dim startResult As HRESULT = S_OK
    Dim createProcessErr As DWORD = 0

    EnterCriticalSection(@gCgiCreateProcessCs)

    If CreatePipe(@hReadStdin, @hWriteStdinLocal, @sa, 0) = 0 Then
        createProcessErr = GetLastError()
        startResult = E_FAIL
        LeaveCriticalSection(@gCgiCreateProcessCs)
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stdin failed, error %u", createProcessErr)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        Return E_FAIL
    End If

    If CreatePipe(@hReadStdoutLocal, @hWriteStdout, @sa, 0) = 0 Then
        createProcessErr = GetLastError()
        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        LeaveCriticalSection(@gCgiCreateProcessCs)
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stdout failed, error %u", createProcessErr)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        Return E_FAIL
    End If

    If CreatePipe(@hReadStderrLocal, @hWriteStderr, @sa, 0) = 0 Then
        createProcessErr = GetLastError()
        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        CloseHandle(hReadStdoutLocal)
        CloseHandle(hWriteStdout)
        LeaveCriticalSection(@gCgiCreateProcessCs)
        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreatePipe for stderr failed, error %u", createProcessErr)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
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

    If CreateProcessW(pszExe, pszArgs, NULL, NULL, TRUE, _
        CREATE_NO_WINDOW Or CREATE_UNICODE_ENVIRONMENT, _
        pszEnv, pszWorkDir, @si, @pi) = 0 Then

        createProcessErr = GetLastError()
        CloseHandle(hReadStdin)
        CloseHandle(hWriteStdinLocal)
        CloseHandle(hReadStdoutLocal)
        CloseHandle(hWriteStdout)
        CloseHandle(hReadStderrLocal)
        CloseHandle(hWriteStderr)
        LeaveCriticalSection(@gCgiCreateProcessCs)

        Dim buffer As WString * 256
        wsprintfW(@buffer, !"CreateProcessW failed, error %u", createProcessErr)
        Dim v As VARIANT : v.vt = VT_EMPTY
        LogWriteEntry(LogEntryType.Error, @buffer, @v)
        Return E_FAIL
    End If

    ' Close the child-side handles in the parent before leaving the critical
    ' section: this ensures that any concurrent CreateProcessW running in
    ' another worker thread cannot inherit these handles. (Inheritance happens
    ' at the moment CreateProcessW snapshots the current process handle table.)
    CloseHandle(hReadStdin)
    CloseHandle(hWriteStdout)
    CloseHandle(hWriteStderr)

    LeaveCriticalSection(@gCgiCreateProcessCs)

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
        If WaitForSingleObject(hProcess, 0) <> WAIT_OBJECT_0 Then
            TerminateProcess(hProcess, 1)
        End If
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
