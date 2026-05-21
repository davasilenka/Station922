#include once "CgiAsyncTask.bi"
#include once "AsyncResult.bi"
#include once "Logger.bi"
#include once "windows.bi"

Extern GlobalCgiReadStdoutAsyncTaskVirtualTable As Const ICgiAsyncIoTaskVirtualTable
Extern GlobalCgiWriteStdinAsyncTaskVirtualTable As Const ICgiAsyncIoTaskVirtualTable

Type CgiReadThreadData
	pTask As CgiReadStdoutAsyncTask Ptr
	pResult As IAsyncResult Ptr
End Type

Type CgiWriteThreadData
	pTask As CgiWriteStdinAsyncTask Ptr
	pResult As IAsyncResult Ptr
End Type

' -----------------------------------------------------------------------------
' CgiReadStdoutAsyncTask
' -----------------------------------------------------------------------------

Private Sub InitializeCgiReadStdoutAsyncTask( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal pIMemoryAllocator As IMalloc Ptr, _
		ByVal hPipeRead As HANDLE, _
		ByVal dwBufSize As DWORD _
	)

	#if __FB_DEBUG__
		CopyMemory( _
			@self->RttiClassName(0), _
			@Str(RTTI_ID_CGIREADSTDOUTASYNCTASK), _
			UBound(self->RttiClassName) - LBound(self->RttiClassName) + 1 _
		)
	#endif
	self->lpVtbl = @GlobalCgiReadStdoutAsyncTaskVirtualTable
	self->ReferenceCounter = 0
	IMalloc_AddRef(pIMemoryAllocator)
	self->pIMemoryAllocator = pIMemoryAllocator
	self->hPipeRead = hPipeRead
	self->hPipeWrite = NULL
	self->dwBufSize = dwBufSize
	self->dwBytesRead = 0
	self->pResult = NULL
	self->pBuffer = IMalloc_Alloc(pIMemoryAllocator, dwBufSize)

End Sub

Private Sub UnInitializeCgiReadStdoutAsyncTask( _
		ByVal self As CgiReadStdoutAsyncTask Ptr _
	)

	If self->pBuffer Then
		IMalloc_Free(self->pIMemoryAllocator, self->pBuffer)
	End If

	If self->pResult Then
		IAsyncResult_Release(self->pResult)
	End If

End Sub

Private Sub DestroyCgiReadStdoutAsyncTask( _
		ByVal self As CgiReadStdoutAsyncTask Ptr _
	)

	Dim pIMemoryAllocator As IMalloc Ptr = self->pIMemoryAllocator

	UnInitializeCgiReadStdoutAsyncTask(self)

	IMalloc_Free(pIMemoryAllocator, self)

	IMalloc_Release(pIMemoryAllocator)

End Sub

Private Function CgiReadStdoutAsyncTaskAddRef( _
		ByVal self As CgiReadStdoutAsyncTask Ptr _
	)As ULONG

	self->ReferenceCounter += 1
	Return 1

End Function

Private Function CgiReadStdoutAsyncTaskRelease( _
		ByVal self As CgiReadStdoutAsyncTask Ptr _
	)As ULONG

	self->ReferenceCounter -= 1
	If self->ReferenceCounter Then
		Return 1
	End If

	DestroyCgiReadStdoutAsyncTask(self)
	Return 0

End Function

Private Function CgiReadStdoutAsyncTaskQueryInterface( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT

	If IsEqualIID(@IID_ICgiAsyncIoTask, riid) Then
		*ppv = @self->lpVtbl
	Else
		If IsEqualIID(@IID_IAsyncIoTask, riid) Then
			*ppv = @self->lpVtbl
		Else
			If IsEqualIID(@IID_IUnknown, riid) Then
				*ppv = @self->lpVtbl
			Else
				*ppv = NULL
				Return E_NOINTERFACE
			End If
		End If
	End If

	CgiReadStdoutAsyncTaskAddRef(self)
	Return S_OK

End Function

Public Function CreateCgiReadStdoutAsyncTask( _
		ByVal pIMemoryAllocator As IMalloc Ptr, _
		ByVal hPipeRead As HANDLE, _
		ByVal dwBufSize As DWORD, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT

	Dim self As CgiReadStdoutAsyncTask Ptr = IMalloc_Alloc( _
		pIMemoryAllocator, _
		SizeOf(CgiReadStdoutAsyncTask) _
	)

	If self Then
		InitializeCgiReadStdoutAsyncTask(self, pIMemoryAllocator, hPipeRead, dwBufSize)

		Dim hrQueryInterface As HRESULT = CgiReadStdoutAsyncTaskQueryInterface( _
			self, _
			riid, _
			ppv _
		)
		If FAILED(hrQueryInterface) Then
			DestroyCgiReadStdoutAsyncTask(self)
		End If

		Return hrQueryInterface
	End If

	*ppv = NULL
	Return E_OUTOFMEMORY

End Function


Private Function ReadPipeThreadProc( _
		ByVal lpParameter As LPVOID _
	)As DWORD

	Dim ptd As CgiReadThreadData Ptr = CPtr(CgiReadThreadData Ptr, lpParameter)
	Dim self As CgiReadStdoutAsyncTask Ptr = ptd->pTask
	Dim pRes As IAsyncResult Ptr = ptd->pResult

	Dim dwRead As DWORD = 0
	Dim dwError As DWORD = 0
	Dim bResult As BOOLEAN = ReadFile( _
		self->hPipeRead, _
		self->pBuffer, _
		self->dwBufSize, _
		@dwRead, _
		NULL _
	)

	If bResult = 0 Then
		dwError = GetLastError()
		Select Case dwError
			Case ERROR_BROKEN_PIPE, ERROR_HANDLE_EOF
				dwRead = 0
				dwError = 0
			Case Else
				LogWriteEntry(LogEntryType.Error, WStr("ReadFile failed"), NULL)
		End Select
	End If

	IAsyncResult_SetCompleted(pRes, dwRead, TRUE, dwError)
	self->dwBytesRead = dwRead

	Dim pcb As AsyncCallback = NULL
	IAsyncResult_GetAsyncCallback(pRes, @pcb)
	If pcb Then
		pcb(pRes)
	End If

	IAsyncResult_Release(pRes)
	CgiReadStdoutAsyncTaskRelease(self)

	IMalloc_Free(self->pIMemoryAllocator, ptd)

	Return 0

End Function

Private Function CgiReadStdoutAsyncTaskBeginExecute( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal StateObject As Any Ptr, _
		ByVal ppIResult As IAsyncResult Ptr Ptr _
	)As HRESULT

	Dim pResult As IAsyncResult Ptr = NULL
	Dim hrCreateResult As HRESULT = CreateAsyncResult( _
		self->pIMemoryAllocator, _
		@IID_IAsyncResult, _
		@pResult _
	)

	If FAILED(hrCreateResult) Then
		*ppIResult = NULL
		Return hrCreateResult
	End If

	IAsyncResult_SetAsyncStateWeakPtr(pResult, pcb, StateObject)

	Dim ptd As CgiReadThreadData Ptr = IMalloc_Alloc( _
		self->pIMemoryAllocator, _
		SizeOf(CgiReadThreadData) _
	)

	If ptd = NULL Then
		IAsyncResult_Release(pResult)
		*ppIResult = NULL
		Return E_OUTOFMEMORY
	End If

	ptd->pTask = self
	ptd->pResult = pResult

	CgiReadStdoutAsyncTaskAddRef(self)
	IAsyncResult_AddRef(pResult)

	Dim hThread As HANDLE = CreateThread( _
		NULL, _
		0, _
		@ReadPipeThreadProc, _
		ptd, _
		0, _
		NULL _
	)

	If hThread = NULL Then
		IAsyncResult_Release(pResult)
		CgiReadStdoutAsyncTaskRelease(self)
		IMalloc_Free(self->pIMemoryAllocator, ptd)
		*ppIResult = NULL
		Return E_FAIL
	End If

	CloseHandle(hThread)

	*ppIResult = pResult
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskEndExecute( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal pIResult As IAsyncResult Ptr _
	)As HRESULT

	Return S_OK

End Function

' ICgiAsyncIoTask methods for read task
Private Function CgiReadStdoutAsyncTaskGetReadPipeHandle( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal phRead As HANDLE Ptr _
	)As HRESULT

	*phRead = self->hPipeRead
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskSetReadPipeHandle( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal hRead As HANDLE _
	)As HRESULT

	If self->hPipeRead <> NULL And self->hPipeRead <> INVALID_HANDLE_VALUE Then
		CloseHandle(self->hPipeRead)
	End If
	self->hPipeRead = hRead
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskGetWritePipeHandle( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal phWrite As HANDLE Ptr _
	)As HRESULT

	*phWrite = self->hPipeWrite
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskSetWritePipeHandle( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal hWrite As HANDLE _
	)As HRESULT

	If self->hPipeWrite <> NULL And self->hPipeWrite <> INVALID_HANDLE_VALUE Then
		CloseHandle(self->hPipeWrite)
	End If
	self->hPipeWrite = hWrite
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskGetBuffer( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal ppBuffer As BYTE Ptr Ptr _
	)As HRESULT

	*ppBuffer = self->pBuffer
	Return S_OK

End Function

Private Function CgiReadStdoutAsyncTaskSetBuffer( _
		ByVal self As CgiReadStdoutAsyncTask Ptr, _
		ByVal pBuffer As BYTE Ptr _
	)As HRESULT

	If self->pBuffer Then
		IMalloc_Free(self->pIMemoryAllocator, self->pBuffer)
	End If
	self->pBuffer = pBuffer
	Return S_OK

End Function

' VTable for CgiReadStdoutAsyncTask
Private Function ICgiAsyncIoTask_QueryInterface_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal riid As REFIID, _
		ByVal ppvObject As Any Ptr Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskQueryInterface(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), riid, ppvObject)
End Function

Private Function ICgiAsyncIoTask_AddRef_Read( _
		ByVal self As ICgiAsyncIoTask Ptr _
	)As ULONG
	Return CgiReadStdoutAsyncTaskAddRef(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl))
End Function

Private Function ICgiAsyncIoTask_Release_Read( _
		ByVal self As ICgiAsyncIoTask Ptr _
	)As ULONG
	Return CgiReadStdoutAsyncTaskRelease(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl))
End Function

Private Function ICgiAsyncIoTask_BeginExecute_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal state As Any Ptr, _
		ByVal ppIResult As IAsyncResult Ptr Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskBeginExecute(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), pcb, state, ppIResult)
End Function

Private Function ICgiAsyncIoTask_EndExecute_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pIResult As IAsyncResult Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskEndExecute(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), pIResult)
End Function

Private Function ICgiAsyncIoTask_GetReadPipeHandle_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal phRead As HANDLE Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskGetReadPipeHandle(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), phRead)
End Function

Private Function ICgiAsyncIoTask_SetReadPipeHandle_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal hRead As HANDLE _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskSetReadPipeHandle(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), hRead)
End Function

Private Function ICgiAsyncIoTask_GetWritePipeHandle_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal phWrite As HANDLE Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskGetWritePipeHandle(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), phWrite)
End Function

Private Function ICgiAsyncIoTask_SetWritePipeHandle_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal hWrite As HANDLE _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskSetWritePipeHandle(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), hWrite)
End Function

Private Function ICgiAsyncIoTask_GetBuffer_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal ppBuffer As BYTE Ptr Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskGetBuffer(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), ppBuffer)
End Function

Private Function ICgiAsyncIoTask_SetBuffer_Read( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pBuffer As BYTE Ptr _
	)As HRESULT
	Return CgiReadStdoutAsyncTaskSetBuffer(CONTAINING_RECORD(self, CgiReadStdoutAsyncTask, lpVtbl), pBuffer)
End Function

Dim GlobalCgiReadStdoutAsyncTaskVirtualTable As Const ICgiAsyncIoTaskVirtualTable = Type( _
	@ICgiAsyncIoTask_QueryInterface_Read, _
	@ICgiAsyncIoTask_AddRef_Read, _
	@ICgiAsyncIoTask_Release_Read, _
	@ICgiAsyncIoTask_BeginExecute_Read, _
	@ICgiAsyncIoTask_EndExecute_Read, _
	@ICgiAsyncIoTask_GetReadPipeHandle_Read, _
	@ICgiAsyncIoTask_SetReadPipeHandle_Read, _
	@ICgiAsyncIoTask_GetWritePipeHandle_Read, _
	@ICgiAsyncIoTask_SetWritePipeHandle_Read, _
	@ICgiAsyncIoTask_GetBuffer_Read, _
	@ICgiAsyncIoTask_SetBuffer_Read _
)

' -----------------------------------------------------------------------------
' CgiWriteStdinAsyncTask
' -----------------------------------------------------------------------------

Private Sub InitializeCgiWriteStdinAsyncTask( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal pIMemoryAllocator As IMalloc Ptr, _
		ByVal hPipeWrite As HANDLE, _
		ByVal pData As BYTE Ptr, _
		ByVal dwDataSize As DWORD _
	)

	#if __FB_DEBUG__
		CopyMemory( _
			@self->RttiClassName(0), _
			@Str(RTTI_ID_CGIWRITESTDINASYNCTASK), _
			UBound(self->RttiClassName) - LBound(self->RttiClassName) + 1 _
		)
	#endif
	self->lpVtbl = @GlobalCgiWriteStdinAsyncTaskVirtualTable
	self->ReferenceCounter = 0
	IMalloc_AddRef(pIMemoryAllocator)
	self->pIMemoryAllocator = pIMemoryAllocator
	self->hPipeRead = NULL
	self->hPipeWrite = hPipeWrite
	self->pData = pData
	self->dwDataSize = dwDataSize
	self->dwBytesWritten = 0
	self->pResult = NULL

End Sub

Private Sub UnInitializeCgiWriteStdinAsyncTask( _
		ByVal self As CgiWriteStdinAsyncTask Ptr _
	)

	If self->pResult Then
		IAsyncResult_Release(self->pResult)
	End If

End Sub

Private Sub DestroyCgiWriteStdinAsyncTask( _
		ByVal self As CgiWriteStdinAsyncTask Ptr _
	)

	Dim pIMemoryAllocator As IMalloc Ptr = self->pIMemoryAllocator

	UnInitializeCgiWriteStdinAsyncTask(self)

	IMalloc_Free(pIMemoryAllocator, self)

	IMalloc_Release(pIMemoryAllocator)

End Sub

Private Function CgiWriteStdinAsyncTaskAddRef( _
		ByVal self As CgiWriteStdinAsyncTask Ptr _
	)As ULONG

	self->ReferenceCounter += 1
	Return 1

End Function

Private Function CgiWriteStdinAsyncTaskRelease( _
		ByVal self As CgiWriteStdinAsyncTask Ptr _
	)As ULONG

	self->ReferenceCounter -= 1
	If self->ReferenceCounter Then
		Return 1
	End If

	DestroyCgiWriteStdinAsyncTask(self)
	Return 0

End Function

Private Function CgiWriteStdinAsyncTaskQueryInterface( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT

	If IsEqualIID(@IID_ICgiAsyncIoTask, riid) Then
		*ppv = @self->lpVtbl
	Else
		If IsEqualIID(@IID_IAsyncIoTask, riid) Then
			*ppv = @self->lpVtbl
		Else
			If IsEqualIID(@IID_IUnknown, riid) Then
				*ppv = @self->lpVtbl
			Else
				*ppv = NULL
				Return E_NOINTERFACE
			End If
		End If
	End If

	CgiWriteStdinAsyncTaskAddRef(self)
	Return S_OK

End Function

Public Function CreateCgiWriteStdinAsyncTask( _
		ByVal pIMemoryAllocator As IMalloc Ptr, _
		ByVal hPipeWrite As HANDLE, _
		ByVal pData As BYTE Ptr, _
		ByVal dwDataSize As DWORD, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT

	Dim self As CgiWriteStdinAsyncTask Ptr = IMalloc_Alloc( _
		pIMemoryAllocator, _
		SizeOf(CgiWriteStdinAsyncTask) _
	)

	If self Then
		InitializeCgiWriteStdinAsyncTask(self, pIMemoryAllocator, hPipeWrite, pData, dwDataSize)

		Dim hrQueryInterface As HRESULT = CgiWriteStdinAsyncTaskQueryInterface( _
			self, _
			riid, _
			ppv _
		)
		If FAILED(hrQueryInterface) Then
			DestroyCgiWriteStdinAsyncTask(self)
		End If

		Return hrQueryInterface
	End If

	*ppv = NULL
	Return E_OUTOFMEMORY

End Function

Private Function WritePipeThreadProc( _
		ByVal lpParameter As LPVOID _
	)As DWORD

	Dim ptd As CgiWriteThreadData Ptr = CPtr(CgiWriteThreadData Ptr, lpParameter)
	Dim self As CgiWriteStdinAsyncTask Ptr = ptd->pTask
	Dim pRes As IAsyncResult Ptr = ptd->pResult

	Dim dwWritten As DWORD = 0
	Dim dwError As DWORD = 0
	Dim bResult As BOOLEAN = WriteFile( _
		self->hPipeWrite, _
		self->pData, _
		self->dwDataSize, _
		@dwWritten, _
		NULL _
	)

	If bResult = 0 Then
		dwError = GetLastError()
		LogWriteEntry(LogEntryType.Error, WStr("WriteFile to stdin pipe failed"), NULL)
	End If

	CloseHandle(self->hPipeWrite)
	self->hPipeWrite = NULL

	IAsyncResult_SetCompleted(pRes, dwWritten, TRUE, dwError)
	self->dwBytesWritten = dwWritten

	Dim pcb As AsyncCallback = NULL
	IAsyncResult_GetAsyncCallback(pRes, @pcb)
	If pcb Then
		pcb(pRes)
	End If

	IAsyncResult_Release(pRes)
	CgiWriteStdinAsyncTaskRelease(self)

	IMalloc_Free(self->pIMemoryAllocator, ptd)

	Return 0

End Function

Private Function CgiWriteStdinAsyncTaskBeginExecute( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal StateObject As Any Ptr, _
		ByVal ppIResult As IAsyncResult Ptr Ptr _
	)As HRESULT

	Dim pResult As IAsyncResult Ptr = NULL
	Dim hrCreateResult As HRESULT = CreateAsyncResult( _
		self->pIMemoryAllocator, _
		@IID_IAsyncResult, _
		@pResult _
	)

	If FAILED(hrCreateResult) Then
		*ppIResult = NULL
		Return hrCreateResult
	End If

	IAsyncResult_SetAsyncStateWeakPtr(pResult, pcb, StateObject)

	Dim ptd As CgiWriteThreadData Ptr = IMalloc_Alloc( _
		self->pIMemoryAllocator, _
		SizeOf(CgiWriteThreadData) _
	)

	If ptd = NULL Then
		IAsyncResult_Release(pResult)
		*ppIResult = NULL
		Return E_OUTOFMEMORY
	End If

	ptd->pTask = self
	ptd->pResult = pResult

	CgiWriteStdinAsyncTaskAddRef(self)
	IAsyncResult_AddRef(pResult)

	Dim hThread As HANDLE = CreateThread( _
		NULL, _
		0, _
		@WritePipeThreadProc, _
		ptd, _
		0, _
		NULL _
	)

	If hThread = NULL Then
		IAsyncResult_Release(pResult)
		CgiWriteStdinAsyncTaskRelease(self)
		IMalloc_Free(self->pIMemoryAllocator, ptd)
		*ppIResult = NULL
		Return E_FAIL
	End If

	CloseHandle(hThread)

	*ppIResult = pResult
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskEndExecute( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal pIResult As IAsyncResult Ptr _
	)As HRESULT

	Return S_OK

End Function

' ICgiAsyncIoTask methods for write task
Private Function CgiWriteStdinAsyncTaskGetReadPipeHandle( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal phRead As HANDLE Ptr _
	)As HRESULT

	*phRead = self->hPipeRead
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskSetReadPipeHandle( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal hRead As HANDLE _
	)As HRESULT

	If self->hPipeRead <> NULL And self->hPipeRead <> INVALID_HANDLE_VALUE Then
		CloseHandle(self->hPipeRead)
	End If
	self->hPipeRead = hRead
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskGetWritePipeHandle( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal phWrite As HANDLE Ptr _
	)As HRESULT

	*phWrite = self->hPipeWrite
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskSetWritePipeHandle( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal hWrite As HANDLE _
	)As HRESULT

	If self->hPipeWrite <> NULL And self->hPipeWrite <> INVALID_HANDLE_VALUE Then
		CloseHandle(self->hPipeWrite)
	End If
	self->hPipeWrite = hWrite
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskGetBuffer( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal ppBuffer As BYTE Ptr Ptr _
	)As HRESULT

	*ppBuffer = self->pData
	Return S_OK

End Function

Private Function CgiWriteStdinAsyncTaskSetBuffer( _
		ByVal self As CgiWriteStdinAsyncTask Ptr, _
		ByVal pBuffer As BYTE Ptr _
	)As HRESULT

	If self->pData Then
		IMalloc_Free(self->pIMemoryAllocator, self->pData)
	End If
	self->pData = pBuffer
	Return S_OK

End Function

' VTable for CgiWriteStdinAsyncTask
Private Function ICgiAsyncIoTask_QueryInterface_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal riid As REFIID, _
		ByVal ppvObject As Any Ptr Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskQueryInterface(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), riid, ppvObject)
End Function

Private Function ICgiAsyncIoTask_AddRef_Write( _
		ByVal self As ICgiAsyncIoTask Ptr _
	)As ULONG
	Return CgiWriteStdinAsyncTaskAddRef(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl))
End Function

Private Function ICgiAsyncIoTask_Release_Write( _
		ByVal self As ICgiAsyncIoTask Ptr _
	)As ULONG
	Return CgiWriteStdinAsyncTaskRelease(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl))
End Function

Private Function ICgiAsyncIoTask_BeginExecute_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal state As Any Ptr, _
		ByVal ppIResult As IAsyncResult Ptr Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskBeginExecute(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), pcb, state, ppIResult)
End Function

Private Function ICgiAsyncIoTask_EndExecute_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pIResult As IAsyncResult Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskEndExecute(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), pIResult)
End Function

Private Function ICgiAsyncIoTask_GetReadPipeHandle_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal phRead As HANDLE Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskGetReadPipeHandle(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), phRead)
End Function

Private Function ICgiAsyncIoTask_SetReadPipeHandle_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal hRead As HANDLE _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskSetReadPipeHandle(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), hRead)
End Function

Private Function ICgiAsyncIoTask_GetWritePipeHandle_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal phWrite As HANDLE Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskGetWritePipeHandle(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), phWrite)
End Function

Private Function ICgiAsyncIoTask_SetWritePipeHandle_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal hWrite As HANDLE _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskSetWritePipeHandle(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), hWrite)
End Function

Private Function ICgiAsyncIoTask_GetBuffer_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal ppBuffer As BYTE Ptr Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskGetBuffer(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), ppBuffer)
End Function

Private Function ICgiAsyncIoTask_SetBuffer_Write( _
		ByVal self As ICgiAsyncIoTask Ptr, _
		ByVal pBuffer As BYTE Ptr _
	)As HRESULT
	Return CgiWriteStdinAsyncTaskSetBuffer(CONTAINING_RECORD(self, CgiWriteStdinAsyncTask, lpVtbl), pBuffer)
End Function

Dim GlobalCgiWriteStdinAsyncTaskVirtualTable As Const ICgiAsyncIoTaskVirtualTable = Type( _
	@ICgiAsyncIoTask_QueryInterface_Write, _
	@ICgiAsyncIoTask_AddRef_Write, _
	@ICgiAsyncIoTask_Release_Write, _
	@ICgiAsyncIoTask_BeginExecute_Write, _
	@ICgiAsyncIoTask_EndExecute_Write, _
	@ICgiAsyncIoTask_GetReadPipeHandle_Write, _
	@ICgiAsyncIoTask_SetReadPipeHandle_Write, _
	@ICgiAsyncIoTask_GetWritePipeHandle_Write, _
	@ICgiAsyncIoTask_SetWritePipeHandle_Write, _
	@ICgiAsyncIoTask_GetBuffer_Write, _
	@ICgiAsyncIoTask_SetBuffer_Write _
)
