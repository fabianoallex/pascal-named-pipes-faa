program PdvOperador;

{ PDV dual-screen - tela do operador (frente de loja). Roda junto com
  PdvCliente (tela do cliente): o operador adiciona itens, pede a forma de
  pagamento e finaliza/cancela a venda; o cliente acompanha e responde
  escolhendo a forma de pagamento quando solicitado.

  Mostra como encapsular TNamedPipeServer atras de uma facade de dominio
  (Pdv.OperadorChannel) em vez de a UI falar TBytes/ConnId direto — ver
  samples/PdvDualScreen/Pdv.Protocolo.pas e Pdv.OperadorChannel.pas. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  Pdv.Protocolo in '..\Pdv.Protocolo.pas',
  Pdv.OperadorChannel in '..\Pdv.OperadorChannel.pas',
  uPdvOperadorMain in 'uPdvOperadorMain.pas' {frmPdvOperador};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmPdvOperador, frmPdvOperador);
  Application.Run;
end.
