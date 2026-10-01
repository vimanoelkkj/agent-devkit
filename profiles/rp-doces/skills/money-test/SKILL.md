---
name: money-test
description: Scaffold a rp-doces regression test for a money, stock or idempotency behaviour using the real route handlers, a disposable local D1 and the deterministic concurrency barrier. Use when the user runs /money-test <area> <comportamento>.
disable-model-invocation: true
---

# /money-test <area> <comportamento>

1. **Read the harness first**: `docs/architecture/testing-strategy.md`, `tests/helpers/b3.mjs` (exports `app`, `fixture`, `state`, `barrier`, `withWaitUntil`, `approvedMp`, `refund`), and one close example (`tests/a1.test.mjs` for idempotency/races, `tests/payment-sync-integrity.test.mjs` for Mercado Pago sync).
2. **File**: `tests/<area>-<comportamento>.test.mjs` (kebab-case, Portuguese). It is picked up automatically by `scripts/run-tests.mjs` — no list to edit.
3. **Skeleton**:
   ```js
   import test from "node:test";
   import assert from "node:assert/strict";
   import { app, fixture, state, barrier } from "./helpers/b3.mjs";

   // <área> — <comportamento>: <por que este teste existe / bug que reproduz>.

   const KEY = "11111111-1111-4111-8111-111111111111";

   test("<área>: <condição> => <resultado esperado>", async t => {
     const db = await fixture(t, { paid: false }); // opções: paid, reserve ('ATIVA'...), ledger
     // chame o handler real: app.<modulo>.onRequestPost({ env: {DB: db, MP_ACCESS_TOKEN: 'fake'}, params, request })
     // afirme sobre o estado persistido: await state(db)
   });
   ```
   `fixture()` returns the D1 wrapper directly; set `db.hook` to intercept statements (that is how `barrier()` is wired in `a1.test.mjs`).
4. **Cover**: happy path; same key + same payload replays the same result; same key + different payload conflicts without a new financial write; for races, force both calls through `barrier(2)` so reads finish before writes — never a bare `Promise.all`.
5. **Assert on persisted state** (`pedido_pagamentos`, `pedido_reembolsos`, `produtos.estoque`/`estoque_reservado`, `pedido_operacoes`), not on internal calls. Never pass a live DOM node as an `assert` value.
6. **Run** `node --test tests/<arquivo>.test.mjs`, then `npm run test`; report both results.
