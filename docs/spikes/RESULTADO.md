# Spike: hook `PermissionRequest` do Claude Code — segurar e resolver permissão programaticamente

**Data:** 2026-07-30
**Versão testada:** Claude Code **v2.1.220** (`/Users/grippado/.local/share/claude/versions/2.1.220`)
**Doc consultada:** https://code.claude.com/docs/en/hooks (lida no dia, não de memória)
**Issue de referência:** anthropics/claude-code#19298 (decisão do hook ignorada, prompt aparecia assim mesmo)

---

## VEREDITO: **VIÁVEL COM RESSALVAS**

As duas premissas centrais se confirmam na v2.1.220:

- **(a) Segurar por vários minutos: SIM.** Um hook `PermissionRequest` segurou a permissão por 90 segundos, tanto no tipo `command` quanto no tipo `http`, e o Claude Code esperou sem desistir.
- **(b) Resolver programaticamente: SIM.** Tanto `allow` quanto `deny` do hook foram respeitados e a ferramenta agiu de acordo. O comportamento da issue #19298 **não se reproduz** nesta versão.

A ressalva que muda o desenho do produto: **o diálogo interativo é renderizado no TUI mesmo assim, e continua vivo e respondendo a teclado durante todo o hold.** O hook não substitui o diálogo, ele corre contra ele. Quem apertar uma tecla primeiro ganha. Detalhes em "Ressalva 1".

---

## Como o spike foi montado

```
/tmp/aiterm-spike/
├── hook-deny.sh              # hook command: loga payload cru + devolve deny
├── hook-allow-{0,5,20}.sh    # hook command: allow após N segundos
├── hook-slow-allow.sh        # hook command: dorme 90s, devolve allow
├── slow_server.py            # servidor HTTP stdlib: /slow-allow /error-500 /never
├── settings-*.json           # um settings por cenário (nenhum toca ~/.claude/settings.json)
├── pty_drive.py              # driver PTY: sobe o TUI real, digita o prompt, captura a tela
├── pty_race.py               # idem + aperta "1" no meio do hold (teste de corrida)
├── hook.log / http.log       # evidência dos payloads recebidos
└── pty-*.txt                 # captura bruta do terminal por cenário
```

O `~/.claude/settings.json` do usuário **não foi modificado** (verificado: só leitura).

### Duas armadilhas metodológicas que quase invalidaram o spike

Registro porque qualquer um que repita isso vai cair nelas:

**1. `PermissionRequest` não dispara em modo headless (`claude -p`).** As três primeiras rodadas não produziram nenhuma linha em `hook.log`. Um controle com o mesmo script registrado como `PreToolUse` disparou normalmente — provando que o carregamento de settings estava certo e que o problema era o evento. Em headless a permissão é curto-circuitada para `"This command requires approval"` **antes** de chegar ao hook. Todo o teste real precisou de TUI de verdade, via PTY.

**2. `.claude/settings.json` de projeto em diretório não confiado é ignorado em silêncio.** `/tmp/aiterm-spike` não estava em `hasTrustDialogAccepted`. Enquanto isso valeu, o hook de projeto simplesmente não existia. Depois que aceitei o diálogo de trust no primeiro PTY, o settings de projeto passou a valer — e como eu tinha deixado o hook de *deny* ali, **ele contaminou os cenários B, B2, C e D**, que apareceram como "deny imediato" e me levaram a concluir errado que a decisão era ignorada. O `hook.log` mostrou o hook de deny disparando em todas as 5 rodadas. Após remover o settings de projeto, os cenários limpos deram resultado oposto. As conclusões abaixo usam **só as rodadas limpas**.

---

## Respostas às perguntas

### 1. O payload traz `tool_name`, `tool_input` e `permission_suggestions`?

**Sim, os três.** Payload cru capturado (`hook.log`, cenário A):

```json
{
  "session_id": "1ae1b042-809c-4bb2-95f7-5c42524ae408",
  "transcript_path": "/Users/grippado/.claude/projects/-private-tmp-aiterm-spike/1ae1b042-....jsonl",
  "cwd": "/private/tmp/aiterm-spike",
  "prompt_id": "01f3f3c7-a92b-4c6b-9f37-2a09ee9c5004",
  "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {
    "command": "/bin/date +SPIKE_MARKER_A",
    "description": "Execute date command with SPIKE_MARKER_A format"
  },
  "permission_suggestions": [
    {
      "type": "addRules",
      "rules": [{ "toolName": "Bash", "ruleContent": "/bin/date +SPIKE_MARKER_A" }],
      "behavior": "allow",
      "destination": "localSettings"
    }
  ]
}
```

**Duas divergências em relação à doc**, ambas relevantes para quem for construir em cima:

| Campo | Doc atual | Observado na v2.1.220 |
|---|---|---|
| `tool_use_id` | listado como campo do payload | **ausente** no `PermissionRequest` (presente no `PreToolUse`) |
| `permission_suggestions[]` | `[{"type":"allow","reason":"..."}]` | `[{"type":"addRules","rules":[{"toolName","ruleContent"}],"behavior","destination"}]` |

A ausência de `tool_use_id` importa: **não dá para correlacionar a requisição de permissão com a tool call pelo id**. Quem for construir um broker externo precisa correlacionar por `session_id` + `prompt_id` + conteúdo de `tool_input`, que é mais frágil.

### 2. A decisão do hook é respeitada, ou o diálogo aparece assim mesmo?

**A decisão é respeitada.** Ambos os sentidos, em rodadas limpas, lidos do transcript oficial da sessão:

| Cenário | Hook | `tool_result` | Evidência |
|---|---|---|---|
| A | `command`, deny imediato | erro, ferramenta não executou | modelo relatou "bloqueado por um hook de permissão"; nenhum comando rodou |
| D2 | `command`, allow imediato | `err=False`, saída `SPIKE_MARKER_D2` | `17:34:08 TOOL_RESULT err=False "SPIKE_MARKER_D2"` |
| C2 | `command`, allow após 90s | `err=False`, saída `SPIKE_MARKER_C2` | `17:35:25 TOOL_USE` → `17:36:55 TOOL_RESULT err=False` |
| B3 | `http`, allow após 90s | `err=False`, saída `SPIKE_MARKER_B3` | `17:38:27 TOOL_USE` → `17:39:58 TOOL_RESULT err=False` |

**O bug da issue #19298 não se reproduz na v2.1.220.** A decisão programática vale.

**Mas o diálogo é desenhado na tela assim mesmo.** Extraído da captura bruta do PTY do cenário C2 (o de 90 segundos):

```
Bash command
  /bin/date +SPIKE_MARKER_C2
  Execute date command with SPIKE_MARKER_C2 format
This command requires approval
Do you want to proceed?
❯ 1. Yes
  2. Yes, and don't ask again for: /bin/date +SPIKE_MARKER_C2
  3. No
Esc to cancel · Tab to amend · ctrl+e to explain
```

Isso aparece em **todos** os cenários, inclusive no D2, onde o hook liberou em menos de 1 segundo (ali o diálogo só pisca e é substituído). Ver "Ressalva 1".

### 3. Qual o timeout efetivo antes de o Claude Code desistir?

**Não observei o Claude Code desistir. Em nenhum momento.**

Cenário F: hook `http` apontando para uma rota `/never` que aceita a conexão e nunca responde, com `timeout` **omitido** do settings (ou seja, valendo o default documentado de 600s).

```
14:46:39  servidor recebe POST /never (payload completo do PermissionRequest)
14:56:41  ...ainda segurando ha 600s    <-- passou o default documentado
14:57:41  ...ainda segurando ha 660s
14:58:11  driver mata o processo do Claude Code (fim da janela de captura)
```

Ao longo dos **~687 segundos (11,5 min)**, na captura do terminal:

- a conexão TCP **nunca foi fechada** pelo cliente (o servidor nunca registrou erro de escrita nem queda);
- a tela continuou mostrando o diálogo de permissão intacto, com o *bell* `Claude needs your permission`;
- **nenhuma** mensagem de timeout, erro de hook ou fallback apareceu (`hook timed out`, `timed out`, `Error`: zero ocorrências);
- o transcript da sessão **não registrou nenhum `tool_result`** — a tool call ficou pendente até o processo morrer.

Ou seja: os 600s da doc **não se manifestaram como um abort observável**. Não consigo afirmar que o Claude Code não estourou algum timer interno aos 600s — só que, se estourou, isso não produziu nenhum efeito visível: nem fecha conexão, nem erro, nem fallback, nem desbloqueio da tool call.

**Consequência prática:** o limite superior de um hold não é o timeout, é a paciência do humano olhando um diálogo respondível. Isso é bom para "segurar" (premissa (a) confirmada com folga: 90s testado com sucesso, 687s sem qualquer corte) e ruim para previsibilidade, porque não existe um estado terminal definido para o caso "o broker externo morreu".

### 4. O que acontece se o hook retornar erro ou não responder?

**Erro HTTP (`500`):** o hook é tratado como erro não-bloqueante e o fluxo cai no **diálogo interativo normal** — que fica na tela esperando resposta humana. Confirmado no cenário E: com o hook apontando para `/error-500`, a sessão terminou os 60s de captura com o diálogo em pé e **nenhum `tool_result` no transcript**. Bate com a doc ("Non-2xx status: Non-blocking error, execution continues").

Consequência para o produto: **falha explícita do broker = fallback para humano**, não para deny nem para allow. É o comportamento seguro, mas significa que uma indisponibilidade do serviço externo devolve o prompt na cara do usuário.

**Não-resposta (conexão aceita, resposta nunca enviada):** é o caso ruim. Como detalhado na pergunta 3, o Claude Code **fica pendurado indefinidamente** (≥687s medidos), sem timeout observável e sem estado terminal. A diferença é importante:

| Falha do hook | Comportamento observado |
|---|---|
| HTTP `500` (erro explícito) | erro não-bloqueante → cai no diálogo interativo normal |
| conexão aceita, sem resposta | **pendura indefinidamente**, sem timeout, sem erro, sem fallback |

Para um produto isso significa: **um broker que morre com um 500 é seguro; um broker que trava é pior que um broker que cai.** O design tem que garantir que o serviço externo sempre responda algo (com watchdog e timeout do lado dele), porque o Claude Code não vai resgatar a sessão.

---

## Ressalva 1 — o diálogo corre contra o hook, e o humano pode ganhar

Este é o achado que mais afeta um produto construído em cima.

Durante o hold do hook, o diálogo não é um placeholder inerte: **ele está vivo e aceita teclado**. Teste G, com o hook `command` configurado para dormir 90s e depois devolver `allow`:

```
17:46:46  TOOL_USE  /bin/date +SPIKE_MARKER_G
          (driver aperta "1" = Yes, no meio do hold)
17:47:16  TOOL_RESULT err=False "SPIKE_MARKER_G"   <-- ferramenta executou
17:48:16  hook-slow.log: "respondendo allow"        <-- hook só respondeu 60s DEPOIS
```

A ferramenta executou **um minuto inteiro antes de o hook responder**. A única entrada foi a tecla `1`. Ou seja: o usuário resolveu a permissão sozinho e o hook chegou tarde.

Implicações:

- Não dá para tratar o hook como **autoridade única** de permissão. Ele é um participante numa corrida com o teclado.
- Um hold longo é uma janela em que o usuário vê um diálogo respondível e provavelmente vai responder — ninguém encara um prompt parado por 3 minutos sem apertar algo.
- Se o produto depende de "a decisão vem de fora, sempre", falta um mecanismo para suprimir ou desabilitar o diálogo local. Nada na doc de hooks oferece isso.

## Ressalva 2 — `PermissionRequest` não existe em headless

`claude -p` nunca dispara o evento; a permissão é negada antes. Qualquer produto que pretenda usar esse hook está **restrito ao TUI interativo** (ou ao SDK com handler de permissão próprio, que não foi testado aqui). Isso exclui de saída CI, cron e automação headless.

## Ressalva 3 — vários hooks: o primeiro a decidir vence, e não se espera pelos outros

Descoberto acidentalmente pela contaminação. Com dois hooks `PermissionRequest` registrados (um deny rápido de projeto, um allow lento via `--settings`), a decisão saiu **no mesmo segundo** do deny rápido, e o hook lento nem foi aguardado. Um broker externo lento pode ser silenciosamente atropelado por qualquer outro hook `PermissionRequest` mais rápido em qualquer nível de settings (usuário, projeto, local, plugin).

Vale notar que o `~/.claude/settings.json` deste usuário **já tem** um hook `PermissionRequest` global (um notificador que sai 0 sem JSON — inofensivo por não emitir decisão, mas ilustra que o slot é disputado).

---

## Reprodução

```bash
BIN=/Users/grippado/.local/share/claude/versions/2.1.220

# cenário allow lento (command), 90s
rm -f /tmp/aiterm-spike/.claude/settings.json     # evitar contaminação
python3 /tmp/aiterm-spike/pty_drive.py \
  /tmp/aiterm-spike/settings-C-slowcmd.json \
  "Use a ferramenta Bash para executar: /bin/date +SPIKE_MARKER_X" \
  170 /tmp/aiterm-spike/saida.txt

# cenário allow lento (http), 90s
SPIKE_DELAY=90 python3 /tmp/aiterm-spike/slow_server.py 8787 &
python3 /tmp/aiterm-spike/pty_drive.py \
  /tmp/aiterm-spike/settings-B-slow.json "..." 170 /tmp/aiterm-spike/saida.txt
```

O árbitro de cada cenário é o transcript oficial em
`~/.claude/projects/-private-tmp-aiterm-spike/*.jsonl` (campos `tool_use` / `tool_result`),
não a raspagem da tela — o PTY acumula frames transitórios e produz falso positivo.

---

## Resumo do veredito

**VIÁVEL COM RESSALVAS.**

O mecanismo faz o que a doc promete e o que o produto precisa: segura a permissão por minutos e resolve programaticamente com `allow`/`deny`. A issue #19298 está resolvida na v2.1.220. Um broker externo de permissões é construível.

O que precisa entrar no desenho desde o dia zero:

1. **O diálogo local não desaparece.** O hook não é a autoridade, é um competidor numa corrida com o teclado do usuário. Não há como suprimir o diálogo pela API de hooks. Um produto que promete "decisão centralizada" vai ter decisões locais furando a política sempre que alguém apertar `1`.
2. **Só funciona no TUI interativo.** `claude -p` não dispara o evento. CI, cron e automação headless estão fora.
3. **Não existe estado terminal para broker travado.** Responda sempre, nem que seja `500` — o Claude Code não tem watchdog observável.
4. **Sem `tool_use_id` no payload**, a correlação com a tool call é heurística (`session_id` + `prompt_id` + `tool_input`).
5. **Outros hooks `PermissionRequest` atropelam o seu** se decidirem mais rápido, em qualquer nível de settings.
6. **A doc tem duas imprecisões** (`tool_use_id` e o formato de `permission_suggestions`) — não confie no schema documentado, valide contra o payload real.

Se o produto tolerar (1) e (2), é viável. Se o pitch for "controle de permissões que o desenvolvedor não pode furar localmente", **não é** — e as alternativas seriam o Claude Agent SDK com handler `canUseTool` próprio (não testado neste spike), ou `permissions`/`deny` estático em settings gerenciado, que é política sem interatividade.
