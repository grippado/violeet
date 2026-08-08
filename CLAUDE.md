# CLAUDE.md — violeet

## Automação de UI (macOS)

**Clique tem endereço, tecla não.**

`keystroke` do System Events não entrega ao app que você nomeia: entrega a quem
estiver em foco naquele instante. `set frontmost to true` não garante nada — o
alvo pode mudar entre uma linha do AppleScript e a seguinte, inclusive porque o
usuário está usando a própria máquina em paralelo.

Regras, quando for dirigir a UI:

- **Cliques por coordenada com `cliclick`, dentro do retângulo da janela alvo.**
  Nada de `keystroke` global.
- **Automação nunca aperta Enter.** Se o roteiro precisa de Enter, quem aperta é
  o Gabriel. Texto digitado na caixa errada é recuperável; Enter na caixa errada
  não é.
- Antes de qualquer ação, **capture a tela e confirme o estado**. Ação às cegas
  em ambiente com muita janela aberta é o mesmo que ação em janela aleatória.

Origem: 2026-08-08. Um `keystroke` com `cd … && claude` + Enter saiu para um
alvo que nunca foi identificado (não foi shell, não foi nvim, não tocou disco).
O comando "rodou", o retorno foi plausível, e o efeito aconteceu em outro lugar.
