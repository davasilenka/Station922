#ifndef CGIASYNCTASK_BI
#define CGIASYNCTASK_BI

#include once "ICgiAsyncIoTask.bi"
#include once "IAsyncResult.bi"
#include once "IThreadPool.bi"
#include once "windows.bi"

Extern CLSID_CGIREADSTDOUTASYNCTASK Alias "CLSID_CGIREADSTDOUTASYNCTASK" As Const CLSID
Extern CLSID_CGIWRITESTDINASYNCTASK Alias "CLSID_CGIWRITESTDINASYNCTASK" As Const CLSID

Const RTTI_ID_CGIREADSTDOUTASYNCTASK = !"\001ReadStdoutCgi\001"
Const RTTI_ID_CGIWRITESTDINASYNCTASK = !"\001WriteStdinCgi\001"

Type CgiReadStdoutAsyncTask
	#if __FB_DEBUG__
		RttiClassName(15) As UByte
	#endif
	lpVtbl As Const ICgiAsyncIoTaskVirtualTable Ptr
	ReferenceCounter As UInteger
	pIMemoryAllocator As IMalloc Ptr
	hPipeRead As HANDLE
	hPipeWrite As HANDLE
	pBuffer As BYTE Ptr
	dwBufSize As DWORD
	dwBytesRead As DWORD
	pResult As IAsyncResult Ptr
End Type

Type CgiWriteStdinAsyncTask
	#if __FB_DEBUG__
		RttiClassName(15) As UByte
	#endif
	lpVtbl As Const ICgiAsyncIoTaskVirtualTable Ptr
	ReferenceCounter As UInteger
	pIMemoryAllocator As IMalloc Ptr
	hPipeRead As HANDLE
	hPipeWrite As HANDLE
	pData As BYTE Ptr
	dwDataSize As DWORD
	dwBytesWritten As DWORD
	pResult As IAsyncResult Ptr
End Type

Declare Function CreateCgiReadStdoutAsyncTask( _
	ByVal pIMemoryAllocator As IMalloc Ptr, _
	ByVal hPipeRead As HANDLE, _
	ByVal dwBufSize As DWORD, _
	ByVal riid As REFIID, _
	ByVal ppv As Any Ptr Ptr _
)As HRESULT

Declare Function CreateCgiWriteStdinAsyncTask( _
	ByVal pIMemoryAllocator As IMalloc Ptr, _
	ByVal hPipeWrite As HANDLE, _
	ByVal pData As BYTE Ptr, _
	ByVal dwDataSize As DWORD, _
	ByVal riid As REFIID, _
	ByVal ppv As Any Ptr Ptr _
)As HRESULT

#endif
