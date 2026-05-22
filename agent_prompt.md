Ты продолжаешь отладку CGI-поддержки веб-сервера Station922. Прочитай session_handoff4.md — там полный контекст, текущее состояние 30/32 и список ВСЕХ изменений в файлах.

Твоя цель: довести тесты до 32/32.

## Оставшиеся проблемы

### 1. POST body пустой (FAIL: post_echo.py echoes body: got=b'')
Сейчас stdin CGI-процесса закрывается сразу после preloaded-байт (которых 0), процесс получает EOF, возвращает 200 с пустым телом.

**КЛЮЧЕВОЕ ОГРАНИЧЕНИЕ:** чтение с IOCP-сокета из синхронного Prepare() ЛОМАЕТ сервер. Проверено трижды:
- `recv()` → writer шлёт RST, сервер падает
- `ioctlsocket(FIONBIO)` + `recv()` с таймаутом → то же самое
- `IBaseAsyncStream_BeginRead/EndRead` → сервер падает

Тело (`b"Hello, POST body!"`, 17 байт) не попадает в `GetPreloadedBytes` (PreloadedLen=0). Значит, `EndOfHeaders == cbLength` в буфере reader'а.

**Что можно попробовать (в порядке приоритета):**

**А.** `IHttpAsyncReader_GetRequestedBytes` возвращает ПОЛНЫЙ буфер (включая заголовки). Если тело пришло в том же TCP-пакете, что и заголовки, но `EndOfHeaders` по какой-то причине указывает за пределы буфера — данные тела могут быть ДО EndOfHeaders. Проверь: возьми `GetRequestedBytes`, найди `\r\n\r\n` вручную, сравни с `EndOfHeaders` из `GetPreloadedBytes`. Если позиции разные — бери тело из `GetRequestedBytes` вручную.

**Б.** `IWebSite_GetBuffer` — стандартный механизм сервера для получения тела запроса (используется в HttpPutProcessor). Он возвращает `IAttributedAsyncStream`, из которого можно прочитать данные. Проверь, можно ли вызвать его в Prepare для получения тела и записи в stdin. Сигнатура: `IWebSite_GetBuffer(pWebSite, pAlloc, pRequest, pReader, ContentLength, pFlags, FileAccess.ReadAccess, ppIBuffer)`.

**В.** Проверь тайминг: добавь `Sleep(100)` перед `GetPreloadedBytes`. Если тело приходит с задержкой, это решит проблему (но это костыль, не окончательное решение).

### 2. Content-Type: None (FAIL: hello.py Content-Type is text/plain: got: None)
Тест 12 вызывает `/cgi-bin/hello.py` и проверяет заголовок `Content-Type: text/plain`. Статус 200 (PASS), но заголовок отсутствует.

**Для диагностики:** вызови hello.py ИЗОЛИРОВАННО (первым запросом после старта сервера) и проверь заголовки:
```python
import http.client
c = http.client.HTTPConnection('localhost', 80, timeout=5)
c.request('GET', '/cgi-bin/hello.py')
r = c.getresponse()
print(dict(r.getheaders()))
```

Если заголовок есть при изолированном вызове, но пропадает в тесте — проблема в накоплении состояния между запросами. Если нет даже изолированно — проблема в парсинге CGI-заголовков.

## Файлы (НЕ ТРОГАТЬ без необходимости)
- `src/CgiProcess.bas` — изменён, работает корректно
- `src/HttpCgiProcessor.bas` — изменён, содержит все фиксы
- `WebServer.ini` — `MemoryPoolCapacity=100`
- `session_handoff4.md` — полный контекст

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

Цель: 32/32. Удачи.
