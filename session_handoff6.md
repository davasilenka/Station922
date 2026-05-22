# Handoff #6 — Station922 CGI: 30/32

## Что сделано

**Content-Type: text/plain — ИСПРАВЛЕНО.** Три бага в `HttpCgiProcessor.bas`:
1. `pOutputBuf[dwHeaderEnd] = 0` затирал `\r` → убран
2. Граница `LineEnd < dwHeaderEnd` не включала `\r\n` → `ScanLimit = dwHeaderEnd + 1`
3. `GetContentTypeOfMimeType(pContentTypeHeader, @Mime)` — параметры перепутаны + `HeapSysFreeString` на weak-ссылке → заменено на `lstrcmpiW` + `IServerResponse_SetMimeType` в конце Prepare

**Убраны все TEMP DEBUG блоки.**

## Два FAIL

### 1. POST body empty
- `BeginRead(NULL)` + poll `GetCompleted` — **читает 17 байт** из сокета (подтверждено диагностикой)
- НО `WriteFile(proc->hStdinWrite, data, 17)` не доставляет данные в CGI-процесс
- **Гипотеза A:** тело УЖЕ в буфере ридера, но `EndOfHeaders` неверен → `GetPreloadedBytes` возвращает 0. Проверить: сравнить поиск `\r\n\r\n` в `GetRequestedBytes` с `EndOfHeaders` из `GetPreloadedBytes`
- **Гипотеза B:** `hStdinWrite` невалиден. Проверить `CgiProcess.bas` — как создаётся stdin pipe
- **Гипотеза C:** `BeginRead`/poll зависает (нет данных в сокете, WSARecv ждёт вечно). Добавить таймаут 500ms в poll-цикл

### 2. status.py?404 → 200 (регресс)
- Индивидуально запрос возвращает 404 (проверено)
- В прогоне тестов падает — вероятно, worker-поток сервера зависает на POST-теле перед status.py
- После исправления POST body должно пройти

## Сборка и тест

```powershell
Get-Process -Name "Station922_x64" -ErrorAction SilentlyContinue | Stop-Process -Force
$env:PATH = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\bin\win64;C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0;C:\Program Files\mingw64\bin;$env:PATH"
$fbc = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\fbc64.exe"
& $fbc -m Station922 -l crypt32 -x Station922_x64.exe -O 3 -gen gcc src\*.bas src\*.RC
Start-Process -FilePath "C:\Station922\Station922_x64.exe" -WorkingDirectory "C:\Station922" -WindowStyle Hidden
Start-Sleep -Seconds 3
python test_cgi.py
```

Ожидаемые warnings: HttpCgiProcessor.bas(N) warning 38, WebSite.bas(358) warning 3, WebSite.bas(360) warning 3

## Ключевые файлы
- `src/HttpCgiProcessor.bas` — все изменения здесь (Step 9: BeginRead/poll для тела, Step 12: dwHeaderEnd fix, конец Prepare: SetMimeType fix)
- `src/CgiProcess.bas` — проверить `StartProcess`, `hStdinWrite`
- `src/HttpAsyncReader.bas` — `GetPreloadedBytes`, `GetRequestedBytes`, `EndOfHeaders`, `cbLength`
- `src/ThreadPool.bas:69-80` — `SetCompleted` + NULL-callback безопасен
- `WebServer.ini` — `MemoryPoolCapacity=500`, `WorkerThreads=8`

## Важно
- **Диагностика прежде всего** — не ломай 30 работающих тестов
- `BeginRead(NULL)` безопасен (ThreadPool проверяет `If pcb Then`)
- Можно добавлять методы в интерфейсы
