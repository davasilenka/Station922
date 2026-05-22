#include once "HttpCgiProcessor.bi"
#include once "CharacterConstants.bi"
#include once "HeapBSTR.bi"
#include once "WebUtils.bi"
#include once "windows.bi"
#include once "win\shlwapi.bi"
#include once "crt.bi"
#include once "CgiProcess.bi"
#include once "Logger.bi"
#include once "ArrayStringWriter.bi"
#include once "MemoryAsyncStream.bi"
#include once "Mime.bi"

Extern GlobalHttpCgiProcessorVirtualTable As Const IHttpCgiAsyncProcessorVirtualTable

Const CompareResultEqual As Long = 0
Const MaxEnvBlockSize As Integer = 32768
Const MaxCgiBufferSize As Integer = 32768
Const NphPrefixLower = WStr("nph-")
Const NphPrefixLen As Integer = 4
Const CompareResultZero As Long = 0

' --------------- MemoryAttributedAsyncStream (for inline buffers) ---------------
Type MemoryAttributedAsyncStream
	#if __FB_DEBUG__
		RttiClassName(15) As UByte
	#endif
	lpVtbl As Const IAttributedAsyncStreamVirtualTable Ptr
	ReferenceCounter As UInteger
	pData As Byte Ptr
	cbData As DWORD
	MimeType As MimeType
End Type

Private Function MemoryStreamAddRef( _
		ByVal self As MemoryAttributedAsyncStream Ptr _
	)As ULONG
	self->ReferenceCounter += 1
	Return 1
End Function

Private Function MemoryStreamRelease( _
		ByVal self As MemoryAttributedAsyncStream Ptr _
	)As ULONG
	self->ReferenceCounter -= 1
	If self->ReferenceCounter = 0 Then
		HeapFree(GetProcessHeap(), 0, self)
	End If
	Return 1
End Function

Private Function MemoryStreamQueryInterface( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT
	If IsEqualIID(@IID_IAttributedAsyncStream, riid) Then
		*ppv = @self->lpVtbl
		MemoryStreamAddRef(self)
		Return S_OK
	Else
		If IsEqualIID(@IID_IUnknown, riid) Then
			*ppv = @self->lpVtbl
			MemoryStreamAddRef(self)
			Return S_OK
		Else
			*ppv = NULL
			Return E_NOINTERFACE
		End If
	End If
End Function

Private Function MemoryStreamGetLength( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pLength As LongInt Ptr _
	)As HRESULT
	*pLength = self->cbData
	Return S_OK
End Function

Private Function MemoryStreamGetContentType( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pMimeType As MimeType Ptr _
	)As HRESULT
	*pMimeType = self->MimeType
	Return S_OK
End Function

Private Function MemoryStreamGetLastFileModifiedDate( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pDate As FILETIME Ptr _
	)As HRESULT
	ZeroMemory(pDate, SizeOf(FILETIME))
	Return S_OK
End Function

Private Function MemoryStreamGetETag( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal ppETag As HeapBSTR Ptr _
	)As HRESULT
	*ppETag = NULL
	Return S_OK
End Function

Private Function MemoryStreamGetLanguage( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal ppLanguage As HeapBSTR Ptr _
	)As HRESULT
	*ppLanguage = NULL
	Return S_OK
End Function

Private Function MemoryStreamGetEncoding( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pZipMode As ZipModes Ptr _
	)As HRESULT
	*pZipMode = ZipModes.None
	Return S_OK
End Function

Private Function MemoryStreamBeginReadSlice( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal StartIndex As LongInt, _
		ByVal Length As LongInt, _
		ByVal pcb As AsyncCallback, _
		ByVal StateObject As Any Ptr, _
		ByVal ppIAsyncResult As IAsyncResult Ptr Ptr _
	)As HRESULT
	*ppIAsyncResult = NULL
	Return E_NOTIMPL
End Function

Private Function MemoryStreamEndReadSlice( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pIAsyncResult As IAsyncResult Ptr, _
		ByVal pBufferSlice As BufferSlice Ptr _
	)As HRESULT
	Return E_NOTIMPL
End Function

Private Function MemoryStreamGetPreloadedBytes( _
		ByVal self As MemoryAttributedAsyncStream Ptr, _
		ByVal pPreloadedBytesLength As UInteger Ptr, _
		ByVal ppPreloadedBytes As UByte Ptr Ptr _
	)As HRESULT
	*pPreloadedBytesLength = 0
	*ppPreloadedBytes = NULL
	Return S_OK
End Function

Dim Shared MemoryAttributedAsyncStreamVTable As IAttributedAsyncStreamVirtualTable = Type( _
	CPtr(Any Ptr, ProcPtr(MemoryStreamQueryInterface)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamAddRef)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamRelease)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamBeginReadSlice)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamEndReadSlice)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetContentType)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetEncoding)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetLanguage)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetETag)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetLastFileModifiedDate)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetLength)), _
	CPtr(Any Ptr, ProcPtr(MemoryStreamGetPreloadedBytes)) _
)

Private Function CreateMemoryAttributedAsyncStream( _
		ByVal pData As Byte Ptr, _
		ByVal cbData As DWORD, _
		ByVal pMime As MimeType Ptr _
	)As MemoryAttributedAsyncStream Ptr
	Dim self As MemoryAttributedAsyncStream Ptr = HeapAlloc(GetProcessHeap(), 0, SizeOf(MemoryAttributedAsyncStream))
	If self Then
		self->lpVtbl = @MemoryAttributedAsyncStreamVTable
		self->ReferenceCounter = 1
		self->pData = pData
		self->cbData = cbData
		If pMime Then
			self->MimeType = *pMime
		Else
			ZeroMemory(@self->MimeType, SizeOf(MimeType))
		End If
	End If
	Return self
End Function

' --------------- HttpCgiProcessor type ---------------
Type HttpCgiProcessor
	#if __FB_DEBUG__
		RttiClassName(15) As UByte
	#endif
	lpVtbl As Const IHttpCgiAsyncProcessorVirtualTable Ptr
	ReferenceCounter As UInteger
	pIMemoryAllocator As IMalloc Ptr
	pIWebSite As IWebSite Ptr
End Type

' --------------- Helper: map URL path to physical filesystem path ---------------
Private Function MapCgiPath( _
		ByVal pPhysicalDirectory As HeapBSTR, _
		ByVal pPath As HeapBSTR, _
		ByVal pBuffer As WString Ptr _
	)As HRESULT
	lstrcpyW(pBuffer, pPhysicalDirectory)
	Dim BufferLength As Integer = SysStringLen(pPhysicalDirectory)
	If BufferLength > 0 Then
		If pBuffer[BufferLength - 1] <> Characters.ReverseSolidus Then
			pBuffer[BufferLength] = Characters.ReverseSolidus
			pBuffer[BufferLength + 1] = 0
		End If
	End If
	Dim PathLength As Integer = SysStringLen(pPath)
	If PathLength > 0 Then
		If pPath[0] = Characters.Solidus Then
			lstrcatW(pBuffer, @pPath[1])
		Else
			lstrcatW(pBuffer, pPath)
		End If
	End If
	Dim FullLength As Integer = lstrlenW(pBuffer)
	For i As Integer = 0 To FullLength - 1
		If pBuffer[i] = Characters.Solidus Then
			pBuffer[i] = Characters.ReverseSolidus
		End If
	Next
	Return S_OK
End Function

' --------------- Helper: check if extension matches CGI extensions ---------------
Private Function IsCgiExtension( _
		ByVal pExtension As WString Ptr, _
		ByVal pExtensions As HeapBSTR _
	)As Boolean
	If pExtensions = NULL Then Return False
	If pExtension = NULL Then Return False
	If pExtension[0] = 0 Then Return False

	Dim ExtLen As Integer = lstrlenW(pExtension)
	Dim ExtensionsLen As Integer = SysStringLen(pExtensions)
	Dim i As Integer = 0
	Do While i < ExtensionsLen
		' Find start of next extension token
		Do While i < ExtensionsLen AndAlso pExtensions[i] = Characters.Comma
			i += 1
		Loop
		If i >= ExtensionsLen Then Exit Do
		Dim TokenStart As Integer = i
		Do While i < ExtensionsLen AndAlso pExtensions[i] <> Characters.Comma
			i += 1
		Loop
		Dim TokenLen As Integer = i - TokenStart
		If TokenLen = ExtLen Then
			If CompareStringW(LOCALE_USER_DEFAULT, NORM_IGNORECASE, _
				@pExtensions[TokenStart], TokenLen, _
				pExtension, ExtLen _
			) = CSTR_EQUAL Then
				Return True
			End If
		End If
	Loop
	Return False
End Function

' --------------- Helper: case-insensitive prefix check ---------------
Private Function StartsWithI( _
		ByVal pSource As WString Ptr, _
		ByVal pPrefix As WString Ptr, _
		ByVal PrefixLen As Integer _
	)As Boolean
	Dim CompareResult As Long = CompareStringW( _
		LOCALE_USER_DEFAULT, _
		NORM_IGNORECASE, _
		pSource, _
		PrefixLen, _
		pPrefix, _
		PrefixLen _
	)
	Return (CompareResult = CSTR_EQUAL)
End Function

' --------------- Helper: left-of-string check (case-insensitive) ---------------
Private Function LeftOfStrW( _
		ByVal pSource As WString Ptr, _
		ByVal pPattern As WString Ptr, _
		ByVal PatternLen As Integer _
	)As Boolean
	Dim CompareResult As Long = CompareStringW( _
		LOCALE_USER_DEFAULT, _
		NORM_IGNORECASE, _
		pSource, _
		PatternLen, _
		pPattern, _
		PatternLen _
	)
	Return (CompareResult = CSTR_EQUAL)
End Function

' --------------- Helper: check if path is in allowed directories ---------------
Private Function IsCgiPathAllowed( _
		ByVal pPhysicalPath As WString Ptr, _
		ByVal pAllowedDirs As HeapBSTR, _
		ByVal pBuf As WString Ptr _
	)As Boolean
	If pAllowedDirs = NULL Then Return True
	If SysStringLen(pAllowedDirs) = 0 Then Return True

	' Build physical path with trailing backslash
	lstrcpyW(pBuf, pPhysicalPath)
	Dim plen As Integer = lstrlenW(pBuf)
	If plen > 0 Then
		If pBuf[plen - 1] <> Characters.ReverseSolidus Then
			pBuf[plen] = Characters.ReverseSolidus
			pBuf[plen + 1] = 0
			plen += 1
		End If
	End If

	Dim DirsLen As Integer = SysStringLen(pAllowedDirs)
	Dim i As Integer = 0
	Do While i < DirsLen
		Do While i < DirsLen AndAlso pAllowedDirs[i] = Characters.Comma
			i += 1
		Loop
		If i >= DirsLen Then Exit Do
		Dim TokenStart As Integer = i
		Do While i < DirsLen AndAlso pAllowedDirs[i] <> Characters.Comma
			i += 1
		Loop
		Dim TokenLen As Integer = i - TokenStart
		If TokenLen > 0 Then
			Dim SearchPattern As WString * (MAX_PATH + 4) = Any
			SearchPattern[0] = Characters.ReverseSolidus
			CopyMemory(@SearchPattern[1], @pAllowedDirs[TokenStart], TokenLen * SizeOf(WString))
			SearchPattern[1 + TokenLen] = Characters.ReverseSolidus
			SearchPattern[1 + TokenLen + 1] = 0
			Dim PatternLen As Integer = TokenLen + 2
			If PatternLen <= plen Then
				Dim pFound As WString Ptr = FindStringIW(pBuf, plen, @SearchPattern, PatternLen)
				If pFound Then
					Return True
				End If
			End If
			If LeftOfStrW(pBuf, @pAllowedDirs[TokenStart], TokenLen) Then
				Return True
			End If
		End If
	Loop
	Return False
End Function

' --------------- Helper: map HttpRequestHeaders to CGI header name ---------------
Private Function GetCgiHeaderName( _
		ByVal HeaderIndex As HttpRequestHeaders _
	)As WString Ptr
	Select Case As Const HeaderIndex
		Case HttpRequestHeaders.HeaderCacheControl: Return @CgiHeaderCacheControlString
		Case HttpRequestHeaders.HeaderConnection: Return @CgiHeaderConnectionString
		Case HttpRequestHeaders.HeaderPragma: Return @CgiHeaderPragmaString
		Case HttpRequestHeaders.HeaderTrailer: Return @CgiHeaderTrailerString
		Case HttpRequestHeaders.HeaderTransferEncoding: Return @CgiHeaderTransferEncodingString
		Case HttpRequestHeaders.HeaderUpgrade: Return @CgiHeaderUpgradeString
		Case HttpRequestHeaders.HeaderVia: Return @CgiHeaderViaString
		Case HttpRequestHeaders.HeaderWarning: Return @CgiHeaderWarningString
		Case HttpRequestHeaders.HeaderAccept: Return @CgiHeaderAcceptString
		Case HttpRequestHeaders.HeaderAcceptCharset: Return @CgiHeaderAcceptCharsetString
		Case HttpRequestHeaders.HeaderAcceptEncoding: Return @CgiHeaderAcceptEncodingString
		Case HttpRequestHeaders.HeaderAcceptLanguage: Return @CgiHeaderAcceptLanguageString
		Case HttpRequestHeaders.HeaderAuthorization: Return @CgiHeaderAuthorizationString
		Case HttpRequestHeaders.HeaderCookie: Return @CgiHeaderCookieString
		Case HttpRequestHeaders.HeaderExpect: Return @CgiHeaderExpectString
		Case HttpRequestHeaders.HeaderDNT: Return @CgiHeaderDNTString
		Case HttpRequestHeaders.HeaderFrom: Return @CgiHeaderFromString
		Case HttpRequestHeaders.HeaderHost: Return @CgiHeaderHostString
		Case HttpRequestHeaders.HeaderIfMatch: Return @CgiHeaderIfMatchString
		Case HttpRequestHeaders.HeaderIfModifiedSince: Return @CgiHeaderIfModifiedSinceString
		Case HttpRequestHeaders.HeaderIfNoneMatch: Return @CgiHeaderIfNoneMatchString
		Case HttpRequestHeaders.HeaderIfRange: Return @CgiHeaderIfRangeString
		Case HttpRequestHeaders.HeaderIfUnModifiedSince: Return @CgiHeaderIfUnmodifiedSinceString
		Case HttpRequestHeaders.HeaderMaxForwards: Return @CgiHeaderMaxForwardsString
		Case HttpRequestHeaders.HeaderProxyAuthorization: Return @CgiHeaderProxyAuthorizationString
		Case HttpRequestHeaders.HeaderRange: Return @CgiHeaderRangeString
		Case HttpRequestHeaders.HeaderReferer: Return @CgiHeaderRefererString
		Case HttpRequestHeaders.HeaderTe: Return @CgiHeaderTeString
		Case HttpRequestHeaders.HeaderUserAgent: Return @CgiHeaderUserAgentString
		Case HttpRequestHeaders.HeaderKeepAlive: Return @CgiHeaderKeepAliveString
		Case HttpRequestHeaders.HeaderOrigin: Return @CgiHeaderOriginString
		Case HttpRequestHeaders.HeaderPurpose: Return NULL
		Case HttpRequestHeaders.HeaderSecWebSocketKey: Return @CgiHeaderSecWebSocketKeyString
		Case HttpRequestHeaders.HeaderSecWebSocketKey1: Return @CgiHeaderSecWebSocketKey1String
		Case HttpRequestHeaders.HeaderSecWebSocketKey2: Return @CgiHeaderSecWebSocketKey2String
		Case HttpRequestHeaders.HeaderSecWebSocketVersion: Return @CgiHeaderSecWebSocketVersionString
		Case HttpRequestHeaders.HeaderUpgradeInsecureRequests: Return @CgiHeaderUpgradeInsecureRequestsString
		Case HttpRequestHeaders.HeaderWebSocketProtocol: Return @CgiHeaderWebSocketProtocolString
		Case HttpRequestHeaders.HeaderContentEncoding: Return @CgiHeaderContentEncodingString
		Case HttpRequestHeaders.HeaderContentLanguage: Return @CgiHeaderContentLanguageString
		Case HttpRequestHeaders.HeaderContentLength: Return @CgiHeaderContentLengthString
		Case HttpRequestHeaders.HeaderContentMd5: Return @CgiHeaderContentMd5String
		Case HttpRequestHeaders.HeaderContentRange: Return @CgiHeaderContentRangeString
		Case HttpRequestHeaders.HeaderContentType: Return @CgiHeaderContentTypeString
		Case Else: Return NULL
	End Select
End Function

' --------------- Build CGI environment block ---------------
Private Function BuildCgiEnvironmentBlock( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pRequest As IClientRequest Ptr, _
		ByVal pPhysicalPath As WString Ptr, _
		ByVal pScriptName As HeapBSTR, _
		ByVal pQueryString As HeapBSTR, _
		ByVal ppszEnvBlock As WString Ptr Ptr _
	)As HRESULT

	Const CgiEnvbufSize As Integer = MaxEnvBlockSize

	Dim cgiBuffer As WString Ptr = IMalloc_Alloc(self->pIMemoryAllocator, CgiEnvbufSize * SizeOf(WString))
	If cgiBuffer = NULL Then
		*ppszEnvBlock = NULL
		Return E_OUTOFMEMORY
	End If

	Dim writer As ArrayStringWriter
	InitializeArrayStringWriter(@writer)
	writer.SetBuffer(cgiBuffer, CgiEnvbufSize)

	' Mandatory CGI variables
	writer.WriteString(WStr("GATEWAY_INTERFACE=CGI/1.1"))
	writer.WriteChar(0)
	writer.WriteString(WStr("SERVER_SOFTWARE=Station922/1.0"))
	writer.WriteChar(0)
	writer.WriteString(WStr("SERVER_PROTOCOL=HTTP/1.1"))
	writer.WriteChar(0)

	' AUTH_TYPE
	Scope
		Dim pAuth As HeapBSTR = Any
		IClientRequest_GetHttpHeader(pRequest, HttpRequestHeaders.HeaderAuthorization, @pAuth)
		If SysStringLen(pAuth) > 0 Then
			Const BasicPrefix = WStr("Basic ")
			If StartsWithI(pAuth, @BasicPrefix, Len(BasicPrefix)) Then
				writer.WriteString(WStr("AUTH_TYPE=Basic"))
			Else
				writer.WriteString(WStr("AUTH_TYPE="))
			End If
		Else
			writer.WriteString(WStr("AUTH_TYPE="))
		End If
		HeapSysFreeString(pAuth)
	End Scope
	writer.WriteChar(0)

	' CONTENT_LENGTH
	Scope
		Dim ContentLen As LongInt = Any
		IClientRequest_GetContentLength(pRequest, @ContentLen)
		writer.WriteString(WStr("CONTENT_LENGTH="))
		Dim clBuffer As WString * 32 = Any
		_ui64tow(ContentLen, @clBuffer, 10)
		writer.WriteString(@clBuffer)
	End Scope
	writer.WriteChar(0)

	' CONTENT_TYPE
	Scope
		Dim ContentType As HeapBSTR = Any
		IClientRequest_GetHttpHeader(pRequest, HttpRequestHeaders.HeaderContentType, @ContentType)
		writer.WriteString(WStr("CONTENT_TYPE="))
		If ContentType Then writer.WriteString(ContentType)
		HeapSysFreeString(ContentType)
	End Scope
	writer.WriteChar(0)

	' PATH_INFO (extra path after script name)
	writer.WriteString(WStr("PATH_INFO="))
	writer.WriteChar(0)

	' PATH_TRANSLATED
	writer.WriteString(WStr("PATH_TRANSLATED="))
	writer.WriteString(pPhysicalPath)
	writer.WriteChar(0)

	' QUERY_STRING
	writer.WriteString(WStr("QUERY_STRING="))
	If pQueryString Then writer.WriteString(pQueryString)
	writer.WriteChar(0)

	' REMOTE_ADDR, REMOTE_HOST, REMOTE_IDENT, REMOTE_USER
	writer.WriteString(WStr("REMOTE_ADDR="))
	writer.WriteChar(0)
	writer.WriteString(WStr("REMOTE_HOST="))
	writer.WriteChar(0)
	writer.WriteString(WStr("REMOTE_IDENT="))
	writer.WriteChar(0)
	writer.WriteString(WStr("REMOTE_USER="))
	writer.WriteChar(0)

	' REQUEST_METHOD
	Scope
		Dim HttpMethod As HeapBSTR = Any
		IClientRequest_GetHttpMethod(pRequest, @HttpMethod)
		writer.WriteString(WStr("REQUEST_METHOD="))
		If HttpMethod Then writer.WriteString(HttpMethod)
		HeapSysFreeString(HttpMethod)
	End Scope
	writer.WriteChar(0)

	' SCRIPT_NAME
	writer.WriteString(WStr("SCRIPT_NAME="))
	If pScriptName Then writer.WriteString(pScriptName)
	writer.WriteChar(0)

	' SERVER_NAME (from Host header)
	Scope
		Dim HostHeader As HeapBSTR = Any
		IClientRequest_GetHttpHeader(pRequest, HttpRequestHeaders.HeaderHost, @HostHeader)
		writer.WriteString(WStr("SERVER_NAME="))
		If HostHeader Then
			Dim pColon As WString Ptr = StrChrW(HostHeader, Characters.Colon)
			If pColon Then
				Dim HostLen As Integer = (Cast(Integer, pColon) - Cast(Integer, HostHeader)) \ 2
				If HostLen > 0 Then
					Dim SavedChar As WChar = HostHeader[HostLen]
					HostHeader[HostLen] = 0
					writer.WriteString(HostHeader)
					HostHeader[HostLen] = SavedChar
				Else
					writer.WriteString(WStr("localhost"))
				End If
			Else
				writer.WriteString(HostHeader)
			End If
		Else
			writer.WriteString(WStr("localhost"))
		End If
		HeapSysFreeString(HostHeader)
	End Scope
	writer.WriteChar(0)

	' SERVER_PORT
	Scope
		Dim HostHeader As HeapBSTR = Any
		IClientRequest_GetHttpHeader(pRequest, HttpRequestHeaders.HeaderHost, @HostHeader)
		If HostHeader Then
			Dim pColon As WString Ptr = StrChrW(HostHeader, Characters.Colon)
			If pColon Then
				writer.WriteString(WStr("SERVER_PORT="))
				writer.WriteString(@pColon[1])
			Else
				writer.WriteString(WStr("SERVER_PORT=80"))
			End If
		Else
			writer.WriteString(WStr("SERVER_PORT=80"))
		End If
		HeapSysFreeString(HostHeader)
	End Scope
	writer.WriteChar(0)

	' HTTP_* headers
	Dim HeaderIndex As HttpRequestHeaders
	For HeaderIndex = 0 To HttpRequestHeadersSize - 1
		Dim HeaderValue As HeapBSTR = Any
		IClientRequest_GetHttpHeader(pRequest, HeaderIndex, @HeaderValue)
		If HeaderValue Then
			If SysStringLen(HeaderValue) > 0 Then
				Dim cgiName As WString * 256 = Any
				Dim pKnown As WString Ptr = GetCgiHeaderName(HeaderIndex)
				If pKnown Then
					lstrcpyW(@cgiName, pKnown)
					writer.WriteString(@cgiName)
					writer.WriteChar(Characters.EqualsSign)
					writer.WriteString(HeaderValue)
					writer.WriteChar(0)
				End If
			End If
			HeapSysFreeString(HeaderValue)
		End If
	Next

	Dim cgiLenRaw As Integer = writer.GetLength()

	' Compact: remove trailing null from WriteChar(0) then copy null-terminated vars
	Dim cgiBuf As WString Ptr = IMalloc_Alloc(self->pIMemoryAllocator, (cgiLenRaw + 2) * SizeOf(WString))
	If cgiBuf = NULL Then
		IMalloc_Free(self->pIMemoryAllocator, cgiBuffer)
		*ppszEnvBlock = NULL
		Return E_OUTOFMEMORY
	End If

	Dim cgiPos As Integer = 0
	For i As Integer = 0 To cgiLenRaw - 1
		If cgiBuffer[i] = 0 Then
			If i > 0 AndAlso cgiBuffer[i - 1] = 0 Then
				' Skip extra null (WriteChar adds null after the explicit null)
			Else
				cgiBuf[cgiPos] = 0
				cgiPos += 1
			End If
		Else
			cgiBuf[cgiPos] = cgiBuffer[i]
			cgiPos += 1
		End If
	Next
	cgiBuf[cgiPos] = 0
	cgiPos += 1

	' Get parent process environment
	Dim pParentEnv As WString Ptr = GetEnvironmentStringsW()
	If pParentEnv = NULL Then
		IMalloc_Free(self->pIMemoryAllocator, cgiBuffer)
		IMalloc_Free(self->pIMemoryAllocator, cgiBuf)
		*ppszEnvBlock = NULL
		Return E_FAIL
	End If

	Dim parentLen As Integer = 0
	Dim pScan As WString Ptr = pParentEnv
	Do While *pScan <> 0
		Dim varLen As Integer = lstrlenW(pScan)
		parentLen += varLen + 1
		pScan += varLen + 1
	Loop
	parentLen += 1

	Dim totalLen As Integer = parentLen + cgiPos
	Dim pEnv As WString Ptr = IMalloc_Alloc(self->pIMemoryAllocator, totalLen * SizeOf(WString))
	If pEnv = NULL Then
		FreeEnvironmentStringsW(pParentEnv)
		IMalloc_Free(self->pIMemoryAllocator, cgiBuffer)
		IMalloc_Free(self->pIMemoryAllocator, cgiBuf)
		*ppszEnvBlock = NULL
		Return E_OUTOFMEMORY
	End If

	CopyMemory(pEnv, pParentEnv, (parentLen - 1) * SizeOf(WString))
	CopyMemory(@pEnv[parentLen - 1], cgiBuf, cgiPos * SizeOf(WString))
	pEnv[totalLen - 1] = 0

	FreeEnvironmentStringsW(pParentEnv)
	IMalloc_Free(self->pIMemoryAllocator, cgiBuffer)
	IMalloc_Free(self->pIMemoryAllocator, cgiBuf)
	*ppszEnvBlock = pEnv
	Return S_OK
End Function

' --------------- Log CGI event ---------------
Private Sub LogCgiEvent( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pwszText As WString Ptr, _
		ByVal Reason As LogEntryType _
	)
	Dim vd As VARIANT = Any
	VariantInit(@vd)
	LogWriteEntry(Reason, pwszText, @vd)
End Sub

' --------------- Helper: create an empty MemoryStream for error responses ---------------
Private Function CgiReturnErrorResponse( _
        ByVal pAlloc As IMalloc Ptr, _
        ByVal pResponse As IServerResponse Ptr, _
        ByVal pWriter As IHttpAsyncWriter Ptr, _
        ByVal ppIBuffer As IAttributedAsyncStream Ptr Ptr _
    )As HRESULT

    Dim pIMemoryBuf As IMemoryStream Ptr = Any
    Dim hrCreate As HRESULT = CreateMemoryStream(pAlloc, @IID_IMemoryStream, @pIMemoryBuf)
    If FAILED(hrCreate) Then
        *ppIBuffer = NULL
        Return S_OK
    End If

    Dim pBuf As Any Ptr = Any
    IMemoryStream_AllocBuffer(pIMemoryBuf, 0, @pBuf)

    Dim Mime As MimeType = Any
    With Mime
        .ContentType = ContentTypes.TextHtml
        .CharsetWeakPtr = NULL
        .Format = MimeFormats.Binary
    End With
    IMemoryStream_SetContentType(pIMemoryBuf, @Mime)

    IHttpAsyncWriter_SetBuffer(pWriter, CPtr(IAttributedAsyncStream Ptr, pIMemoryBuf))
    IHttpAsyncWriter_Prepare(pWriter, pResponse, 0, FileAccess.ReadAccess)

    *ppIBuffer = CPtr(IAttributedAsyncStream Ptr, pIMemoryBuf)
    Return S_OK
End Function

' --------------- Prepare (main CGI processing) ---------------
Private Function HttpCgiProcessorPrepare( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal ppIBuffer As IAttributedAsyncStream Ptr Ptr _
	)As HRESULT

	*ppIBuffer = NULL

	Dim pRequest As IClientRequest Ptr = pContext->pIRequest
	Dim pResponse As IServerResponse Ptr = pContext->pIResponse
	Dim pWriter As IHttpAsyncWriter Ptr = pContext->pIWriter
	Dim pReader As IHttpAsyncReader Ptr = pContext->pIReader
	Dim pWebSite As IWebSite Ptr = pContext->pIWebSite
	Dim pAlloc As IMalloc Ptr = pContext->pIMemoryAllocator

	self->pIWebSite = pWebSite
	IWebSite_AddRef(self->pIWebSite)

	' === Step 1: Check CGI enabled ===
	Dim CgiEnabled As BOOL = Any
	Scope
		Dim hrEnabled As HRESULT = IWebSite_GetCgiEnabled(pWebSite, @CgiEnabled)
		If FAILED(hrEnabled) OrElse CgiEnabled = FALSE Then
			IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.NotImplemented)
			Return E_NOTIMPL
		End If
	End Scope

	' === Step 2: Get URI path and check CGI extension ===
	Dim ScriptName As HeapBSTR = Any
	Dim QueryString As HeapBSTR = Any
	Scope
		Dim pClientUri As IClientUri Ptr = Any
		IClientRequest_GetUri(pRequest, @pClientUri)
		If pClientUri Then
			IClientUri_GetPath(pClientUri, @ScriptName)
			IClientUri_GetQuery(pClientUri, @QueryString)
			IClientUri_Release(pClientUri)
		End If
	End Scope

    If ScriptName = NULL Then
        IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.NotFound)
        Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
    End If

	' Check extension against CgiExtensions
	Scope
		Dim pExt As WString Ptr = PathFindExtensionW(ScriptName)

		Dim Extensions As HeapBSTR = Any
		IWebSite_GetCgiExtensions(pWebSite, @Extensions)

		If IsCgiExtension(pExt, Extensions) = FALSE Then
			HeapSysFreeString(Extensions)
			HeapSysFreeString(QueryString)
			HeapSysFreeString(ScriptName)
			IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.NotImplemented)
			Return E_NOTIMPL
		End If
		HeapSysFreeString(Extensions)
	End Scope

	' === Step 3: Map to physical path and check file existence ===
	Dim PhysicalDir As HeapBSTR = Any
	IWebSite_GetSitePhysicalDirectory(pWebSite, @PhysicalDir)

	Dim PhysicalPath As WString * (MAX_PATH + 1) = Any
	MapCgiPath(PhysicalDir, ScriptName, @PhysicalPath)
	HeapSysFreeString(PhysicalDir)

	' Check if file exists
	Dim FileAttrs As DWORD = GetFileAttributesW(@PhysicalPath)
    If FileAttrs = INVALID_FILE_ATTRIBUTES Then
        HeapSysFreeString(QueryString)
        HeapSysFreeString(ScriptName)
        IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.NotFound)
        Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
    End If

	' Check if it's a directory
    If FileAttrs And FILE_ATTRIBUTE_DIRECTORY Then
        HeapSysFreeString(QueryString)
        HeapSysFreeString(ScriptName)
        IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.Forbidden)
        Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
    End If

	' === Step 4: Check CgiAllowedDirs ===
	Scope
		Dim AllowedDirs As HeapBSTR = Any
		IWebSite_GetCgiAllowedDirs(pWebSite, @AllowedDirs)
		If AllowedDirs Then
			If SysStringLen(AllowedDirs) > 0 Then
				Dim PathBuf As WString * (MAX_PATH + 1) = Any
                If IsCgiPathAllowed(@PhysicalPath, AllowedDirs, @PathBuf) = FALSE Then
                    HeapSysFreeString(AllowedDirs)
                    HeapSysFreeString(QueryString)
                    HeapSysFreeString(ScriptName)
                    IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.Forbidden)
                    Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
                End If
			End If
			HeapSysFreeString(AllowedDirs)
		End If
	End Scope

	' === Step 5: Build environment block ===
	Dim pEnvBlock As WString Ptr = Any
	Scope
		Dim hrEnv As HRESULT = BuildCgiEnvironmentBlock( _
			self, _
			pRequest, _
			@PhysicalPath, _
			ScriptName, _
			QueryString, _
			@pEnvBlock _
		)
		HeapSysFreeString(QueryString)
		If FAILED(hrEnv) Then
			HeapSysFreeString(ScriptName)
			Return E_FAIL
		End If
	End Scope

	' === Step 6: Determine interpreter ===
	Dim Interpreter As HeapBSTR = Any
	Scope
		Dim pExt As WString Ptr = PathFindExtensionW(ScriptName)
		IWebSite_GetCgiInterpreter(pWebSite, pExt, @Interpreter)
	End Scope

	' === Step 7: Create and start CGI process ===
	Dim proc As CgiProcess Ptr = New CgiProcess
	If proc = NULL Then
		HeapSysFreeString(Interpreter)
		HeapSysFreeString(ScriptName)
		IMalloc_Free(self->pIMemoryAllocator, pEnvBlock)
		LogCgiEvent(self, WStr("Cannot allocate CgiProcess"), LogEntryType.Error)
		Return E_FAIL
	End If

	' Build process command line
	Dim pszExe As LPCWSTR = Any
	Dim pszArgs As LPWSTR = Any
	Dim ArgsBuffer As WString * (MAX_PATH * 2 + 32) = Any

	If Interpreter AndAlso SysStringLen(Interpreter) > 0 Then
		pszExe = NULL
		lstrcpyW(@ArgsBuffer, Interpreter)
		lstrcatW(@ArgsBuffer, WStr(" "))
		lstrcatW(@ArgsBuffer, @PhysicalPath)
		pszArgs = @ArgsBuffer
	Else
		pszExe = @PhysicalPath
		lstrcpyW(@ArgsBuffer, @PhysicalPath)
		pszArgs = @ArgsBuffer
	End If

	Dim WorkDir As WString * (MAX_PATH + 1) = Any
	' Set working directory to script's directory
	lstrcpyW(@WorkDir, @PhysicalPath)
	PathRemoveFileSpecW(@WorkDir)

	Dim hrStart As HRESULT = proc->StartProcess(pszExe, pszArgs, pEnvBlock, @WorkDir)
	IMalloc_Free(self->pIMemoryAllocator, pEnvBlock)
	HeapSysFreeString(Interpreter)

	If FAILED(hrStart) Then
		Delete proc
		HeapSysFreeString(ScriptName)
		LogCgiEvent(self, WStr("StartProcess failed"), LogEntryType.Error)
		Return E_FAIL
	End If

	' === Step 8: Get timeout and max output size ===
	Dim dwTimeout As DWORD = Any
	IWebSite_GetCgiTimeout(pWebSite, @dwTimeout)

	Dim dwMaxOutput As DWORD = Any
	IWebSite_GetCgiMaxOutputSize(pWebSite, @dwMaxOutput)

	' === Step 9: Write request body to stdin ===
	Dim ContentLen As LongInt = Any
	IClientRequest_GetContentLength(pRequest, @ContentLen)
	If ContentLen > 0 Then
		Dim dwTotalWritten As DWORD = 0

		Dim PreloadedLen As Integer = Any
		Dim pPreloadedBytes As UByte Ptr = Any
		IHttpAsyncReader_GetPreloadedBytes(pReader, @PreloadedLen, @pPreloadedBytes)
		If PreloadedLen > 0 AndAlso pPreloadedBytes Then
			Dim BytesWritten As DWORD = Any
			Dim dwToWrite As DWORD = Cast(DWORD, PreloadedLen)
			If Cast(DWORD, ContentLen) < dwToWrite Then dwToWrite = Cast(DWORD, ContentLen)
			WriteFile(proc->hStdinWrite, pPreloadedBytes, dwToWrite, @BytesWritten, NULL)
			dwTotalWritten = BytesWritten
		End If

		If dwTotalWritten < Cast(DWORD, ContentLen) Then
			Dim dwRemaining As DWORD = Cast(DWORD, ContentLen) - dwTotalWritten
			Dim pStream As IBaseAsyncStream Ptr = Any
			IHttpAsyncReader_GetBaseStream(pReader, @pStream)
			If pStream Then
				Dim pReadBuf As UByte Ptr = IMalloc_Alloc(self->pIMemoryAllocator, dwRemaining + 1)
				If pReadBuf Then
					Dim pAsyncResult As IAsyncResult Ptr = Any
					Dim hrBegin As HRESULT = IBaseAsyncStream_BeginRead( _
						pStream, pReadBuf, dwRemaining, NULL, NULL, @pAsyncResult)
					If SUCCEEDED(hrBegin) AndAlso pAsyncResult Then
						Dim bCompleted As Boolean = False
						Dim dwBytesRead As DWORD = 0
						Dim dwErr As DWORD = 0
						Dim dwPollStart As DWORD = GetTickCount()
						Do
							IAsyncResult_GetCompleted(pAsyncResult, @dwBytesRead, @bCompleted, @dwErr)
							If bCompleted = False Then
								' Bound the poll loop so a client that drops mid-upload doesn't hang a worker.
								If GetTickCount() - dwPollStart > 5000 Then Exit Do
								Sleep(5)
							End If
						Loop While bCompleted = False
						If dwBytesRead > 0 Then
							Dim bw As DWORD = Any
							If proc->hStdinWrite <> INVALID_HANDLE_VALUE Then
								WriteFile(proc->hStdinWrite, pReadBuf, dwBytesRead, @bw, NULL)
							End If
						End If
						IBaseAsyncStream_EndRead(pStream, pAsyncResult, @dwBytesRead)
					End If
					IMalloc_Free(self->pIMemoryAllocator, pReadBuf)
				End If
				IBaseAsyncStream_Release(pStream)
			End If
		End If

		CloseHandle(proc->hStdinWrite)
		proc->hStdinWrite = INVALID_HANDLE_VALUE
	Else
		CloseHandle(proc->hStdinWrite)
		proc->hStdinWrite = INVALID_HANDLE_VALUE
	End If

	' === Step 10: Read stdout concurrently with process execution ===
	Dim pOutputBuf As Byte Ptr = IMalloc_Alloc(self->pIMemoryAllocator, dwMaxOutput + 1)
	If pOutputBuf = NULL Then
		proc->Terminate()
		Delete proc
		HeapSysFreeString(ScriptName)
		LogCgiEvent(self, WStr("Cannot allocate output buffer"), LogEntryType.Error)
		Return E_FAIL
	End If

	Dim dwTotalRead As DWORD = 0
	Dim bReadOk As Boolean = True
	Dim bProcessExited As Boolean = False
	Dim startTicks As DWORD = GetTickCount()

	Do While dwTotalRead < dwMaxOutput
		' Check timeout first
		Dim dwElapsed As DWORD = GetTickCount() - startTicks
		If dwElapsed > dwTimeout Then
			proc->Terminate()
			Delete proc
			HeapSysFreeString(ScriptName)
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
            LogCgiEvent(self, WStr("CGI process timed out"), LogEntryType.Warning)
            IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.GatewayTimeout)
            Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
		End If

		' Check available data in pipe
		Dim dwAvail As DWORD = 0
        If PeekNamedPipe(proc->hStdoutRead, NULL, 0, NULL, @dwAvail, NULL) = 0 Then
            ' ERROR_BROKEN_PIPE means the child closed its stdout write end (EOF).
            ' Treat as a normal end-of-output condition; the drain ReadFile below
            ' will pull any buffered bytes and itself signal broken-pipe when done.
            If GetLastError() = ERROR_BROKEN_PIPE Then
                bProcessExited = True
                Exit Do
            End If
            If WaitForSingleObject(proc->hProcess, 0) = WAIT_OBJECT_0 Then
                bProcessExited = True
                Exit Do
            End If
            bReadOk = False
            Exit Do
        End If

		If dwAvail > 0 Then
			Dim dwRemaining As DWORD = dwMaxOutput - dwTotalRead
			Dim dwToRead As DWORD = dwAvail
			If dwToRead > dwRemaining Then dwToRead = dwRemaining
			Dim dwBytesRead As DWORD = Any
            If ReadFile(proc->hStdoutRead, @pOutputBuf[dwTotalRead], dwToRead, @dwBytesRead, NULL) = 0 Then
                Dim readErr As DWORD = GetLastError()
                If readErr = ERROR_BROKEN_PIPE Then
                    bProcessExited = True
                    Exit Do
                End If
                If WaitForSingleObject(proc->hProcess, 0) = WAIT_OBJECT_0 Then
                    bProcessExited = True
                    Exit Do
                End If
                bReadOk = False
                Exit Do
            End If
			If dwBytesRead = 0 Then
				Exit Do
			End If
			dwTotalRead += dwBytesRead
		Else
			' No data available - check if process has exited
			If WaitForSingleObject(proc->hProcess, 0) = WAIT_OBJECT_0 Then
				bProcessExited = True
				' Brief sleep to allow pipe to drain
				Sleep(1)
				Continue Do
			End If
			' Small sleep to avoid busy-waiting
			Sleep(10)
		End If
	Loop

    ' If process exited with zero output, skip pipe operations entirely
    ' (pipe may be in transitional state after process exit)
    If bProcessExited = FALSE OrElse dwTotalRead > 0 Then
        ' If process exited, drain any remaining data in pipe
        If bProcessExited Then
            Do While dwTotalRead < dwMaxOutput
                Dim dwBytesRead As DWORD = Any
                Dim dwRemaining As DWORD = dwMaxOutput - dwTotalRead
                Dim dwToRead As DWORD = 4096
                If dwToRead > dwRemaining Then dwToRead = dwRemaining
                If ReadFile(proc->hStdoutRead, @pOutputBuf[dwTotalRead], dwToRead, @dwBytesRead, NULL) = 0 Then
                    Dim drainErr As DWORD = GetLastError()
                    If drainErr = ERROR_BROKEN_PIPE Then Exit Do
                    If WaitForSingleObject(proc->hProcess, 0) = WAIT_OBJECT_0 Then Exit Do
                    bReadOk = False
                    Exit Do
                End If
                If dwBytesRead = 0 Then Exit Do
                dwTotalRead += dwBytesRead
            Loop
        End If

        ' Check if max output exceeded
        If bReadOk = FALSE Then
            IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
            proc->Terminate()
            Delete proc
            HeapSysFreeString(ScriptName)
            LogCgiEvent(self, WStr("CGI stdout read error"), LogEntryType.Error)
            Return E_FAIL
        End If

        ' Check if there's more data (process still has data but we exceeded max)
        If dwTotalRead >= dwMaxOutput Then
            Dim dwMoreBytes As DWORD = Any
            Dim dwAvail As DWORD = 0
            If PeekNamedPipe(proc->hStdoutRead, NULL, 0, NULL, @dwAvail, NULL) AndAlso dwAvail > 0 Then
                ' There is more data - exceed limit
                IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
                proc->Terminate()
                Delete proc
                HeapSysFreeString(ScriptName)
                LogCgiEvent(self, WStr("CGI output exceeded max size"), LogEntryType.Warning)
                Return E_FAIL
            End If
        End If
    End If

    ' Fast path: process exited with zero output - direct 502
    If bProcessExited AndAlso dwTotalRead = 0 Then
        Delete proc
        IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
        HeapSysFreeString(ScriptName)
        IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.BadGateway)
        Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
    End If

    pOutputBuf[dwTotalRead] = 0

	' === Step 11: Ensure process has exited (wait with short timeout) ===
	Scope
		Dim dwRemainingTimeout As DWORD = dwTimeout
		Dim dwElapsed As DWORD = GetTickCount() - startTicks
		If dwElapsed < dwTimeout Then
			dwRemainingTimeout = dwTimeout - dwElapsed
		Else
			dwRemainingTimeout = 0
		End If
		Dim bExited As Boolean = proc->WaitForExit(dwRemainingTimeout)
		If bExited = FALSE Then
			proc->Terminate()
			Delete proc
			HeapSysFreeString(ScriptName)
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
            LogCgiEvent(self, WStr("CGI process timed out after reading output"), LogEntryType.Warning)
            IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.GatewayTimeout)
            Return CgiReturnErrorResponse(pAlloc, pResponse, pWriter, ppIBuffer)
		End If
	End Scope

	' === Step 12: Find \r\n\r\n header separator ===
	Dim dwHeaderEnd As DWORD = CUInt(-1)
	If dwTotalRead >= 4 Then
		Dim maxSearch As DWORD = dwTotalRead - 3
		For i As DWORD = 0 To maxSearch
			If pOutputBuf[i] = 13 AndAlso pOutputBuf[i + 1] = 10 AndAlso _
			   pOutputBuf[i + 2] = 13 AndAlso pOutputBuf[i + 3] = 10 Then
				dwHeaderEnd = i
				Exit For
			End If
		Next
	End If

	' Check NPH (nph-* script)
	Dim bNph As Boolean = False
	Scope
		Dim pLastSlash As WString Ptr = StrRChrW(ScriptName, NULL, Characters.Solidus)
		Dim pFilename As WString Ptr = Any
		If pLastSlash Then
			pFilename = pLastSlash + 1
		Else
			pFilename = ScriptName
		End If
		If StartsWithI(pFilename, @NphPrefixLower, NphPrefixLen) Then
			bNph = True
		End If
	End Scope

	HeapSysFreeString(ScriptName)

	Dim pBodyData As Byte Ptr
	Dim dwBodyLen As DWORD

	If bNph Then
		' NPH: pass entire stdout as body
		pBodyData = pOutputBuf
		dwBodyLen = dwTotalRead
	Else
		' Standard CGI: parse headers and extract body
		If dwHeaderEnd = CUInt(-1) Then
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
			Delete proc
			LogCgiEvent(self, WStr("CGI output missing header separator"), LogEntryType.Error)
			Return E_FAIL
		End If

		' Parse CGI response headers
		Dim bHasStatus As Boolean = False
		Dim bHasLocation As Boolean = False
		Dim HeaderStart As DWORD = 0

		Dim ScanLimit As DWORD = dwHeaderEnd + 1
		Do While HeaderStart < dwHeaderEnd
			Dim LineEnd As DWORD = HeaderStart
			Do While LineEnd < ScanLimit
				If pOutputBuf[LineEnd] = 13 AndAlso pOutputBuf[LineEnd + 1] = 10 Then
					Exit Do
				End If
				LineEnd += 1
			Loop
			If LineEnd >= ScanLimit Then Exit Do

			pOutputBuf[LineEnd] = 0
			Dim pLine As ZString Ptr = CPtr(ZString Ptr, @pOutputBuf[HeaderStart])
			Dim LineLen As DWORD = LineEnd - HeaderStart

			If LineLen > 0 Then
				' Find colon separator
				Dim pColon As ZString Ptr = strchr(pLine, Asc(":"))
				If pColon Then
					' Skip whitespace after colon
					Dim pValue As ZString Ptr = pColon + 1
					Do While (*pValue = Asc(" ")) OrElse (*pValue = Asc(Chr(9)))
						pValue += 1
					Loop

					' Convert to WString for comparison
					Dim wName As WString * 128 = Any
					Dim wValue As WString * 1024 = Any
					Dim NameLen As DWORD = Cast(DWORD, pColon - pLine)
					Dim NameWcharsWritten As Integer = MultiByteToWideChar(CP_UTF8, 0, pLine, NameLen, @wName, 127)
					If NameWcharsWritten < 0 Then NameWcharsWritten = 0
					If NameWcharsWritten > 127 Then NameWcharsWritten = 127
					wName[NameWcharsWritten] = 0
					MultiByteToWideChar(CP_UTF8, 0, pValue, -1, @wValue, 1023)

					' Check Status header
					If lstrcmpiW(@wName, WStr("Status")) = CompareResultZero Then
						Dim iStatusCode As Integer = atoi(pValue)
						If iStatusCode >= 100 AndAlso iStatusCode <= 599 Then
							IServerResponse_SetStatusCode(pResponse, Cast(HttpStatusCodes, iStatusCode))
							bHasStatus = True
						End If
					ElseIf lstrcmpiW(@wName, WStr("Content-Type")) = CompareResultZero Then
						IServerResponse_AddResponseHeader( _
							pResponse, _
							CreateHeapStringLen(pAlloc, WStr("Content-Type"), 12), _
							CreateHeapStringLen(pAlloc, @wValue, lstrlenW(@wValue)) _
						)
					ElseIf lstrcmpiW(@wName, WStr("Location")) = CompareResultZero Then
						IServerResponse_AddResponseHeader( _
							pResponse, _
							CreateHeapStringLen(pAlloc, WStr("Location"), 8), _
							CreateHeapStringLen(pAlloc, @wValue, lstrlenW(@wValue)) _
						)
						IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.Found)
						bHasLocation = True
					Else
						' Pass other headers as-is
						IServerResponse_AddResponseHeader( _
							pResponse, _
							CreateHeapStringLen(pAlloc, @wName, lstrlenW(@wName)), _
							CreateHeapStringLen(pAlloc, @wValue, lstrlenW(@wValue)) _
						)
					End If
				End If
			End If

			HeaderStart = LineEnd + 2
		Loop

		' Set default status if none provided
		If bHasStatus = FALSE AndAlso bHasLocation = FALSE Then
			IServerResponse_SetStatusCode(pResponse, HttpStatusCodes.OK)
		End If

		' Body starts after \r\n\r\n separator (4 bytes)
		pBodyData = @pOutputBuf[dwHeaderEnd + 4]
		dwBodyLen = dwTotalRead - (dwHeaderEnd + 4)
	End If

	' === Step 13: Check exit code for errors ===
	Scope
		Dim dwExitCode As DWORD = proc->GetExitCode()
		If dwExitCode <> 0 AndAlso dwBodyLen = 0 AndAlso (Not bNph) Then
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
			Delete proc
			LogCgiEvent(self, WStr("CGI process exited with non-zero code and empty body"), LogEntryType.Error)
			Return E_FAIL
		End If
	End Scope

	' Clean up process (we already have the output)
	Delete proc

	' === Step 14: Build response buffer via IMemoryAsyncStream ===
	Dim pIMemoryBuf As IMemoryStream Ptr = Any
	Scope
		Dim hrCreateMem As HRESULT = CreateMemoryStream( _
			pAlloc, _
			@IID_IMemoryStream, _
			@pIMemoryBuf _
		)
		If FAILED(hrCreateMem) Then
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
			LogCgiEvent(self, WStr("Cannot create memory stream"), LogEntryType.Error)
			Return E_FAIL
		End If
	End Scope

	' Allocate and fill buffer
	Scope
		Dim pBuf As Any Ptr = Any
		Dim hrAlloc As HRESULT = IMemoryStream_AllocBuffer( _
			pIMemoryBuf, _
			dwBodyLen, _
			@pBuf _
		)
		If FAILED(hrAlloc) Then
			IMemoryStream_Release(pIMemoryBuf)
			IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)
			LogCgiEvent(self, WStr("Cannot allocate memory stream buffer"), LogEntryType.Error)
			Return E_FAIL
		End If

		If dwBodyLen > 0 Then
			CopyMemory(pBuf, pBodyData, dwBodyLen)
		End If
	End Scope

	' Set content type on memory stream
	Scope
		Dim Mime As MimeType = Any
		If bNph Then
			With Mime
				.ContentType = ContentTypes.TextHtml
				.CharsetWeakPtr = NULL
				.Format = MimeFormats.Binary
			End With
		Else
			' Parse Content-Type from CGI response headers — determine Mime
			Dim pContentTypeHeader As HeapBSTR = Any
			IServerResponse_GetHttpHeader(pResponse, HttpResponseHeaders.HeaderContentType, @pContentTypeHeader)
			If pContentTypeHeader Then
				If lstrcmpiW(pContentTypeHeader, WStr("text/plain")) = CompareResultZero Then
					Mime.ContentType = ContentTypes.TextPlain
				ElseIf lstrcmpiW(pContentTypeHeader, WStr("text/html")) = CompareResultZero Then
					Mime.ContentType = ContentTypes.TextHtml
				ElseIf lstrcmpiW(pContentTypeHeader, WStr("text/css")) = CompareResultZero Then
					Mime.ContentType = ContentTypes.TextCss
				ElseIf lstrcmpiW(pContentTypeHeader, WStr("text/xml")) = CompareResultZero Then
					Mime.ContentType = ContentTypes.TextXml
				Else
					Mime.ContentType = ContentTypes.TextHtml
				End If
				Mime.CharsetWeakPtr = NULL
				Mime.Format = MimeFormats.Binary
			Else
				With Mime
					.ContentType = ContentTypes.TextHtml
					.CharsetWeakPtr = NULL
					.Format = MimeFormats.Binary
				End With
			End If
		End If
		IMemoryStream_SetContentType(pIMemoryBuf, @Mime)
	End Scope

	' Free the temporary output buffer
	IMalloc_Free(self->pIMemoryAllocator, pOutputBuf)

	' === Step 15: Set up IHttpAsyncWriter and send response ===
	Scope
		Dim hrSetBuf As HRESULT = IHttpAsyncWriter_SetBuffer( _
			pWriter, _
			CPtr(IAttributedAsyncStream Ptr, pIMemoryBuf) _
		)
		If FAILED(hrSetBuf) Then
			IMemoryStream_Release(pIMemoryBuf)
			Return E_FAIL
		End If
	End Scope

	' Check HEAD method
	Scope
		Dim HttpMethod As HeapBSTR = Any
		IClientRequest_GetHttpMethod(pRequest, @HttpMethod)
		Dim CompareResult As Long = lstrcmpW(HttpMethod, WStr("HEAD"))
		If CompareResult = CompareResultEqual Then
			IServerResponse_SetSendOnlyHeaders(pResponse, True)
		End If
		HeapSysFreeString(HttpMethod)
	End Scope

	' Prepare the writer with the response
	Scope
		If Not bNph Then
			Dim pCt As HeapBSTR = Any
			IServerResponse_GetHttpHeader(pResponse, HttpResponseHeaders.HeaderContentType, @pCt)
			If pCt Then
				Dim MimeT As MimeType = Any
				MimeT.CharsetWeakPtr = NULL
				MimeT.Format = MimeFormats.Binary
				If lstrcmpiW(pCt, WStr("text/plain")) = CompareResultZero Then
					MimeT.ContentType = ContentTypes.TextPlain
				ElseIf lstrcmpiW(pCt, WStr("text/html")) = CompareResultZero Then
					MimeT.ContentType = ContentTypes.TextHtml
				ElseIf lstrcmpiW(pCt, WStr("text/css")) = CompareResultZero Then
					MimeT.ContentType = ContentTypes.TextCss
				ElseIf lstrcmpiW(pCt, WStr("text/xml")) = CompareResultZero Then
					MimeT.ContentType = ContentTypes.TextXml
				Else
					MimeT.ContentType = ContentTypes.TextHtml
				End If
				IServerResponse_SetMimeType(pResponse, @MimeT)
			End If
		End If
		Dim BodyLen As LongInt = CLngInt(dwBodyLen)
		Dim hrPrepare As HRESULT = IHttpAsyncWriter_Prepare( _
			pWriter, _
			pResponse, _
			BodyLen, _
			FileAccess.ReadAccess _
		)
		If FAILED(hrPrepare) Then
			IMemoryStream_Release(pIMemoryBuf)
			Return hrPrepare
		End If
	End Scope

	*ppIBuffer = CPtr(IAttributedAsyncStream Ptr, pIMemoryBuf)

	Return S_OK
End Function

' --------------- BeginProcess ---------------
Private Function HttpCgiProcessorBeginProcess( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal StateObject As Any Ptr, _
		ByVal ppIAsyncResult As IAsyncResult Ptr Ptr _
	)As HRESULT

	Dim hrBeginWrite As HRESULT = IHttpAsyncWriter_BeginWrite( _
		pContext->pIWriter, _
		pcb, _
		StateObject, _
		ppIAsyncResult _
	)
	If FAILED(hrBeginWrite) Then Return hrBeginWrite
	Return HTTPASYNCPROCESSOR_S_IO_PENDING
End Function

' --------------- EndProcess ---------------
Private Function HttpCgiProcessorEndProcess( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal pIAsyncResult As IAsyncResult Ptr _
	)As HRESULT

	Dim hrEndWrite As HRESULT = IHttpAsyncWriter_EndWrite( _
		pContext->pIWriter, _
		pIAsyncResult _
	)
	If FAILED(hrEndWrite) Then Return hrEndWrite

	Select Case hrEndWrite
		Case S_OK
			Return S_OK
		Case S_FALSE
			Return S_FALSE
		Case HTTPWRITER_S_IO_PENDING
			Return HTTPASYNCPROCESSOR_S_IO_PENDING
	End Select

	Return S_OK
End Function

' --------------- Lifecycle functions ---------------
Private Sub InitializeHttpCgiProcessor( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal pIMemoryAllocator As IMalloc Ptr _
	)
	#if __FB_DEBUG__
		CopyMemory( _
			@self->RttiClassName(0), _
			@Str(RTTI_ID_HTTPCGIPROCESSOR), _
			UBound(self->RttiClassName) - LBound(self->RttiClassName) + 1 _
		)
	#endif
	self->lpVtbl = @GlobalHttpCgiProcessorVirtualTable
	self->ReferenceCounter = CUInt(-1)
	IMalloc_AddRef(pIMemoryAllocator)
	self->pIMemoryAllocator = pIMemoryAllocator
	self->pIWebSite = NULL
End Sub

Private Sub UnInitializeHttpCgiProcessor( _
		ByVal self As HttpCgiProcessor Ptr _
	)
	If self->pIWebSite Then
		IWebSite_Release(self->pIWebSite)
	End If
End Sub

Private Sub DestroyHttpCgiProcessor( _
		ByVal self As HttpCgiProcessor Ptr _
	)
	Dim pIMemoryAllocator As IMalloc Ptr = self->pIMemoryAllocator
	UnInitializeHttpCgiProcessor(self)
	IMalloc_Free(pIMemoryAllocator, self)
	IMalloc_Release(pIMemoryAllocator)
End Sub

Private Function HttpCgiProcessorAddRef( _
		ByVal self As HttpCgiProcessor Ptr _
	)As ULONG
	Return 1
End Function

Private Function HttpCgiProcessorRelease( _
		ByVal self As HttpCgiProcessor Ptr _
	)As ULONG
	Return 0
End Function

Private Function HttpCgiProcessorQueryInterface( _
		ByVal self As HttpCgiProcessor Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT
	If IsEqualIID(@IID_IHttpCgiAsyncProcessor, riid) Then
		*ppv = @self->lpVtbl
	Else
		If IsEqualIID(@IID_IHttpAsyncProcessor, riid) Then
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
	HttpCgiProcessorAddRef(self)
	Return S_OK
End Function

Public Function CreateHttpCgiProcessor( _
		ByVal pIMemoryAllocator As IMalloc Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT
	Dim self As HttpCgiProcessor Ptr = IMalloc_Alloc( _
		pIMemoryAllocator, _
		SizeOf(HttpCgiProcessor) _
	)
	If self Then
		InitializeHttpCgiProcessor(self, pIMemoryAllocator)
		Dim hrQueryInterface As HRESULT = HttpCgiProcessorQueryInterface( _
			self, _
			riid, _
			ppv _
		)
		If FAILED(hrQueryInterface) Then
			DestroyHttpCgiProcessor(self)
		End If
		Return hrQueryInterface
	End If
	*ppv = NULL
	Return E_OUTOFMEMORY
End Function

' --------------- VTable wrappers ---------------
Private Function IHttpCgiProcessorQueryInterface( _
		ByVal self As IHttpCgiAsyncProcessor Ptr, _
		ByVal riid As REFIID, _
		ByVal ppv As Any Ptr Ptr _
	)As HRESULT
	Return HttpCgiProcessorQueryInterface(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl), riid, ppv)
End Function

Private Function IHttpCgiProcessorAddRef( _
		ByVal self As IHttpCgiAsyncProcessor Ptr _
	)As ULONG
	Return HttpCgiProcessorAddRef(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl))
End Function

Private Function IHttpCgiProcessorRelease( _
		ByVal self As IHttpCgiAsyncProcessor Ptr _
	)As ULONG
	Return HttpCgiProcessorRelease(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl))
End Function

Private Function IHttpCgiProcessorPrepare( _
		ByVal self As IHttpCgiAsyncProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal ppIBuffer As IAttributedAsyncStream Ptr Ptr _
	)As HRESULT
	Return HttpCgiProcessorPrepare(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl), pContext, ppIBuffer)
End Function

Private Function IHttpCgiProcessorBeginProcess( _
		ByVal self As IHttpCgiAsyncProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal pcb As AsyncCallback, _
		ByVal StateObject As Any Ptr, _
		ByVal ppIAsyncResult As IAsyncResult Ptr Ptr _
	)As HRESULT
	Return HttpCgiProcessorBeginProcess(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl), pContext, pcb, StateObject, ppIAsyncResult)
End Function

Private Function IHttpCgiProcessorEndProcess( _
		ByVal self As IHttpCgiAsyncProcessor Ptr, _
		ByVal pContext As ProcessorContext Ptr, _
		ByVal pIAsyncResult As IAsyncResult Ptr _
	)As HRESULT
	Return HttpCgiProcessorEndProcess(CONTAINING_RECORD(self, HttpCgiProcessor, lpVtbl), pContext, pIAsyncResult)
End Function

Dim GlobalHttpCgiProcessorVirtualTable As Const IHttpCgiAsyncProcessorVirtualTable = Type( _
	@IHttpCgiProcessorQueryInterface, _
	@IHttpCgiProcessorAddRef, _
	@IHttpCgiProcessorRelease, _
	@IHttpCgiProcessorPrepare, _
	@IHttpCgiProcessorBeginProcess, _
	@IHttpCgiProcessorEndProcess _
)
