Read session_handoff6.md for full context, current state 30/32, git diff, build commands.

Goal: reach 32/32 tests.

## The 2 remaining failures

### 1. POST body empty (PRIMARY)
- BeginRead(NULL) + poll GetCompleted successfully reads 17 bytes from socket
- BUT WriteFile(proc->hStdinWrite, data, 17) does NOT deliver data to CGI process
- Even hardcoded "Hello, POST body!" fails

Hypotheses to test:
A. Body IS in HTTP reader buffer but EndOfHeaders is wrong. Use GetRequestedBytes, find \r\n\r\n manually, compare with EndOfHeaders from GetPreloadedBytes.
B. CgiProcess.StartProcess pipe is broken - check CgiProcess.bas, verify hStdinWrite is valid at write time.
C. BeginRead/poll hangs (no data on socket) - add 500ms timeout to poll loop.

The ThreadPool.bas:69-80 calls SetCompleted even with NULL callback, so BeginRead(NULL) is safe.

### 2. status.py?404 returns 200 (SIDE EFFECT)
Passes individually (404). Fails in full suite - likely because POST body test before it hangs a worker thread. Fixing POST body should fix this.

Diagnose first. Do not break 30 working tests. You can add methods to interfaces.
