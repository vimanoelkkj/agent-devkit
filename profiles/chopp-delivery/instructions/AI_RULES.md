# AI_RULES — política compartilhada (Codex, Claude Code, Antigravity)

Política compartilhada apenas do perfil `chopp-delivery`, aplicada na raiz do consumidor. Não é uma política global do Agent DevKit. `AGENTS.md` e `CLAUDE.md` só acrescentam o que é específico de cada agente. Leia este arquivo antes de qualquer tarefa, respeitando a hierarquia de instruções da plataforma e o escopo autorizado pelo usuário.

## Contexto do projeto

- Stack: React, Vite, TypeScript, Cloudflare Pages, Workers, D1 e R2. Código em `src/`, `server/`, `functions/`, `shared/`, `migrations/`, `config/cloudflare/`.
- Homologação privada é separada da demo pública. Não misture bindings, bancos, buckets ou URLs entre elas.
- Não altere a publicação editorial sem autorização explícita.
- A biblioteca de mídia remota permanece **desabilitada** após o erro `409 MEDIA_BUSY_OR_CONFLICT`. Não a reabilite nem contorne o erro sem autorização.
- Preserve arquivos e configurações locais protegidos: `.env*` (exceto `.env.example`), `.dev.vars*` (exceto `.dev.vars.example`), `.wrangler/` e `graphify-out/`.
- Documentação de referência: `docs/` (por exemplo `docs/cms-*.md` e `docs/immersive-cms-*.md`).

## Regras

1. **Graphify:** antes de alterar código, consulte o grafo existente para dependências e impacto, usando `graphify query`, `graphify explain` ou `graphify path` conforme a versão instalada. Use os resultados para localizar leituras pontuais e confirme-os nos arquivos atuais; o grafo pode estar desatualizado ou incompleto. Se `graphify-out/wiki/index.md` existir, use-o para navegação ampla. Consulte `graphify-out/GRAPH_REPORT.md` só para visão geral ou quando as consultas focadas forem insuficientes. Após mudanças estruturais (arquivos criados, movidos ou removidos; imports ou dependências alterados), atualize o grafo existente pelo fluxo documentado, como `graphify update .`, e confira as relações afetadas. Agrupe a atualização ao final das mudanças relacionadas; não repita consultas ou atualizações sem nova necessidade. Se a ferramenta ou o grafo estiver indisponível, informe a limitação e faça análise direcionada de fontes e dependências; não instale ferramentas nem gere um grafo amplo implicitamente. Preserve os hooks existentes e cumpra requisitos mais estritos do projeto. Não presuma que `graphify-out/` seja versionado: se o grafo for rastreado e sua atualização reescrever o arquivo inteiro, avalie a causa antes de tratá-la como churn; não suprima a atualização ou os hooks apenas para reduzir o diff. Informe falhas de atualização sem forçar sobrescritas.
2. **Execução direta:** faça operações locais normais (ler, editar, buscar, rodar verificações) sem pedir permissão.
3. **Economia de tokens:** buscas específicas, comandos agrupados, logs resumidos, sem análise redundante nem releitura do que já foi lido.
4. **Testes proporcionais ao risco:** rode só o que cobre a mudança (um arquivo de teste, `npm run typecheck`, `npm run lint`) e cumpra as verificações obrigatórias do projeto. Priorize regressões, segurança e integridade de dados. Não rode suíte completa, `npm run build` geral ou E2E (`test:e2e*`) sem necessidade técnica. Para documentação, valide estrutura, referências e diff direcionado. Não apresente verificações não executadas como aprovadas.
5. **Mudanças pequenas e direcionadas**, compatíveis com a arquitetura existente. Sem refatoração oportunista.
6. **Escopo:** não modifique arquivos fora do escopo nem sobrescreva alterações preexistentes. Rode `git status` antes de editar e preserve o que não é seu.
7. **Ações que exigem autorização explícita:** commit, push, merge, deploy, migrations remotas (`wrangler d1 ... --remote`) e qualquer mudança em recursos Cloudflare (Pages, Workers, D1, R2, secrets, rotas).
8. **Segredos:** nunca registre, revele ou versione secrets, tokens, cookies ou credenciais, nem em logs, mensagens ou docs.
9. **Rigor:** separe fatos comprovados, hipóteses e riscos. Não invente scripts, caminhos ou dependências: confira em `package.json` e no repositório.
10. **Entrega:** informe somente as alterações feitas, as verificações relevantes (com resultado real) e as pendências reais.
11. **Subagentes:** não presuma herança automática de instruções. Quando a delegação for autorizada e útil, forneça objetivo, escopo, restrições relevantes e o caminho desta política no consumidor; exija sua leitura e repasse a regra de Graphify a quem explorar ou alterar código. Preserve a hierarquia de instruções e evite exploração duplicada.
12. **Handoffs concisos:** use a compactação nativa quando disponível e mantenha um resumo apenas quando a continuidade exigir. Retenha objetivo, autorizações, decisões, arquivos alterados, estado não commitado, validações, bloqueios e próximo passo. Omita logs redundantes e segredos. Ao retomar, confira arquivos e estado do Git antes de confiar no resumo.

## Scripts úteis (`package.json`)

`npm run typecheck` · `npm run lint` · `npm run test:backend` · `npm test` · `npm run build` · `npm run db:init` (D1 local).
