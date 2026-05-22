# Handoff — Фаза 2: Async I/O через IOCP (главный этап)

## Цель сессии

Привести pipe I/O в строгое соответствие task.md:
> - ReadFile/WriteFile с **OVERLAPPED** структурами
> - **CreateIoCompletionPort** для асинхронного ввода-вывода
> - **Асинхронное чтение** вывода CGI-скрипта **без блокировки рабочих потоков**
> - Использование **пула потоков (ThreadPool)** для асинхронных операций с pipes
> - Интеграция с существующей системой async I/O сервера (**IAsyncIoTask, IBaseAsyncStream**)

Подразумевается, что фаза 1 уже выполнена (named pipes есть, stderr дренажится, allowed dirs работают). Если фаза 1 не выполнена — **остановись** и доложи пользователю.

## Проверка отправной точки

1. Запустить `test_cgi.py` — должно быть 32/32.
2. Прочитать `git log -10 --oneline` — должны быть коммиты от фазы 1 (`CGI: remove unused CgiAsyncTask`, `CGI: drain stderr`, `CGI: enforce allowed directories`, `CGI: switch to named pipes (sync mode)`).
3. В [src/CgiProcess.bas](src/CgiProcess.bas) уже должен быть `CreateNamedPipeW` (не `CreatePipe`).

Если что-то из этого не так — стоп, доложить.

## Что НЕ делать

- **НЕ менять интерфейсы** IBaseAsyncStream, IAsyncResult, IHttpAsyncReader, IHttpAsyncWriter. Только реализовать существующие.
- **НЕ удалять** критическую секцию вокруг pipe creation + CreateProcess. Это нужно и в async-режиме (handle inheritance race никуда не делся).
- **НЕ объединять** подэтапы. Каждый подэтап = отдельный коммит = отдельный прогон тестов.
- **НЕ оставлять** диагностические `_dbg_*.txt` файлы в финальном коде.

## Граблины предупреждения (читай до того как начнёшь)

Это места, на которых предыдущие агенты падали. Я (агент, делавший фазу 0/1) видел эти грабли. Игнорировать — потерять часы.

### G1. ConnectNamedPipe ОБЯЗАТЕЛЕН перед CreateProcess

Named pipe в режиме `PIPE_ACCESS_*` создан в состоянии «listening». Пока server-end не вызовет `ConnectNamedPipe`, client-end через `CreateFileW` либо застрянет, либо вернёт `ERROR_PIPE_BUSY`.

Правильная последовательность:
```
1. CreateNamedPipeW(server-end, FILE_FLAG_OVERLAPPED)
2. ConnectNamedPipe(server-end, OVERLAPPED)  ← возвращает FALSE с ERROR_IO_PENDING, это нормально
3. CreateFileW(client-end)  ← теперь успешно открывается
4. ConnectNamedPipe completion придёт через IOCP (или вернёт ERROR_PIPE_CONNECTED синхронно если client уже подключился)
5. CreateProcessW передаёт client-end в STARTUPINFO
6. CloseHandle(client-end в родителе)
```

Если делаешь все шаги в одном потоке (не через IOCP callback) — `ConnectNamedPipe` после `CreateFileW` синхронно вернёт `ERROR_PIPE_CONNECTED` (это не ошибка, это «уже подключён»). Этот код нужно обрабатывать как success.

### G2. Анонимные pipes НЕ работают с OVERLAPPED

Если на каком-то этапе видишь `CreatePipe` — это ошибка. Фаза 1 уже перешла на `CreateNamedPipeW`. Проверь что во всех местах CGI используется именно named pipes.

### G3. CancelIoEx не освобождает OVERLAPPED сразу

Если для таймаута вызываешь `CancelIoEx(handle, pOverlapped)` — НЕ освобождай память pOverlapped/AsyncResult сразу. I/O всё ещё может писать туда. Нужно либо:
- Дождаться IOCP completion с `ERROR_OPERATION_ABORTED`
- ЛИБО просто `TerminateProcess` — он автоматически закроет pipes, и все pending I/O получат `ERROR_BROKEN_PIPE` через IOCP, что естественно завершит цепочку

**Рекомендация: НЕ использовать CancelIoEx. Использовать TerminateProcess для таймаутов** — это проще и надёжнее.

### G4. Process-pipe race

В Windows гарантируется: `WaitForSingleObject(hProcess, ...)` может вернуть `WAIT_OBJECT_0` РАНЬШЕ чем pipe-read дренажит все буферизованные данные. Логика должна быть:
- Главный сигнал «закончили читать» = `ReadFile` → `ERROR_BROKEN_PIPE`
- НЕ `GetExitCodeProcess() != STILL_ACTIVE`

### G5. IOCP completion key

В [src/ThreadPool.bas:54](src/ThreadPool.bas#L54) `completionKey=0` — сигнал shutdown:
```basic
If CompletionKey = 0 Then
    Exit Do
End If
```

При `CreateIoCompletionPort(hPipe, hExistingIOCP, completionKey, 0)` — completionKey должен быть **не-нулевым**. Используй адрес `IAsyncResult` или `CgiProcess` как ключ. Иначе worker thread выйдет при первом completion.

### G6. Reuse существующей инфраструктуры

В проекте есть [src/NetworkAsyncStream.bas](src/NetworkAsyncStream.bas) — образец `IBaseAsyncStream` через `WSARecv`+IOCP. По его аналогии нужен `PipeAsyncStream.bas` — но с `ReadFile`+OVERLAPPED+IOCP. Структура почти идентична — копируй паттерн.

В [src/AsyncResult.bas](src/AsyncResult.bas) уже есть `IAsyncResult` с `OVERLAPPED` внутри (для WSA*). Тот же IAsyncResult можно использовать для pipe I/O — структура OVERLAPPED совместима.

### G7. FreeBASIC специфика

- `_WIN32_WINNT` в проекте не выставлен явно. Часть API (`InitOnceExecuteOnce`, `STARTUPINFOEX`) недоступны. Не пытайся их использовать.
- `InterlockedIncrement(@var)` для атомарных счётчиков (уникальное именование pipes).
- Boolean в FB = Long. `If pcb Then pcb(pIResult)` уже используется в ThreadPool — это работает с NULL.

---

## Подэтапы

### Подэтап 2.1 — Включить FILE_FLAG_OVERLAPPED на pipes

**Что сделать:**
В [src/CgiProcess.bas](src/CgiProcess.bas):
1. Добавить `FILE_FLAG_OVERLAPPED` в `CreateNamedPipeW` параметр `dwOpenMode` (например, `PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED`).
2. Client-end (`CreateFileW`) **оставить БЕЗ** `FILE_FLAG_OVERLAPPED`. Child process работает с pipe синхронно.
3. Добавить `ConnectNamedPipe(serverEnd, NULL)` для каждого server-end **после** `CreateNamedPipeW`. Это вернёт `ERROR_PIPE_LISTENING` синхронно — это OK, потом `CreateFileW` подключится.

   **Альтернатива (рекомендуемая для простоты):** Не делать ConnectNamedPipe явно. После `CreateFileW(client-end)` сам факт открытия client'ом подключает обе стороны. Server-end готов к I/O сразу после CreateFile client-end.

4. **На этом этапе I/O всё ещё синхронный** (`ReadFile`/`WriteFile` без overlapped — да, оно будет работать на overlapped handle, но без преимуществ async). Логику в HttpCgiProcessor НЕ менять.

5. Тесты 32/32.

**Коммит:** `CGI: enable FILE_FLAG_OVERLAPPED on server-end pipes`

**Зачем этот подэтап отдельно:** убедиться что overlapped flag сам по себе не ломает существующий синхронный ReadFile/WriteFile. Если ломает — это сразу видно, можно откатить.

**Возможная проблема:** на overlapped handle синхронный `ReadFile(h, buf, len, &n, NULL)` (NULL вместо OVERLAPPED*) ведёт себя странно. **Решение:** передавать `OVERLAPPED` структуру даже для «синхронного» чтения, и потом ждать через `GetOverlappedResult(h, &ov, &n, TRUE)`. Это эквивалент sync read.

### Подэтап 2.2 — Создать PipeAsyncStream.bas

**Что сделать:**
1. Создать [src/PipeAsyncStream.bas](src/PipeAsyncStream.bas) и `.bi` по образцу [src/NetworkAsyncStream.bas](src/NetworkAsyncStream.bas):

   ```
   Type PipeAsyncStream
       lpVtbl As IBaseAsyncStreamVirtualTable Ptr
       ReferenceCounter As ULONG
       pIMemoryAllocator As IMalloc Ptr
       hPipe As HANDLE
       ... (RTTI debug field) ...
   End Type
   ```

2. Реализовать vtable:
   - `QueryInterface`, `AddRef`, `Release` — стандартно
   - `BeginRead(buf, count, pcb, state, ppResult)`:
     - `CreateAsyncResult`
     - `IAsyncResult_AllocBuffers(...)` для OVERLAPPED (или используется built-in WsaOverlapped — тот же OVERLAPPED, проверь)
     - `IAsyncResult_GetWsaOverlapped(pResult, @pOverlap)` — берём OVERLAPPED из AsyncResult
     - `IAsyncResult_SetAsyncStateWeakPtr(pResult, pcb, state)`
     - `ReadFile(hPipe, buf, count, NULL, pOverlap)` — запуск async I/O
     - Если `ReadFile` вернул FALSE с `GetLastError()=ERROR_IO_PENDING` — нормально, ждать completion через IOCP
     - Если `ERROR_BROKEN_PIPE` — установить completion сразу через `IAsyncResult_SetCompleted(0, TRUE, ERROR_BROKEN_PIPE)`
   - `BeginWrite(buf, count, pcb, state, ppResult)` — аналогично через `WriteFile`
   - `EndRead(pResult, pReadBytes)` — взять `BytesTransferred` из AsyncResult
   - `EndWrite(pResult, pWritedBytes)` — то же

3. Создать функцию `CreatePipeAsyncStream(pAllocator, hPipe, riid, ppv) As HRESULT` — конструктор.

4. **Привязать pipe к IOCP** в момент создания stream — `CreateIoCompletionPort(hPipe, hExistingIOCP, CULngPtr(pStream), 0)`. completionKey = адрес stream (НЕ ноль).

   Где взять `hExistingIOCP`? Это `ThreadPool->CompletionPort`. Нужен публичный геттер или передавать pool в `CreatePipeAsyncStream`. Посмотри [src/ThreadPool.bas](src/ThreadPool.bas) — добавь публичный метод `IThreadPool_GetCompletionPort` если ещё нет.

5. **Пока stream НЕ ИСПОЛЬЗУЕТСЯ** в HttpCgiProcessor. Это будет в 2.3-2.4.

6. Тесты 32/32 (должны проходить как раньше — новый модуль не подключён).

**Коммит:** `CGI: add PipeAsyncStream module (IBaseAsyncStream over IOCP-bound pipe)`

**Грабли:**
- `ERROR_IO_PENDING` ≠ ошибка. Это «async запущен, ждём completion». НЕ возвращай как failure.
- В IOCP completion для pipe нет «socket flags» — но OVERLAPPED-структура работает идентично. WsaOverlapped в проекте — это просто OVERLAPPED с псевдонимом.

### Подэтап 2.3 — Переключить Step 9 (stdin write) на async

**Что сделать:**
В [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas), Step 9:
1. Вместо `WriteFile(proc->hStdinWrite, ...)` создать `PipeAsyncStream` через `proc->hStdinWrite`.
2. Использовать `IBaseAsyncStream_BeginWrite(...)` — передать **реальный callback** (не NULL!), либо использовать паттерн poll-loop с `GetCompleted` (уже есть в Step 9 для socket BeginRead).
3. Для совместимости: callback может просто вызывать `SetEvent(hStdinDoneEvent)`, и worker ждёт через `WaitForSingleObject(hStdinDoneEvent, dwTimeout)`.

   **Альтернативно:** оставить poll-loop с GetCompleted, как сейчас — оно работает (доказано в фазе 0). Но если хочешь сделать «правильно» — через реальный callback.

4. **EOF к дочернему процессу:** после завершения всех writes на stdin — закрыть `proc->hStdinWrite`. Дочерний `ReadFile` вернёт 0 байт = EOF.

5. Тесты 32/32. Особенно `POST post_echo.py`.

**Коммит:** `CGI: rewrite stdin write through PipeAsyncStream (async via IOCP)`

### Подэтап 2.4 — Переключить Step 10 (stdout read) на async

**Что сделать:**
В [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas), Step 10:
1. Удалить весь цикл `PeekNamedPipe`+`Sleep(10)`. Это главная синхронная блокировка.
2. Заменить на цепочку async `BeginRead`:
   - Создать `PipeAsyncStream` через `proc->hStdoutRead`
   - В цикле (или цепочкой callback) делать `BeginRead` по чанкам (например, 8 КБ)
   - При completion: если `dwBytes > 0` → записать в общий буфер `pOutputBuf`, запустить следующий `BeginRead`
   - При completion с `ERROR_BROKEN_PIPE` или `dwBytes = 0` → EOF, выйти из цикла
3. Таймаут: запустить параллельно `WaitForSingleObject(proc->hProcess, dwTimeout)` в отдельном thread. При timeout вызвать `TerminateProcess(proc->hProcess, 1)` — это закроет pipes, pending BeginRead вернётся с broken pipe.
4. Drain после exit процесса — последний `BeginRead` должен дочитать буфер pipe до `ERROR_BROKEN_PIPE`.

5. Тесты 32/32. Особенно `slow.py 504`, `bigoutput.py 200000`, `5 parallel`.

**Коммит:** `CGI: rewrite stdout read through PipeAsyncStream (async via IOCP)`

### Подэтап 2.5 — Stderr через PipeAsyncStream

**Что сделать:**
В [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas):
1. Заменить синхронный stderr-drain (из фазы 1.2) на async через `PipeAsyncStream(proc->hStderrRead)`.
2. Аналогично stdout — цепочка `BeginRead`. Накопленный stderr передать в Logger.
3. Тесты 32/32.

**Коммит:** `CGI: rewrite stderr drain through PipeAsyncStream`

### Подэтап 2.6 — Финальная очистка

**Что сделать:**
1. Убрать 5-сек poll-loop timeout в Step 9 — он был костылём, теперь не нужен (есть реальный IOCP completion).
2. Убрать комментарии о «PeekNamedPipe race» — путь устаревший.
3. Прогнать тесты 3 раза подряд — стабильно 32/32.
4. Обновить [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md):
   - «Асинхронный ввод-вывод» → соответствует
   - «Технические детали (OVERLAPPED, IOCP)» → соответствует
   - «CgiAsyncTask мёртвый код» → заменён на PipeAsyncStream (соответствует task.md «Создание модуля для асинхронных операций с pipes»)

**Коммит:** `CGI: cleanup + update TASK_COMPLIANCE.md to full compliance`

---

## Stop conditions

**Останавливайся и докладывай пользователю если:**
- Любой подэтап не сходится с 32/32 за 3 попытки
- Сервер начинает падать (Station922_x64.exe не в Get-Process после запроса)
- Тесты висят больше 60 секунд
- Появляется тест, который раньше проходил, а теперь нет (регрессия) — после третьей попытки фикса
- Замечаешь что нужно изменить интерфейс из списка запрещённых (IBaseAsyncStream и т.д.)

В докладе укажи:
- Какой подэтап в работе
- Симптомы (какие тесты падают, какие проходят)
- Что ты пробовал
- Твоя гипотеза

## По завершении сессии

- Все 6 подэтапов выполнены, по одному коммиту на каждый
- 3 прогона test_cgi.py подряд — 32/32
- `_dbg_*` файлы убраны
- TASK_COMPLIANCE.md показывает полное соответствие
- `git push origin master`
- Доложить пользователю: «Фаза 2 завершена. 32/32. Все архитектурные расхождения с task.md закрыты.»

## Правила работы

- Исходники .bas/.bi в **Windows-1251**. Кириллицу не пиши в новых строках через Edit/Write.
- Push после каждого коммита.
- Маленькие коммиты, не объединять подэтапы.

## Ключевые файлы

- [task.md](task.md) — требования
- [src/NetworkAsyncStream.bas](src/NetworkAsyncStream.bas) — **образец** для PipeAsyncStream
- [src/ThreadPool.bas](src/ThreadPool.bas) — IOCP infrastructure, completion key handling
- [src/AsyncResult.bas](src/AsyncResult.bas) — IAsyncResult с OVERLAPPED внутри
- [src/CgiProcess.bas](src/CgiProcess.bas) — pipe creation, нужен FILE_FLAG_OVERLAPPED
- [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas) — Step 9/10/11 переписать
- [test_cgi.py](test_cgi.py) — must be 32/32 always
