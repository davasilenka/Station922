# Handoff #7 — Привести Station922 CGI к полному соответствию task.md

## Контекст

**Текущее состояние:** 32/32 теста [test_cgi.py](test_cgi.py) проходят стабильно (коммит `d35997f` на `master`). Все функциональные критерии приёмки task.md выполнены.

**Однако** есть архитектурные расхождения с task.md, зафиксированные в [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md). Цель этой сессии — устранить эти расхождения, **не сломав 32/32**.

**Главное требование:** строго следовать [task.md](task.md). Это единственный источник истины.

---

## Что нужно сделать (по приоритету)

### Задача 1. Настоящий асинхронный I/O для CGI pipes — критично

task.md явно требует:
> - Использование асинхронных pipes для передачи данных в stdin и из stdout/stderr CGI-процесса
> - Интеграция с существующей системой async I/O сервера (IAsyncIoTask, IBaseAsyncStream)
> - Асинхронное чтение вывода CGI-скрипта без блокировки рабочих потоков
> - ReadFile/WriteFile с OVERLAPPED структурами
> - CreateIoCompletionPort для асинхронного ввода-вывода
> - Использование пула потоков (ThreadPool) для асинхронных операций с pipes

Сейчас (после коммита `d35997f`): stdout читается синхронно через `PeekNamedPipe` + `ReadFile` + `Sleep(10)` в worker-потоке ([HttpCgiProcessor.bas:993-1054](src/HttpCgiProcessor.bas#L993-L1054)). Worker блокируется. OVERLAPPED не используется.

**Что нужно сделать:**

1. **Переписать [CgiProcess.bas](src/CgiProcess.bas)** на named pipes с `FILE_FLAG_OVERLAPPED`:
   - Заменить `CreatePipe` на `CreateNamedPipeW` с уникальным именем (например, `\\.\pipe\station922-cgi-<pid>-<atomicCounter>`)
   - Server-конец (родителю) — `PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED` для stdin, `PIPE_ACCESS_INBOUND | FILE_FLAG_OVERLAPPED` для stdout/stderr
   - Client-конец (дочернему) — открыть через `CreateFileW` с inheritable SA, **без** FILE_FLAG_OVERLAPPED
   - Привязать parent-end handles к IOCP `ThreadPool->CompletionPort` через `CreateIoCompletionPort`
   - Сохранить текущую критическую секцию вокруг pipe-creation + CreateProcess + close child ends (handle inheritance leak иначе вернётся)

2. **Либо подключить существующий [CgiAsyncTask.bas](src/CgiAsyncTask.bas) к HttpCgiProcessor, либо удалить его и сделать `PipeAsyncStream.bas`** (реализующий `IBaseAsyncStream` поверх pipe-handle, по аналогии с [NetworkAsyncStream.bas](src/NetworkAsyncStream.bas)). Второй вариант архитектурно чище, потому что HttpCgiProcessor использует `IBaseAsyncStream` для других потоков. `CgiAsyncTask` сейчас реализован через `CreateThread`+sync `ReadFile`, что НЕ соответствует task.md (требуется IOCP).

3. **Переписать Step 9/10/11 в [HttpCgiProcessor.bas](src/HttpCgiProcessor.bas)** на async:
   - Step 9 (POST stdin): `IBaseAsyncStream_BeginWrite` на stdin pipe — chained до тех пор, пока весь body не передан
   - Step 10 (stdout): `BeginRead` chained drain до `ERROR_BROKEN_PIPE`, накопление в общий буфер
   - Step 11 (timeout): через `WaitForMultipleObjectsEx` на `proc->hProcess` + `CancelIoEx` на pending OVERLAPPED при таймауте

4. **Stderr drain** — параллельно со stdout, async chain до `ERROR_BROKEN_PIPE`. Вывод писать в Logger через `LogWriteEntry`. task.md требует «Логирование ошибок выполнения CGI».

**Подводные камни:**
- `CancelIoEx` не освобождает OVERLAPPED сразу — нужно дождаться completion с `ERROR_OPERATION_ABORTED`.
- При закрытии client-end pipe handle до `CreateProcessW` дочерний процесс получит ERROR_BROKEN_PIPE сразу при попытке чтения. Закрытие client ends в родителе **должно** идти после `CreateProcessW`, в текущей CS — это уже правильно.
- Уникальность имени named pipe критична при параллельных запросах — использовать `InterlockedIncrement` для seq counter.
- Inheritance: client-end pipes должны быть `bInheritHandle=TRUE` в SECURITY_ATTRIBUTES при открытии через CreateFileW, parent-end — NON-inheritable (через `SetHandleInformation`).

### Задача 2. Allowed CGI directories — конфиг

task.md требует:
> - Настройка директорий, в которых разрешено выполнение CGI-скриптов

Сейчас отсутствует. Нужно:
1. Добавить поле `CgiAllowedDirectories As HeapBSTR` (или массив) в [WebSite.bas](src/WebSite.bas) и геттеры/сеттеры в [IWebSite.bi](src/IWebSite.bi)
2. Парсинг секции в [IniConfiguration.bas](src/IniConfiguration.bas) — например, `CgiAllowedDirs=/cgi-bin;/scripts`
3. Проверка в [HttpCgiProcessor.bas](src/HttpCgiProcessor.bas) перед запуском: путь скрипта должен быть в одной из разрешённых директорий. Если нет — 403 Forbidden.
4. Тесты: добавить тест на `/non-allowed-dir/script.py` → 403

### Задача 3. Подчистить TASK_COMPLIANCE.md

После выполнения Задач 1-2 обновить [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md) — отметить как "соответствует".

---

## Регрессионная защита

**Тесты должны проходить 32/32 после каждого этапа.** Запуск:

```powershell
Get-Process -Name "Station922_x64" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500
$env:PATH = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\bin\win64;C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0;C:\Program Files\mingw64\bin;$env:PATH"
$fbc = "C:\FreeBASIC-1.10.1-winlibs-gcc-9.3.0\fbc64.exe"
& $fbc -m Station922 -l crypt32 -x Station922_x64.exe -O 3 -gen gcc src\*.bas src\*.RC
Start-Process -FilePath "C:\Station922\Station922_x64.exe" -WorkingDirectory "C:\Station922" -WindowStyle Hidden
Start-Sleep -Seconds 2
python test_cgi.py
```

Ожидаемые warnings (норма): `HttpCgiProcessor.bas warning 38`, `WebSite.bas(358) warning 3`, `WebSite.bas(360) warning 3`.

**Тесты с наивысшим риском регрессии** при переписке на async pipes:
- `5 parallel GET hello.py -> all 200` — handle inheritance race, named pipe naming
- `POST post_echo.py echoes body` — async stdin write, EOF к дочернему процессу
- `slow.py timeout -> 504` — `CancelIoEx` на pending OVERLAPPED, deadlock возможен
- `bigoutput.py?200000 returns 200` — chunked async read большого вывода
- `exit1 -> 502` — детект «процесс завершился» vs «pipe closed»

**Стратегия:** делать маленькими шагами с тестом после каждого.

---

## Правила работы (из памяти)

1. **Кодировка исходников:** все `*.bas`/`*.bi` хранятся в **Windows-1251**, не UTF-8. Если редактируешь через Edit/Write — пиши только ASCII в новых строках. Кириллицу в новых .bas-файлах писать **нельзя** (Edit запишет UTF-8 и сломает существующую кириллицу). Комментарии — на английском или транслите. Markdown файлы (.md) — UTF-8, как обычно.

2. **Push после каждого коммита:** `git push origin master`. Ветка master.

3. **Ошибки компиляции:**
   - Тривиальные синтаксические ошибки / typo / переименования — фиксить **сразу** без подтверждения
   - Нетривиальные (требуют изменения архитектуры или подходa) — сначала план + подтверждение пользователя

4. **Запретно:** менять интерфейсы `IBaseAsyncStream`, `IAsyncResult`, `IHttpAsyncReader`, `IHttpAsyncWriter`, `IServerResponse`, `IClientRequest` — это ломает остальной сервер. Расширять — можно (добавлять методы в конец vtable).

5. **`cgi-bin/post_echo.py`** — сейчас пишет всё в `sys.stdout.buffer.write` (binary). Не возвращай text-режим — text-буфер flush'ится после binary, что ломает порядок headers/body. Это документировано в коммите `d35997f`.

---

## Ключевые файлы

| Файл | Что в нём |
|---|---|
| [task.md](task.md) | Источник истины. Читать первым. |
| [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md) | Текущий статус соответствия по разделам. |
| [test_cgi.py](test_cgi.py) | Автотесты, должны проходить 32/32. |
| [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas) | Главный CGI-обработчик. Step 9/10/11 — кандидаты на переписку. |
| [src/CgiProcess.bas](src/CgiProcess.bas) | CreatePipe + CreateProcess. Замена на named pipes здесь. |
| [src/CgiAsyncTask.bas](src/CgiAsyncTask.bas) | Существующий async task, **мёртвый код**. Подключить или удалить. |
| [src/NetworkAsyncStream.bas](src/NetworkAsyncStream.bas) | Образец IBaseAsyncStream-реализации поверх IOCP (через WSARecv). По аналогии можно сделать PipeAsyncStream. |
| [src/ThreadPool.bas](src/ThreadPool.bas) | IOCP worker. `pcb=NULL` обрабатывается корректно (`If pcb Then pcb(pIResult)`). |
| [src/IWebSite.bi](src/IWebSite.bi) | Интерфейс конфигурации. Расширять для AllowedCgiDirs. |
| [WebServer.ini](WebServer.ini) | `WorkerThreads=8, MemoryPoolCapacity=500`. |

---

## Известные особенности, которые могут запутать

1. **`MultiByteToWideChar` не ставит NULL terminator** при явной длине источника. Если будешь писать новые парсеры — ставь `wBuf[wcharsWritten] = 0` сразу после, или используй параметр `-1` (для NULL-terminated source).

2. **Анонимные pipes не поддерживают OVERLAPPED** — это документированное ограничение Windows. Только named pipes.

3. **`PeekNamedPipe` возвращает `ERROR_BROKEN_PIPE`** когда дочерний процесс закрыл write-end даже если процесс ещё формально не exit'нул. Это EOF, не ошибка.

4. **Handle inheritance leak при параллельных CreateProcess** — был исправлен через критическую секцию в [CgiProcess.bas:14-33](src/CgiProcess.bas#L14-L33). При переходе на named pipes можно использовать `STARTUPINFOEX` + `PROC_THREAD_ATTRIBUTE_HANDLE_LIST` для явного списка наследуемых handles (это требует `_WIN32_WINNT >= 0x0600`, который сейчас не выставлен в проекте — придётся либо выставлять, либо оставлять CS).

5. **5-сек таймаут в poll-loop Step 9** ([HttpCgiProcessor.bas:903-908](src/HttpCgiProcessor.bas#L903-L908)) — защита от вечного зависания на BeginRead с NULL callback. После перехода на полноценный async-через-IOCP с реальным callback это можно убрать.

---

## План коммитов (рекомендуемый)

1. **`CGI: switch to named pipes with FILE_FLAG_OVERLAPPED`** — только CgiProcess.bas. После: тесты должны пройти (синхронный ReadFile на overlapped pipe всё ещё работает, просто блокирует worker).
2. **`CGI: PipeAsyncStream — IBaseAsyncStream over IOCP-attached pipe`** (или подключение CgiAsyncTask) — новый модуль, ещё не используется. После: тесты те же.
3. **`CGI: rewrite stdout/stderr read loop as async drain`** — Step 10 в HttpCgiProcessor.bas. После: тесты 32/32.
4. **`CGI: rewrite stdin write as async`** — Step 9. После: тесты 32/32.
5. **`CGI: read stderr and log via LogWriteEntry`** — stderr drain. После: тесты 32/32.
6. **`CGI: allowed directories config + 403 check`** — IWebSite/IniConfiguration/HttpCgiProcessor. Возможно расширить test_cgi.py новым тестом.
7. **`docs: update TASK_COMPLIANCE.md to reflect full task.md compliance`**.

Каждый коммит — `git push origin master` сразу после.
