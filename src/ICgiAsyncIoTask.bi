#ifndef ICGIASYNCIOTASK_BI
#define ICGIASYNCIOTASK_BI

#include once "IAsyncIoTask.bi"

Extern IID_ICgiAsyncIoTask Alias "IID_ICgiAsyncIoTask" As Const IID

Type ICgiAsyncIoTask As ICgiAsyncIoTask_

Type ICgiAsyncIoTaskVirtualTable

    QueryInterface As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal riid As REFIID, _
        ByVal ppvObject As Any Ptr Ptr _
    )As HRESULT

    AddRef As Function( _
        ByVal self As ICgiAsyncIoTask Ptr _
    )As ULONG

    Release As Function( _
        ByVal self As ICgiAsyncIoTask Ptr _
    )As ULONG

    BeginExecute As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal pcb As AsyncCallback, _
        ByVal state As Any Ptr, _
        ByVal ppIResult As IAsyncResult Ptr Ptr _
    )As HRESULT

    EndExecute As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal pIResult As IAsyncResult Ptr _
    )As HRESULT

    GetReadPipeHandle As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal phRead As HANDLE Ptr _
    )As HRESULT

    SetReadPipeHandle As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal hRead As HANDLE _
    )As HRESULT

    GetWritePipeHandle As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal phWrite As HANDLE Ptr _
    )As HRESULT

    SetWritePipeHandle As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal hWrite As HANDLE _
    )As HRESULT

    GetBuffer As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal ppBuffer As BYTE Ptr Ptr _
    )As HRESULT

    SetBuffer As Function( _
        ByVal self As ICgiAsyncIoTask Ptr, _
        ByVal pBuffer As BYTE Ptr _
    )As HRESULT

End Type

Type ICgiAsyncIoTask_
    lpVtbl As ICgiAsyncIoTaskVirtualTable Ptr
End Type

#define ICgiAsyncIoTask_QueryInterface(self, riid, ppv) (self)->lpVtbl->QueryInterface(self, riid, ppv)
#define ICgiAsyncIoTask_AddRef(self) (self)->lpVtbl->AddRef(self)
#define ICgiAsyncIoTask_Release(self) (self)->lpVtbl->Release(self)
#define ICgiAsyncIoTask_BeginExecute(self, pcb, state, ppIResult) (self)->lpVtbl->BeginExecute(self, pcb, state, ppIResult)
#define ICgiAsyncIoTask_EndExecute(self, pIResult) (self)->lpVtbl->EndExecute(self, pIResult)
#define ICgiAsyncIoTask_GetReadPipeHandle(self, phRead) (self)->lpVtbl->GetReadPipeHandle(self, phRead)
#define ICgiAsyncIoTask_SetReadPipeHandle(self, hRead) (self)->lpVtbl->SetReadPipeHandle(self, hRead)
#define ICgiAsyncIoTask_GetWritePipeHandle(self, phWrite) (self)->lpVtbl->GetWritePipeHandle(self, phWrite)
#define ICgiAsyncIoTask_SetWritePipeHandle(self, hWrite) (self)->lpVtbl->SetWritePipeHandle(self, hWrite)
#define ICgiAsyncIoTask_GetBuffer(self, ppBuffer) (self)->lpVtbl->GetBuffer(self, ppBuffer)
#define ICgiAsyncIoTask_SetBuffer(self, pBuffer) (self)->lpVtbl->SetBuffer(self, pBuffer)

#endif
