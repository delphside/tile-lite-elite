// Computes the identifier every account this run creates will carry (#252 R1).
//
// **Once per run, not once per worker.** `playwright.config.ts` sets
// `fullyParallel: true` with `workers: undefined` off CI, so tests run in
// several worker *processes*. A module-level constant in `helpers.ts` would be
// evaluated once in each of them and every worker would believe it was a
// separate run — and the failure would look exactly like the convention
// working. `globalSetup` runs once, before any worker is spawned, and the
// workers inherit the environment.
//
// **Distinctness is what has to be generated; ordering comes free.** Nothing
// reads run ids in order, so there is no counter to keep, nothing to record and
// nothing to conflict over. The timestamp leads so that sorting names sorts the
// runs — the owner's question is *"which run was mine, just now"*, not *"which
// run was fifth"*.

import { runPrefixFor } from './naming';

export const RUN_ID_VAR = 'E2E_RUN_ID';

export default async function globalSetup() {
  // Respected if already set, so a caller — CI, or a person re-running a
  // cleanup — can name the run rather than having one invented underneath them.
  if (process.env[RUN_ID_VAR]) {
    console.log(`[e2e] run ${process.env[RUN_ID_VAR]} (from the environment)`);
    return;
  }
  const stamp = Date.now().toString(36);
  const rand = Math.random().toString(36).slice(2, 6);
  process.env[RUN_ID_VAR] = `${stamp}${rand}`;
  console.log(
    `[e2e] run ${process.env[RUN_ID_VAR]} — accounts are ${runPrefixFor(process.env[RUN_ID_VAR]!)}*`,
  );
}
