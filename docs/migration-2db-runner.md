# Runner da migração 2D-B

Executor versionável: `scripts/migrate-2db.mjs`. Ele substitui o procedimento temporário `/tmp/devkit-2db-migrate.mjs`, preservado com seu journal em `state/chopp-delivery/migration-backups/2db-2026-10-17T23-14-10.045Z-cf640839/`. O original não deve ser reutilizado: a asserção de consumidor limpo na linha 98 antecede `release()` e reprova o próprio `.agent-devkit-sync`.

Este runner não é importado pela engine nem pela CLI de sync. Importar o módulo não executa migração. Nenhuma configuração de produção está embutida ou é gerada automaticamente. O runner mantém o delta revisado da 2D-B (perfil e duas expectativas de teste), sem modificar engine/CLI. A implementação e os ensaios desta etapa não autorizam execução real.

## Contrato de execução

Antes de qualquer mutação, conferir raízes canônicas independentes, HEADs/branches explícitos, Git limpo, ausência de guards e processos escritores identificáveis, inventário protegido e estado legado esperado. A checagem de processos é conservadora para comandos que mencionam as raízes; não substitui a suspensão operacional de outros escritores. Metadados locais e oito Skills precisam estar ignorados e não rastreados. Não alterar excludes durante a operação.

Uma configuração JSON contém `devkitRoot`, `projectDir`, `heads` e `branches` indexados pelas duas raízes absolutas, e `inventory` indexado por caminhos absolutos, com os metadados retornados por `fileMeta()`. O inventário deve vir do preflight autorizado. Não reutilizar o inventário de outro checkout: hashes, inodes e mtimes são vinculados à cópia inspecionada.

Se já houver backups anteriores (como o rollback real da 2D-B), fornecer também `archiveInventory`, inventário completo e aprovado dos arquivos existentes sob `state/chopp-delivery/migration-backups/`. Sem esse inventário exato, o preflight reprova. Esses arquivos entram no conjunto protegido e não são movidos, editados ou apagados. Não há exceção genérica para estado scoped ou qualquer outro arquivo em `state/`.

## Preflight público somente leitura

```sh
NODE_DISABLE_COMPILE_CACHE=1 node scripts/migrate-2db.mjs --preflight /tmp/2db/preflight-inputs.json
```

O comando reutiliza as verificações internas, retorna JSON em stdout e termina antes da preparação transacional: `status: "preflight-passed"` e exit code 0 para aprovação, `status: "preflight-blocked"` com diagnóstico e exit code 1 para bloqueio, inclusive JSON/argumentos inválidos. Em ambos os casos `readOnly` é true. Não cria configuração, diretório, backup, journal ou guard, não importa a engine e não chama callbacks de execução ou recuperação. A API equivalente é `preflightMigration(config)`.

O campo `mode: "scratch"` aceita clones em `/tmp`; sem `mode`, a validação exige as duas raízes reais exatas já definidas pelo executor. Esse campo controla apenas a fronteira de caminhos: `--preflight` nunca inicia `runMigration()`, independentemente do conteúdo do JSON. Não há opção para ignorar Git sujo, guards ou inventários divergentes. Aprovação do preflight não autoriza migração.

As leituras Git dessa entrada isolam as variáveis `GIT_*`, ignoram configuração global/system, desabilitam hooks, fsmonitor executável e atualização opcional do index. Filtros Git locais `clean`/`process`, incluindo configurações incluídas, bloqueiam o preflight antes de `status`, que poderia executá-los; não são contornados para produzir aprovação. O diagnóstico também verifica origin/markers exclusivos, compatibilidade do lock legado, recursos permitidos, mesmo filesystem para os renames, machine-id Linux válido e journals anteriores encerrados, inclusive guards.json quando presente. O reconhecedor de processos inclui `MainThread`, nome usado pelo Node 24 no Linux. As entradas de execução/recuperação mantêm seu leitor e sequência transacional anteriores.

Leituras podem atualizar atime. `NODE_DISABLE_COMPILE_CACHE=1` evita gravações de cache do runtime Node configurado externamente; a aplicação escreve somente o diagnóstico em stdout. Os testes bloqueiam APIs de mutação e comparam conteúdo, inode, modo, nlink, mtime/ctime, diretórios e metadados Git antes/depois, incluindo aprovação, falhas, configuração fsmonitor e ambiente Git hostis.

Comandos de ensaio (somente `/tmp`, config de cada clone):

```sh
node scripts/migrate-2db.mjs --scratch /tmp/ensaio/config.json
node scripts/migrate-2db.mjs --recover-scratch /tmp/ensaio/devkit/state/chopp-delivery/migration-backups/ID
```

As entradas `--execute CONFIG` e `--recover BASE` existem para futura execução especificamente autorizada. Aceitam somente as raízes reais exatas `/home/zzzzz/dev/agent-devkit` e `/home/zzzzz/dev/chopp-delivery`, exigem os mesmos preflights e usam o mesmo fluxo dos ensaios. Não foram chamadas nesta etapa. Sem opção explícita não há execução. `--scratch` não pode ser convertido em execução real por um campo do JSON. Não há autoaprovação, staging ou commit do resultado pelo runner.

Enquanto estes arquivos estiverem untracked no DevKit, o preflight real deve reprová-los. Não criar exceção no gate para acomodar o próprio código do runner; eventual versionamento e novo baseline dependem de autorização separada.

## Guards e gate Git

`scripts/migration-guards.mjs` registra um journal durável `guards.json`, 0600, no diretório privado 0700 do backup. O id é o mesmo do journal da migração. A área central `state/` precisa já ser ignorada; o runner não cria regras de ignore. Snapshot do Git inclui HEAD, branch, index, config e exclude. `GIT_OPTIONAL_LOCKS=0` e `diff.autoRefreshIndex=false` impedem que as próprias leituras de status/diff atualizem o index. Alterações externas desses metadados continuam reprovando.

Aquisição usa caminho exato, O_EXCL/O_NOFOLLOW, token exclusivo, fsync e conferência pathname/descritor; registra device/inode, nlink, modo, tamanho, mtime/ctime e SHA-256. Guard preexistente, desconhecido, de outra execução, substituído, adulterado, symlink ou hardlink não é adotado nem removido.

O gate intermediário usa porcelain v1 NUL (`-z --untracked-files=all`) nos DOIS repositórios. Aceita apenas registros `??` dos guards exatos, adquiridos e integralmente iguais ao journal desta execução. Todos os demais registros precisam corresponder exatamente aos três arquivos editados no DevKit, com hashes finais aprovados; consumidor exige conjunto vazio. Guards desconhecidos na raiz são recusados mesmo se ignorados. Não há filtro por prefixo nem tolerância para staging, rename, exclusões ou untracked adicional.

Após todos os gates de plano, verify, dry-run, 169 testes legados, sintaxe, diff e inventário, o runner libera guards em ordem inversa. Cada unlink tem intenção durável, revalidação imediatamente anterior, fsync do diretório e confirmação individual. Falha de remoção ou liberação parcial impede conclusão. Após release, repete verify/dry-run e inventário, e então executa o gate Git final sem exceção para guards. Só depois registra `completed`. O marcador prematuro `all-gates-passed` foi retirado.

## Rollback e recuperação

O journal de migração é gravado por temporário exclusivo, fsync, rename e fsync do diretório. Ele registra backups, edições, renames, seed e diretórios próprios. Os dois módulos executados são copiados para o backup. Renames mantêm o primitivo Linux `renameat2(RENAME_NOREPLACE)` do runner original; não há fallback que possa sobrescrever um destino concorrente.

Após falha, readquirir os guards já liberados exclusivamente antes de restaurar qualquer alvo. Novo escritor, guard desconhecido ou guard adulterado causa `rollback-conflict`; não forçar a limpeza. A recuperação valida vínculos de raízes/id/journals, os caminhos permitidos da 2D-B, backups e pós-estados antes de tocar nos alvos e revalida imediatamente antes de restaurá-los.

Renames são registrados antes da operação e conciliados pela presença/identidade em origem e destino. Remoção do seed e restauração de edições têm estados de intenção. Liberação parcial é idempotente: `releasing` com caminho ausente é conciliado, `released` com arquivo recriado é conflito, e `held` desaparecido não autoriza presumir remoção própria. Aquisição ou escrita interrompida sem identidade/conteúdo completos, backup divergente ou escrita parcial ambígua exige revisão manual.

Remover somente seed integralmente igual ao criado e diretórios próprios vazios; restaurar os três arquivos por bytes/modos e os metadados/lock legado por rename sem sobrescrita. Nunca varrer untracked, usar reset/clean ou sync reparador. As oito Skills conservam hashes, inodes, mtimes e permissões.

Estados finais:

| Estado | Significado |
|---|---|
| `completed` | Migração passou no gate final após release |
| `rolled-back` | Alvos restaurados, guards próprios removidos e Git estrito aprovado |
| `rolled-back-git-dirty` | Alvos restaurados, mas Git final reprovado; arquivos extras preservados |
| `rollback-conflict` | Recuperação automática parou para preservar conteúdo/propriedade concorrente |

Uma execução de migração que fez rollback continua retornando falha no CLI, mesmo que o rollback tenha sido limpo. A entrada explícita de recuperação retorna sucesso somente para `rolled-back`. Não tratar falha recuperada como migração concluída.

## Validação

```sh
node --test tests/migration-guards.test.mjs tests/migrate-2db.test.mjs
node --test tests/migration-preflight.test.mjs
node --test tests/devkit-linux.test.mjs tests/devkit-linux-resources.test.mjs tests/devkit-checkout-state.test.mjs
node --check scripts/migrate-2db.mjs
node --check scripts/migration-guards.mjs
git -c diff.autoRefreshIndex=false diff --check
```

Os 31 testes do gate anterior foram transportados preservando as asserções e apontando para o módulo integrado. As fixtures criam clones locais com template vazio e sem hardlinks, origin sintético e metadados legados montados diretamente a partir das fontes Core, sem sync para preparar a migração. Por padrão usam o próprio DevKit como fonte Git de ambos os clones; `DEVKIT_TEST_SOURCE`/`DEVKIT_TEST_CONSUMER_SOURCE` permitem ensaiar os dois repositórios reais apenas como fontes somente leitura. Os arquivos criados pelos testes permanecem em `/tmp/devkit-guard-tests-*` e `/tmp/devkit-runner-tests-*` para inspeção.

Os testes de integração passam pelo executor completo, inclusive o CLI, verify/dry-run reais nas cópias e a suíte legada de 169 testes. Falhas são injetadas antes/depois de seed, gates e release; SIGKILL é real, com recuperação do journal em outro processo. Untracked e guards de terceiros permanecem preservados. O ambiente da suíte filha remove `NODE_TEST_CONTEXT` para não aceitar uma execução recursiva vazia como validação.

Limites: os guards são cooperativos; ainda existe TOCTOU contra escritores arbitrários e não há transação atômica entre repositórios. Journal privado é parte da confiança. SIGKILL não simula perda de energia. Git não inventaria arquivos ignorados comuns: os inventários de Skills, metadados e estado continuam necessários. A suíte Node legada contém uma fixture Git com commit vazio em diretório descartável; nenhuma operação de staging/commit se destina aos dois repositórios reais. A engine PowerShell permanece sem alterações; o runner requer Linux, Node 24, Git e Python3/glibc para rename sem sobrescrita.
