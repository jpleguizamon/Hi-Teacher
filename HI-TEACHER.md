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

- **Cores**
  - Fundo: gradiente azul-marinho bem escuro (`#030509` → `#082242`), não preto chapado.
  - Superfícies (cards, chips, inputs): tons de azul-marinho escuro em camadas (`--surface:#0e1726`, `--surface-2:#0a1420`, `--surface-3:#0f172a`).
  - Acento/marca: azul-céu `#38bdf8` (`--accent`), usado em botões primários, foco de campos, ícones ativos, badges de seleção, gráficos.
  - Texto: quase-branco `#f8fafc` (`--text`) para primário, cinza-azulado `#94a3b8` (`--muted`) para secundário/labels.
  - Semânticas fixas (não fazem parte da paleta de marca, mas têm significado): verde `#4ade80` (sucesso/concluído), laranja `#fb923c` (pendente/aviso), vermelho `#f87171` (erro/exclusão), dourado `#fbbf24` (estrelas de avaliação).
  - Tokens completos estão no `:root` do `<style>`, no topo do `index.html`.
- **Formas**: cantos bem arredondados (escala `--radius-xs` a `--radius-pill`, de 0.4375rem a pílula completa), bordas de 1px sutis (`--border`/`--border-strong`), sombras leves e com offset real (nunca glow chapado).
- **Componentes padronizados**: botões de ação primária em formato de pílula (fundo azul, texto escuro para contraste), botões secundários neutros, cards de aluno/aula/estatística com preenchimento liso (sem gradiente diagonal carregado), badges de status coloridos por estado.
- **Escala responsiva**: `html{font-size}` muda por `@media` (de 76% em telas muito pequenas a 126% em telas grandes), e quase todo o CSS usa `rem`, então tudo (fonte, espaçamento, avatares, ícones) encolhe/cresce junto e na mesma proporção.
- **Layout**: menu-drawer com hambúrguer no celular; barra lateral fixa sempre visível a partir de ~900px de largura.

## Fontes

- **Inter** (via stack de sistema `Inter, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif`) — fonte de toda a interface (não é carregada de fora, usa a instalada no sistema ou a mais próxima).
- **Fraunces** (itálica, peso 600, carregada do Google Fonts) — usada só na saudação de boas-vindas da Home ("Olá, [nome]"), como toque editorial/premium pontual.
- **Logo "Hi Teacher"**: imagem (script cursivo elegante) embutida como `data:image/png;base64` diretamente no HTML, usada na tela de login, no cabeçalho e na barra lateral — não é texto, é uma imagem fornecida pelo dono do projeto.

## Estrutura das páginas

Tudo vive num único `index.html` (~5.800 linhas): HTML + `<style>` + `<script>` no mesmo arquivo, sem build step. Navegação por `data-page`, trocando qual `<section>`/bloco fica visível.

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
- `localStorage` como cache local dos dados (alunos, aulas, metas, configurações), sincronizado com o Supabase.
- SheetJS (xlsx), JSZip e Tesseract.js via CDN, usados na importação de planilhas de alunos (inclusive com OCR de imagem).
- Ícones em sprite SVG inline (`<defs>` no topo do `<body>`), sem biblioteca de ícones externa.

## O que ainda falta / próximos passos

- **Estrutura visual "premium" ainda rasa em algumas páginas**: o pedido de deixar o app com cara mais premium (inspirado no app Pierre) foi aplicado só parcialmente — a forma (cantos, botões em pílula, cards lisos, sombra leve) foi mantida, mas mudanças mais profundas de layout (densidade, hierarquia tipográfica dos números, espaçamento) ainda não foram feitas nas páginas de configurações, avaliação e organizador de aulas.
- **Sem testes automatizados**: não há suíte de testes (unitário, e2e) para este arquivo; validação hoje é manual (abrir no navegador) mais checagem estática pontual (ex.: `impeccable detect` para anti-padrões de UI).
- **Página de Testes** (`data-page="tests"`) ainda existe no menu de produção — é uma página de mockups internos que deveria ser removida ou escondida antes de considerar o app "pronto" para outros usuários além do dono.
- **Onboarding de instrumentos**: lista de instrumentos é customizável (pensado originalmente pra resolver o caso de professores de instrumentos fora da lista padrão, como bateria), mas ainda não foi testado com um segundo professor de verdade além do dono do projeto.
- **Sem modo claro**: o app é 100% tema escuro; não há plano definido de suporte a tema claro.
- **Sem histórico de versão do arquivo**: até este commit, o projeto vivia só como arquivo trocado manualmente por chat, sem controle de versão — este é o primeiro commit dele num repositório git.
