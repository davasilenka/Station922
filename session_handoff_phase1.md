# Handoff — Фаза 1: Безопасные доработки

Эта сессия закрывает 3 расхождения из [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md) с **минимальным риском регрессии** и подготавливает фундамент для фазы 2 (full async). Фаза 2 будет в следующей сессии — **здесь её не делать**.

## Цель сессии

Закрыть пункты из TASK_COMPLIANCE.md:
- «Stderr не читается»
- «Список разрешённых директорий для CGI отсутствует»
- «CgiAsyncTask.bas существует, но не подключён» (решение: удалить как мёртвый код, в фазе 2 будет создан новый PipeAsyncStream)
- Подготовить фундамент: перейти с анонимных pipes на named pipes (но **с тем же синхронным поведением**)

После сессии: 32/32 тестов проходят, на master 4 новых коммита.

## Что НЕ делать в этой сессии

- **НЕ включать `FILE_FLAG_OVERLAPPED`** на pipes. Это в фазе 2.
- **НЕ привязывать pipe handles к IOCP**. Это в фазе 2.
- **НЕ переписывать Step 9/10/11 в HttpCgiProcessor**. Сейчас они синхронные — оставить.
- **НЕ менять интерфейсы** IBaseAsyncStream, IAsyncResult, IHttpAsyncReader, IHttpAsyncWriter.
- **НЕ писать новые модули** для PipeAsyncStream. Это в фазе 2.

Если хочется сделать «сразу всё» — стоп. Это сильно повышает риск регрессии.

## Подэтапы

После КАЖДОГО подэтапа:
1. Билд: `fbc64.exe -m Station922 -l crypt32 -x Station922_x64.exe -O 3 -gen gcc src\*.bas src\*.RC`
2. Прогон test_cgi.py — должно быть 32/32
3. Если 32/32 — commit + `git push origin master`
4. Если НЕ 32/32 — откат изменения, доложить пользователю что упало и почему

---

### Подэтап 1.1 — Удаление мёртвого `CgiAsyncTask`

**Что сделать:**
1. Подтвердить что `CgiAsyncTask` нигде не используется кроме самого себя:
   ```
   Grep по проекту: CreateCgiReadStdoutAsyncTask, CreateCgiWriteStdinAsyncTask
   Ожидается: только в CgiAsyncTask.bas/bi и нигде больше
   ```
2. Удалить файлы:
   - `src/CgiAsyncTask.bas`
   - `src/CgiAsyncTask.bi`
   - `src/ICgiAsyncIoTask.bas` (если не используется)
   - `src/ICgiAsyncIoTask.bi` (если не используется)
3. Грепом убедиться что ничто больше не ссылается на `ICgiAsyncIoTask`, `IID_ICgiAsyncIoTask`, `CgiReadStdoutAsyncTask`, `CgiWriteStdinAsyncTask`
4. Билд + тесты

**Коммит:** `CGI: remove unused CgiAsyncTask (dead code)`

**Обоснование:** task.md требует «Создание модуля CgiAsyncTask.bas/bi для асинхронных операций с pipes». В фазе 2 будет создан **новый правильный** модуль — `PipeAsyncStream.bas`, который реализует `IBaseAsyncStream` поверх pipe handle через IOCP. Текущий `CgiAsyncTask` — это мёртвая эмуляция через `CreateThread`+sync `ReadFile`, **не** соответствующая требованию task.md «использование пула потоков (ThreadPool) для асинхронных операций» (имеется в виду IOCP-based ThreadPool, не отдельные threads).

---

### Подэтап 1.2 — Stderr drain

**Что сделать:**
1. В [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas) после `CreateProcessW` (после Step 9 или параллельно со Step 10) сделать дренаж stderr:
   - Создать буфер фиксированного размера (например, 8 КБ)
   - Циклом `PeekNamedPipe`+`ReadFile` (синхронно, по аналогии со Step 10 stdout) пока не получим `ERROR_BROKEN_PIPE` или процесс не завершится
   - Накопленный stderr передать в Logger через `LogWriteEntry(LogEntryType.Warning, WStr("CGI stderr"), pVariantWithStderrText)`

   **Проще:** добавить отдельный thread через `CreateThread` который дренажит stderr и пишет в Logger. Этот thread должен завершаться когда `hStderrRead` закрывается родителем.

2. В [src/CgiProcess.bas](src/CgiProcess.bas) добавить `CloseHandle(hStderrRead)` в `CloseHandles()` (уже есть, проверить что закрытие происходит).

**Коммит:** `CGI: drain stderr to log (was being ignored)`

**Обоснование task.md:**
> - Получение ответа от CGI-скрипта и передача его клиенту
> - **Логирование ошибок выполнения CGI**

**Гразиблы:**
- stderr нельзя оставлять полностью открытым: если скрипт пишет >4 КБ в stderr, write блокируется на скрипте. Дренаж обязателен.
- Не блокируй worker thread синхронным ReadFile на stderr — либо отдельный thread, либо PeekNamedPipe (non-blocking).

---

### Подэтап 1.3 — Allowed CGI directories

**Что сделать:**
1. Расширить [src/IWebSite.bi](src/IWebSite.bi):
   - Добавить `GetCgiAllowedDirectories(ppDirs As HeapBSTR Ptr) As HRESULT`
   - Добавить `SetCgiAllowedDirectories(pDirs As HeapBSTR) As HRESULT`
   - Vtable: добавить в КОНЕЦ (не нарушать порядок существующих методов)

2. В [src/WebSite.bas](src/WebSite.bas):
   - Добавить поле `CgiAllowedDirectories As HeapBSTR`
   - Реализовать геттер/сеттер
   - В деструкторе освободить через `HeapSysFreeString`

3. В [src/IniConfiguration.bas](src/IniConfiguration.bas):
   - Парсить ключ `CgiAllowedDirs` (формат: `/cgi-bin;/scripts;/dynamic`)
   - Если ключ отсутствует — по умолчанию разрешать **только `/cgi-bin`** (для обратной совместимости с тестами)

4. В [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas), в начале `HttpCgiProcessorPrepare`:
   - После определения SCRIPT_NAME — получить разрешённые директории из IWebSite
   - Проверить что SCRIPT_NAME начинается с одного из разрешённых префиксов
   - Если не разрешено — `IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.Forbidden)` и `Return CgiReturnErrorResponse(...)`. Статус 403.

5. В WebServer.ini / WebSites.ini добавить `CgiAllowedDirs=/cgi-bin` (если уже не так).

**Коммит:** `CGI: enforce allowed directories config (403 if not allowed)`

**Обоснование task.md:**
> - Настройка директорий, в которых разрешено выполнение CGI-скриптов

**Тестировать:** существующие тесты должны пройти 32/32 (все тесты используют `/cgi-bin/`). Дополнительный тест на `/random/script.py` → 403 не добавлять — это в фазе 3 если останется время, не обязательно.

---

### Подэтап 1.4 — Переход на named pipes (без OVERLAPPED)

**ВАЖНО:** Этот подэтап только **закладывает фундамент** для фазы 2. Pipes становятся named, но всё ещё работают синхронно. Тесты должны проходить как есть.

**Что сделать:**
В [src/CgiProcess.bas](src/CgiProcess.bas) в функции `StartProcess`:

1. Заменить `CreatePipe(@hReadStdin, @hWriteStdinLocal, @sa, 0)` на:
   ```
   - Генерировать уникальное имя: \\.\pipe\station922-cgi-<pid>-<atomicSeq>-stdin
     где atomicSeq инкрементируется через InterlockedIncrement
   - hWriteStdinLocal = CreateNamedPipeW(name,
                          PIPE_ACCESS_OUTBOUND,  // НЕ FILE_FLAG_OVERLAPPED пока!
                          PIPE_TYPE_BYTE | PIPE_WAIT,
                          1,           // max instances
                          65536, 65536,// out/in buffer
                          0,           // default timeout
                          NULL)        // default SA — не inheritable
   - hReadStdin = CreateFileW(name,
                     GENERIC_READ,
                     0,
                     @sa,              // inheritable
                     OPEN_EXISTING,
                     0,                // НЕ FILE_FLAG_OVERLAPPED — child stdin sync
                     NULL)
   ```
   (Аналогично для stdout и stderr — но направления противоположные: stdout это `PIPE_ACCESS_INBOUND` для read-end, и `CreateFileW(GENERIC_WRITE)` для child write-end.)

2. Оставить всё остальное как есть: STARTUPINFO, CreateProcessW, CloseHandle child ends.

3. Критическая секция вокруг pipe creation + CreateProcess (уже есть, не трогать).

**Зачем уникальное имя:** named pipe — это глобальный объект NT. Если два параллельных CGI создают pipe с одним именем — второй получит `ERROR_PIPE_BUSY`. PID процесса + atomic counter гарантируют уникальность.

**Коммит:** `CGI: switch to named pipes (sync mode, foundation for async)`

**Обоснование:** task.md требует pipes с OVERLAPPED. Анонимные pipes не поддерживают OVERLAPPED. Этот шаг переключает на named pipes, но оставляет синхронное чтение/запись. Фаза 2 включит `FILE_FLAG_OVERLAPPED` и привязку к IOCP.

**Тесты:** 32/32 должны пройти как и раньше.

**Грабли:**
- Имя pipe должно быть короче 256 символов
- Не забыть `@sa` (с inheritable) только для CLIENT-end, не для server
- Не указывать `FILE_FLAG_OVERLAPPED` ни в `CreateNamedPipeW`, ни в `CreateFileW` — иначе синхронный ReadFile поведёт себя странно
- `PIPE_WAIT` — синхронный режим (что нам и нужно сейчас)

---

## По завершении сессии

1. **Финальный прогон тестов 3 раза подряд** — 32/32 каждый раз.
2. **Обновить [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md):**
   - «Stderr не читается» — статус «соответствует»
   - «Список разрешённых директорий» — статус «соответствует»
   - «CgiAsyncTask.bas мёртвый код» — статус «удалён (будет заменён в фазе 2)»
3. Коммит обновлений TASK_COMPLIANCE.md.
4. Финальный push всех коммитов.
5. Доложить пользователю:
   - Какие подэтапы выполнены (1.1, 1.2, 1.3, 1.4)
   - Список коммитов
   - Статус тестов
   - Что осталось для фазы 2 (главное: `FILE_FLAG_OVERLAPPED` + IOCP + PipeAsyncStream + переписать Step 9/10)

## Правила работы

- Исходники .bas/.bi в **Windows-1251**. Кириллицу в новых строках не писать через Edit/Write — только ASCII. Комментарии на английском.
- Push после каждого коммита: `git push origin master`.
- Тривиальные ошибки компиляции — фиксить сразу. Нетривиальные — план + подтверждение пользователя.
- Если подэтап не сходится с 32/32 за 3 попытки — стоп, доложить пользователю с симптомами.

## Команды для копирования

**Билд + тест:**
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

**Ожидаемые warnings** (норма, игнорировать): `HttpCgiProcessor.bas warning 38`, `WebSite.bas(358/360) warning 3`.

## Ключевые файлы

- [task.md](task.md) — требования
- [TASK_COMPLIANCE.md](TASK_COMPLIANCE.md) — текущий статус
- [src/CgiProcess.bas](src/CgiProcess.bas) — главная точка изменений в подэтапе 1.4
- [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas) — Step 10 (stderr добавить), allowed dirs check в начале Prepare
- [src/IWebSite.bi](src/IWebSite.bi) + [src/WebSite.bas](src/WebSite.bas) — для allowed dirs
- [src/IniConfiguration.bas](src/IniConfiguration.bas) — парсинг новой настройки
- [test_cgi.py](test_cgi.py) — автотесты, должны давать 32/32
