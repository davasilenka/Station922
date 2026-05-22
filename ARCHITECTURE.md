# ARCHITECTURE.md — анализ для поддержки CGI в Station922

## 1. ПАТТЕРН ИНТЕРФЕЙСОВ

Все интерфейсы построены по общей схеме: структура с полем `lpVtbl`, указывающим на константную виртуальную таблицу (VTable).  
VTable содержит указатели на функции-методы, первым параметром получающие указатель на объект.  
Методы `QueryInterface` / `AddRef` / `Release` обязательны (IUnknown).  
Для доступа к полям объекта используется макрос `CONTAINING_RECORD`.

### 1.1 IHttpAsyncProcessor (`src\IHttpAsyncProcessor.bi`)

