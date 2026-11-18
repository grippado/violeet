# violeet

O violeet é um **app de navegador** para rodar e acompanhar várias sessões de agentes de código (Claude Code, Codex e Cursor) lado a lado. Ele abre no navegador do desktop e do celular, com a mesma tela, e as sessões continuam rodando na sua máquina mesmo com a aba fechada.

**Está em desenvolvimento** e ainda não tem versão para instalar. O código vive num repositório privado, `violeet-lab`, até a versão aberta.

Landing, com o que já existe, a interface do redesign e o roadmap: https://grippado.github.io/violeet/

## O que já existe

- Runs em terminais de verdade no navegador, uma por card
- Seções para agrupar runs
- Lançador com texto livre, imagens e melhorar prompt
- Dados da sessão por run: modelo, contexto restante e tokens
- Notas e gráficos de uso
- Uso pelo celular, com as teclas de atalho na tela

## Em andamento: redesign e rebranding

A interface está sendo redesenhada e, junto, ganha o nome violeet (antes ela se chamava fluxd):

- **M1, base visual e o nome violeet:** interface linear, header na lateral com o nome e o ícone, seções em accordion.
- **M2, a sessão no composer:** dados da sessão acima do input, esc, setas, to new session e imagens no composer.
- **M3, fluxos novos:** melhorar prompt no composer e handoff entre sessões em segundo plano.
- **Versão aberta:** o código sai do laboratório privado.

O estado de cada fatia está em [`docs/roadmap.json`](docs/roadmap.json), a mesma fonte que a landing desenha.

## Este repositório

Guarda só a landing, publicada pelo GitHub Pages a partir de `docs/`:

- `docs/index.html`: a página
- `docs/roadmap.json`: o roadmap
- `docs/*.png`: os mockups do redesign e o print da versão atual, com dados fictícios

## Código antigo

A primeira versão do violeet (daemon em Rust e app em SwiftUI) foi desativada em novembro de 2026 e continua preservada:

- tag [`legacy-app`](https://github.com/grippado/violeet/tree/legacy-app)
- branch [`legacy/app`](https://github.com/grippado/violeet/tree/legacy/app)

As releases antigas continuam em [Releases](https://github.com/grippado/violeet/releases) e são desse app antigo.

## Licença

[LICENSE](LICENSE)
