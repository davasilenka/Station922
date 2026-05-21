#ifndef IHTTPCGIASYNCPROCESSOR_BI
#define IHTTPCGIASYNCPROCESSOR_BI

#include once "IHttpAsyncProcessor.bi"

Extern IID_IHttpCgiAsyncProcessor Alias "IID_IHttpCgiAsyncProcessor" As Const IID

Type IHttpCgiAsyncProcessor As IHttpCgiAsyncProcessor_

Type IHttpCgiAsyncProcessorVirtualTable

    QueryInterface As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr, _
        ByVal riid As REFIID, _
        ByVal ppvObject As Any Ptr Ptr _
    )As HRESULT

    AddRef As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr _
    )As ULONG

    Release As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr _
    )As ULONG

    Prepare As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr, _
        ByVal pContext As ProcessorContext Ptr, _
        ByVal ppIBuffer As IAttributedAsyncStream Ptr Ptr _
    )As HRESULT

    BeginProcess As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr, _
        ByVal pContext As ProcessorContext Ptr, _
        ByVal pcb As AsyncCallback, _
        ByVal StateObject As Any Ptr, _
        ByVal ppIAsyncResult As IAsyncResult Ptr Ptr _
    )As HRESULT

    EndProcess As Function( _
        ByVal self As IHttpCgiAsyncProcessor Ptr, _
        ByVal pContext As ProcessorContext Ptr, _
        ByVal pIAsyncResult As IAsyncResult Ptr _
    )As HRESULT

End Type

Type IHttpCgiAsyncProcessor_
    lpVtbl As IHttpCgiAsyncProcessorVirtualTable Ptr
End Type

#define IHttpCgiAsyncProcessor_QueryInterface(self, riid, ppv) (self)->lpVtbl->QueryInterface(self, riid, ppv)
#define IHttpCgiAsyncProcessor_AddRef(self) (self)->lpVtbl->AddRef(self)
#define IHttpCgiAsyncProcessor_Release(self) (self)->lpVtbl->Release(self)
#define IHttpCgiAsyncProcessor_Prepare(self, pContext, ppIBuffer) (self)->lpVtbl->Prepare(self, pContext, ppIBuffer)
#define IHttpCgiAsyncProcessor_BeginProcess(self, pContext, pcb, StateObject, ppIAsyncResult) (self)->lpVtbl->BeginProcess(self, pContext, pcb, StateObject, ppIAsyncResult)
#define IHttpCgiAsyncProcessor_EndProcess(self, pContext, pIAsyncResult) (self)->lpVtbl->EndProcess(self, pContext, pIAsyncResult)

#endif
