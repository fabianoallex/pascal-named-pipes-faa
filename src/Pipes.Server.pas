unit Pipes.Server;

{$I pipes.inc}

{ TPipeServer: servidor de Named Pipes multi-cliente.

  Threads:
    1 acceptor (TPipeAcceptorThread) + 1 reader por conexao
    (TPipeServerReaderThread) + pool de despacho (Pipes.Base).

  Invariantes de lock e posse (violar = deadlock/use-after-free):
  - FConnLock protege FConnections e FNextConnId. Ordem "de fora pra dentro":
    FConnLock -> write lock da conexao; nunca o inverso. Nenhum callback de
    usuario roda sob FConnLock.
  - Cada conexao tem refcount (FRefs): 1 do registro (FConnections) + 1
    transitorio por SendBytes em andamento. O objeto e' liberado quando zera.
  - REMOVER do dicionario e' o ato de POSSE do teardown: morte natural
    (reader), DisconnectClient e Stop disputam pela remocao sob FConnLock;
    so quem removeu faz CloseAbort/join/Release — nunca ha dois teardowns
    da mesma conexao.
  - Morte natural: o reader nao pode dar join em si mesmo, entao remove a
    conexao, despacha OnClientDisconnected e enfileira a limpeza (join do
    reader + Release) no pool GLOBAL, contada em FInFlight — Stop/Destroy
    esperam por ela no DrainInFlight.
  - Stop e' sincrono: fecha listener -> join do acceptor -> CloseAbort de
    todas as conexoes -> join dos readers -> DrainInFlight -> libera.
    NAO chame Stop/Destroy de dentro de um callback do proprio servidor.
  - DisconnectClient e' ASSINCRONO (CloseAbort + limpeza no pool): pode ser
    chamado ate de dentro de um callback da propria conexao.
  - Broadcast tira um snapshot das conexoes sob FConnLock (com AddRef) e
    envia FORA do lock: um cliente lento nao trava a lista nem os demais.
  - OnRequest roda SEMPRE no pool (global ou serializado), nunca na main
    thread mesmo em pdmMainThread: o reply e' enviado pelo proprio worker ao
    fim do handler e nao pode ficar atras do loop de mensagens. Excecao no
    handler (ou handler ausente) vira reply de erro (PIPE_FLAG_ERROR) — o
    Request do cliente levanta EPipeError com a mensagem. }

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  Generics.Collections,
  Pipes.Types,
  Pipes.Threading,
  Pipes.Framing,
  Pipes.Transport,
  Pipes.Base;

type
  TPipeServer = class;

  { Conexao aceita (interna; a API publica enxerga so o TPipeConnectionId). }
  TPipeServerConnection = class
  private
    FServer: TPipeServer;
    FId: TPipeConnectionId;
    FEndpoint: TPipeEndpoint;
    FStream: TPipeEndpointStream;
    FReader: TThread;
    FWriteLock: TCriticalSection;
    FRefs: Integer;
    // Conexao ESTABELECIDA: handshake concluido, prestes a disparar
    // OnClientConnected. Antes disso ela existe (ocupa vaga de MaxClients) mas
    // nao aparece em ClientIds/ClientCount — sob mTLS, uma conexao ainda
    // negociando pode nunca se autenticar, e contar como "cliente" um par que
    // sera' recusado e' o que fazia o painel piscar clientes fantasmas.
    // Escrito sob FConnLock pela reader thread; lido sob FConnLock.
    FEstablished: Boolean;
    procedure AddRef;
    procedure Release; // libera o objeto quando zera
    procedure StartReader;
    procedure SendFrame(const AFrame: TPipeFrame);
  public
    constructor Create(AServer: TPipeServer; AId: TPipeConnectionId;
      AEndpoint: TPipeEndpoint);
    destructor Destroy; override;
    property Id: TPipeConnectionId read FId;
  end;

  TPipeServer = class(TPipeBase)
  private
    FListener: TPipeListener;
    FAcceptor: TThread;
    FConnections: TDictionary<TPipeConnectionId, TPipeServerConnection>;
    // Identidades dos clientes autenticados. SEPARADO de FConnections de
    // proposito: a conexao sai do registro ANTES de OnClientDisconnected
    // disparar (a remocao e' o ato de posse do teardown), entao um handler que
    // perguntasse "quem saiu?" nao teria resposta se a identidade morresse
    // junto com a conexao.
    //
    // Nao da' para liberar a entrada na limpeza da conexao: o evento e a
    // limpeza vao para filas diferentes (pool de eventos x pool global) e, em
    // pdmPool ou pdmMainThread, nao ha ordem garantida entre os dois — a
    // identidade poderia sumir antes do handler rodar. Por isso a entrada
    // sobrevive, e o que limita a memoria e' o teto abaixo.
    FIdentities: TDictionary<TPipeConnectionId, TPipePeerIdentity>;
    FIdentityOrder: TList<TPipeConnectionId>; // ordem de chegada, p/ despejo
    FConnLock: TCriticalSection;
    FNextConnId: TPipeConnectionId; // sob FConnLock
    FActive: Boolean;
    FStopping: Integer; // atomico
    FMaxClients: Integer;
    FOnClientConnected: TPipeConnectionEvent;
    FOnClientDisconnected: TPipeConnectionEvent;
    FOnRequest: TPipeRequestEvent;
    // Chamados pelas threads/works internos (mesma unit):
    procedure HandleAccepted(AEndpoint: TPipeEndpoint);
    /// Marca a conexao como estabelecida e captura a identidade do par, se
    /// houver. Chamada pela reader thread apos o Handshake, ANTES de
    /// OnClientConnected.
    procedure PublishEstablished(AConn: TPipeServerConnection);
    procedure AcceptorFinished(const AError: string);
    procedure ReaderFinished(AConn: TPipeServerConnection; const AError: string);
    procedure HandleFrame(AConn: TPipeServerConnection; const AFrame: TPipeFrame);
    /// Remove a conexao do dicionario (ato de posse). False se outro teardown
    /// (Stop/DisconnectClient/morte natural) chegou antes.
    function TakeConnection(AConn: TPipeServerConnection): Boolean;
    procedure QueueCleanup(AConn: TPipeServerConnection);
    procedure RunCleanup(AConn: TPipeServerConnection); // roda no pool global
    procedure DispatchRequest(AConn: TPipeServerConnection; ACorrId: UInt64;
      const AData: TBytes);
    procedure ExecuteRequest(AConn: TPipeServerConnection; ACorrId: UInt64;
      const AData: TBytes; ACallback: TPipeRequestEvent); // roda no pool
  protected
    function GetActive: Boolean; override;
  public
    constructor Create(const AAddress: string;
      ATransport: TPipeTransport = ptLocal);
    destructor Destroy; override;
    /// Nao-blocante: cria o listener e sobe a acceptor thread.
    procedure Listen;
    /// Sincrono e idempotente: para tudo e espera callbacks em voo.
    procedure Stop;
    procedure SendBytes(AConnId: TPipeConnectionId; const AData: TBytes);
    procedure SendText(AConnId: TPipeConnectionId; const AText: string);
    /// Envia a todos os clientes conectados. Falha de envio a UM cliente e'
    /// ignorada (a desconexao dele sera notificada pelo proprio reader).
    procedure Broadcast(const AData: TBytes);
    procedure BroadcastText(const AText: string);
    /// Assincrono e idempotente: aborta a conexao; a limpeza roda no pool.
    procedure DisconnectClient(AConnId: TPipeConnectionId);
    /// Quantos clientes ESTABELECIDOS — aqueles para os quais
    /// OnClientConnected ja disparou e OnClientDisconnected ainda nao. Conexoes
    /// aceitas mas ainda negociando TLS nao entram: sob mTLS elas podem nunca
    /// se autenticar.
    ///
    /// Difere de MaxClients de proposito: aquele e' um limite de RECURSO e
    /// conta tambem as conexoes em negociacao, senao um par que nunca conclui
    /// o handshake nao ocuparia vaga nenhuma.
    function ClientCount: Integer;
    /// Ids dos clientes estabelecidos (mesmo criterio de ClientCount).
    function ClientIds: TArray<TPipeConnectionId>;
    /// Quem e' o cliente, segundo o certificado validado no handshake mTLS.
    /// False quando nao ha identidade verificada — sem TLS, ou com TLS sem
    /// mTLS. False NUNCA significa "ainda nao chegou": nao ha o que esperar.
    ///
    /// Continua respondendo DEPOIS de o cliente sair, entao um handler de
    /// OnClientDisconnected pode perguntar "quem saiu?". A identidade das
    /// ultimas PIPES_RECENT_IDENTITIES conexoes autenticadas fica retida; alem
    /// disso a mais antiga e' descartada.
    ///
    /// E' Try* e nao levanta como SendBytes porque o uso tipico e' varrer
    /// ClientIds e consultar cada um; entre as duas chamadas uma conexao pode
    /// cair, e uma excecao ali obrigaria try/except dentro do laco.
    function TryClientIdentity(AConnId: TPipeConnectionId;
      out AIdentity: TPipePeerIdentity): Boolean;
    property MaxClients: Integer read FMaxClients write FMaxClients; // 0 = sem teto
    property OnClientConnected: TPipeConnectionEvent
      read FOnClientConnected write FOnClientConnected;
    property OnClientDisconnected: TPipeConnectionEvent
      read FOnClientDisconnected write FOnClientDisconnected;
    /// Request-reply: o retorno em AReply vira o frame de resposta (mesmo
    /// corrId), enviado pelo worker ao fim do handler. Roda sempre no pool.
    property OnRequest: TPipeRequestEvent read FOnRequest write FOnRequest;
  end;

  /// Alias de compatibilidade (ver TNamedPipeBase em Pipes.Base).
  TNamedPipeServer = TPipeServer;

implementation

type
  TPipeAcceptorThread = class(TThread)
  private
    FServer: TPipeServer;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TPipeServer);
  end;

  TPipeServerReaderThread = class(TThread)
  private
    FConn: TPipeServerConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TPipeServerConnection);
  end;

  { Limpeza pos-morte de uma conexao cujo teardown pertence a um work item
    (morte natural/DisconnectClient): join do reader + Release do registro. }
  TPipeConnCleanupWork = class(TPipeWorkItem)
  private
    FServer: TPipeServer;
    FConn: TPipeServerConnection;
  public
    constructor Create(AServer: TPipeServer; AConn: TPipeServerConnection);
    procedure Execute; override;
  end;

  { Um request em execucao: handler + envio do reply, no pool. }
  TPipeRequestWork = class(TPipeWorkItem)
  private
    FServer: TPipeServer;
    FConn: TPipeServerConnection; // AddRef feito no despacho
    FCorrId: UInt64;
    FData: TBytes;
    FCallback: TPipeRequestEvent; // capturado no despacho (pode ser nil)
  public
    constructor Create(AServer: TPipeServer; AConn: TPipeServerConnection;
      ACorrId: UInt64; const AData: TBytes; ACallback: TPipeRequestEvent);
    procedure Execute; override;
  end;

{ TPipeAcceptorThread }

constructor TPipeAcceptorThread.Create(AServer: TPipeServer);
begin
  FServer := AServer;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeAcceptorThread.Execute;
var
  LEndpoint: TPipeEndpoint;
begin
  try
    while True do
    begin
      LEndpoint := FServer.FListener.Accept;
      if LEndpoint = nil then
        Break; // listener fechado (Stop)
      FServer.HandleAccepted(LEndpoint);
    end;
    FServer.AcceptorFinished('');
  except
    on E: Exception do
      FServer.AcceptorFinished(E.Message);
  end;
end;

{ TPipeServerReaderThread }

constructor TPipeServerReaderThread.Create(AConn: TPipeServerConnection);
begin
  FConn := AConn;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeServerReaderThread.Execute;
var
  LFrame: TPipeFrame;
begin
  try
    // Negociacao (TLS do lado servidor) AQUI, nao no Accept: presa nesta
    // thread, ela afeta so esta conexao. Um par que trave no meio nao impede
    // o servidor de aceitar os outros.
    FConn.FEndpoint.Handshake;
    // So depois de negociar o cliente conta como conectado — com mTLS e' o
    // ponto em que ele esta autenticado. Handshake que falha nunca dispara
    // OnClientConnected: cai direto no except como qualquer outra queda.
    //
    // A ordem aqui e' contratual: publicar ANTES do evento, para que um
    // handler de OnClientConnected que consulte ClientIds/TryClientIdentity ja
    // enxergue a propria conexao que acabou de ser anunciada.
    FConn.FServer.PublishEstablished(FConn);
    FConn.FServer.DispatchConnEvent(FConn.FServer.FOnClientConnected, FConn.Id);
    while True do
    begin
      LFrame := PipeReadFrame(FConn.FStream, FConn.FServer.MaxMessageSize);
      FConn.FServer.HandleFrame(FConn, LFrame);
    end;
  except
    on EPipeClosed do
      FConn.FServer.ReaderFinished(FConn, ''); // desconexao (normal)
    on E: Exception do
      FConn.FServer.ReaderFinished(FConn, E.Message); // erro de protocolo etc.
  end;
end;

{ TPipeConnCleanupWork }

constructor TPipeConnCleanupWork.Create(AServer: TPipeServer;
  AConn: TPipeServerConnection);
begin
  inherited Create;
  FServer := AServer;
  FConn := AConn;
end;

procedure TPipeConnCleanupWork.Execute;
begin
  FServer.RunCleanup(FConn);
end;

{ TPipeRequestWork }

constructor TPipeRequestWork.Create(AServer: TPipeServer;
  AConn: TPipeServerConnection; ACorrId: UInt64; const AData: TBytes;
  ACallback: TPipeRequestEvent);
begin
  inherited Create;
  FServer := AServer;
  FConn := AConn;
  FCorrId := ACorrId;
  FData := AData;
  FCallback := ACallback;
end;

procedure TPipeRequestWork.Execute;
begin
  FServer.ExecuteRequest(FConn, FCorrId, FData, FCallback);
end;

{ TPipeServerConnection }

constructor TPipeServerConnection.Create(AServer: TPipeServer;
  AId: TPipeConnectionId; AEndpoint: TPipeEndpoint);
begin
  inherited Create;
  FServer := AServer;
  FId := AId;
  FEndpoint := AEndpoint;
  FStream := TPipeEndpointStream.Create(AEndpoint);
  FWriteLock := TCriticalSection.Create;
  FRefs := 1; // referencia do registro (FConnections)
end;

destructor TPipeServerConnection.Destroy;
begin
  // FReader ja foi joinado e liberado por quem possuiu o teardown.
  FStream.Free;
  FEndpoint.Free;
  FWriteLock.Free;
  inherited;
end;

procedure TPipeServerConnection.AddRef;
begin
  PipeAtomicInc(FRefs);
end;

procedure TPipeServerConnection.Release;
begin
  if PipeAtomicDec(FRefs) = 0 then
    Free;
end;

procedure TPipeServerConnection.StartReader;
begin
  FReader := TPipeServerReaderThread.Create(Self);
end;

procedure TPipeServerConnection.SendFrame(const AFrame: TPipeFrame);
begin
  FWriteLock.Enter;
  try
    PipeWriteFrame(FStream, AFrame, FServer.MaxMessageSize);
  finally
    FWriteLock.Leave;
  end;
end;

{ TPipeServer }

constructor TPipeServer.Create(const AAddress: string;
  ATransport: TPipeTransport);
begin
  inherited Create(AAddress, ATransport);
  FConnections := TDictionary<TPipeConnectionId, TPipeServerConnection>.Create;
  FIdentities := TDictionary<TPipeConnectionId, TPipePeerIdentity>.Create;
  FIdentityOrder := TList<TPipeConnectionId>.Create;
  FConnLock := TCriticalSection.Create;
end;

destructor TPipeServer.Destroy;
begin
  try
    Stop; // idempotente
  except
  end;
  FConnections.Free;
  FIdentities.Free;
  FIdentityOrder.Free;
  FConnLock.Free;
  inherited;
end;

function TPipeServer.GetActive: Boolean;
begin
  Result := FActive;
end;

procedure TPipeServer.Listen;
begin
  if FActive then
    raise EPipeError.Create('servidor ja esta ativo');
  SetupDispatch;
  try
    // TlsOptions so' e' consultado em ptTls; nos demais a sobrecarga delega
    // para a forma sem opcoes. Erro de certificado/senha aparece AQUI, no
    // Listen, e nao quando o primeiro cliente conectar.
    FListener := PipeCreateListener(Address, Transport, KeepAliveSeconds,
      TlsOptions.AsOptions);
  except
    TeardownDispatch;
    raise;
  end;
  PipeAtomicSet(FStopping, 0);
  FActive := True;
  FAcceptor := TPipeAcceptorThread.Create(Self);
end;

procedure TPipeServer.Stop;
var
  LConns: TArray<TPipeServerConnection>;
  LConn: TPipeServerConnection;
begin
  if not FActive then
    Exit;
  PipeAtomicSet(FStopping, 1);

  // 1) para de aceitar: fecha o listener e espera o acceptor.
  FListener.Close;
  FAcceptor.WaitFor;
  FreeAndNil(FAcceptor);
  FreeAndNil(FListener);

  // 2) toma posse de todas as conexoes restantes.
  FConnLock.Enter;
  try
    LConns := FConnections.Values.ToArray;
    FConnections.Clear;
  finally
    FConnLock.Leave;
  end;

  // 3) aborta todas (desbloqueia os readers) e so entao faz os joins:
  //    o abort em lote evita esperar cada leitura serialmente.
  for LConn in LConns do
    LConn.FEndpoint.CloseAbort;
  for LConn in LConns do
  begin
    LConn.FReader.WaitFor;
    FreeAndNil(LConn.FReader);
    DispatchConnEvent(FOnClientDisconnected, LConn.FId);
    LConn.Release; // referencia do registro
  end;

  // 4) espera callbacks em voo (inclui limpezas de mortes naturais anteriores).
  DrainInFlight;
  TeardownDispatch;
  FActive := False;
end;

procedure TPipeServer.HandleAccepted(AEndpoint: TPipeEndpoint);
var
  LConn: TPipeServerConnection;
  LId: TPipeConnectionId;
begin
  if PipeAtomicGet(FStopping) <> 0 then
  begin
    AEndpoint.CloseAbort;
    AEndpoint.Free;
    Exit;
  end;
  LConn := nil;
  LId := 0;
  FConnLock.Enter;
  try
    if (FMaxClients <= 0) or (FConnections.Count < FMaxClients) then
    begin
      Inc(FNextConnId);
      LId := FNextConnId;
      LConn := TPipeServerConnection.Create(Self, LId, AEndpoint);
      FConnections.Add(LId, LConn);
    end;
  finally
    FConnLock.Leave;
  end;
  if LConn = nil then
  begin
    AEndpoint.CloseAbort;
    AEndpoint.Free;
    DispatchError(0, 'conexao recusada: MaxClients atingido');
    Exit;
  end;
  // OnClientConnected NAO e' despachado aqui: quem faz isso e' a reader thread,
  // depois do Handshake do endpoint (ver TPipeServerReaderThread.Execute). A
  // ordem "OnClientConnected antes do primeiro OnMessage desta conexao" segue
  // garantida no pdmSerialized, porque quem enfileira os dois e' a MESMA
  // thread, nesta ordem.
  //
  // Tudo o que roda aqui e' na thread de ACCEPT e precisa continuar rapido e
  // sem IO: e' o que impede um cliente lento de barrar os demais.
  LConn.StartReader;
end;

procedure TPipeServer.AcceptorFinished(const AError: string);
begin
  // Acceptor caiu com o servidor ativo (ex.: CreateNamedPipe falhou): o
  // servidor para de aceitar novos clientes, mas os conectados seguem; o
  // usuario decide (Stop/Listen de novo) a partir do OnError.
  if (AError <> '') and (PipeAtomicGet(FStopping) = 0) then
    DispatchError(0, 'acceptor encerrado: ' + AError);
end;

procedure TPipeServer.ReaderFinished(AConn: TPipeServerConnection;
  const AError: string);
begin
  if not TakeConnection(AConn) then
    Exit; // Stop/DisconnectClient ja possuem este teardown
  if AError <> '' then
    DispatchError(AConn.FId, AError);
  AConn.FEndpoint.CloseAbort; // erro de protocolo: transporte pode estar vivo
  DispatchConnEvent(FOnClientDisconnected, AConn.FId);
  QueueCleanup(AConn); // join deste proprio reader: precisa de outra thread
end;

procedure TPipeServer.HandleFrame(AConn: TPipeServerConnection;
  const AFrame: TPipeFrame);
begin
  case AFrame.Kind of
    pfkMessage:
      DispatchMessage(AConn.FId, AFrame.Payload);
    pfkRequest:
      DispatchRequest(AConn, AFrame.CorrId, AFrame.Payload);
    pfkPing, pfkReply:
      ; // ping: reservado; reply: servidor nao faz requests na v1
  end;
end;

procedure TPipeServer.DispatchRequest(AConn: TPipeServerConnection;
  ACorrId: UInt64; const AData: TBytes);
begin
  // Mesmo sem handler o work roda (para responder com erro ao cliente).
  AConn.AddRef; // o work escreve o reply nesta conexao
  IncInFlight;
  EventPool.Queue(TPipeRequestWork.Create(Self, AConn, ACorrId, AData, FOnRequest));
end;

procedure TPipeServer.ExecuteRequest(AConn: TPipeServerConnection;
  ACorrId: UInt64; const AData: TBytes; ACallback: TPipeRequestEvent);
var
  LReply: TBytes;
  LErr: string;
begin
  try
    LReply := nil;
    LErr := '';
    if Assigned(ACallback) then
      try
        ACallback(Self, AConn.FId, AData, LReply);
      except
        on E: Exception do
          LErr := E.Message; // excecao do handler vira reply de erro
      end
    else
      LErr := 'servidor sem handler OnRequest';
    try
      if LErr <> '' then
        AConn.SendFrame(TPipeFrame.ErrorReply(ACorrId, LErr))
      else
        AConn.SendFrame(TPipeFrame.Reply(ACorrId, LReply));
    except
      // conexao caiu antes do reply: o cliente ja vai receber EPipeClosed
    end;
  finally
    AConn.Release;
    DecInFlight;
  end;
end;

function TPipeServer.TakeConnection(AConn: TPipeServerConnection): Boolean;
var
  LCur: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    Result := FConnections.TryGetValue(AConn.FId, LCur) and (LCur = AConn);
    if Result then
      FConnections.Remove(AConn.FId);
  finally
    FConnLock.Leave;
  end;
end;

procedure TPipeServer.QueueCleanup(AConn: TPipeServerConnection);
begin
  // Sempre no pool GLOBAL: nao pode entrar atras de callbacks do usuario no
  // pool serializado. Contada em FInFlight para o Stop/Destroy esperarem.
  IncInFlight;
  PipePool.Queue(TPipeConnCleanupWork.Create(Self, AConn));
end;

procedure TPipeServer.RunCleanup(AConn: TPipeServerConnection);
begin
  try
    if Assigned(AConn.FReader) then
    begin
      AConn.FReader.WaitFor;
      FreeAndNil(AConn.FReader);
    end;
    AConn.Release; // referencia do registro
  finally
    DecInFlight;
  end;
end;

procedure TPipeServer.SendBytes(AConnId: TPipeConnectionId;
  const AData: TBytes);
var
  LConn: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    // FEstablished na condicao: um id so' vira publico em OnClientConnected,
    // que roda depois do handshake, entao na pratica ninguem tem como pedir
    // envio para uma conexao em negociacao. A checagem fecha o caso de um id
    // adivinhado ou guardado — e mantem a mesma regra de Broadcast.
    if FConnections.TryGetValue(AConnId, LConn) and LConn.FEstablished then
      LConn.AddRef // segura o objeto durante a escrita (fora do lock)
    else
      LConn := nil;
  finally
    FConnLock.Leave;
  end;
  if LConn = nil then
    raise EPipeError.Create('cliente ' + IntToStr(Int64(AConnId)) +
      ' nao esta conectado');
  try
    LConn.SendFrame(TPipeFrame.Msg(AData));
  finally
    LConn.Release;
  end;
end;

procedure TPipeServer.SendText(AConnId: TPipeConnectionId;
  const AText: string);
begin
  SendBytes(AConnId, PipeUtf8Encode(AText));
end;

procedure TPipeServer.Broadcast(const AData: TBytes);
var
  LConns: TArray<TPipeServerConnection>;
  LConn: TPipeServerConnection;
begin
  // Snapshot com AddRef sob o lock; envio fora dele (cliente lento nao trava
  // a lista) sob o write lock individual de cada conexao.
  //
  // So conexoes ESTABELECIDAS entram. Nao e' cosmetico: sob mTLS uma conexao
  // ainda em handshake e' um par que NAO se autenticou, e mandar payload de
  // aplicacao para ele seria vazar dado para quem talvez seja recusado a
  // seguir. (Mesmo sem mTLS o envio estaria errado: a sessao TLS ainda nao
  // existe, entao nao ha por onde cifrar.)
  SetLength(LConns, 0);
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished then
      begin
        LConn.AddRef;
        SetLength(LConns, Length(LConns) + 1);
        LConns[High(LConns)] := LConn;
      end;
  finally
    FConnLock.Leave;
  end;
  for LConn in LConns do
  begin
    try
      try
        LConn.SendFrame(TPipeFrame.Msg(AData));
      except
        // conexao caindo: o reader dela notificara; o broadcast segue
      end;
    finally
      LConn.Release;
    end;
  end;
end;

procedure TPipeServer.BroadcastText(const AText: string);
begin
  Broadcast(PipeUtf8Encode(AText));
end;

procedure TPipeServer.DisconnectClient(AConnId: TPipeConnectionId);
var
  LConn: TPipeServerConnection;
begin
  FConnLock.Enter;
  try
    if not FConnections.TryGetValue(AConnId, LConn) then
      Exit; // ja desconectado: idempotente
    FConnections.Remove(AConnId); // posse do teardown
  finally
    FConnLock.Leave;
  end;
  LConn.FEndpoint.CloseAbort; // o reader vai cair com EPipeClosed
  DispatchConnEvent(FOnClientDisconnected, AConnId);
  QueueCleanup(LConn);
end;

procedure TPipeServer.PublishEstablished(AConn: TPipeServerConnection);
var
  LIdentity: TPipePeerIdentity;
  LHas: Boolean;
begin
  // A consulta ao endpoint fica FORA do FConnLock: ela nao faz IO (a
  // identidade ja foi extraida durante o handshake e so' esta guardada), mas
  // segurar o lock das conexoes enquanto se chama codigo do transporte
  // inverteria a ordem "lista de conexoes -> transporte" que o resto da unit
  // respeita.
  LHas := AConn.FEndpoint.TryPeerIdentity(LIdentity);
  FConnLock.Enter;
  try
    if LHas then
    begin
      FIdentities.AddOrSetValue(AConn.Id, LIdentity);
      FIdentityOrder.Add(AConn.Id);
      // Despejo pelo mais antigo. Os ids sao monotonicos, entao a ordem de
      // chegada e' a propria ordem da lista.
      while FIdentityOrder.Count > PIPES_RECENT_IDENTITIES do
      begin
        FIdentities.Remove(FIdentityOrder[0]);
        FIdentityOrder.Delete(0);
      end;
    end;
    AConn.FEstablished := True;
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientCount: Integer;
var
  LConn: TPipeServerConnection;
begin
  Result := 0;
  FConnLock.Enter;
  try
    for LConn in FConnections.Values do
      if LConn.FEstablished then
        Inc(Result);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.TryClientIdentity(AConnId: TPipeConnectionId;
  out AIdentity: TPipePeerIdentity): Boolean;
var
  LConn: TPipeServerConnection;
begin
  Result := False;
  Finalize(AIdentity);
  FillChar(AIdentity, SizeOf(AIdentity), 0);
  FConnLock.Enter;
  try
    // Nao exige conexao viva: a identidade sobrevive a saida do cliente, que
    // e' justamente o que permite responder "quem saiu?" dentro do
    // OnClientDisconnected.
    Result := FIdentities.TryGetValue(AConnId, AIdentity);
  finally
    FConnLock.Leave;
  end;
end;

function TPipeServer.ClientIds: TArray<TPipeConnectionId>;
var
  LConn: TPipeServerConnection;
  LCount: Integer;
begin
  FConnLock.Enter;
  try
    SetLength(Result, FConnections.Count); // teto; encolhe no fim
    LCount := 0;
    for LConn in FConnections.Values do
      if LConn.FEstablished then
      begin
        Result[LCount] := LConn.Id;
        Inc(LCount);
      end;
    SetLength(Result, LCount);
  finally
    FConnLock.Leave;
  end;
end;

end.
