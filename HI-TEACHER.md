# Hi Teacher

Aplicativo web (single-file, `index.html`) de gestão de agenda, alunos e financeiro para professores particulares de música.

## Objetivo

Substituir planilhas e agendas soltas por um painel único onde um professor particular consegue, no dia a dia:

- ver a agenda de aulas da semana e marcar cada aula como dada/concluída;
- cadastrar e organizar os alunos ativos e inativos (instrumento, horário, modalidade, mensalidade, tempo de casa);
- avaliar o desempenho de cada aluno por critério (pontualidade, prática, comprometimento, desenvolvimento) com notas em estrelas;
- acompanhar a evolução financeira (faturamento por mês) e quantitativa (nº de alunos ativos por mês) em gráficos;
- organizar materiais/planos de aula por tema;
- controlar metas pessoais e profissionais (curto, médio e longo prazo);
- gerenciar as próprias configurações (lista de instrumentos que leciona, valores padrão, dias de trabalho, lembretes, localização para feriados).

## Público

Professores particulares de música (violão, piano, teclado, bateria, canto etc.), autônomos, que dão aula individual ou em grupo e hoje não têm um sistema dedicado — só planilha, agenda de papel ou caderno. A interface e os textos são em português (pt-BR), pensados para uso no celular no dia a dia entre uma aula e outra, com telas maiores (tablet/desktop) tratadas como bônus, não como alvo principal.

## Estilo visual

Tema escuro único (não tem modo claro). A identidade visual é **azul e preto** — isso é intencional e não deve ser trocado por outra paleta (já foi tentado um redesign inspirado no app Pierre com preto puro + verde-limão; foi revertido a pedido do dono do projeto, que quer manter azul/preto como cor de marca).

**Direção atual (set/2026): dark glassmorphism preto + azul elétrico**, pedida pelo dono do projeto com uma referência de dashboard em vidro fosco. Substituiu o visual anterior de superfícies azul-marinho lisas e acento azul-céu `#38bdf8`.

- **Cores**
  - Fundo: **animado em WebGL2** (`<canvas id="ribbonGlowCanvas">` fixo atrás de tudo + script no fim do `<body>`), fornecido pelo dono do projeto: preto `#05060B` (`--bg`) com brilhos azul `#4F8CFF` e ciano `#2FD3F2` que fluem devagar e seguem o mouse/dedo. O arquivo original tinha um violeta `#8F7BFF` no segundo brilho; foi trocado pelo ciano da marca por causa da regra azul/preto (para voltar, é a linha `accent2` do `fragmentSrc`). Roda em meia resolução e a ~30 fps (é só gradiente suave, e cada quadro faz todo o vidro refazer o desfoque). Se o WebGL2 falhar ou o contexto cair, o canvas some e aparecem as luzes estáticas do `body::before`. Com `prefers-reduced-motion` desenha um quadro só, parado.
  - Vidro: todo container (cards, sidebar, cabeçalho, modais, gavetas, login, grade da Agenda, botões de ícone) é **transparente e fosco** — tinta `rgba(14,20,34,.4)` (`--glass`) + reflexo diagonal branco (`--sheen`), combinados em `--glass-fill`; variantes `--glass-fill-strong` (sidebar/gavetas/aviso), `--glass-fill-raised` (card em destaque), `--glass-inset` (linhas dentro de um painel) e `--glass-field` (inputs). Painel novo deve usar `background: var(--glass-fill)` + `backdrop-filter: var(--blur)`.
  - Bordas: 1px ciano translúcido `rgba(47,211,242,.18)` (`--glass-border`) ou mais suave (`--glass-border-soft`); separadores internos em `--hairline`.
  - Acento/marca: ciano elétrico `#2FD3F2` (`--accent`) em ação primária, item ativo, foco, seleção e linha dos gráficos; azul elétrico `#1E88E5` (`--accent-2`) como apoio (luz ambiente, avatares, gradiente da barra de progresso). Texto sobre o ciano é quase-preto `#021219` (`--accent-ink`).
  - Texto: branco `#FFFFFF` (`--text`), secundário `#94A3B8` (`--muted`), títulos com leve toque de ciano `#E6FAFE` (`--heading`).
  - Semânticas fixas (não fazem parte da paleta de marca, mas têm significado): verde `#4ade80` (sucesso/concluído/alta), laranja `#fb923c` (pendente/aviso), vermelho `#f87171` (erro/exclusão/queda), dourado `#fbbf24` (estrelas de avaliação, com brilho). Eventos próprios da Agenda usam o ciano da marca.
  - Tokens completos estão no `:root` do `<style>`, no topo do `index.html`. Componente novo deve usar só os tokens.
- **Vidro e brilho**: `backdrop-filter: blur(16px) saturate(160%)` (`--blur`) nos painéis; o brilho azul (`--glow-sm`/`--glow`/`--glow-lg`, ex.: `0 0 15px rgba(47,211,242,.3)`) é reservado a estado ativo, ação primária e hover — nunca em elementos em repouso. Com `prefers-reduced-transparency` o vidro fica opaco; com `prefers-reduced-motion` as transições somem.
- **Regras técnicas do vidro** (fáceis de quebrar sem perceber):
  - Um `backdrop-filter` dentro de outro só "enxerga" o pai, não o fundo. Por isso o fundo dos modais (`.modal-bg`) só escurece e quem desfoca é o painel `.modal`; e o portão de login não desfoca — o cartão `.auth-card` é que desfoca, direto sobre o fundo animado (o app atrás fica `visibility:hidden` enquanto o login/onboarding está aberto).
  - `opacity < 1` num elemento que *contém* vidro também desliga o desfoque dos filhos; por isso a animação de troca de página do `<main>` usa só `transform`.
  - Na Agenda o desfoque fica na grade inteira (um `backdrop-filter` só, sem `saturate` pra não marcar a borda da grade) e as 42 células são vidro translúcido por cima.
- **Formas**: caixas entre 12px e 24px de raio (`--radius-sm` a `--radius-xl`); botões, chips, badges e itens de menu em pílula (`--radius-pill`).
- **Componentes padronizados**: ação primária em pílula ciano com brilho (`.save`, `.btn-set-month`, botão "Hoje"); secundária em pílula de vidro (`.cancel`, `.btn-historico`); item ativo do menu em pílula acesa (gradiente ciano→azul translúcido + borda + brilho, ícone em ciano); badges de status em pílula translúcida da cor do estado; estrelas douradas com brilho.
- **Escala responsiva**: `html{font-size}` muda por `@media` (de 76% em telas muito pequenas a 126% em telas grandes), e quase todo o CSS usa `rem`, então tudo (fonte, espaçamento, avatares, ícones) encolhe/cresce junto e na mesma proporção.
- **Layout**: menu-drawer com hambúrguer (botão flutuante de vidro) no celular; barra lateral fixa sempre visível a partir de ~900px de largura. Cabeçalho e barra lateral são `sticky` de verdade (o `body` usa `overflow-x: clip` em vez de `hidden` justamente pra isso), e o conteúdo rola desfocado por baixo do cabeçalho de vidro. Rodapé da barra lateral: "Configurações" e "Sair da conta" (`#btnLogout`, mesma ação da linha "Sair da conta" em Configurações).

## Fontes

- **Inter** (via stack de sistema `Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`) — fonte de toda a interface, inclusive da saudação da Home (não é carregada de fora, usa a instalada no sistema ou a mais próxima). Números de tabela/KPI/horário usam `tabular-nums`.
- A **Fraunces** itálica que era usada só na saudação "Olá, [nome]" foi removida no redesign glass (o briefing pediu tipografia sans-serif limpa); o `<link>` do Google Fonts saiu junto, então o app não carrega mais nenhuma fonte externa.
- **Logo "Hi Teacher"**: imagem (script cursivo elegante) embutida como `data:image/png;base64` diretamente no HTML, usada na tela de login, no cabeçalho e na barra lateral — não é texto, é uma imagem fornecida pelo dono do projeto.

## Estrutura das páginas

Tudo vive num único `index.html` (~6.000 linhas): HTML + `<style>` + `<script>` no mesmo arquivo, sem build step. Navegação por `data-page`, trocando qual `<section>`/bloco fica visível.

| Página (`data-page`) | O que tem |
|---|---|
| `home` | Saudação do dia, lista de aulas dos próximos dias (cards com horário, aluno, instrumento, status), lista de mensalidades do mês. |
| `students` | Grade de cards dos alunos ativos (instrumento, horário, modalidade, permanência, mensalidade) e lista de inativos/saídas; busca, ordenação e filtros (formato, instrumento, dia). |
| `evaluation` | Gráfico das 4 competências (pontualidade, prática, comprometimento, desenvolvimento) por aluno ou média geral, com histórico de avaliações por aula. |
| `studentsPerformance` | Desempenho dos alunos por tema/assunto musical vinculado. |
| `planner` | Organizador de aulas/materiais por tema, com upload de imagem/mapa mental. |
| `agenda` | Calendário mensal com dias de aula, feriados nacionais e da cidade configurada. |
| `goals` | Metas pessoais/profissionais organizadas por período (dia/semana/mês/ano), inspirado no padrão de apps de tarefas (seções fixas, progresso por seção, concluídas colapsadas). |
| `evolutionFinancial` | Gráfico de faturamento mês a mês, KPIs (maior ganho, média mensal), edição de valor por mês. |
| `evolutionQuantitative` | Gráfico de nº de alunos ativos por mês. |
| `tests` | Página interna de testes/mockups de componentes (não é uma feature do produto final). |

Outras telas importantes fora do menu principal: `#authGate` (login/cadastro via Supabase), `#onboardingGate` (configuração inicial: nome, cidade/estado, instrumentos lecionados, mensalidade padrão), Configurações (lista de instrumentos customizável, valores padrão, dias úteis, duração de aula, lembretes, localização).

## Stack técnica

- Um único arquivo HTML, sem framework, sem build.
- **Supabase** (`@supabase/supabase-js` via CDN) para autenticação e persistência dos dados do usuário (a chave anônima no arquivo é pública por design do Supabase — a segurança real vem das regras de RLS no banco, não do sigilo da chave).
  - O login precisa da biblioteca do CDN. Se ela não carregar (sem internet, ou o `index.html` aberto dentro de outro app — visualizador de e-mail, WhatsApp, Drive, Claude — que bloqueia scripts externos), o login mostra "Não foi possível conectar ao login" com um botão "Tentar de novo". Antes desse ajuste (set/2026) o app caía calado no modo "só local" e abria o onboarding sem pedir login, parecendo que o login tinha sumido. O modo "só local" continua existindo, mas só quando `SUPABASE_URL` está vazio.
  - Mensagens de erro do Supabase são traduzidas por `authErrorMessage()` (credenciais inválidas, email não confirmado, conta já existente, sem conexão).
  - Sincronização: os dados de cada conta ficam numa linha da tabela `user_data` (coluna `data`, um JSON com as chaves `jp_*` do `localStorage`), e cada envio **substitui a linha inteira**. Por isso o app só envia depois de ler a nuvem com sucesso naquela sessão (`cloudPullOk`). Antes (até set/2026), se a leitura falhasse o app enviava os dados do aparelho — vazios num celular novo — por cima da nuvem, apagando tudo. Se a leitura falhar agora, aparece um aviso e nada é enviado até abrir o app de novo com internet.
  - Os dados salvos só no aparelho ficam no `localStorage` do navegador/endereço onde o app foi aberto: arquivo aberto em outro lugar ou outro endereço (ex.: o site) começa vazio até fazer login e puxar da nuvem.
  - Testado em set/2026: o Supabase aceita login tanto de página hospedada quanto do arquivo aberto localmente (origem `null`). Para uso no celular, o caminho confiável é abrir por uma URL no navegador (ex.: GitHub Pages do repositório). Os links de confirmação de conta e de "esqueci minha senha" voltam para a URL de onde o app foi aberto, então essa URL precisa estar em Authentication → URL Configuration no painel do Supabase.
- `localStorage` como cache local dos dados (alunos, aulas, metas, configurações), sincronizado com o Supabase.
- SheetJS (xlsx), JSZip e Tesseract.js via CDN, usados na importação de planilhas de alunos (inclusive com OCR de imagem).
- Ícones em sprite SVG inline (`<defs>` no topo do `<body>`), sem biblioteca de ícones externa.

## O que ainda falta / próximos passos

- **Redesign glass aplicado só na camada visual**: o redesign de set/2026 trocou cores, vidro, bordas, raios, brilho e estados de todos os componentes, mas não mexeu em layout/estrutura das páginas (densidade, hierarquia dos números, textos de estados vazios). Próximas rodadas possíveis: estados vazios que ensinam a usar a tela, KPIs com mais hierarquia, e os gráficos (a linha despenca a zero nos meses ainda não lançados, e o gráfico de competências fica vazio sem avaliações por mês).
- **Sem testes automatizados**: não há suíte de testes (unitário, e2e) para este arquivo; validação hoje é manual (abrir no navegador) mais checagem estática pontual (ex.: `impeccable detect` para anti-padrões de UI).
- **Página de Testes** (`data-page="tests"`) ainda existe no menu de produção — é uma página de mockups internos que deveria ser removida ou escondida antes de considerar o app "pronto" para outros usuários além do dono.
- **Onboarding de instrumentos**: lista de instrumentos é customizável (pensado originalmente pra resolver o caso de professores de instrumentos fora da lista padrão, como bateria), mas ainda não foi testado com um segundo professor de verdade além do dono do projeto.
- **Sem modo claro**: o app é 100% tema escuro; não há plano definido de suporte a tema claro.
- **Sem histórico de versão do arquivo**: até este commit, o projeto vivia só como arquivo trocado manualmente por chat, sem controle de versão — este é o primeiro commit dele num repositório git.
