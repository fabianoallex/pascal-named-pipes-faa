unit Pipes.Transport.Tls;

{$I pipes.inc}

{ Transporte TLS (ptTls): TCP com a sessao cifrada por cima.

  Esta unit e' o ponto NEUTRO — nao implementa TLS. Ela escolhe o backend e faz
  a adaptacao de contratos:

    backend TLS                  quem implementa
    Windows .................... Pipes.Transport.Schannel (SSPI nativo; nao
                                 depende de DLL externa — decisivo em parque de
                                 maquinas antigo, onde distribuir e atualizar
                                 OpenSSL e' problema operacional)
    POSIX (e Windows opt-in) ... Pipes.Transport.OpenSSL (libssl/libcrypto
                                 carregadas dinamicamente)

  A adaptacao existe porque os dois lados falam linguas diferentes:

    TPipeEndpoint  --TPipeEndpointStream-->  TStream  --backend TLS-->  TStream
                                                                          |
    TPipeTlsEndpoint <--------------------------------------------------- +

  Ou seja: o endpoint TCP vira TStream, o backend cifra sobre esse TStream, e
  TPipeTlsEndpoint traz o resultado de volta ao contrato TPipeEndpoint que o
  resto da lib conhece. O framing NPF1 nao sabe que ha TLS embaixo.

  Invariantes (alem do contrato de Pipes.Transport):
  - POSSE: o stream do backend e' dono do TStream de baixo (libera os dois no
    Free), mas NAO do TPipeEndpoint TCP — esse e' liberado aqui. Ordem no
    destructor: primeiro o stream TLS (que tenta o close_notify), depois o
    endpoint.
  - ABORT: CloseAbort delega ao endpoint TCP. Uma leitura presa no backend TLS
    esta, na pratica, presa no Read do endpoint de baixo; abortar aquele faz o
    EPipeClosed subir pela pilha de decifragem. Nao ha estado a desarmar no
    proprio TLS.
  - O contrato de Read difere do TStream: aqui Read NUNCA devolve 0 — fim de
    conexao e' EPipeClosed. A conversao e' feita neste adaptador.

  Onde cada lado negocia:
  - CLIENTE: no construtor, na thread de quem chamou Connect. Quem espera e'
    quem pediu, entao bloquear ali nao afeta mais ninguem.
  - SERVIDOR: NAO no accept. O listener devolve o endpoint ainda nao
    negociado e quem chama Handshake e' a reader thread da conexao. Feito no
    accept, um unico cliente travado no meio do handshake impediria o servidor
    de aceitar todos os outros.

  Estado: servidor implementado so no Windows (Schannel). No POSIX o lado
  servidor do OpenSSL ainda falta, e TlsPipeCreateListener recusa. }

interface

uses
  SysUtils,
  Classes,
  Pipes.Types,
  Pipes.Transport
  {$IFDEF PIPES_WINDOWS}
  , Pipes.Transport.Schannel // TPipeSchannelServerStream e' campo da classe
  {$ENDIF};

type
  { Embrulha um TPipeEndpoint ja conectado numa sessao TLS. Assume a posse do
    endpoint de baixo. }
  TPipeTlsEndpoint = class(TPipeEndpoint)
  private
    FInner: TPipeEndpoint;   // endpoint TCP; propriedade desta classe
    FTls: TStream;           // stream do backend; dono do TPipeEndpointStream
    {$IFDEF PIPES_WINDOWS}
    // <> nil enquanto ha negociacao de servidor pendente.
    FServerTls: TPipeSchannelServerStream;
    {$ENDIF}
  public
    /// ATargetName e' o nome usado para SNI e para validar o certificado
    /// (tipicamente o host de Address). AVerifyPeer=False desliga a validacao
    /// da cadeia — util so em laboratorio, nunca em producao.
    constructor Create(AInner: TPipeEndpoint; const ATargetName: string;
      AVerifyPeer: Boolean);
    {$IFDEF PIPES_WINDOWS}
    /// Lado SERVIDOR: embrulha o endpoint aceito sem negociar nada ainda. A
    /// negociacao acontece em Handshake, chamado pela reader thread — no
    /// accept, um cliente lento prenderia o servidor inteiro (ver T1).
    constructor CreateServer(AInner: TPipeEndpoint; ACertContext: Pointer);
    {$ENDIF}
    destructor Destroy; override;
    procedure Handshake; override;
    function Read(var ABuffer; ACount: Integer): Integer; override;
    procedure WriteExactly(const ABuffer; ACount: Integer); override;
    procedure CloseAbort; override;
  end;

{$IFDEF PIPES_WINDOWS}
  { Listener que embrulha o listener TCP: cada conexao aceita volta como
    TPipeTlsEndpoint AINDA NAO negociado. E' dono do certificado, que e'
    compartilhado por todas as conexoes. }
  TPipeTlsListener = class(TPipeListener)
  private
    FInner: TPipeListener;
    FCertContext: Pointer;
  public
    constructor Create(AInner: TPipeListener; ACertContext: Pointer);
    destructor Destroy; override;
    function Accept: TPipeEndpoint; override;
    procedure Close; override;
  end;
{$ENDIF}

/// Conecta via TCP e faz o handshake TLS como CLIENTE.
function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;

/// ACertFile e' um PFX com a chave privada do servidor. O handshake de cada
/// conexao roda depois, na reader thread dela (ver TPipeEndpoint.Handshake).
function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const ACertFile, ACertPassword: string): TPipeListener;

implementation

uses
  Pipes.Transport.Tcp
  {$IFDEF PIPES_OPENSSL}
  , Pipes.Transport.OpenSSL
  {$ENDIF};

{ TPipeTlsEndpoint }

constructor TPipeTlsEndpoint.Create(AInner: TPipeEndpoint;
  const ATargetName: string; AVerifyPeer: Boolean);
var
  LRaw: TPipeEndpointStream;
begin
  inherited Create;
  FInner := AInner; // posse assumida JA: se o handshake abaixo levantar, o
                    // destructor desta classe e' chamado e libera AInner — o
                    // chamador nao deve liberar nada depois de chamar Create.
  // TPipeEndpointStream nao e' dono do endpoint; o backend TLS passa a ser
  // dono DELE (nao do endpoint).
  //
  // Sem 'try/except LRaw.Free' aqui de proposito: o backend assume a posse de
  // LRaw na primeira linha do construtor dele, entao se o handshake falhar o
  // destructor DELE ja libera LRaw. Liberar aqui tambem seria double-free —
  // e' o que o cabecalho de Pipes.Transport.Schannel avisa, e o que uma versao
  // anterior deste adaptador fazia (EAccessViolation ao rejeitar certificado
  // invalido, justamente o caminho de erro que precisa funcionar).
  {$IFDEF PIPES_OPENSSL}
  LRaw := TPipeEndpointStream.Create(AInner);
  FTls := TPipeOpenSslStream.Create(LRaw, ATargetName, AVerifyPeer);
  {$ELSE}
    {$IFDEF PIPES_WINDOWS}
    LRaw := TPipeEndpointStream.Create(AInner);
    FTls := TPipeSchannelStream.Create(LRaw, ATargetName, AVerifyPeer);
    {$ELSE}
    raise EPipeTls.Create('build sem backend TLS: compile com PIPES_OPENSSL');
    {$ENDIF}
  {$ENDIF}
end;

{$IFDEF PIPES_WINDOWS}
constructor TPipeTlsEndpoint.CreateServer(AInner: TPipeEndpoint;
  ACertContext: Pointer);
var
  LRaw: TPipeEndpointStream;
begin
  inherited Create;
  FInner := AInner; // posse assumida ja (mesma regra do construtor cliente)
  LRaw := TPipeEndpointStream.Create(AInner);
  FServerTls := TPipeSchannelServerStream.Create(LRaw, ACertContext);
  FTls := FServerTls;
end;
{$ENDIF}

procedure TPipeTlsEndpoint.Handshake;
begin
  {$IFDEF PIPES_WINDOWS}
  // So o lado servidor tem negociacao pendente; no cliente ela ja aconteceu
  // no construtor, na thread de quem chamou Connect.
  if Assigned(FServerTls) then
    FServerTls.Negotiate;
  {$ENDIF}
end;

destructor TPipeTlsEndpoint.Destroy;
begin
  // O stream TLS tenta o close_notify no proprio destructor (best-effort, ja
  // protegido la) e libera o TPipeEndpointStream. O endpoint TCP e' nosso.
  FTls.Free;
  FInner.Free;
  inherited;
end;

procedure TPipeTlsEndpoint.CloseAbort;
begin
  // Toda espera do backend TLS termina num Read/Write do endpoint de baixo:
  // abortar la desbloqueia a pilha inteira. Idempotente porque o do TCP e'.
  if Assigned(FInner) then
    FInner.CloseAbort;
end;

function TPipeTlsEndpoint.Read(var ABuffer; ACount: Integer): Integer;
begin
  Result := FTls.Read(ABuffer, ACount);
  // TStream sinaliza fim com 0; o contrato de TPipeEndpoint e' excecao.
  if Result <= 0 then
    raise EPipeClosed.Create('conexao TLS encerrada pelo par');
end;

procedure TPipeTlsEndpoint.WriteExactly(const ABuffer; ACount: Integer);
begin
  // Os backends escrevem tudo ou levantam; o laco e' rede de seguranca para
  // uma eventual escrita parcial.
  if FTls.Write(ABuffer, ACount) <> ACount then
    raise EPipeClosed.Create('escrita TLS incompleta');
end;

{ --- fabricas --- }

function TlsPipeConnect(const AAddress: string; ATimeoutMs: Cardinal;
  AKeepAliveSeconds: Cardinal; AVerifyPeer: Boolean): TPipeEndpoint;
var
  LTcp: TPipeEndpoint;
  LHost: string;
  LPort: Word;
begin
  // O host de Address e' o nome esperado no certificado (SNI + validacao).
  PipeParseHostPort(AAddress, LHost, LPort);
  LTcp := TcpPipeConnect(AAddress, ATimeoutMs, AKeepAliveSeconds);
  // Idem: TPipeTlsEndpoint.Create assume a posse de LTcp imediatamente, e o
  // destructor dele o libera se o handshake falhar. Nao ha nada a liberar aqui.
  Result := TPipeTlsEndpoint.Create(LTcp, LHost, AVerifyPeer);
end;

{$IFDEF PIPES_WINDOWS}

{ TPipeTlsListener }

constructor TPipeTlsListener.Create(AInner: TPipeListener;
  ACertContext: Pointer);
begin
  inherited Create;
  FInner := AInner;
  FCertContext := ACertContext;
end;

destructor TPipeTlsListener.Destroy;
begin
  FInner.Free;
  PipeSchannelFreeCert(FCertContext);
  inherited;
end;

function TPipeTlsListener.Accept: TPipeEndpoint;
var
  LTcp: TPipeEndpoint;
begin
  LTcp := FInner.Accept;
  if LTcp = nil then
    Exit(nil); // listener fechado
  // Sem handshake aqui de proposito: esta chamada roda na thread de accept.
  Result := TPipeTlsEndpoint.CreateServer(LTcp, FCertContext);
end;

procedure TPipeTlsListener.Close;
begin
  FInner.Close;
end;

{$ENDIF}

function TlsPipeCreateListener(const AAddress: string;
  AKeepAliveSeconds: Cardinal;
  const ACertFile, ACertPassword: string): TPipeListener;
{$IFDEF PIPES_WINDOWS}
var
  LTcp: TPipeListener;
  LCert: Pointer;
{$ENDIF}
begin
  {$IFDEF PIPES_WINDOWS}
  LCert := PipeSchannelLoadPfx(ACertFile, ACertPassword);
  try
    LTcp := TcpPipeCreateListener(AAddress, AKeepAliveSeconds);
  except
    PipeSchannelFreeCert(LCert); // o listener nao chegou a assumir a posse
    raise;
  end;
  Result := TPipeTlsListener.Create(LTcp, LCert);
  {$ELSE}
  Result := nil;
  raise EPipeTls.Create('servidor ptTls no POSIX ainda nao implementado ' +
    '(exige o lado servidor do OpenSSL)');
  {$ENDIF}
end;

end.
