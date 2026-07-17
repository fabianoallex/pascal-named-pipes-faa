unit Pdv.Protocolo;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$H+}
{$ENDIF}

{ Contrato de mensagens do PDV dual-screen (tela do operador <-> tela do
  cliente). Unit pura: so texto e tipos de dominio, sem depender da lib de
  pipes — e' o que faz operador e cliente se entenderem sem que a UI de
  nenhum dos dois lados veja TBytes/TPipeConnectionId (isso fica encapsulado
  em Pdv.OperadorChannel / Pdv.ClienteChannel).

  Formato de fio (uma linha de texto UTF-8 por mensagem): "KIND|campo1|campo2".
  Valores monetarios trafegam em centavos (Int64) para nao depender do
  separador decimal da configuracao regional da maquina. }

interface

uses
  SysUtils;

type
  TPdvMsgKind = (
    pmkItemAdicionado,          // operador -> cliente
    pmkTotalAtualizado,         // operador -> cliente
    pmkSolicitarFormaPagamento, // operador -> cliente
    pmkFormaPagamentoEscolhida, // cliente -> operador
    pmkVendaFinalizada,         // operador -> cliente
    pmkVendaCancelada           // operador -> cliente
  );

  TPdvFormaPagamento = (fpDinheiro, fpDebito, fpCredito, fpPix);

  TPdvItem = record
    Descricao: string;
    Quantidade: Integer;
    ValorUnitario: Currency;
    function ValorTotal: Currency;
  end;

  EPdvProtocolo = class(Exception);

function PdvFormaPagamentoToStr(AForma: TPdvFormaPagamento): string;
function PdvFormaPagamentoFromStr(const AStr: string): TPdvFormaPagamento;

/// Le so o "KIND" da linha. EPdvProtocolo se a linha nao for reconhecida.
function PdvMsgKindOf(const ALinha: string): TPdvMsgKind;

function PdvEncodeItemAdicionado(const AItem: TPdvItem): string;
function PdvDecodeItemAdicionado(const ALinha: string): TPdvItem;

function PdvEncodeTotalAtualizado(ATotal: Currency): string;
function PdvDecodeTotalAtualizado(const ALinha: string): Currency;

function PdvEncodeFormaPagamentoEscolhida(AForma: TPdvFormaPagamento): string;
function PdvDecodeFormaPagamentoEscolhida(const ALinha: string): TPdvFormaPagamento;

// Mensagens sem payload: o KIND sozinho ja diz tudo.
function PdvEncodeSolicitarFormaPagamento: string;
function PdvEncodeVendaFinalizada: string;
function PdvEncodeVendaCancelada: string;

implementation

const
  KIND_NAMES: array[TPdvMsgKind] of string = (
    'ITEM_ADICIONADO', 'TOTAL_ATUALIZADO', 'SOLICITAR_FORMA_PAGAMENTO',
    'FORMA_PAGAMENTO_ESCOLHIDA', 'VENDA_FINALIZADA', 'VENDA_CANCELADA');

  FORMA_NAMES: array[TPdvFormaPagamento] of string = (
    'DINHEIRO', 'DEBITO', 'CREDITO', 'PIX');

{ TPdvItem }

function TPdvItem.ValorTotal: Currency;
begin
  Result := ValorUnitario * Quantidade;
end;

{ Consome e remove o proximo campo de AText, delimitado por '|'. }
function PdvNextToken(var AText: string): string;
var
  LPos: Integer;
begin
  LPos := Pos('|', AText);
  if LPos = 0 then
  begin
    Result := AText;
    AText := '';
  end
  else
  begin
    Result := Copy(AText, 1, LPos - 1);
    Delete(AText, 1, LPos);
  end;
end;

function PdvFormaPagamentoToStr(AForma: TPdvFormaPagamento): string;
begin
  Result := FORMA_NAMES[AForma];
end;

function PdvFormaPagamentoFromStr(const AStr: string): TPdvFormaPagamento;
var
  LForma: TPdvFormaPagamento;
begin
  for LForma := Low(TPdvFormaPagamento) to High(TPdvFormaPagamento) do
    if SameText(FORMA_NAMES[LForma], AStr) then
      Exit(LForma);
  raise EPdvProtocolo.CreateFmt('forma de pagamento desconhecida: "%s"', [AStr]);
end;

function PdvMsgKindOf(const ALinha: string): TPdvMsgKind;
var
  LResto, LToken: string;
  LKind: TPdvMsgKind;
begin
  LResto := ALinha;
  LToken := PdvNextToken(LResto);
  for LKind := Low(TPdvMsgKind) to High(TPdvMsgKind) do
    if SameText(KIND_NAMES[LKind], LToken) then
      Exit(LKind);
  raise EPdvProtocolo.CreateFmt('mensagem desconhecida: "%s"', [ALinha]);
end;

function PdvEncodeItemAdicionado(const AItem: TPdvItem): string;
begin
  // Protocolo de exemplo sem escaping de verdade: '|' numa descricao vira
  // espaco para nao quebrar o parser.
  Result := KIND_NAMES[pmkItemAdicionado] + '|' +
    StringReplace(AItem.Descricao, '|', ' ', [rfReplaceAll]) + '|' +
    IntToStr(AItem.Quantidade) + '|' +
    IntToStr(Round(AItem.ValorUnitario * 100));
end;

function PdvDecodeItemAdicionado(const ALinha: string): TPdvItem;
var
  LResto: string;
begin
  LResto := ALinha;
  PdvNextToken(LResto); // KIND, ja identificado por PdvMsgKindOf
  Result.Descricao := PdvNextToken(LResto);
  Result.Quantidade := StrToInt(PdvNextToken(LResto));
  Result.ValorUnitario := StrToInt64(PdvNextToken(LResto)) / 100;
end;

function PdvEncodeTotalAtualizado(ATotal: Currency): string;
begin
  Result := KIND_NAMES[pmkTotalAtualizado] + '|' + IntToStr(Round(ATotal * 100));
end;

function PdvDecodeTotalAtualizado(const ALinha: string): Currency;
var
  LResto: string;
begin
  LResto := ALinha;
  PdvNextToken(LResto);
  Result := StrToInt64(PdvNextToken(LResto)) / 100;
end;

function PdvEncodeFormaPagamentoEscolhida(AForma: TPdvFormaPagamento): string;
begin
  Result := KIND_NAMES[pmkFormaPagamentoEscolhida] + '|' + FORMA_NAMES[AForma];
end;

function PdvDecodeFormaPagamentoEscolhida(const ALinha: string): TPdvFormaPagamento;
var
  LResto: string;
begin
  LResto := ALinha;
  PdvNextToken(LResto);
  Result := PdvFormaPagamentoFromStr(PdvNextToken(LResto));
end;

function PdvEncodeSolicitarFormaPagamento: string;
begin
  Result := KIND_NAMES[pmkSolicitarFormaPagamento];
end;

function PdvEncodeVendaFinalizada: string;
begin
  Result := KIND_NAMES[pmkVendaFinalizada];
end;

function PdvEncodeVendaCancelada: string;
begin
  Result := KIND_NAMES[pmkVendaCancelada];
end;

end.
