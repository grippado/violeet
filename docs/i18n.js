// The page's copy, in the four languages it speaks.
//
// A plain global rather than four JSON files behind `fetch`: the strings have
// to be there before the first paint, and a fetch is a round-trip that happens
// after it. Loaded from <head>, this object is already in memory when the
// script at the end of the body goes to apply it. It also means the page still
// translates when opened straight off disk, where `fetch` is blocked.
//
// English is not just a row in here: it is written into the HTML as real
// content, so a reader with no JavaScript, and a crawler, get a whole page.
// The rows below overwrite it. Keys hold markup where the sentence has some
// (a link, a `<code>`), and it is applied as HTML, which is safe because this
// file is the only thing that writes it.
window.VIOLEET_I18N = {
  en: {
    "meta.title": "Violeet: a terminal for watching agents work",
    "meta.description": "A macOS terminal built for running several coding agents at once: every session on a board, permission requests surfaced, and the files each one wrote.",

    "lang.label": "Language",
    "brand.home": "Violeet, home",
    "theme.to_light": "Switch to light",
    "theme.to_dark": "Switch to dark",

    "hero.h1": "A terminal for watching agents work.",
    "hero.lede": "Run six coding agents at once and the hard part stops being the code. It is knowing which one is blocked on you, which one is burning context, and what any of them actually changed. Violeet puts that on a board beside the terminal.",

    "cta.download": "Download for macOS",
    "cta.source": "Source on GitHub",
    "cta.wears": "Wears",

    "term.title": "violeet · sessions",
    "term.s1.name": "refactor the transcript reader",
    "term.s1.status": "waiting for you",
    "term.s2.name": "files panel",
    "term.s2.status": "working",
    "term.s3.name": "docs sweep",
    "term.s3.status": "idle",

    "does.h2": "What it does",
    "does.lede": "Every agent session on the machine appears on the board, including the ones started somewhere else.",
    "does.blocked.h3": "Blocked agents come to you",
    "does.blocked.p": "A session waiting on a permission request is signalled three ways at once: a lit edge, a slow pulse, and a colour used nowhere else. You are not watching the sidebar, so it has to reach you from the corner of your eye.",
    "does.context.h3": "Context, measured",
    "does.context.p": "How full each window is, with the absolute pair beside the percentage. A small window nearly full and a large one barely touched call for opposite reactions, and one number cannot tell them apart.",
    "does.files.h3": "The files each session wrote",
    "does.files.p": "A tree grouped by root, with a real diffstat, read from the diff the agent itself produced, not estimated. Click a file and it opens in your editor, on the first uncommitted change.",
    "does.anywhere.h3": "Sessions from anywhere",
    "does.anywhere.p": "An agent started in iTerm, or in another window, is still a real session. It shows up on the board, clearly marked as living somewhere else rather than quietly omitted.",

    "theme.lede": "The palette Violeet ships with, published on its own under MIT. Two variants. This page is painted with it, and the stylesheet below is generated from the same file the terminals download, so the page cannot advertise colours it is not using.",
    "theme.meta_dark": "#24203F · worst text contrast 4.53",
    "theme.meta_light": "#FAF8FE · worst text contrast 5.06",
    "theme.aa": "Every colour that can carry text clears WCAG AA against its own background, and that is checked rather than claimed: the build fails if one drops under 4.5:1. It is MIT and has its own home, so you can wear it without ever installing this terminal.",
    "theme.th_editors": "Editors",
    "theme.th_terminals": "Terminals",
    "theme.th_web": "Web",
    "theme.painted": "The page you are reading is painted with it, and so is <a href=\"https://grippado.github.io/violeeter/\">its own</a>. Nothing here uses a colour the theme does not ship.",
    "theme.get": "Get",

    "install.h2": "Install",
    "install.lede": "macOS, Apple silicon and Intel. Builds are ad-hoc signed, so the first launch needs the quarantine flag cleared.",
    "install.daemon": "The daemon that watches sessions installs separately and runs under <code>launchd</code>. It is optional: with it stopped, Violeet is still a terminal, and the board simply says so.",

    "glabs.eyebrow": "the wider constellation",
    "glabs.h2": "Held by <span>[GLabs]</span>.",
    "glabs.lede": "[GLabs] is the umbrella that ties the family together in Violeeter’s visual language.",
    "glabs.flux": "the workflow · direct reference ↗",
    "glabs.violeeter": "the visual system · direct reference ↗",
    "footer": "Violeet and Violeeter are MIT licensed. Built by <a href=\"https://github.com/grippado\">grippado</a>."
  },

  pt: {
    "meta.title": "Violeet: um terminal para acompanhar agentes trabalhando",
    "meta.description": "Um terminal para macOS feito para rodar vários agentes de código ao mesmo tempo: cada sessão em um painel, os pedidos de permissão à vista e os arquivos que cada um escreveu.",

    "lang.label": "Idioma",
    "brand.home": "Violeet, início",
    "theme.to_light": "Mudar para o claro",
    "theme.to_dark": "Mudar para o escuro",

    "hero.h1": "Um terminal para acompanhar agentes trabalhando.",
    "hero.lede": "Rode seis agentes de código ao mesmo tempo e a parte difícil deixa de ser o código. Passa a ser saber qual deles está travado esperando você, qual está queimando contexto e o que cada um mudou de verdade. O Violeet põe isso num painel ao lado do terminal.",

    "cta.download": "Baixar para macOS",
    "cta.source": "Código no GitHub",
    "cta.wears": "Veste",

    "term.title": "violeet · sessões",
    "term.s1.name": "refatorar o leitor de transcript",
    "term.s1.status": "esperando você",
    "term.s2.name": "painel de arquivos",
    "term.s2.status": "trabalhando",
    "term.s3.name": "varredura da documentação",
    "term.s3.status": "parado",

    "does.h2": "O que ele faz",
    "does.lede": "Toda sessão de agente na máquina aparece no painel, inclusive as que começaram em outro lugar.",
    "does.blocked.h3": "Agente travado vem até você",
    "does.blocked.p": "Uma sessão parada num pedido de permissão é sinalizada de três jeitos ao mesmo tempo: uma borda acesa, um pulso lento e uma cor que não aparece em nenhum outro canto. Você não está olhando para a barra lateral, então ela precisa te alcançar pelo canto do olho.",
    "does.context.h3": "Contexto, medido",
    "does.context.p": "O quanto cada janela está cheia, com o par absoluto ao lado da porcentagem. Uma janela pequena quase cheia e uma grande mal tocada pedem reações opostas, e um número sozinho não distingue as duas.",
    "does.files.h3": "Os arquivos que cada sessão escreveu",
    "does.files.p": "Uma árvore agrupada por raiz, com diffstat de verdade, lido do diff que o próprio agente produziu, não estimado. Clique num arquivo e ele abre no seu editor, na primeira mudança ainda não commitada.",
    "does.anywhere.h3": "Sessões de qualquer lugar",
    "does.anywhere.p": "Um agente iniciado no iTerm, ou em outra janela, continua sendo uma sessão de verdade. Ele aparece no painel, marcado com clareza como quem mora em outro lugar, em vez de ser omitido em silêncio.",

    "theme.lede": "A paleta que o Violeet veste de fábrica, publicada por conta própria sob MIT. Duas variantes. Esta página é pintada com ela, e a folha de estilo abaixo é gerada do mesmo arquivo que os terminais baixam, então a página não tem como anunciar cores que não está usando.",
    "theme.meta_dark": "#24203F · pior contraste de texto 4,53",
    "theme.meta_light": "#FAF8FE · pior contraste de texto 5,06",
    "theme.aa": "Toda cor capaz de carregar texto passa no WCAG AA contra o próprio fundo, e isso é verificado, não prometido: o build falha se alguma cair abaixo de 4,5:1. É MIT e tem casa própria, então você pode vesti-la sem nunca instalar este terminal.",
    "theme.th_editors": "Editores",
    "theme.th_terminals": "Terminais",
    "theme.th_web": "Web",
    "theme.painted": "A página que você está lendo é pintada com ela, e a <a href=\"https://grippado.github.io/violeeter/\">dela</a> também. Nada aqui usa uma cor que o tema não entrega.",
    "theme.get": "Baixar o",

    "install.h2": "Instalação",
    "install.lede": "macOS, Apple silicon e Intel. Os builds são assinados ad-hoc, então a primeira abertura exige limpar a flag de quarentena.",
    "install.daemon": "O daemon que observa as sessões se instala à parte e roda sob <code>launchd</code>. Ele é opcional: com ele parado, o Violeet continua sendo um terminal, e o painel simplesmente diz isso.",

    "glabs.eyebrow": "a constelação maior",
    "glabs.h2": "Sob o guarda-chuva da <span>[GLabs]</span>.",
    "glabs.lede": "[GLabs] é o guarda-chuva que conecta a família na linguagem visual do Violeeter.",
    "glabs.flux": "o fluxo de trabalho · referência direta ↗",
    "glabs.violeeter": "o sistema visual · referência direta ↗",
    "footer": "Violeet e Violeeter são licenciados sob MIT. Feito por <a href=\"https://github.com/grippado\">grippado</a>."
  },

  es: {
    "meta.title": "Violeet: una terminal para ver a los agentes trabajar",
    "meta.description": "Una terminal para macOS hecha para ejecutar varios agentes de código a la vez: cada sesión en un panel, las solicitudes de permiso a la vista y los archivos que escribió cada uno.",

    "lang.label": "Idioma",
    "brand.home": "Violeet, inicio",
    "theme.to_light": "Cambiar a claro",
    "theme.to_dark": "Cambiar a oscuro",

    "hero.h1": "Una terminal para ver a los agentes trabajar.",
    "hero.lede": "Ejecuta seis agentes de código a la vez y lo difícil deja de ser el código. Pasa a ser saber cuál está bloqueado esperándote, cuál está quemando contexto y qué cambió cada uno de verdad. Violeet pone eso en un panel junto a la terminal.",

    "cta.download": "Descargar para macOS",
    "cta.source": "Código en GitHub",
    "cta.wears": "Viste",

    "term.title": "violeet · sesiones",
    "term.s1.name": "refactorizar el lector de transcript",
    "term.s1.status": "te está esperando",
    "term.s2.name": "panel de archivos",
    "term.s2.status": "trabajando",
    "term.s3.name": "repaso de la documentación",
    "term.s3.status": "en reposo",

    "does.h2": "Qué hace",
    "does.lede": "Toda sesión de agente en la máquina aparece en el panel, incluidas las que empezaron en otro sitio.",
    "does.blocked.h3": "El agente bloqueado va hasta ti",
    "does.blocked.p": "Una sesión detenida en una solicitud de permiso se señala de tres formas a la vez: un borde encendido, un pulso lento y un color que no se usa en ningún otro sitio. No estás mirando la barra lateral, así que tiene que alcanzarte por el rabillo del ojo.",
    "does.context.h3": "Contexto, medido",
    "does.context.p": "Cuán llena está cada ventana, con el par absoluto junto al porcentaje. Una ventana pequeña casi llena y una grande apenas tocada piden reacciones opuestas, y un solo número no las distingue.",
    "does.files.h3": "Los archivos que escribió cada sesión",
    "does.files.p": "Un árbol agrupado por raíz, con un diffstat real, leído del diff que produjo el propio agente, no estimado. Haz clic en un archivo y se abre en tu editor, en el primer cambio sin commit.",
    "does.anywhere.h3": "Sesiones desde cualquier lugar",
    "does.anywhere.p": "Un agente iniciado en iTerm, o en otra ventana, sigue siendo una sesión real. Aparece en el panel, marcado con claridad como algo que vive en otro sitio, en lugar de omitirse en silencio.",

    "theme.lede": "La paleta con la que viene Violeet, publicada por su cuenta bajo MIT. Dos variantes. Esta página está pintada con ella, y la hoja de estilos de abajo se genera del mismo archivo que descargan las terminales, así que la página no puede anunciar colores que no está usando.",
    "theme.meta_dark": "#24203F · peor contraste de texto 4,53",
    "theme.meta_light": "#FAF8FE · peor contraste de texto 5,06",
    "theme.aa": "Todo color capaz de llevar texto cumple WCAG AA contra su propio fondo, y eso se verifica, no se promete: el build falla si alguno baja de 4,5:1. Es MIT y tiene casa propia, así que puedes vestirla sin instalar nunca esta terminal.",
    "theme.th_editors": "Editores",
    "theme.th_terminals": "Terminales",
    "theme.th_web": "Web",
    "theme.painted": "La página que estás leyendo está pintada con ella, y la <a href=\"https://grippado.github.io/violeeter/\">suya</a> también. Nada aquí usa un color que el tema no incluya.",
    "theme.get": "Obtener",

    "install.h2": "Instalación",
    "install.lede": "macOS, Apple silicon e Intel. Los builds están firmados ad-hoc, así que el primer arranque exige quitar la marca de cuarentena.",
    "install.daemon": "El daemon que observa las sesiones se instala aparte y corre bajo <code>launchd</code>. Es opcional: con él detenido, Violeet sigue siendo una terminal, y el panel simplemente lo dice.",

    "glabs.eyebrow": "la constelación mayor",
    "glabs.h2": "Bajo el paraguas de <span>[GLabs]</span>.",
    "glabs.lede": "[GLabs] conecta la familia con el lenguaje visual de Violeeter.",
    "glabs.flux": "el flujo de trabajo · referencia directa ↗",
    "glabs.violeeter": "el sistema visual · referencia directa ↗",
    "footer": "Violeet y Violeeter tienen licencia MIT. Hecho por <a href=\"https://github.com/grippado\">grippado</a>."
  },

  de: {
    "meta.title": "Violeet: ein Terminal, um Agenten bei der Arbeit zuzusehen",
    "meta.description": "Ein macOS-Terminal, gebaut für mehrere Coding-Agents gleichzeitig: jede Sitzung auf einem Board, Berechtigungsanfragen sichtbar, und die Dateien, die jeder geschrieben hat.",

    "lang.label": "Sprache",
    "brand.home": "Violeet, Startseite",
    "theme.to_light": "Zu Hell wechseln",
    "theme.to_dark": "Zu Dunkel wechseln",

    "hero.h1": "Ein Terminal, um Agenten bei der Arbeit zuzusehen.",
    "hero.lede": "Lass sechs Coding-Agents gleichzeitig laufen, und das Schwierige ist nicht mehr der Code. Es ist zu wissen, welcher auf dich wartet, welcher Kontext verbrennt und was einer davon tatsächlich geändert hat. Violeet stellt das auf ein Board neben dem Terminal.",

    "cta.download": "Für macOS laden",
    "cta.source": "Quellcode auf GitHub",
    "cta.wears": "Trägt",

    "term.title": "violeet · Sitzungen",
    "term.s1.name": "Transcript-Reader refactoren",
    "term.s1.status": "wartet auf dich",
    "term.s2.name": "Dateien-Panel",
    "term.s2.status": "arbeitet",
    "term.s3.name": "Doku durchgehen",
    "term.s3.status": "im Leerlauf",

    "does.h2": "Was es tut",
    "does.lede": "Jede Agent-Sitzung auf dem Rechner erscheint auf dem Board, auch die, die woanders gestartet wurde.",
    "does.blocked.h3": "Blockierte Agents kommen zu dir",
    "does.blocked.p": "Eine Sitzung, die auf eine Berechtigungsanfrage wartet, meldet sich dreifach zugleich: eine leuchtende Kante, ein langsamer Puls und eine Farbe, die sonst nirgends vorkommt. Du schaust nicht auf die Seitenleiste, also muss sie dich aus dem Augenwinkel erreichen.",
    "does.context.h3": "Kontext, gemessen",
    "does.context.p": "Wie voll jedes Fenster ist, mit den absoluten Zahlen neben dem Prozentwert. Ein kleines, fast volles Fenster und ein großes, kaum genutztes verlangen entgegengesetzte Reaktionen, und eine einzelne Zahl kann sie nicht unterscheiden.",
    "does.files.h3": "Die Dateien, die jede Sitzung geschrieben hat",
    "does.files.p": "Ein nach Wurzelverzeichnis gruppierter Baum mit echtem Diffstat, gelesen aus dem Diff, den der Agent selbst erzeugt hat, nicht geschätzt. Klick auf eine Datei, und sie öffnet sich in deinem Editor, bei der ersten nicht committeten Änderung.",
    "does.anywhere.h3": "Sitzungen von überall",
    "does.anywhere.p": "Ein Agent, der in iTerm oder in einem anderen Fenster gestartet wurde, ist trotzdem eine echte Sitzung. Er erscheint auf dem Board, klar als anderswo lebend markiert, statt stillschweigend zu fehlen.",

    "theme.lede": "Die Palette, die Violeet mitbringt, eigenständig unter MIT veröffentlicht. Zwei Varianten. Diese Seite ist damit gemalt, und das Stylesheet unten wird aus derselben Datei erzeugt, die die Terminals herunterladen, also kann die Seite keine Farben bewerben, die sie gar nicht benutzt.",
    "theme.meta_dark": "#24203F · schlechtester Textkontrast 4,53",
    "theme.meta_light": "#FAF8FE · schlechtester Textkontrast 5,06",
    "theme.aa": "Jede Farbe, die Text tragen kann, erfüllt WCAG AA gegen ihren eigenen Hintergrund, und das wird geprüft, nicht behauptet: der Build schlägt fehl, sobald eine unter 4,5:1 fällt. Sie steht unter MIT und hat ein eigenes Zuhause, du kannst sie also tragen, ohne dieses Terminal je zu installieren.",
    "theme.th_editors": "Editoren",
    "theme.th_terminals": "Terminals",
    "theme.th_web": "Web",
    "theme.painted": "Die Seite, die du gerade liest, ist damit gemalt, und <a href=\"https://grippado.github.io/violeeter/\">ihre eigene</a> auch. Nichts hier benutzt eine Farbe, die das Theme nicht mitliefert.",
    "theme.get": "Hol dir",

    "install.h2": "Installation",
    "install.lede": "macOS, Apple Silicon und Intel. Die Builds sind ad-hoc signiert, der erste Start braucht also ein entferntes Quarantäne-Flag.",
    "install.daemon": "Der Daemon, der die Sitzungen beobachtet, wird separat installiert und läuft unter <code>launchd</code>. Er ist optional: steht er still, ist Violeet immer noch ein Terminal, und das Board sagt genau das.",

    "glabs.eyebrow": "die weitere Konstellation",
    "glabs.h2": "Unter dem Dach von <span>[GLabs]</span>.",
    "glabs.lede": "[GLabs] verbindet die Familie in der visuellen Sprache von Violeeter.",
    "glabs.flux": "der Workflow · direkter Verweis ↗",
    "glabs.violeeter": "das visuelle System · direkter Verweis ↗",
    "footer": "Violeet und Violeeter stehen unter MIT-Lizenz. Gebaut von <a href=\"https://github.com/grippado\">grippado</a>."
  }
};
