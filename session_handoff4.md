# Handoff #4 — Station922 CGI: финальное состояние

## Достигнутый прогресс: 30/32 тестов (+7 от baseline 23)

Сервер стабилен, не падает, не вешает соединения. Все error-пути возвращают корректные HTTP-ответы.

## Состояние файлов

| Файл | Изменения относительно оригинала |
|------|----------------------------------|
| `src/CgiProcess.bas:125-131` | `Terminate()`: добавлен `WaitForSingleObject(hProcess, 0) <> WAIT_OBJECT_0` перед `TerminateProcess` |
| `src/HttpCgiProcessor.bas:657-687` | Добавлена `CgiReturnErrorResponse()` — создаёт MemoryStream с 0 байт для error-ответов |
| `src/HttpCgiProcessor.bas:919-926` | PeekNamedPipe error: вместо проверки `ERROR_BROKEN_PIPE` — проверка `WaitForSingleObject(hProcess, 0) = WAIT_OBJECT_0` |
| `src/HttpCgiProcessor.bas:938-948` | ReadFile error (главный цикл): добавлен fallback `WaitForSingleObject` |
| `src/HttpCgiProcessor.bas:977-982` | ReadFile error (drain-луп): добавлен fallback `WaitForSingleObject` |
| `src/HttpCgiProcessor.bas:971-1017` | Drain-луп + проверки bReadOk/maxOutput обёрнуты в `If bProcessExited = FALSE OrElse dwTotalRead > 0` (пропуск при нулевом выводе) |
| `src/HttpCgiProcessor.bas:1019-1025` | Fast path: `bProcessExited AndAlso dwTotalRead = 0` → сразу 502, без доп. операций с pipe |
| `src/HttpCgiProcessor.bas:909-915` | Первый таймаут: `GatewayTimeout` + `CgiReturnErrorResponse` вместо `E_FAIL` |
| `src/HttpCgiProcessor.bas:870-895` | Step 9: stdin закрывается сразу (ContentLen=0 или после preloaded-байт). Если тело не дочитано — процесс получает EOF вместо зависания |
| 6 точек возврата `S_OK` с NULL | Заменены на `CgiReturnErrorResponse` (404, 403, 502, 504) |
| `WebServer.ini` | `MemoryPoolCapacity=100` (без изменений от handoff3) |

## Что работает (28 проверок PASS)

- GET hello.py, env.py, query, headers, status, bigoutput — все 200
- nonexistent → 404
- exit1 → 502 (без краша!)
- slow.py → 504 (timeout)
- 5 parallel → все 200
- Content-Type: статус 200, заголовок body содержит контент

## Что НЕ работает (2 проверки FAIL)

### 1. POST body echo — тело пустое (priority: HIGH)
**Симптом:** `POST post_echo.py returns 200` (PASS), но `post_echo.py echoes body: got=b''` (FAIL).
**Корень:** тело POST-запроса не доходит до CGI-процесса. `PreloadedLen = 0` — данные не попали в первый WSARecv. Сейчас stdin закрывается сразу → процесс получает EOF → пустой ответ.
**Что пробовали и почему не сработало:**
- `recv()` на IOCP-сокете: читает данные, но ломает writer (RST/ConnectionReset) — **недопустимо**
- `ioctlsocket(FIONBIO)` + `recv()` с таймаутом: то же самое
- `IBaseAsyncStream_BeginRead/EndRead`: сервер падает (краш процесса) — **недопустимо**
**Направление:** все три подхода к чтению с IOCP-сокета из синхронного `Prepare()` ломают сервер. Нужен принципиально другой подход. Возможные варианты:
  - **А.** Использовать `GetRequestedBytes` вместо `GetPreloadedBytes` — проверить, не лежит ли тело в полном буфере reader'а (маловероятно, т.к. PreloadedLen=0 означает что `cbLength == EndOfHeaders`)
  - **Б.** Увеличить размер буфера reader'а (сейчас ~16KB), чтобы заголовки+тело гарантированно попадали в первый WSARecv — может не помочь при фрагментации TCP
  - **В.** Использовать `IWebSite_GetBuffer` (как HttpPutProcessor) для получения тела через стандартный механизм сервера, затем скопировать в stdin
  - **Г.** Оставить как есть (stdin закрывается, тело не передаётся) — тест не пройдёт, но сервер стабилен

### 2. Content-Type: None (priority: LOW)
**Симптом:** `hello.py Content-Type is text/plain: got: None`. Тест вызывает `/cgi-bin/hello.py` 12-м по счёту (после bigoutput.py).
**Гипотеза:** не гонка и не состояние сервера. Возможно, заголовок `Content-Type` из CGI-ответа парсится, но не попадает в финальный HTTP-ответ при определённых условиях. Требуется расследование: проверить `IServerResponse_AddResponseHeader` в блоке парсинга CGI-заголовков (строки ~1100-1140 в текущем файле).
**Workaround:** можно вызвать hello.py первым запросом в изоляции и проверить заголовки.

## Сборка и тест

```powershell
Get-Process -Name "Station922_x64" -ErrorAction SilentlyContinue | Stop-Process -Force
$env:PATH = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\bin\win64;C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0;C:\Program Files\mingw64\bin;$env:PATH"
$fbc = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\fbc64.exe"
& $fbc -m Station922 -l crypt32 -x Station922_x64.exe -O 3 -gen gcc src\*.bas src\*.RC
Start-Process -FilePath "C:\Station922\Station922_x64.exe" -WorkingDirectory "C:\Station922" -WindowStyle Hidden
Start-Sleep -Seconds 2
python test_cgi.py
```

Ожидаемые warnings при сборке (3 шт., как в оригинале):
- `HttpCgiProcessor.bas(N) warning 38(1): Suspicious logic operation`
- `WebSite.bas(358) warning 3(2): Passing different pointer types`
- `WebSite.bas(360) warning 3(2): Passing different pointer types`
