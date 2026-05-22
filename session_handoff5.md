# Handoff #5 — Station922 CGI: 30/32, нужен финальный рывок

## Состояние: 30/32 тестов (базовый коммит `31e36cb`)

Сервер стабилен. Все error-пути (404, 403, 502, 504) работают корректно через `CgiReturnErrorResponse`.

## Файлы (НЕ МЕНЯТЬ без диагностики)

| Файл | Статус |
|------|--------|
| `src/CgiProcess.bas` | Исправлен `Terminate()` — WaitForSingleObject перед TerminateProcess |
| `src/HttpCgiProcessor.bas` (1595 строк) | Содержит все фиксы handoff4 |
| `WebServer.ini` | `MemoryPoolCapacity=100` |

## Два оставшихся FAIL

### 1. POST body empty (test_cgi.py, тест 4)
```
FAIL POST post_echo.py echoes body: expected=b'Hello, POST body!', got=b''
```

**Корень:** `GetPreloadedBytes` возвращает `PreloadedLen=0` для POST-запроса `b"Hello, POST body!"` (17 байт). Тело не попало в первый WSARecv вместе с заголовками.

**Почему:** `HttpAsyncReader.EndReadLine` находит `\r\n\r\n`, выставляет `IsAllBytesReaded=True` и `EndOfHeaders`. Дальнейшие чтения с сокета НЕ выполняются. `cbLength` заморожено, `PreloadedLen = cbLength - EndOfHeaders = 0`. Тело сидит в TCP-буфере ядра — никто его не читает.

**Что пробовали и результат:**
- `recv()` на сокете → крах сервера (writer шлёт RST)
- `ioctlsocket(FIONBIO)` + `recv()` → крах
- `IBaseAsyncStream_BeginRead/EndRead` из синхронного Prepare() → крах
- `select_()` + `recv()` → не крашнуло, но данных не прочитало
- `ioctlsocket(FIONREAD)` + `recv()` → крахнуло другие тесты (500-е ошибки)

**Гипотезы для исследования:**
- **А.** `IHttpAsyncReader_GetRequestedBytes` возвращает ПОЛНЫЙ сырой буфер ридера. Найди в нём `\r\n\r\n` вручную. Сравни позицию с `EndOfHeaders` из `GetPreloadedBytes`. Возможно, `EndOfHeaders` проставлен НЕВЕРНО — и тело ЛЕЖИТ в буфере, но PreloadedLen=0 из-за смещённого указателя.
- **Б.** `IWebSite_GetBuffer` с `ReadAccess` — может вернуть поток, из которого можно прочитать тело. Так делает `HttpPutProcessor` (но он использует `CreateAccess` для ЗАПИСИ в файл).
- **В.** Механизм `IHttpAsyncReader_SetSkippedBytes` / `SkippedBytes` — ридер умеет пропускать байты тела при переходе к следующему keep-alive запросу. Можно ли использовать этот механизм для ЧТЕНИЯ тела вместо пропуска?
- **Г.** Добавить публичный метод в `IHttpAsyncReader` для синхронного чтения N байт с нижележащего сокета, безопасно обходящий IOCP (например, через `recv()` с предварительной проверкой доступности данных).
- **Д.** Проверить тайминг: `Sleep(50-100)` перед `GetPreloadedBytes`. Если тело приходит с задержкой в отдельном TCP-сегменте, IOCP мог успеть прочитать его в какой-то внутренний буфер.

### 2. Content-Type: None (test_cgi.py, тест 12)
```
FAIL hello.py Content-Type is text/plain: got: None
```

CGI-скрипт `hello.py` выводит `Content-Type: text/plain`, статус 200 (PASS), но HTTP-заголовок `Content-Type` отсутствует в ответе.

**Корень:** `ServerResponse.AllHeadersToZString` (ServerResponse.bas:712) генерирует заголовок `Content-Type` ТОЛЬКО если `self->Mime.ContentType <> ContentTypes.AnyAny`. По умолчанию MIME = AnyAny → заголовок не эмитится.

**Цепочка парсинга CGI-заголовков (HttpCgiProcessor.bas ~строка 1267-1345):**
1. CGI-парсер находит `Content-Type: text/plain` → вызывает `IServerResponse_AddResponseHeader(pResponse, "Content-Type", "text/plain")`
2. AddResponseHeader сохраняет значение в `ResponseHeaders[HeaderContentType]`
3. **НО** в MIME-блоке (~строка 1367-1383) оригинальный код пытается прочитать его обратно через `GetHttpHeader` и вызывает `GetContentTypeOfMimeType(pContentTypeHeader, @Mime)` — эта функция конвертирует MimeType→строка, а НЕ строка→MimeType! Параметры перепутаны.
4. MIME на ответе остаётся `AnyAny` → AllHeadersToZString НЕ эмитит Content-Type.

**Гипотезы для исправления:**
- **А.** Написать правильную конвертацию строка→enum в MIME-блоке (вместо `GetContentTypeOfMimeType`): сравнить `pContentTypeHeader` через `lstrcmpiW` с известными типами и выставить `Mime.ContentType` в соответствующий enum.
- **Б.** После установки MIME вызвать `IServerResponse_SetMimeType(pResponse, @Mime)`.
- **В.** Проверить, что `IServerResponse_AddResponseHeader` действительно сохраняет заголовок (в `ResponseHeaderNodesVector` запись `HeaderContentTypeString = "Content-Type"`, сравнение через case-sensitive `lstrcmpW`).

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

Ожидаемые warnings (3 шт.):
- `HttpCgiProcessor.bas(N) warning 38(1): Suspicious logic operation`
- `WebSite.bas(358) warning 3(2): Passing different pointer types`
- `WebSite.bas(360) warning 3(2): Passing different pointer types`
