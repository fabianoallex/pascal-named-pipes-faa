# Brief: sample de echo seguro (ptTls + mTLS)

**Modelo sugerido:** haiku (sample/wiring, milestone M8).
**Origem:** code review `0b11f97..HEAD` + sessão de follow-up.

## Por que este sample existe

`ptTls` e o mTLS existem para o caso de uso PDV-sobre-VPN (memória
`caso-de-uso-pdv-lojas-vpn`), mas TODOS os samples de rede hoje são texto claro.
Falta o exemplo que mostra a fiação real: servidor exigindo certificado de cliente,
cliente apresentando o dele, tráfego cifrado.

## O que construir

Par console `samples/EchoSeguro/EchoSeguroServer.dpr` +
`EchoSeguroClient.dpr`, espelhando `samples/EchoServer` e `samples/EchoClient`
(mesmo estilo: classe com callbacks `of object`, log sob `TCriticalSection`,
`Readln` encerra). Gerar também `.dproj` (Delphi) + `.lpi`/`.lpr` (Lazarus) para
cada, como nos outros samples.

## Fiação TLS (referência canônica: `tests/Integration/Pipes.TlsTests.pas`)

Servidor:
```pascal
FServer := TPipeServer.Create('0.0.0.0:5000', ptTls); // Pipes.Server
// Windows/Schannel: PFX. Linux/OpenSSL: PEM (CertFile + KeyFile).
{$IFDEF PIPES_SCHANNEL}
FServer.TlsOptions.CertFile := '<pki>/srv.pfx';
FServer.TlsOptions.CertPassword := 'pipestest';
{$ELSE}
FServer.TlsOptions.CertFile := '<pki>/srv_cert.pem';
FServer.TlsOptions.KeyFile  := '<pki>/srv_key.pem';
{$ENDIF}
FServer.TlsOptions.CaFile := '<pki>/ca_cert.pem'; // LIGA mTLS
FServer.Listen;
```
Cliente: análogo com `cli.pfx`/`cli_cert.pem`+`cli_key.pem`. Como a PKI de teste
(`tests/pki`) não está no trust store da máquina, o cliente precisa de
`FClient.TlsOptions.SkipServerVerification := True` **com um comentário GRITANTE**
de que isso é só para o demo com PKI de teste e NUNCA em produção (em produção a
CA do servidor está no trust store, ou usa-se `CaFile` no backend OpenSSL).

Imprimir `PipeTlsBackendInfo` (de `Pipes.Types`) no início, para o operador ver
qual backend está em uso.

## Passos que se esquece (obrigatórios — ver CLAUDE.md)

1. Registrar cada `.dproj` novo em **`Pipes.groupproj`** (Projects + Targets +
   CallTarget de Build/Clean/Make) e cada `.lpi` em **`Pipes.lpg`** (Target com
   BuildModes). Sem isso o sample não entra no build do grupo.
2. Linux exige `-dPIPES_OPENSSL` (SChannel não existe lá); documentar no cabeçalho
   do `.dpr` como no `EchoServer.dpr`.
3. Uma linha no `README.md` na lista de samples.

## Verificação

- Delphi: abrir o grupo, build all verde, rodar servidor+cliente, ver o round-trip
  cifrado e o log de conexão autenticada.
- FPC/Windows: `lazbuild` de cada `.lpi`.
- Prova de que o mTLS não é decorativo: um cliente **sem** certificado de cliente
  (ou `TPipeClient` comum) é recusado e o servidor não dispara `OnClientConnected`.
