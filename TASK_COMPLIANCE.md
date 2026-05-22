# Соответствие реализации требованиям task.md

Документ фиксирует, какие требования из [task.md](task.md) выполнены полностью, какие частично, а какие не выполнены. Все ссылки указывают на коммит `d35997f` (master, 32/32 тестов проходят).

## Сводная таблица

| Раздел task.md | Статус |
|---|---|
| Базовая поддержка CGI | соответствует |
| Обработка ответа CGI | соответствует |
| Управление процессами | соответствует |
| Архитектурные требования (структура модулей) | частично |
| Асинхронный ввод-вывод | **не соответствует** |
| Технические детали (OVERLAPPED, IOCP для pipes) | **не соответствует** |
| Безопасность и конфигурация | частично |
| Обработка ошибок | соответствует |
| Критерии приёмки (функциональные) | соответствует (32/32 теста) |

---

## Что соответствует полностью

**Базовая поддержка CGI** — [src/HttpCgiProcessor.bas](src/HttpCgiProcessor.bas)
- Выполнение CGI по расширениям файлов (.py, .exe, .cgi, .pl, .php) — настраивается через `CgiExtensions`
- Все обязательные переменные окружения: `GATEWAY_INTERFACE`, `SERVER_NAME`, `SERVER_PORT`, `SERVER_PROTOCOL`, `SERVER_SOFTWARE`, `REQUEST_METHOD`, `QUERY_STRING`, `CONTENT_TYPE`, `CONTENT_LENGTH`, `SCRIPT_NAME`, `PATH_INFO`, `PATH_TRANSLATED`, `REMOTE_ADDR`, `REMOTE_HOST`, `REMOTE_IDENT`, `REMOTE_USER`, `AUTH_TYPE`, `HTTP_*` ([HttpCgiProcessor.bas:427-577](src/HttpCgiProcessor.bas#L427-L577))
- Передача POST/PUT тела в stdin процесса
- Получение ответа от CGI и передача клиенту

**Обработка ответа CGI**
- Парсинг заголовков формата `Header: Value`
- Обработка `Status:` для HTTP-статуса
- Обработка `Content-Type`, `Location`
- Поддержка NPH (скрипты с префиксом `nph-`) — [HttpCgiProcessor.bas:1098-1108](src/HttpCgiProcessor.bas#L1098-L1108)
- Передача тела ответа клиенту через `IHttpAsyncWriter`

**Управление процессами**
- Настраиваемый таймаут CGI (`CgiTimeout`)
- Принудительное завершение по таймауту через `TerminateProcess` — [HttpCgiProcessor.bas:1000-1007](src/HttpCgiProcessor.bas#L1000-L1007)
- Лимит размера вывода CGI (`CgiMaxOutputSize`)

**Обработка ошибок**
- 500 — невозможность запуска CGI
- 502 (Bad Gateway) — CGI завершился с ошибкой
- 504 (Gateway Timeout) — превышение таймаута
- Логирование ошибок через `LogCgiEvent`

**Критерии приёмки (функциональные)** — 32 из 32 тестов в [test_cgi.py](test_cgi.py) проходят стабильно (Python CGI, GET, POST, query string, HTTP headers, Status header, NPH-подобные, timeout, большой вывод, параллельные запросы).

---

## Что соответствует частично

**Архитектурные требования — структура модулей**

task.md требует:
- `CgiProcess.bas/bi` — есть, используется ([src/CgiProcess.bas](src/CgiProcess.bas))
- `CgiAsyncTask.bas/bi` — **файл существует, но не подключён**: ни одна функция из [CgiAsyncTask.bas](src/CgiAsyncTask.bas) не вызывается из `HttpCgiProcessor.bas`. Это мёртвый код.
- `HttpCgiProcessor.bas/bi` — есть, используется
- Расширение `IWebSite` для CGI-конфигурации — есть ([IWebSite.bi:200-262](src/IWebSite.bi#L200-L262))
- Расширение парсера INI — есть

**Безопасность и конфигурация**

| Требование | Статус |
|---|---|
| Настройка расширений CGI | есть (`CgiExtensions`) |
| Указание интерпретатора | есть (`CgiInterpreter`) |
| Таймаут | есть (`CgiTimeout`) |
| Лимит входных данных | есть (`CgiMaxInputSize`) |
| Лимит выходных данных | есть (`CgiMaxOutputSize`) |
| Включение/отключение CGI на сайт | есть (`CgiEnabled`) |
| **Список разрешённых директорий для CGI** | **отсутствует** |
| chroot/jail (помечено как опционально в task.md) | не реализовано — допустимо |

---

## Что не соответствует

### 1. Асинхронный ввод-вывод для pipes

task.md требует:
> - Использование асинхронных pipes для передачи данных в stdin и из stdout/stderr CGI-процесса
> - Интеграция с существующей системой async I/O сервера (`IAsyncIoTask`, `IBaseAsyncStream`)
> - Асинхронное чтение вывода CGI-скрипта без блокировки рабочих потоков
> - Использование пула потоков (`ThreadPool`) для асинхронных операций с pipes

Реальность ([HttpCgiProcessor.bas:993-1054](src/HttpCgiProcessor.bas#L993-L1054)):
- Stdout читается **синхронно** в worker-потоке: цикл `PeekNamedPipe` + `ReadFile` + `Sleep(10)`.
- Worker-поток заблокирован на всё время выполнения CGI-скрипта.
- При `WorkerThreads=8` это означает максимум 8 одновременных CGI; функционально проходит, но «без блокировки рабочих потоков» формально нарушено.

### 2. Технические детали — Windows API для async pipes

task.md требует:
> - `ReadFile`/`WriteFile` с **OVERLAPPED** структурами
> - `CreateIoCompletionPort` для асинхронного ввода-вывода

Реальность:
- В [CgiProcess.bas:41-72](src/CgiProcess.bas#L41-L72) pipes создаются через `CreatePipe` (анонимные pipes). Windows физически не поддерживает `FILE_FLAG_OVERLAPPED` для анонимных pipes.
- Для настоящего async требуются **named pipes** (`CreateNamedPipeW`) с `FILE_FLAG_OVERLAPPED` и привязкой к IOCP. Не реализовано.
- `OVERLAPPED` структуры для pipe I/O нигде не используются.

### 3. Stderr игнорируется

В [CgiProcess.bas:50-72](src/CgiProcess.bas#L50-L72) создаётся pipe для stderr и хранится handle `hStderrRead`, но **ни одна функция его не читает**. Если CGI-скрипт пишет в stderr больше размера буфера pipe (~4 КБ) — скрипт повиснет. task.md требует «Логирование ошибок выполнения CGI» — stderr в лог не попадает.

---

## Замечание

Расхождения по разделам «Асинхронный ввод-вывод» и «Технические детали» — это **архитектурные требования** task.md. По разделу «Критерии приёмки» (функциональные тесты) реализация соответствует полностью.
