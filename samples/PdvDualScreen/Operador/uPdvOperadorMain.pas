unit uPdvOperadorMain;

{ Tela do operador (frente de loja) do sample PDV dual-screen: ele adiciona
  itens, pede a forma de pagamento e finaliza/cancela a venda. Tudo que sai
  ou entra passa por TPdvOperadorChannel — este form nunca importa
  Pipes.Server/Pipes.Types diretamente, so Pdv.Protocolo/Pdv.OperadorChannel.

  Compila nos dois mundos a partir do MESMO fonte (dfm para o Delphi/VCL, lfm
  para o Lazarus/LCL), igual ao sample ChatVcl. }

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

interface

uses
  SysUtils, Classes, Generics.Collections,
  Graphics, Controls, Forms, Dialogs, StdCtrls,
  Pdv.Protocolo, Pdv.OperadorChannel;

type
  TfrmPdvOperador = class(TForm)
    lblPipe: TLabel;
    edtPipeName: TEdit;
    btnAbrirCaixa: TButton;
    lblStatus: TLabel;
    lblDescricao: TLabel;
    edtDescricao: TEdit;
    lblQuantidade: TLabel;
    edtQuantidade: TEdit;
    lblValor: TLabel;
    edtValor: TEdit;
    btnAdicionarItem: TButton;
    listItens: TListBox;
    lblTotal: TLabel;
    btnSolicitarPagamento: TButton;
    lblFormaPagamento: TLabel;
    btnFinalizarVenda: TButton;
    btnCancelarVenda: TButton;
    memoLog: TMemo;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure btnAbrirCaixaClick(Sender: TObject);
    procedure btnAdicionarItemClick(Sender: TObject);
    procedure btnSolicitarPagamentoClick(Sender: TObject);
    procedure btnFinalizarVendaClick(Sender: TObject);
    procedure btnCancelarVendaClick(Sender: TObject);
  private
    FChannel: TPdvOperadorChannel;
    FItens: TList<TPdvItem>;
    FTotal: Currency;
    FAguardandoPagamento: Boolean;
    FPagamentoEscolhido: Boolean;
    FFormatSettingsValor: TFormatSettings; // '.' fixo, independente da config regional
    procedure Log(const S: string);
    procedure AtualizarTotal;
    procedure ResetarVenda(const AMotivo: string);
    procedure AtualizarBotoesVenda;
    procedure ChClienteConectado(Sender: TObject);
    procedure ChClienteDesconectado(Sender: TObject);
    procedure ChFormaPagamentoEscolhida(Sender: TObject;
      AForma: TPdvFormaPagamento);
    procedure ChErro(Sender: TObject; const AMensagem: string);
  end;

var
  frmPdvOperador: TfrmPdvOperador;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

procedure TfrmPdvOperador.FormCreate(Sender: TObject);
begin
  FItens := TList<TPdvItem>.Create;
  FFormatSettingsValor := FormatSettings;
  FFormatSettingsValor.DecimalSeparator := '.';
  FFormatSettingsValor.ThousandSeparator := ',';
end;

procedure TfrmPdvOperador.Log(const S: string);
begin
  memoLog.Lines.Add(FormatDateTime('hh:nn:ss', Now) + '  ' + S);
end;

procedure TfrmPdvOperador.btnAbrirCaixaClick(Sender: TObject);
begin
  FChannel := TPdvOperadorChannel.Create(edtPipeName.Text);
  FChannel.OnClienteConectado := ChClienteConectado;
  FChannel.OnClienteDesconectado := ChClienteDesconectado;
  FChannel.OnFormaPagamentoEscolhida := ChFormaPagamentoEscolhida;
  FChannel.OnErro := ChErro;
  try
    FChannel.Iniciar;
  except
    FreeAndNil(FChannel);
    raise;
  end;
  lblStatus.Caption := 'caixa aberto - aguardando tela do cliente';
  Log('caixa aberto em "' + edtPipeName.Text + '".');
  btnAbrirCaixa.Enabled := False;
  edtPipeName.Enabled := False;
  AtualizarBotoesVenda;
end;

procedure TfrmPdvOperador.AtualizarTotal;
begin
  lblTotal.Caption := Format('Total: R$ %.2f', [FTotal]);
end;

procedure TfrmPdvOperador.AtualizarBotoesVenda;
var
  LCaixaAberto: Boolean;
  LEmAndamento: Boolean; // aguardando escolha OU ja escolhida (nao mexe mais nos itens)
begin
  LCaixaAberto := Assigned(FChannel);
  LEmAndamento := FAguardandoPagamento or FPagamentoEscolhido;
  btnAdicionarItem.Enabled := LCaixaAberto and not LEmAndamento;
  btnSolicitarPagamento.Enabled := LCaixaAberto and not LEmAndamento
    and (FItens.Count > 0);
  btnCancelarVenda.Enabled := LCaixaAberto and (FItens.Count > 0);
  btnFinalizarVenda.Enabled := LCaixaAberto and FPagamentoEscolhido;
end;

procedure TfrmPdvOperador.btnAdicionarItemClick(Sender: TObject);
var
  LItem: TPdvItem;
begin
  if Trim(edtDescricao.Text) = '' then
  begin
    ShowMessage('Informe a descricao do item.');
    Exit;
  end;
  LItem.Descricao := Trim(edtDescricao.Text);
  LItem.Quantidade := StrToIntDef(edtQuantidade.Text, 1);
  // StrToCurrDef usa o separador decimal da config regional (',' no
  // pt-BR): sem passar FormatSettings fixo com '.', o texto normalizado
  // abaixo (',' -> '.') falha ao parsear e cai no default 0.
  LItem.ValorUnitario := StrToCurrDef(
    StringReplace(edtValor.Text, ',', '.', []), 0, FFormatSettingsValor);
  if (LItem.Quantidade <= 0) or (LItem.ValorUnitario <= 0) then
  begin
    ShowMessage('Quantidade e valor precisam ser maiores que zero.');
    Exit;
  end;
  FItens.Add(LItem);
  FTotal := FTotal + LItem.ValorTotal;
  listItens.Items.Add(Format('%dx %s ....... R$ %.2f',
    [LItem.Quantidade, LItem.Descricao, LItem.ValorTotal]));
  AtualizarTotal;
  FChannel.EnviarItemAdicionado(LItem);
  FChannel.EnviarTotalAtualizado(FTotal);
  Log('item adicionado: ' + LItem.Descricao);
  edtDescricao.Text := '';
  edtQuantidade.Text := '1';
  edtValor.Text := '';
  edtDescricao.SetFocus;
  AtualizarBotoesVenda;
end;

procedure TfrmPdvOperador.btnSolicitarPagamentoClick(Sender: TObject);
begin
  FAguardandoPagamento := True;
  FChannel.SolicitarFormaPagamento;
  lblFormaPagamento.Caption := 'aguardando o cliente escolher...';
  Log('forma de pagamento solicitada ao cliente.');
  AtualizarBotoesVenda;
end;

procedure TfrmPdvOperador.btnFinalizarVendaClick(Sender: TObject);
begin
  FChannel.FinalizarVenda;
  Log('venda finalizada.');
  ResetarVenda('venda concluida - pronto para a proxima');
end;

procedure TfrmPdvOperador.btnCancelarVendaClick(Sender: TObject);
begin
  FChannel.CancelarVenda;
  Log('venda cancelada.');
  ResetarVenda('venda cancelada - pronto para a proxima');
end;

procedure TfrmPdvOperador.ResetarVenda(const AMotivo: string);
begin
  FItens.Clear;
  FTotal := 0;
  FAguardandoPagamento := False;
  FPagamentoEscolhido := False;
  listItens.Clear;
  AtualizarTotal;
  lblFormaPagamento.Caption := '';
  lblStatus.Caption := AMotivo;
  AtualizarBotoesVenda;
end;

procedure TfrmPdvOperador.ChClienteConectado(Sender: TObject);
begin
  lblStatus.Caption := 'tela do cliente conectada';
  Log('tela do cliente conectou.');
end;

procedure TfrmPdvOperador.ChClienteDesconectado(Sender: TObject);
begin
  lblStatus.Caption := 'tela do cliente desconectada';
  Log('tela do cliente caiu.');
end;

procedure TfrmPdvOperador.ChFormaPagamentoEscolhida(Sender: TObject;
  AForma: TPdvFormaPagamento);
begin
  FAguardandoPagamento := False;
  FPagamentoEscolhido := True;
  lblFormaPagamento.Caption := 'forma escolhida: ' + PdvFormaPagamentoToStr(AForma);
  Log('cliente escolheu: ' + PdvFormaPagamentoToStr(AForma));
  AtualizarBotoesVenda;
end;

procedure TfrmPdvOperador.ChErro(Sender: TObject; const AMensagem: string);
begin
  Log('erro: ' + AMensagem);
end;

procedure TfrmPdvOperador.FormDestroy(Sender: TObject);
begin
  // Eventos pdmMainThread que ainda estiverem na fila viram no-op depois
  // daqui (objeto-guarda da lib) — fechar a janela no meio do trafego e' seguro.
  FreeAndNil(FChannel);
  FItens.Free;
end;

end.
