unit Pdv.ClienteChannel;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Facade de dominio para a tela do cliente: encapsula TNamedPipeClient e fala
  TPdvItem/TPdvFormaPagamento com a UI. AutoReconnect fica ligado por
  padrao — se o frente de loja reiniciar, a tela do cliente volta sozinha
  (mas nao ha resincronizacao de estado da venda; ver comentario em
  Pdv.OperadorChannel).

  DispatchMode = pdmMainThread: os eventos abaixo chegam na thread da UI. }

interface

uses
  SysUtils, Classes,
  Pipes.Types, Pipes.Framing, Pipes.Client,
  Pdv.Protocolo;

type
  TPdvItemEvent = procedure(Sender: TObject; const AItem: TPdvItem) of object;
  TPdvTotalEvent = procedure(Sender: TObject; ATotal: Currency) of object;
  TPdvErrorEvent = procedure(Sender: TObject; const AMensagem: string) of object;

  TPdvClienteChannel = class
  private
    FClient: TNamedPipeClient;
    FOnConectado: TNotifyEvent;
    FOnDesconectado: TNotifyEvent;
    FOnItemAdicionado: TPdvItemEvent;
    FOnTotalAtualizado: TPdvTotalEvent;
    FOnSolicitarFormaPagamento: TNotifyEvent;
    FOnVendaFinalizada: TNotifyEvent;
    FOnVendaCancelada: TNotifyEvent;
    FOnErro: TPdvErrorEvent;
    procedure CliConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure CliMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure CliError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create(const APipeName: string);
    destructor Destroy; override;
    procedure Conectar(ATimeoutMs: Cardinal = 3000);
    procedure Desconectar;
    function Conectado: Boolean;
    procedure EscolherFormaPagamento(AForma: TPdvFormaPagamento);
    property OnConectado: TNotifyEvent read FOnConectado write FOnConectado;
    property OnDesconectado: TNotifyEvent
      read FOnDesconectado write FOnDesconectado;
    property OnItemAdicionado: TPdvItemEvent
      read FOnItemAdicionado write FOnItemAdicionado;
    property OnTotalAtualizado: TPdvTotalEvent
      read FOnTotalAtualizado write FOnTotalAtualizado;
    property OnSolicitarFormaPagamento: TNotifyEvent
      read FOnSolicitarFormaPagamento write FOnSolicitarFormaPagamento;
    property OnVendaFinalizada: TNotifyEvent
      read FOnVendaFinalizada write FOnVendaFinalizada;
    property OnVendaCancelada: TNotifyEvent
      read FOnVendaCancelada write FOnVendaCancelada;
    property OnErro: TPdvErrorEvent read FOnErro write FOnErro;
  end;

implementation

constructor TPdvClienteChannel.Create(const APipeName: string);
begin
  inherited Create;
  FClient := TNamedPipeClient.Create(APipeName);
  FClient.DispatchMode := pdmMainThread;
  FClient.AutoReconnect := True;
  FClient.OnConnected := CliConnected;
  FClient.OnDisconnected := CliDisconnected;
  FClient.OnMessage := CliMessage;
  FClient.OnError := CliError;
end;

destructor TPdvClienteChannel.Destroy;
begin
  FClient.Free; // Disconnect sincrono no destructor
  inherited;
end;

procedure TPdvClienteChannel.Conectar(ATimeoutMs: Cardinal);
begin
  FClient.Connect(ATimeoutMs);
end;

procedure TPdvClienteChannel.Desconectar;
begin
  FClient.Disconnect;
end;

function TPdvClienteChannel.Conectado: Boolean;
begin
  Result := FClient.Connected;
end;

procedure TPdvClienteChannel.EscolherFormaPagamento(AForma: TPdvFormaPagamento);
begin
  FClient.SendText(PdvEncodeFormaPagamentoEscolhida(AForma));
end;

procedure TPdvClienteChannel.CliConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if Assigned(FOnConectado) then
    FOnConectado(Self);
end;

procedure TPdvClienteChannel.CliDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if Assigned(FOnDesconectado) then
    FOnDesconectado(Self);
end;

procedure TPdvClienteChannel.CliMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LLinha: string;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    case PdvMsgKindOf(LLinha) of
      pmkItemAdicionado:
        if Assigned(FOnItemAdicionado) then
          FOnItemAdicionado(Self, PdvDecodeItemAdicionado(LLinha));
      pmkTotalAtualizado:
        if Assigned(FOnTotalAtualizado) then
          FOnTotalAtualizado(Self, PdvDecodeTotalAtualizado(LLinha));
      pmkSolicitarFormaPagamento:
        if Assigned(FOnSolicitarFormaPagamento) then
          FOnSolicitarFormaPagamento(Self);
      pmkVendaFinalizada:
        if Assigned(FOnVendaFinalizada) then
          FOnVendaFinalizada(Self);
      pmkVendaCancelada:
        if Assigned(FOnVendaCancelada) then
          FOnVendaCancelada(Self);
    else
      if Assigned(FOnErro) then
        FOnErro(Self, 'mensagem inesperada do operador: ' + LLinha);
    end;
  except
    on E: EPdvProtocolo do
      if Assigned(FOnErro) then
        FOnErro(Self, E.Message);
  end;
end;

procedure TPdvClienteChannel.CliError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  if Assigned(FOnErro) then
    FOnErro(Self, AError);
end;

end.
