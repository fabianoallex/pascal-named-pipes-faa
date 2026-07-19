# Brief: teste da CA gêmea (guarda de fronteira do mTLS SChannel)

**Modelo sugerido:** sonnet (teste, segue padrão existente).
**Origem:** code review `0b11f97..HEAD` + sessão de follow-up (ver memória
`ptls-estado-e-armadilhas`).

## Por que este teste existe

O passo 3 de `TPipeSchannelServerStream.VerifyClientChain`
(`src/Pipes.Transport.Schannel.pas`) ancora a confiança do mTLS chamando
`CertFindCertificateInStore(..., CERT_FIND_EXISTING, raiz_da_cadeia, ...)`: a raiz
da cadeia do cliente tem de "existir" no store da CA configurada.

A doc da MS só diz "exact match" para `CERT_FIND_EXISTING`, **sem definir o
critério**. Sonda empírica nesta sessão confirmou que o crypt32 do **Windows**
compara o certificado INTEIRO (uma CA forjada com o mesmo issuer+serial mas chave
diferente NÃO casa). Mas o crypt32 do **Wine** implementa o "exact match" só por
issuer+serial (`compare_existing_cert` → `CertCompareCertificate`) — ali seria
bypass.

**Não é vulnerabilidade no alvo** (Delphi/FPC Win64 nativo). O valor deste teste é:
(a) travar contra uma futura troca de implementação por comparação mais fraca;
(b) versionar a evidência da fronteira. Seja honesto sobre isso no comentário do
teste — no Windows ele passa trivialmente.

## Fixtures a gerar (versionar em `tests/pki/`)

Ler o serial da CA real primeiro:
```sh
openssl x509 -in tests/pki/ca_cert.pem -serial -noout   # ex.: serial=2CD3...
```
Gerar a CA GÊMEA (mesmo CN e MESMO serial, chave nova). No Git Bash use
`MSYS_NO_PATHCONV=1` senão o `/CN=...` vira caminho:
```sh
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout gemea_ca_key.pem -out gemea_ca_cert.pem -days 10950 \
  -subj "/CN=pipes-faa-test-CA" -set_serial 0x<SERIAL_DA_CA_REAL>
```
Emitir um leaf de cliente sob a gêmea, **com EKU clientAuth** (sem ele o SChannel
recusa pelo motivo errado — ver LEIA-ME) e mesmo CN do cliente legítimo
(`pdv-loja-001`). Gerar também o `.pfx` (senha `pipestest`) para o backend SChannel
e o par PEM para o OpenSSL. Espelhe exatamente o esquema dos arquivos `rogue_*`.

Atualizar `tests/pki/LEIA-ME.md`: nova linha explicando `gemea_*` (mesmo
issuer+serial da CA real, chave diferente — testa a comparação de bytes da raiz).

## Teste a adicionar

`Mtls_ClienteDeCaGemea_Recusado`, espelhando `Mtls_ClienteAutoAssinado_Recusado`,
nos DOIS arquivos e suas listas published:
- `tests/Integration/Pipes.TlsTests.pas` (DUnitX, `[Test]`)
- `tests/Integration/fpc/Pipes.TlsTests.pas` (FPCUnit, `published`)

Corpo: `FHarness.Listen(Pki('ca_cert.pem'))` (mTLS com a CA REAL), depois
`TryConnect('gemea', LErro)`, e `AssertFalse` em `ClienteAutenticado(2000)` e
`Eco(...)`. Mensagens no padrão "GRAVE: ...".

## Verificação

- FPC: `lazbuild tests/Integration/fpc/PipesIntegrationTestsFpc.lpi` e rodar
  `PipesIntegrationTestsFpc.exe --suite=TPipeTlsTests --format=plain` — todos verdes.
- Delphi: abrir o grupo na IDE.
- **Não** há sabotagem útil aqui (no Windows o teste passa por construção); registre
  isso no comentário em vez de fingir que é guarda de bug vivo.
