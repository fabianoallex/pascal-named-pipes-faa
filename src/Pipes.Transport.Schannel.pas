unit Pipes.Transport.Schannel;

{$I pipes.inc}

{ Transporte TLS (amqps://) via SChannel nativo do Windows (SSPI).

  Motivação de design (ver plano/CLAUDE): TLS SEM dependências externas — nada de
  DLLs de OpenSSL para distribuir/manter. Usa o SChannel do próprio Windows
  (secur32.dll), que a lib acessa via SSPI. A RTL do Delphi NÃO declara essa API,
  então as assinaturas/records/constantes necessárias são declaradas aqui mesmo
  (nada de terceiros — só a especificação da API Win32).

  TPipeSchannelStream é um TStream que ENVOLVE outro TStream de bytes crus (o
  TPipeSocketStream sobre o socket TCP) e faz a criptografia por cima. O resto da
  lib continua falando com um TStream — o framing (Pipes.Framing) nao sabe que ha TLS
  embaixo. Como o stream cru continua sendo o socket, fechar o socket
  (reconexão/heartbeat) desbloqueia a leitura exatamente como no caminho plain.

  Escopo: cliente, autenticação de servidor. Validação de certificado via cadeia
  do Windows (default) ou modo inseguro opt-in (self-signed em dev). mTLS e
  renegociação iniciada pelo servidor ficam fora desta primeira versão. }

interface

{ Unit exclusiva de Windows (SChannel). Em outras plataformas ela compila
  vazia; Pipes.Transport.Tcp so a referencia sob PIPES_WINDOWS. TLS multiplataforma
  (OpenSSL) e' roadmap. }
{$IFDEF PIPES_WINDOWS}

uses
  SysUtils,
  Classes,
  Windows,
  Pipes.Types; // EPipeTls

type
  { Handles/structs SSPI usados como campos da classe (layout binário exato da
    API Win32). O restante da superfície SSPI (funções, SecBuffer, SCHANNEL_CRED,
    constantes) fica na implementation, pois só é usado dentro dos métodos. }
  PSecHandle = ^TSecHandle;
  TSecHandle = record
    dwLower: ULONG_PTR;
    dwUpper: ULONG_PTR;
  end;
  TCredHandle = TSecHandle;
  TCtxtHandle = TSecHandle;

  TSecPkgContext_StreamSizes = record
    cbHeader: ULONG;
    cbTrailer: ULONG;
    cbMaximumMessage: ULONG;
    cBuffers: ULONG;
    cbBlockSize: ULONG;
  end;

  { Stream TLS cliente. Faz o handshake no construtor (síncrono, sobre o stream
    cru), depois cifra/decifra em Read/Write. É dono do stream de baixo (Free
    libera os dois). }
  TPipeSchannelStream = class(TStream)
  private
    FUnderlying: TStream;      // bytes crus (socket); TPipeSchannelStream é dono
    FCred: TCredHandle;
    FCtxt: TCtxtHandle;
    FStreamSizes: TSecPkgContext_StreamSizes;
    // UnicodeString nos dois compiladores: a API SSPI e' wide (PWideChar) e no
    // FPC 'string' e' AnsiString — o cast direto nao existiria.
    FTargetName: UnicodeString; // SNI / nome para validação
    FVerifyPeer: Boolean;
    FCredValid: Boolean;
    FCtxtValid: Boolean;
    // buffer de plaintext já decifrado, aguardando consumo por Read
    FPlain: TBytes;
    FPlainPos: Integer;
    FPlainEnd: Integer;
    // ciphertext lido do socket ainda não processado (inclui SECBUFFER_EXTRA)
    FCipher: TBytes;
    FCipherLen: Integer;
    procedure RecvRaw;                 // lê um bloco do socket e acrescenta a FCipher
    procedure SendAll(APtr: Pointer; ALen: Integer);
    procedure AcquireCred;
    procedure DoHandshake;
    procedure FillPlain;               // decifra até haver plaintext (ou EOF)
    procedure ShutdownTls;
  public
    /// Uso interno (o FPC avisa sobre construtor protegido, dai ser publico):
    /// inicializa campos SEM negociar. O lado servidor usa isto porque negocia
    /// depois, na reader thread da conexao.
    constructor CreateDeferred(AUnderlying: TStream);
    constructor Create(AUnderlying: TStream; const ATargetName: string;
      AVerifyPeer: Boolean);
    destructor Destroy; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
  end;

  { Stream TLS SERVIDOR. Difere do cliente em dois pontos:

    - a credencial e' INBOUND e carrega um certificado (o cliente valida o
      servidor; sem certificado nao ha o que apresentar);
    - o handshake e' AcceptSecurityContext, e o servidor NUNCA fala primeiro:
      espera o ClientHello antes da primeira chamada.

    A negociacao NAO acontece no construtor: quem a dispara e' Negotiate,
    chamada pela reader thread da conexao (ver TPipeEndpoint.Handshake). Fazer
    isso no accept prenderia o loop de accept inteiro num cliente lento. }
  TPipeSchannelServerStream = class(TPipeSchannelStream)
  private
    FCertContext: Pointer; // PCCERT_CONTEXT; a POSSE fica com o chamador
    FNegotiated: Boolean;
    procedure AcquireServerCred;
    procedure DoServerHandshake;
  public
    /// ACertContext continua sendo do chamador: varias conexoes compartilham
    /// o mesmo certificado do servidor, entao esta classe nao o libera.
    constructor Create(AUnderlying: TStream; ACertContext: Pointer);
    /// Idempotente. Levanta EPipeTls se a negociacao falhar.
    procedure Negotiate;
  end;

/// Carrega um certificado de servidor (com chave privada) de um arquivo PFX.
/// O contexto devolvido e' do CHAMADOR: liberar com PipeSchannelFreeCert.
function PipeSchannelLoadPfx(const AFileName, APassword: string): Pointer;
/// Libera o que PipeSchannelLoadPfx devolveu. Aceita nil.
procedure PipeSchannelFreeCert(ACertContext: Pointer);

{$ENDIF PIPES_WINDOWS}

implementation

{$IFDEF PIPES_WINDOWS}

{ ------------------------------------------------------------------------------
  Declarações SSPI / SChannel (Win32). Nomes seguem a API oficial; os records têm
  o layout binário exato esperado pelo secur32.dll.
  ------------------------------------------------------------------------------ }

type
  SECURITY_STATUS = LongInt;

  // Ponteiros para os handles (os records TSecHandle/TCredHandle/TCtxtHandle e
  // TSecPkgContext_StreamSizes estão na interface, pois são campos da classe).
  PCredHandle = PSecHandle;
  PCtxtHandle = PSecHandle;

  // A API usa TimeStamp (LARGE_INTEGER); só o recebemos como out e ignoramos.
  TSecTimeStamp = Int64;
  PSecTimeStamp = ^TSecTimeStamp;

  PSecBuffer = ^TSecBuffer;
  TSecBuffer = record
    cbBuffer: ULONG;
    BufferType: ULONG;
    pvBuffer: Pointer;
  end;

  PSecBufferDesc = ^TSecBufferDesc;
  TSecBufferDesc = record
    ulVersion: ULONG;
    cBuffers: ULONG;
    pBuffers: PSecBuffer;
  end;

  // SCHANNEL_CRED (versão 4). Só preenchemos dwVersion e dwFlags; o resto zerado.
  TSChannelCred = record
    dwVersion: DWORD;
    cCreds: DWORD;
    paCred: Pointer;
    hRootStore: THandle;
    cMappers: DWORD;
    aphMappers: Pointer;
    cSupportedAlgs: DWORD;
    palgSupportedAlgs: Pointer;
    grbitEnabledProtocols: DWORD;
    dwMinimumCipherStrength: DWORD;
    dwMaximumCipherStrength: DWORD;
    dwSessionLifespan: DWORD;
    dwFlags: DWORD;
    dwCredFormat: DWORD;
  end;

const
  UNISP_NAME = 'Microsoft Unified Security Protocol Provider';

  SECPKG_CRED_OUTBOUND     = 2;
  SECPKG_CRED_INBOUND      = 1;
  SECURITY_NATIVE_DREP     = $10;
  SECBUFFER_VERSION        = 0;
  SCHANNEL_CRED_VERSION    = 4;

  // Tipos de SecBuffer
  SECBUFFER_EMPTY          = 0;
  SECBUFFER_DATA           = 1;
  SECBUFFER_TOKEN          = 2;
  SECBUFFER_EXTRA          = 5;
  SECBUFFER_STREAM_TRAILER = 6;
  SECBUFFER_STREAM_HEADER  = 7;
  SECBUFFER_ALERT          = 17;

  // Flags de InitializeSecurityContext (cliente, modo stream)
  ISC_REQ_REPLAY_DETECT    = $00000004;
  ISC_REQ_SEQUENCE_DETECT  = $00000008;
  ISC_REQ_CONFIDENTIALITY  = $00000010;
  ISC_REQ_EXTENDED_ERROR   = $00004000;
  ISC_REQ_ALLOCATE_MEMORY  = $00000100;
  ISC_REQ_STREAM           = $00008000;

  // Flags de SCHANNEL_CRED.dwFlags
  SCH_CRED_NO_SYSTEM_MAPPER       = $00000002;
  SCH_CRED_NO_SERVERNAME_CHECK    = $00000004;
  SCH_CRED_MANUAL_CRED_VALIDATION = $00000008;
  SCH_CRED_NO_DEFAULT_CREDS       = $00000010;
  SCH_CRED_AUTO_CRED_VALIDATION   = $00000020;

  SECPKG_ATTR_STREAM_SIZES = 4;

  // Status (as constantes de erro têm o bit alto setado; comparar via Cardinal).
  SEC_E_OK                 = $00000000;
  SEC_I_CONTINUE_NEEDED    = $00090312;
  SEC_I_CONTEXT_EXPIRED    = $00090317;
  SEC_I_RENEGOTIATE        = $00090321;
  SEC_E_INCOMPLETE_MESSAGE = $80090318;

  SCHANNEL_SHUTDOWN = 1;

  RAW_CHUNK = 16384; // leitura de socket por rodada (record TLS máx ~16KB)

  // Flags pedidas no handshake (cliente, modo stream).
  HANDSHAKE_REQ = ISC_REQ_SEQUENCE_DETECT or ISC_REQ_REPLAY_DETECT or
    ISC_REQ_CONFIDENTIALITY or ISC_REQ_EXTENDED_ERROR or ISC_REQ_ALLOCATE_MEMORY or
    ISC_REQ_STREAM;

  // Flags de AcceptSecurityContext (servidor, modo stream). Espelham as do
  // cliente: mesma familia ASC_*, mesmos valores.
  ASC_REQ_REPLAY_DETECT    = $00000004;
  ASC_REQ_SEQUENCE_DETECT  = $00000008;
  ASC_REQ_CONFIDENTIALITY  = $00000010;
  ASC_REQ_EXTENDED_ERROR   = $00008000;
  ASC_REQ_ALLOCATE_MEMORY  = $00000100;
  ASC_REQ_STREAM           = $00010000;

  ACCEPT_REQ = ASC_REQ_SEQUENCE_DETECT or ASC_REQ_REPLAY_DETECT or
    ASC_REQ_CONFIDENTIALITY or ASC_REQ_EXTENDED_ERROR or ASC_REQ_ALLOCATE_MEMORY or
    ASC_REQ_STREAM;

  // crypt32: carga do PFX
  X509_ASN_ENCODING        = 1;
  PKCS_7_ASN_ENCODING      = $10000;
  CRYPT_EXPORTABLE         = 1;
  CERT_KEY_PROV_INFO_PROP_ID = 2;

type
  TCryptDataBlob = record
    cbData: DWORD;
    pbData: Pointer;
  end;

function AcceptSecurityContext(phCredential: PCredHandle;
  phContext: PCtxtHandle; pInput: PSecBufferDesc; fContextReq: ULONG;
  TargetDataRep: ULONG; phNewContext: PCtxtHandle; pOutput: PSecBufferDesc;
  pfContextAttr: PULONG; ptsTimeStamp: PSecTimeStamp): SECURITY_STATUS; stdcall;
  external 'secur32.dll' name 'AcceptSecurityContext';

function PFXImportCertStore(pPFX: Pointer; szPassword: PWideChar;
  dwFlags: DWORD): THandle; stdcall; external 'crypt32.dll' name 'PFXImportCertStore';
function CertEnumCertificatesInStore(hCertStore: THandle;
  pPrev: Pointer): Pointer; stdcall;
  external 'crypt32.dll' name 'CertEnumCertificatesInStore';
function CertGetCertificateContextProperty(pCertContext: Pointer;
  dwPropId: DWORD; pvData: Pointer; var pcbData: DWORD): BOOL; stdcall;
  external 'crypt32.dll' name 'CertGetCertificateContextProperty';
function CertDuplicateCertificateContext(pCertContext: Pointer): Pointer;
  stdcall; external 'crypt32.dll' name 'CertDuplicateCertificateContext';
function CertFreeCertificateContext(pCertContext: Pointer): BOOL; stdcall;
  external 'crypt32.dll' name 'CertFreeCertificateContext';
function CertCloseStore(hCertStore: THandle; dwFlags: DWORD): BOOL; stdcall;
  external 'crypt32.dll' name 'CertCloseStore';

function AcquireCredentialsHandleW(pszPrincipal, pszPackage: PWideChar;
  fCredentialUse: ULONG; pvLogonID, pAuthData, pGetKeyFn, pvGetKeyArgument: Pointer;
  phCredential: PCredHandle; ptsExpiry: PSecTimeStamp): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

function InitializeSecurityContextW(phCredential: PCredHandle;
  phContext: PCtxtHandle; pszTargetName: PWideChar; fContextReq, Reserved1,
  TargetDataRep: ULONG; pInput: PSecBufferDesc; Reserved2: ULONG;
  phNewContext: PCtxtHandle; pOutput: PSecBufferDesc; pfContextAttr: PULONG;
  ptsExpiry: PSecTimeStamp): SECURITY_STATUS; stdcall; external 'secur32.dll';

function QueryContextAttributesW(phContext: PCtxtHandle; ulAttribute: ULONG;
  pBuffer: Pointer): SECURITY_STATUS; stdcall; external 'secur32.dll';

function EncryptMessage(phContext: PCtxtHandle; fQOP: ULONG;
  pMessage: PSecBufferDesc; MessageSeqNo: ULONG): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

function DecryptMessage(phContext: PCtxtHandle; pMessage: PSecBufferDesc;
  MessageSeqNo: ULONG; pfQOP: PULONG): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

function ApplyControlToken(phContext: PCtxtHandle;
  pInput: PSecBufferDesc): SECURITY_STATUS; stdcall; external 'secur32.dll';

function DeleteSecurityContext(phContext: PCtxtHandle): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

function FreeCredentialsHandle(phCredential: PCredHandle): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

function FreeContextBuffer(pvContextBuffer: Pointer): SECURITY_STATUS; stdcall;
  external 'secur32.dll';

// Compara um SECURITY_STATUS com uma constante (as de erro têm bit alto setado).
function StatusIs(AStatus: SECURITY_STATUS; AConst: Cardinal): Boolean; inline;
begin
  Result := Cardinal(AStatus) = AConst;
end;

function StatusFailed(AStatus: SECURITY_STATUS): Boolean; inline;
begin
  Result := AStatus < 0; // HRESULT-like: negativo = falha
end;

{ TPipeSchannelStream }

constructor TPipeSchannelStream.CreateDeferred(AUnderlying: TStream);
begin
  inherited Create;
  FUnderlying := AUnderlying;
  SetLength(FCipher, RAW_CHUNK);
  FCipherLen := 0;
end;

constructor TPipeSchannelStream.Create(AUnderlying: TStream;
  const ATargetName: string; AVerifyPeer: Boolean);
begin
  CreateDeferred(AUnderlying);
  FTargetName := UnicodeString(ATargetName);
  FVerifyPeer := AVerifyPeer;
  // Se AcquireCred/DoHandshake levantarem, o Delphi chama o destrutor
  // automaticamente — que libera credencial/contexto (guardados por
  // FCredValid/FCtxtValid) e o stream de baixo. Nada de cleanup manual aqui
  // (seria double-free).
  AcquireCred;
  DoHandshake;
end;

destructor TPipeSchannelStream.Destroy;
begin
  try
    if FCtxtValid then
      ShutdownTls;
  except
  end;
  if FCtxtValid then
    DeleteSecurityContext(@FCtxt);
  if FCredValid then
    FreeCredentialsHandle(@FCred);
  FUnderlying.Free;
  inherited;
end;

procedure TPipeSchannelStream.AcquireCred;
var
  LCred: TSChannelCred;
  LStatus: SECURITY_STATUS;
begin
  FillChar(LCred, SizeOf(LCred), 0);
  LCred.dwVersion := SCHANNEL_CRED_VERSION;
  if FVerifyPeer then
    LCred.dwFlags := SCH_CRED_AUTO_CRED_VALIDATION or SCH_CRED_NO_DEFAULT_CREDS
  else
    LCred.dwFlags := SCH_CRED_MANUAL_CRED_VALIDATION or
      SCH_CRED_NO_SERVERNAME_CHECK or SCH_CRED_NO_DEFAULT_CREDS;
  // grbitEnabledProtocols = 0: deixa o SChannel escolher (TLS 1.2/1.3).

  LStatus := AcquireCredentialsHandleW(nil, UNISP_NAME, SECPKG_CRED_OUTBOUND,
    nil, @LCred, nil, nil, @FCred, nil);
  if StatusFailed(LStatus) then
    raise EPipeTls.CreateFmt('AcquireCredentialsHandle falhou (0x%.8x)', [Cardinal(LStatus)]);
  FCredValid := True;
  // Para PipeTlsBackendInfo: no Windows nao ha DLL nem versao a descobrir (o
  // SChannel e' do SO), mas saber QUAL backend esta ativo ja e' o essencial —
  // uma build com PIPES_OPENSSL usaria o outro.
  PipeSetTlsBackendDetail('SChannel (SSPI, nativo do Windows)');
end;

// Lê um bloco do socket e acrescenta ao fim de FCipher (crescendo o array se
// preciso). Levanta EPipeTls em fim de stream.
procedure TPipeSchannelStream.RecvRaw;
var
  LRead: Integer;
begin
  if Length(FCipher) - FCipherLen < RAW_CHUNK then
    SetLength(FCipher, FCipherLen + RAW_CHUNK);
  LRead := FUnderlying.Read(FCipher[FCipherLen], RAW_CHUNK);
  if LRead <= 0 then
    raise EPipeTls.Create('conexão fechada durante TLS');
  Inc(FCipherLen, LRead);
end;

procedure TPipeSchannelStream.SendAll(APtr: Pointer; ALen: Integer);
var
  LWritten, LNow: Integer;
  P: PByte;
begin
  P := APtr;
  LWritten := 0;
  while LWritten < ALen do
  begin
    LNow := FUnderlying.Write(P[LWritten], ALen - LWritten);
    if LNow <= 0 then
      raise EPipeTls.Create('falha ao enviar dados TLS');
    Inc(LWritten, LNow);
  end;
end;

procedure TPipeSchannelStream.DoHandshake;
var
  LInBuf: array[0..1] of TSecBuffer;
  LOutBuf: array[0..0] of TSecBuffer;
  LInDesc, LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LTarget: PWideChar;
  LReadMore: Boolean;
  LExtra: Integer;
begin
  LTarget := nil;
  if FTargetName <> '' then
    LTarget := PWideChar(FTargetName);

  // 1ª chamada: sem token de entrada, gera o ClientHello.
  LOutBuf[0].cbBuffer := 0;
  LOutBuf[0].BufferType := SECBUFFER_TOKEN;
  LOutBuf[0].pvBuffer := nil;
  LOutDesc.ulVersion := SECBUFFER_VERSION;
  LOutDesc.cBuffers := 1;
  LOutDesc.pBuffers := @LOutBuf[0];

  LStatus := InitializeSecurityContextW(@FCred, nil, LTarget, HANDSHAKE_REQ, 0,
    SECURITY_NATIVE_DREP, nil, 0, @FCtxt, @LOutDesc, @LAttr, nil);
  if not StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) then
  begin
    // Libera um eventual token de saída alocado (ex.: alerta TLS) antes de sair,
    // para não vazar o buffer do SSPI no caminho de falha.
    if LOutBuf[0].pvBuffer <> nil then
      FreeContextBuffer(LOutBuf[0].pvBuffer);
    raise EPipeTls.CreateFmt('InitializeSecurityContext inicial falhou (0x%.8x)', [Cardinal(LStatus)]);
  end;
  FCtxtValid := True; // contexto criado
  if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
  begin
    SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
    FreeContextBuffer(LOutBuf[0].pvBuffer);
  end;

  // Loop: lê resposta do servidor e alimenta o ISC até SEC_E_OK. Só lê mais bytes
  // quando o buffer está vazio ou o record chegou incompleto.
  LReadMore := True;
  while True do
  begin
    if LReadMore or (FCipherLen = 0) then
      RecvRaw;

    LInBuf[0].cbBuffer := FCipherLen;
    LInBuf[0].BufferType := SECBUFFER_TOKEN;
    LInBuf[0].pvBuffer := @FCipher[0];
    LInBuf[1].cbBuffer := 0;
    LInBuf[1].BufferType := SECBUFFER_EMPTY;
    LInBuf[1].pvBuffer := nil;
    LInDesc.ulVersion := SECBUFFER_VERSION;
    LInDesc.cBuffers := 2;
    LInDesc.pBuffers := @LInBuf[0];

    LOutBuf[0].cbBuffer := 0;
    LOutBuf[0].BufferType := SECBUFFER_TOKEN;
    LOutBuf[0].pvBuffer := nil;
    LOutDesc.ulVersion := SECBUFFER_VERSION;
    LOutDesc.cBuffers := 1;
    LOutDesc.pBuffers := @LOutBuf[0];

    LStatus := InitializeSecurityContextW(@FCred, @FCtxt, LTarget, HANDSHAKE_REQ,
      0, SECURITY_NATIVE_DREP, @LInDesc, 0, @FCtxt, @LOutDesc, @LAttr, nil);

    // Token de saída pendente (mesmo em SEC_E_OK pode haver): envia.
    if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
    begin
      SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
      FreeContextBuffer(LOutBuf[0].pvBuffer);
      LOutBuf[0].pvBuffer := nil;
    end;

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      LReadMore := True; // record incompleto: mantém FCipher e lê mais
      Continue;
    end;

    if StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) or StatusIs(LStatus, SEC_E_OK) then
    begin
      // Bytes não consumidos (início do próximo record) ficam em SECBUFFER_EXTRA,
      // no FIM do buffer de entrada. Preserva-os para a próxima etapa/leitura.
      if LInBuf[1].BufferType = SECBUFFER_EXTRA then
      begin
        LExtra := LInBuf[1].cbBuffer;
        if LExtra > 0 then
          Move(FCipher[FCipherLen - LExtra], FCipher[0], LExtra);
        FCipherLen := LExtra;
      end
      else
        FCipherLen := 0;

      if StatusIs(LStatus, SEC_E_OK) then
        Break; // handshake concluído
      // Só há mais o que processar sem ler se sobrou extra; senão, aguarda o
      // servidor (lê mais).
      LReadMore := (FCipherLen = 0);
      Continue;
    end;

    raise EPipeTls.CreateFmt('handshake TLS falhou (0x%.8x)', [Cardinal(LStatus)]);
  end;

  // Tamanhos para cifrar/decifrar (header/trailer/máx por record).
  LStatus := QueryContextAttributesW(@FCtxt, SECPKG_ATTR_STREAM_SIZES, @FStreamSizes);
  if StatusFailed(LStatus) then
    raise EPipeTls.CreateFmt('QueryContextAttributes(STREAM_SIZES) falhou (0x%.8x)', [Cardinal(LStatus)]);
end;

// Decifra do FCipher até haver plaintext em FPlain (ou sinaliza EOF via exceção
// tratada pelo chamador). Consome/guarda SECBUFFER_EXTRA entre records.
procedure TPipeSchannelStream.FillPlain;
var
  LBuf: array[0..3] of TSecBuffer;
  LDesc: TSecBufferDesc;
  LStatus: SECURITY_STATUS;
  I, LExtra: Integer;
  LData, LExtraBuf: PSecBuffer;
begin
  while True do
  begin
    if FCipherLen = 0 then
      RecvRaw;

    LBuf[0].cbBuffer := FCipherLen;
    LBuf[0].BufferType := SECBUFFER_DATA;
    LBuf[0].pvBuffer := @FCipher[0];
    for I := 1 to 3 do
    begin
      LBuf[I].cbBuffer := 0;
      LBuf[I].BufferType := SECBUFFER_EMPTY;
      LBuf[I].pvBuffer := nil;
    end;
    LDesc.ulVersion := SECBUFFER_VERSION;
    LDesc.cBuffers := 4;
    LDesc.pBuffers := @LBuf[0];

    LStatus := DecryptMessage(@FCtxt, @LDesc, 0, nil);

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      RecvRaw; // record incompleto: lê mais e tenta de novo
      Continue;
    end;

    if StatusIs(LStatus, SEC_I_CONTEXT_EXPIRED) then
    begin
      FCipherLen := 0;
      FPlainPos := 0;
      FPlainEnd := 0;
      Exit; // servidor encerrou o TLS (close_notify) => tratamos como EOF
    end;

    if StatusIs(LStatus, SEC_I_RENEGOTIATE) then
      // RabbitMQ não renegocia; não suportado nesta versão.
      raise EPipeTls.Create('renegociação TLS solicitada pelo servidor não suportada');

    if not StatusIs(LStatus, SEC_E_OK) then
      raise EPipeTls.CreateFmt('DecryptMessage falhou (0x%.8x)', [Cardinal(LStatus)]);

    // Encontra o buffer de dados decifrados e eventual sobra (próximo record).
    LData := nil;
    LExtraBuf := nil;
    for I := 0 to 3 do
      if (LBuf[I].BufferType = SECBUFFER_DATA) and (LData = nil) then
        LData := @LBuf[I]
      else if (LBuf[I].BufferType = SECBUFFER_EXTRA) and (LExtraBuf = nil) then
        LExtraBuf := @LBuf[I];

    if (LData <> nil) and (LData.cbBuffer > 0) then
    begin
      SetLength(FPlain, LData.cbBuffer);
      Move(PByte(LData.pvBuffer)^, FPlain[0], LData.cbBuffer);
      FPlainPos := 0;
      FPlainEnd := LData.cbBuffer;
    end
    else
    begin
      FPlainPos := 0;
      FPlainEnd := 0;
    end;

    // Sobra = bytes do próximo record; move para o início de FCipher.
    if LExtraBuf <> nil then
    begin
      LExtra := LExtraBuf.cbBuffer;
      if LExtra > 0 then
        Move(PByte(LExtraBuf.pvBuffer)^, FCipher[0], LExtra);
      FCipherLen := LExtra;
    end
    else
      FCipherLen := 0;

    if FPlainEnd > 0 then
      Exit; // temos plaintext para servir
    // record sem dados de aplicação (ex.: handshake pós-troca): decifra o próximo
  end;
end;

function TPipeSchannelStream.Read(var Buffer; Count: Longint): Longint;
var
  LAvail: Integer;
begin
  if Count <= 0 then
    Exit(0);
  if FPlainPos >= FPlainEnd then
  begin
    try
      FillPlain;
    except
      on EPipeTls do
        Exit(0); // conexão caiu / EOF: sinaliza fim de stream ao framing
    end;
    if FPlainPos >= FPlainEnd then
      Exit(0); // EOF (close_notify)
  end;
  LAvail := FPlainEnd - FPlainPos;
  if LAvail > Count then
    LAvail := Count;
  Move(FPlain[FPlainPos], Buffer, LAvail);
  Inc(FPlainPos, LAvail);
  Result := LAvail;
end;

function TPipeSchannelStream.Write(const Buffer; Count: Longint): Longint;
var
  LBuf: array[0..3] of TSecBuffer;
  LDesc: TSecBufferDesc;
  LStatus: SECURITY_STATUS;
  LChunk, LOffset, LTotal: Integer;
  LRec: TBytes;
  P: PByte;
begin
  P := @Buffer;
  LOffset := 0;
  while LOffset < Count do
  begin
    LChunk := Count - LOffset;
    if LChunk > Integer(FStreamSizes.cbMaximumMessage) then
      LChunk := Integer(FStreamSizes.cbMaximumMessage);

    // record = header + plaintext + trailer, contíguos.
    SetLength(LRec, FStreamSizes.cbHeader + Cardinal(LChunk) + FStreamSizes.cbTrailer);
    Move(P[LOffset], LRec[FStreamSizes.cbHeader], LChunk);

    LBuf[0].cbBuffer := FStreamSizes.cbHeader;
    LBuf[0].BufferType := SECBUFFER_STREAM_HEADER;
    LBuf[0].pvBuffer := @LRec[0];
    LBuf[1].cbBuffer := LChunk;
    LBuf[1].BufferType := SECBUFFER_DATA;
    LBuf[1].pvBuffer := @LRec[FStreamSizes.cbHeader];
    LBuf[2].cbBuffer := FStreamSizes.cbTrailer;
    LBuf[2].BufferType := SECBUFFER_STREAM_TRAILER;
    LBuf[2].pvBuffer := @LRec[FStreamSizes.cbHeader + Cardinal(LChunk)];
    LBuf[3].cbBuffer := 0;
    LBuf[3].BufferType := SECBUFFER_EMPTY;
    LBuf[3].pvBuffer := nil;
    LDesc.ulVersion := SECBUFFER_VERSION;
    LDesc.cBuffers := 4;
    LDesc.pBuffers := @LBuf[0];

    LStatus := EncryptMessage(@FCtxt, 0, @LDesc, 0);
    if StatusFailed(LStatus) then
      raise EPipeTls.CreateFmt('EncryptMessage falhou (0x%.8x)', [Cardinal(LStatus)]);

    // EncryptMessage ajusta os cbBuffer; envia os três contíguos.
    LTotal := Integer(LBuf[0].cbBuffer) + Integer(LBuf[1].cbBuffer) +
      Integer(LBuf[2].cbBuffer);
    SendAll(@LRec[0], LTotal);

    Inc(LOffset, LChunk);
  end;
  Result := Count;
end;

function TPipeSchannelStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := 0; // silencia W5093; a excecao abaixo e que vale
  raise EPipeTls.Create('TPipeSchannelStream nao suporta Seek');
end;

procedure TPipeSchannelStream.ShutdownTls;
var
  LToken: DWORD;
  LCtrlBuf: TSecBuffer;
  LCtrlDesc: TSecBufferDesc;
  LOutBuf: TSecBuffer;
  LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LTarget: PWideChar;
begin
  // Best-effort: avisa o servidor (close_notify). Falhas são ignoradas.
  LToken := SCHANNEL_SHUTDOWN;
  LCtrlBuf.cbBuffer := SizeOf(LToken);
  LCtrlBuf.BufferType := SECBUFFER_TOKEN;
  LCtrlBuf.pvBuffer := @LToken;
  LCtrlDesc.ulVersion := SECBUFFER_VERSION;
  LCtrlDesc.cBuffers := 1;
  LCtrlDesc.pBuffers := @LCtrlBuf;
  if StatusFailed(ApplyControlToken(@FCtxt, @LCtrlDesc)) then
    Exit;

  LTarget := nil;
  if FTargetName <> '' then
    LTarget := PWideChar(FTargetName);

  LOutBuf.cbBuffer := 0;
  LOutBuf.BufferType := SECBUFFER_TOKEN;
  LOutBuf.pvBuffer := nil;
  LOutDesc.ulVersion := SECBUFFER_VERSION;
  LOutDesc.cBuffers := 1;
  LOutDesc.pBuffers := @LOutBuf;

  LStatus := InitializeSecurityContextW(@FCred, @FCtxt, LTarget, HANDSHAKE_REQ, 0,
    SECURITY_NATIVE_DREP, nil, 0, @FCtxt, @LOutDesc, @LAttr, nil);
  if (not StatusFailed(LStatus)) and (LOutBuf.cbBuffer > 0) and
     (LOutBuf.pvBuffer <> nil) then
  begin
    try
      SendAll(LOutBuf.pvBuffer, LOutBuf.cbBuffer);
    except
    end;
    FreeContextBuffer(LOutBuf.pvBuffer);
  end;
end;


{ --- certificado do servidor ------------------------------------------------ }

function PipeSchannelLoadPfx(const AFileName, APassword: string): Pointer;
var
  LStream: TFileStream;
  LData: TBytes;
  LBlob: TCryptDataBlob;
  LStore: THandle;
  LCert, LFound: Pointer;
  LSize: DWORD;
  LPwd: UnicodeString;
begin
  Result := nil;
  if not FileExists(AFileName) then
    raise EPipeTls.CreateFmt('certificado nao encontrado: %s', [AFileName]);
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(LData, LStream.Size);
    if Length(LData) = 0 then
      raise EPipeTls.CreateFmt('certificado vazio: %s', [AFileName]);
    LStream.ReadBuffer(LData[0], Length(LData));
  finally
    LStream.Free;
  end;

  LBlob.cbData := Length(LData);
  LBlob.pbData := @LData[0];
  LPwd := UnicodeString(APassword);
  // CRYPT_EXPORTABLE: a chave privada precisa ficar utilizavel pelo SChannel.
  LStore := PFXImportCertStore(@LBlob, PWideChar(LPwd), CRYPT_EXPORTABLE);
  if LStore = 0 then
    raise EPipeTls.CreateFmt(
      'PFXImportCertStore falhou em %s (erro %d) — senha errada ou arquivo ' +
      'corrompido', [AFileName, GetLastError]);
  try
    // Um PFX costuma trazer a cadeia inteira; o que serve ao servidor e' o
    // unico com CHAVE PRIVADA. Pegar "o primeiro" pegaria a CA e o handshake
    // falharia depois, longe daqui.
    LFound := nil;
    LCert := CertEnumCertificatesInStore(LStore, nil);
    while LCert <> nil do
    begin
      LSize := 0;
      if CertGetCertificateContextProperty(LCert, CERT_KEY_PROV_INFO_PROP_ID,
           nil, LSize) then
      begin
        LFound := LCert;
        Break;
      end;
      LCert := CertEnumCertificatesInStore(LStore, LCert);
    end;
    if LFound = nil then
      raise EPipeTls.CreateFmt(
        '%s nao contem certificado com chave privada', [AFileName]);
    // Duplica: o contexto precisa sobreviver ao fechamento do store.
    Result := CertDuplicateCertificateContext(LFound);
  finally
    CertCloseStore(LStore, 0);
  end;
end;

procedure PipeSchannelFreeCert(ACertContext: Pointer);
begin
  if ACertContext <> nil then
    CertFreeCertificateContext(ACertContext);
end;

{ TPipeSchannelServerStream }

constructor TPipeSchannelServerStream.Create(AUnderlying: TStream;
  ACertContext: Pointer);
begin
  CreateDeferred(AUnderlying);
  if ACertContext = nil then
    raise EPipeTls.Create('servidor TLS exige certificado');
  FCertContext := ACertContext;
  FVerifyPeer := False; // sem mTLS ainda: o cliente nao apresenta certificado
end;

procedure TPipeSchannelServerStream.Negotiate;
begin
  if FNegotiated then
    Exit;
  AcquireServerCred;
  DoServerHandshake;
  FNegotiated := True;
end;

procedure TPipeSchannelServerStream.AcquireServerCred;
var
  LCred: TSChannelCred;
  LCertArray: array[0..0] of Pointer;
  LStatus: SECURITY_STATUS;
begin
  FillChar(LCred, SizeOf(LCred), 0);
  LCred.dwVersion := SCHANNEL_CRED_VERSION;
  LCertArray[0] := FCertContext;
  LCred.cCreds := 1;
  LCred.paCred := @LCertArray[0];
  // Sem validacao de cliente: mTLS e T4. Aqui o servidor so se apresenta.
  LCred.dwFlags := SCH_CRED_NO_SYSTEM_MAPPER;
  // grbitEnabledProtocols = 0: o SChannel escolhe (TLS 1.2/1.3).

  LStatus := AcquireCredentialsHandleW(nil, UNISP_NAME, SECPKG_CRED_INBOUND,
    nil, @LCred, nil, nil, @FCred, nil);
  if StatusFailed(LStatus) then
    raise EPipeTls.CreateFmt(
      'AcquireCredentialsHandle(INBOUND) falhou (0x%.8x)', [Cardinal(LStatus)]);
  FCredValid := True;
  PipeSetTlsBackendDetail('SChannel (SSPI, nativo do Windows)');
end;

procedure TPipeSchannelServerStream.DoServerHandshake;
var
  LInBuf: array[0..1] of TSecBuffer;
  LOutBuf: array[0..0] of TSecBuffer;
  LInDesc, LOutDesc: TSecBufferDesc;
  LAttr: ULONG;
  LStatus: SECURITY_STATUS;
  LCtxPtr: PCtxtHandle;
  LReadMore: Boolean;
  LExtra: Integer;
begin
  // Diferenca central em relacao ao cliente: o servidor NUNCA fala primeiro.
  // Nao ha chamada inicial sem entrada — espera-se o ClientHello.
  LReadMore := True;
  while True do
  begin
    if LReadMore or (FCipherLen = 0) then
      RecvRaw;

    LInBuf[0].cbBuffer := FCipherLen;
    LInBuf[0].BufferType := SECBUFFER_TOKEN;
    LInBuf[0].pvBuffer := @FCipher[0];
    LInBuf[1].cbBuffer := 0;
    LInBuf[1].BufferType := SECBUFFER_EMPTY;
    LInBuf[1].pvBuffer := nil;
    LInDesc.ulVersion := SECBUFFER_VERSION;
    LInDesc.cBuffers := 2;
    LInDesc.pBuffers := @LInBuf[0];

    LOutBuf[0].cbBuffer := 0;
    LOutBuf[0].BufferType := SECBUFFER_TOKEN;
    LOutBuf[0].pvBuffer := nil;
    LOutDesc.ulVersion := SECBUFFER_VERSION;
    LOutDesc.cBuffers := 1;
    LOutDesc.pBuffers := @LOutBuf[0];

    // Primeira chamada passa contexto nulo; as seguintes, o ja criado.
    if FCtxtValid then
      LCtxPtr := @FCtxt
    else
      LCtxPtr := nil;

    LStatus := AcceptSecurityContext(@FCred, LCtxPtr, @LInDesc, ACCEPT_REQ,
      SECURITY_NATIVE_DREP, @FCtxt, @LOutDesc, @LAttr, nil);

    // Token de saida pendente (ate em SEC_E_OK pode haver): envia.
    if (LOutBuf[0].cbBuffer > 0) and (LOutBuf[0].pvBuffer <> nil) then
    begin
      SendAll(LOutBuf[0].pvBuffer, LOutBuf[0].cbBuffer);
      FreeContextBuffer(LOutBuf[0].pvBuffer);
      LOutBuf[0].pvBuffer := nil;
    end;

    if StatusIs(LStatus, SEC_E_INCOMPLETE_MESSAGE) then
    begin
      LReadMore := True; // record incompleto: preserva FCipher e le mais
      Continue;
    end;

    if StatusIs(LStatus, SEC_I_CONTINUE_NEEDED) or StatusIs(LStatus, SEC_E_OK) then
    begin
      FCtxtValid := True; // a partir daqui ha contexto a liberar no destructor
      // Sobras (inicio do proximo record) vem em SECBUFFER_EXTRA, no FIM do
      // buffer de entrada — mesma mecanica do lado cliente.
      if LInBuf[1].BufferType = SECBUFFER_EXTRA then
      begin
        LExtra := LInBuf[1].cbBuffer;
        if LExtra > 0 then
          Move(FCipher[FCipherLen - LExtra], FCipher[0], LExtra);
        FCipherLen := LExtra;
      end
      else
        FCipherLen := 0;

      if StatusIs(LStatus, SEC_E_OK) then
        Break;
      LReadMore := (FCipherLen = 0);
      Continue;
    end;

    raise EPipeTls.CreateFmt('handshake TLS (servidor) falhou (0x%.8x)',
      [Cardinal(LStatus)]);
  end;

  LStatus := QueryContextAttributesW(@FCtxt, SECPKG_ATTR_STREAM_SIZES,
    @FStreamSizes);
  if StatusFailed(LStatus) then
    raise EPipeTls.CreateFmt(
      'QueryContextAttributes(STREAM_SIZES) falhou (0x%.8x)', [Cardinal(LStatus)]);
end;

{$ENDIF PIPES_WINDOWS}

end.
