---
name: new-migration
description: Create the next sequential Cloudflare D1 migration for rp-doces with the project header, an additive-only checklist, local apply and the test suite. Use when the user runs /new-migration <descricao>.
disable-model-invocation: true
---

# /new-migration <descricao>

1. **Number.** List `migrations/*.sql`, take the highest `NNNN_` prefix and add 1 (4 digits). Name the file `migrations/NNNN_<descricao_em_snake_case>.sql`. Never reuse or renumber an existing file.
2. **Header.** Start with a Portuguese comment block, like the existing migrations:
   - `-- Migration NNNN: <título>` and why the change exists (tracking tag if any: `A1`, `Passo N`, `HUMAN-N`);
   - what the migration does NOT touch (list the ledger/stock tables it leaves alone);
   - how it stays safe on the production D1.
3. **Additive only.** Prefer `CREATE TABLE`, `ALTER TABLE ... ADD COLUMN`, `CREATE INDEX`, `CREATE TRIGGER`. Before any `DROP TABLE` + `RENAME` rebuild, run `grep -n "REFERENCES <tabela>" migrations/*.sql`: if any child uses `ON DELETE CASCADE`, STOP and tell the user — the rebuild would wipe child rows even under `PRAGMA defer_foreign_keys` (see `docs/architecture/database-migrations.md` and `scripts/b5-production-compat.sql`).
4. **Invariants in the database.** Express status enums as `CHECK (status IN (...))`, uniqueness as UNIQUE indexes, and cross-row rules as `BEFORE` triggers; money as `*_centavos INTEGER`; fractional quantities as integer thousandths.
5. **Validate locally.**
   - `npm run db:migrate:local`
   - `npm run test` (the harness applies every migration to a fresh D1, so a broken migration fails the whole suite)
6. **Report** the new file path and the test result. Do NOT run anything with `--remote`; production apply is done by the user.
