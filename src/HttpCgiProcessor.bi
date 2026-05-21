#ifndef HTTPCGIPROCESSOR_BI
#define HTTPCGIPROCESSOR_BI

#include once "IHttpCgiAsyncProcessor.bi"
#include once "IWebSite.bi"
#include once "IThreadPool.bi"

Extern CLSID_HTTPCGIPROCESSOR Alias "CLSID_HTTPCGIPROCESSOR" As Const CLSID

Const RTTI_ID_HTTPCGIPROCESSOR = !"\001Cgi________Proc\001"

Declare Function CreateHttpCgiProcessor( _
    ByVal pIMemoryAllocator As IMalloc Ptr, _
    ByVal riid As REFIID, _
    ByVal ppv As Any Ptr Ptr _
)As HRESULT

#endif
