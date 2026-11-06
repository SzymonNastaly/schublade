---
name: add-binding
description: >
  Adds a Cloudflare binding to Schublade: a D1 database, R2 bucket, AI Search
  instance, Workers AI, Browser Run, Workflow, Durable Object, queue, text
  variable, or secret. Use when a task needs a new Cloudflare service, a new
  environment variable or secret, or a change to cloudflare.config.ts. Covers
  the binding builders, resource identifiers from schublade.deploy.json, the
  build guard, remote-only bindings in development, and verification.
---

# Add a Cloudflare binding

`cloudflare.config.ts` declares every binding in `worker.env` with the `bindings` builders from `cf/config`. The `Env` type is inferred from it, so a binding is typed as soon as `pnpm typecheck` regenerates `.cloudflare/types`. There is no `wrangler.jsonc`. Do not create one.

## 1. Find the builder

Read the declarations instead of guessing. The `Bindings` interface lists every builder and its options:

```bash
grep -n "interface Bindings" -A 140 node_modules/cf/../@cloudflare/config/dist/public-*.d.mts
```

`cf docs search "<binding type> binding"` finds the product documentation.

## 2. Choose how the binding resolves its resource

- **Resource bindings** (D1, R2, AI Search, KV, Vectorize, Hyperdrive) name a resource that must exist before deployment. `cf deploy` provisions a new, empty D1, R2, or KV resource for any such binding without an identifier and never records it. Add the identifier to `deploymentParametersSchema` in `cloudflare.config.ts`, add it to the check in `resourceBindings` so that every build mode throws while it is missing, and give it a local value in the development branch. The provisioning script, `scripts/provision_environment.ts`, creates the resource and writes the identifier to `schublade.deploy.json`.
- **Remote-only bindings** (Workers AI, Browser Run) have no local simulation. Declare them with `dev: { remote: true }`. AI Search is remote too, but it needs an existing instance, so development omits it until one is provisioned.
- **Bindings to this Worker** (Workflow, Durable Object) add an export under `worker.exports` with `workerExports.workflow()` or `workerExports.durableObject({ storage: "sqlite" })`, a binding that names `workerName` and the export, and an `export` of the class from `src/server.ts`.
- **Text variables** use `bindings.text()` with a value from `schublade.deploy.json` and a default. A blank value must never weaken a check. Access variables deny every request when blank.
- **Secrets** use `bindings.secret()`. Local values go in `.dev.vars`, which git ignores. Deployments upload values with `cf deploy --secrets-file <PATH>`. Never put a secret value in `cloudflare.config.ts`.

Name the binding in upper snake case with full words, such as `DOCUMENT_STORAGE` or `AI_GATEWAY_IDENTIFIER`, per the naming specification in AGENTS.md.

## 3. Use the binding

Import `env` from `cloudflare:workers` in server-only code:

```ts
import { env } from "cloudflare:workers"

const object = await env.DOCUMENT_STORAGE.get(`documents/${documentId}/original.pdf`)
```

Keep logic that uses a binding in a pure module that receives the binding or a small port interface, so a Node test can replace it with a fake. A billed binding (Workers AI, Browser Run, AI Search) always gets a recorded response in tests.

## 4. Verify

```bash
pnpm typecheck   # regenerates Env and type-checks the new binding
pnpm dev         # starts with the binding simulated locally or connected remotely
```

To see the bindings a deployment would upload, write a temporary `schublade.deploy.json` with placeholder identifiers, run `cf deploy --dry-run`, and delete the file. The dry run builds and prints the bindings without uploading anything.

Then run `pnpm check` and commit.
