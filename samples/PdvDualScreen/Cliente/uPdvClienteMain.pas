unit uPdvClienteMain;

{ Tela do cliente do sample PDV dual-screen: acompanha os itens e o total que
  o operador vai lancando e, quando solicitado, mostra os botoes de forma de
  pagamento. Tudo passa por TPdvClienteChannel — este form nunca importa
  Pipes.Client/Pipes.Types diretamente, so Pdv.Protocolo/Pdv.ClienteChannel.

  Compila nos dois mundos a partir do MESMO fonte (dfm para o Delphi/VCL, lfm
  para o Lazarus/LCL), igual ao sample ChatVcl. AutoReconnect fica a cargo do
  TPdvClienteChannel: se o operador reiniciar o caixa, esta tela reconecta
  sozinha (sem reconstruir o estado da venda anterior — fora do escopo do
  sample). }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  Graphics, Controls, Forms, Dialogs, StdCtrls, ExtCtrls,
  Pdv.Protocolo, Pdv.ClienteChannel;

type
  TfrmPdvCliente = class(TForm)
    lblPipe: TLabel;
    edtPipeName: TEdit;
    btnConectar: TButton;
    lblStatus: TLabel;
    listItens: TListBox;
    lblTotal: TLabel;
    pnlPagamento: TPanel;
    lblEscolhaPagamento: TLabel;
    btnDinheiro: TButton;
    btnDebito: TButton;
    btnCredito: TButton;
    btnPix: TButton;
    memoLog: TMemo;
    procedure FormDestroy(Sender: TObject);
    procedure btnConectarClick(Sender: TObject);
    procedure btnDinheiroClick(Sender: TObject);
    procedure btnDebitoClick(Sender: TObject);
    procedure btnCreditoClick(Sender: TObject);
    procedure btnPixClick(Sender: TObject);
  private
    FChannel: TPdvClienteChannel;
    procedure Log(const S: string);
    procedure EscolherPagamento(AForma: TPdvFormaPagamento);
    procedure LimparTelaVenda;
    procedure ChConectado(Sender: TObject);
    procedure ChDesconectado(Sender: TObject);
    procedure ChItemAdicionado(Sender: TObject; const AItem: TPdvItem);
    procedure ChTotalAtualizado(Sender: TObject; ATotal: Currency);
    procedure ChSolicitarFormaPagamento(Sender: TObject);
    procedure ChVendaFinalizada(Sender: TObject);
    procedure ChVendaCancelada(Sender: TObject);
    procedure ChErro(Sender: TObject; const AMensagem: string);
  end;

var
  frmPdvCliente: TfrmPdvCliente;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

procedure TfrmPdvCliente.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TfrmPdvCliente.btnConectarClick(Sender: TObject);
begin
  FChannel := TPdvClienteChannel.Create(edtPipeName.Text);
  FChannel.OnConectado := ChConectado;
  FChannel.OnDesconectado := ChDesconectado;
  FChannel.OnItemAdicionado := ChItemAdicionado;
  FChannel.OnTotalAtualizado := ChTotalAtualizado;
  FChannel.OnSolicitarFormaPagamento := ChSolicitarFormaPagamento;
  FChannel.OnVendaFinalizada := ChVendaFinalizada;
  FChannel.OnVendaCancelada := ChVendaCancelada;
  FChannel.OnErro := ChErro;
  try
    FChannel.Conectar(3000); // blocante ate 3 s: aceitavel num clique de sample
  except
    FreeAndNil(FChannel);
    raise;
  end;
  btnConectar.Enabled := False;
  edtPipeName.Enabled := False;
end;

procedure TfrmPdvCliente.LimparTelaVenda;
begin
  listItens.Clear;
  lblTotal.Caption := 'Total: R$ 0.00';
  pnlPagamento.Visible := False;
end;

procedure TfrmPdvCliente.ChConectado(Sender: TObject);
begin
  lblStatus.Caption := 'conectado ao caixa';
  Log('conectado ao caixa.');
end;

procedure TfrmPdvCliente.ChDesconectado(Sender: TObject);
begin
  lblStatus.Caption := 'caixa caiu - reconectando...';
  Log('conexao com o caixa caiu.');
  pnlPagamento.Visible := False;
end;

procedure TfrmPdvCliente.ChItemAdicionado(Sender: TObject; const AItem: TPdvItem);
begin
  listItens.Items.Add(Format('%dx %s ....... R$ %.2f',
    [AItem.Quantidade, AItem.Descricao, AItem.ValorTotal]));
end;

procedure TfrmPdvCliente.ChTotalAtualizado(Sender: TObject; ATotal: Currency);
begin
  lblTotal.Caption := Format('Total: R$ %.2f', [ATotal]);
end;

procedure TfrmPdvCliente.ChSolicitarFormaPagamento(Sender: TObject);
begin
  pnlPagamento.Visible := True;
  Log('escolha a forma de pagamento.');
end;

procedure TfrmPdvCliente.EscolherPagamento(AForma: TPdvFormaPagamento);
begin
  FChannel.EscolherFormaPagamento(AForma);
  pnlPagamento.Visible := False;
  Log('voce escolheu: ' + PdvFormaPagamentoToStr(AForma));
end;

procedure TfrmPdvCliente.btnDinheiroClick(Sender: TObject);
begin
  EscolherPagamento(fpDinheiro);
end;

procedure TfrmPdvCliente.btnDebitoClick(Sender: TObject);
begin
  EscolherPagamento(fpDebito);
end;

procedure TfrmPdvCliente.btnCreditoClick(Sender: TObject);
begin
  EscolherPagamento(fpCredito);
end;

procedure TfrmPdvCliente.btnPixClick(Sender: TObject);
begin
  EscolherPagamento(fpPix);
end;

procedure TfrmPdvCliente.ChVendaFinalizada(Sender: TObject);
begin
  Log('venda finalizada - obrigado!');
  LimparTelaVenda;
end;

procedure TfrmPdvCliente.ChVendaCancelada(Sender: TObject);
begin
  Log('venda cancelada.');
  LimparTelaVenda;
end;

procedure TfrmPdvCliente.ChErro(Sender: TObject; const AMensagem: string);
begin
  Log('erro: ' + AMensagem);
end;

procedure TfrmPdvCliente.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread que ainda estiverem na fila viram no-op depois
  // daqui (objeto-guarda da lib) — fechar a janela no meio do trafego e' seguro.
  FreeAndNil(FChannel);
end;

end.
