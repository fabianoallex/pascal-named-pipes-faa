unit Pdv.OperadorChannel;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Facade de dominio para a tela do operador (frente de loja): encapsula
  TNamedPipeServer e fala TPdvItem/TPdvFormaPagamento com a UI — nunca
  TBytes/TPipeConnectionId. So a tela do cliente conecta neste pipe; o
  Broadcast cobre o caso de zero clientes (nao envia nada, sem erro) e o de
  reconexao (quem reconecta perde o que foi enviado antes — um PDV de
  verdade resincronizaria o estado da venda no OnClienteConectado; fora do
  escopo deste sample).

  DispatchMode = pdmMainThread: os eventos abaixo chegam na thread da UI do
  form que usar este canal, sem Synchronize/Queue manual. }

interface

uses
  SysUtils, Classes,
  Pipes.Types, Pipes.Framing, Pipes.Server,
  Pdv.Protocolo;

type
  TPdvFormaPagamentoEvent = procedure(Sender: TObject;
    AForma: TPdvFormaPagamento) of object;
  TPdvErrorEvent = procedure(Sender: TObject; const AMensagem: string) of object;

  TPdvOperadorChannel = class
  private
    FServer: TNamedPipeServer;
    FOnClienteConectado: TNotifyEvent;
    FOnClienteDesconectado: TNotifyEvent;
    FOnFormaPagamentoEscolhida: TPdvFormaPagamentoEvent;
    FOnErro: TPdvErrorEvent;
    procedure SrvConnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvDisconnected(Sender: TObject; AConnId: TPipeConnectionId);
    procedure SrvMessage(Sender: TObject; AConnId: TPipeConnectionId;
      const AData: TBytes);
    procedure SrvError(Sender: TObject; AConnId: TPipeConnectionId;
      const AError: string);
  public
    constructor Create(const APipeName: string);
    destructor Destroy; override;
    procedure Iniciar;
    procedure Parar;
    function TelaClienteConectada: Boolean;
    procedure EnviarItemAdicionado(const AItem: TPdvItem);
    procedure EnviarTotalAtualizado(ATotal: Currency);
    procedure SolicitarFormaPagamento;
    procedure FinalizarVenda;
    procedure CancelarVenda;
    property OnClienteConectado: TNotifyEvent
      read FOnClienteConectado write FOnClienteConectado;
    property OnClienteDesconectado: TNotifyEvent
      read FOnClienteDesconectado write FOnClienteDesconectado;
    property OnFormaPagamentoEscolhida: TPdvFormaPagamentoEvent
      read FOnFormaPagamentoEscolhida write FOnFormaPagamentoEscolhida;
    property OnErro: TPdvErrorEvent read FOnErro write FOnErro;
  end;

implementation

constructor TPdvOperadorChannel.Create(const APipeName: string);
begin
  inherited Create;
  FServer := TNamedPipeServer.Create(APipeName);
  FServer.DispatchMode := pdmMainThread;
  FServer.OnClientConnected := SrvConnected;
  FServer.OnClientDisconnected := SrvDisconnected;
  FServer.OnMessage := SrvMessage;
  FServer.OnError := SrvError;
end;

destructor TPdvOperadorChannel.Destroy;
begin
  FServer.Free; // Stop sincrono no destructor
  inherited;
end;

procedure TPdvOperadorChannel.Iniciar;
begin
  FServer.Listen;
end;

procedure TPdvOperadorChannel.Parar;
begin
  FServer.Stop;
end;

function TPdvOperadorChannel.TelaClienteConectada: Boolean;
begin
  Result := FServer.ClientCount > 0;
end;

procedure TPdvOperadorChannel.EnviarItemAdicionado(const AItem: TPdvItem);
begin
  FServer.BroadcastText(PdvEncodeItemAdicionado(AItem));
end;

procedure TPdvOperadorChannel.EnviarTotalAtualizado(ATotal: Currency);
begin
  FServer.BroadcastText(PdvEncodeTotalAtualizado(ATotal));
end;

procedure TPdvOperadorChannel.SolicitarFormaPagamento;
begin
  FServer.BroadcastText(PdvEncodeSolicitarFormaPagamento);
end;

procedure TPdvOperadorChannel.FinalizarVenda;
begin
  FServer.BroadcastText(PdvEncodeVendaFinalizada);
end;

procedure TPdvOperadorChannel.CancelarVenda;
begin
  FServer.BroadcastText(PdvEncodeVendaCancelada);
end;

procedure TPdvOperadorChannel.SrvConnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if Assigned(FOnClienteConectado) then
    FOnClienteConectado(Self);
end;

procedure TPdvOperadorChannel.SrvDisconnected(Sender: TObject;
  AConnId: TPipeConnectionId);
begin
  if Assigned(FOnClienteDesconectado) then
    FOnClienteDesconectado(Self);
end;

procedure TPdvOperadorChannel.SrvMessage(Sender: TObject;
  AConnId: TPipeConnectionId; const AData: TBytes);
var
  LLinha: string;
begin
  LLinha := PipeUtf8Decode(AData);
  try
    if PdvMsgKindOf(LLinha) = pmkFormaPagamentoEscolhida then
    begin
      if Assigned(FOnFormaPagamentoEscolhida) then
        FOnFormaPagamentoEscolhida(Self, PdvDecodeFormaPagamentoEscolhida(LLinha));
    end
    else if Assigned(FOnErro) then
      FOnErro(Self, 'mensagem inesperada da tela do cliente: ' + LLinha);
  except
    on E: EPdvProtocolo do
      if Assigned(FOnErro) then
        FOnErro(Self, E.Message);
  end;
end;

procedure TPdvOperadorChannel.SrvError(Sender: TObject;
  AConnId: TPipeConnectionId; const AError: string);
begin
  if Assigned(FOnErro) then
    FOnErro(Self, AError);
end;

end.
