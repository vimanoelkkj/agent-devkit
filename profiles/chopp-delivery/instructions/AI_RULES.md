# AI_RULES — política compartilhada (Codex, Claude Code, Antigravity)

Fonte única das regras. `AGENTS.md` e `CLAUDE.md` só acrescentam o que é específico de cada agente. Leia este arquivo antes de qualquer tarefa.

## Contexto do projeto

- Stack: React, Vite, TypeScript, Cloudflare Pages, Workers, D1 e R2. Código em `src/`, `server/`, `functions/`, `shared/`, `migrations/`, `config/cloudflare/`.
- Homologação privada é separada da demo pública. Não misture bindings, bancos, buckets ou URLs entre elas.
- Não altere a publicação editorial sem autorização explícita.
- A biblioteca de mídia remota permanece **desabilitada** após o erro `409 MEDIA_BUSY_OR_CONFLICT`. Não a reabilite nem contorne o erro sem autorização.
- Preserve arquivos e configurações locais protegidos: `.env*` (exceto `.env.example`), `.dev.vars*` (exceto `.dev.vars.example`), `.wrangler/` e `graphify-out/`.
- Documentação de referência: `docs/` (por exemplo `docs/cms-*.md` e `docs/immersive-cms-*.md`).

## Regras

1. **Graphify:** antes de mudar código, consulte o grafo (`graphify query`, `explain` ou `path`) para dependências e impacto. Se `graphify-out/graph.json` não existir, gere-o com `/graphify`. Atualize com `graphify update .` depois de mudanças estruturais (arquivos criados, movidos ou removidos; imports alterados). Não consulte a cada comando.
2. **Execução direta:** faça operações locais normais (ler, editar, buscar, rodar verificações) sem pedir permissão.
3. **Economia de tokens:** buscas específicas, comandos agrupados, logs resumidos, sem análise redundante nem releitura do que já foi lido.
4. **Testes proporcionais ao risco:** rode só o que cobre a mudança (um arquivo de teste, `npm run typecheck`, `npm run lint`). Não rode suíte completa, `npm run build` geral ou E2E (`test:e2e*`) sem necessidade técnica.
5. **Mudanças pequenas e direcionadas**, compatíveis com a arquitetura existente. Sem refatoração oportunista.
6. **Escopo:** não modifique arquivos fora do escopo nem sobrescreva alterações preexistentes. Rode `git status` antes de editar e preserve o que não é seu.
7. **Ações que exigem autorização explícita:** commit, push, merge, deploy, migrations remotas (`wrangler d1 ... --remote`) e qualquer mudança em recursos Cloudflare (Pages, Workers, D1, R2, secrets, rotas).
8. **Segredos:** nunca registre, revele ou versione secrets, tokens, cookies ou credenciais, nem em logs, mensagens ou docs.
9. **Rigor:** separe fatos comprovados, hipóteses e riscos. Não invente scripts, caminhos ou dependências: confira em `package.json` e no repositório.
10. **Entrega:** informe somente as alterações feitas, as verificações relevantes (com resultado real) e as pendências reais.

## Scripts úteis (`package.json`)

`npm run typecheck` · `npm run lint` · `npm run test:backend` · `npm test` · `npm run build` · `npm run db:init` (D1 local).
