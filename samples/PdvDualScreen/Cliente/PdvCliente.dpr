program PdvCliente;

{ PDV dual-screen - tela do cliente. Roda junto com PdvOperador (tela do
  operador): acompanha os itens/total lancados pelo operador e, quando
  solicitado, permite escolher a forma de pagamento.

  Mostra como encapsular TNamedPipeClient atras de uma facade de dominio
  (Pdv.ClienteChannel) em vez de a UI falar TBytes direto — ver
  samples/PdvDualScreen/Pdv.Protocolo.pas e Pdv.ClienteChannel.pas. }

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}
  cthreads, // threads reais no Unix: sem isso os eventos/condvars da lib falham em runtime
    {$ENDIF}
  Interfaces,
  {$ENDIF}
  Forms,
  Pdv.Protocolo in '..\Pdv.Protocolo.pas',
  Pdv.ClienteChannel in '..\Pdv.ClienteChannel.pas',
  uPdvClienteMain in 'uPdvClienteMain.pas' {frmPdvCliente};

begin
  {$IFNDEF FPC}
  ReportMemoryLeaksOnShutdown := True;
  {$ENDIF}
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TfrmPdvCliente, frmPdvCliente);
  Application.Run;
end.
