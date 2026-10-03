# End-to-end UI tests (Playwright)

Browser tests that drive the real (wasm) web client against a running backend —
catching client/server **contract** breaks that Rust unit/integration tests
can't see, since those never render the client or cross the wire. This is the
only Node in the repo, quarantined to this directory and kept out of the cargo
workspace.

## Running

The suite runs against an **already-running dev environment** — it does not
start the app itself. That's [runbook](../docs/3.3-testing-ci-and-release.md#shipping-a-change-the-full-sequence)
step 2 (`./scripts/services.sh restart-server` or `restart`), which brings up
the server (`:3000`) and web client (`:8080`). Then:

```bash
cd e2e
npm install            # first time only
npx playwright install chromium   # first time only — downloads the browser
npm test               # runs the suite against http://localhost:8080
npm run test:headed    # watch it in a real browser window
npm run report         # open the last HTML report
```

Point it elsewhere (e.g. preview) with `PLAYWRIGHT_BASE_URL=http://localhost:8081 npm test`.

## Test data & cleanup

Every player a test creates is named **`T-e2e-<run>-<base>`** (#252), so what
made an account is readable from the account rather than guessed.

| part | |
| --- | --- |
| `T-` | a test account. Underscore-led, so that if display names come to exclude the underscore a player cannot take a name of this shape at all |
| `e2e` | the suite. `check-rate-limits.sh` has its own |
| `<run>` | one value for the whole run, from `global-setup.ts`. A base36 timestamp and four random characters — **timestamp first, so sorting names sorts the runs** |
| `<base>` | the account within the run, as the test named it |

**Three prefixes fall out of it**, and `clean-test-accounts.sh --prefix` takes
any of them: `T-` is every test account anywhere, `T-e2e-` is this suite's, and
`T-e2e-<run>-` is one run's.

**The teardown deletes only its own run.** Two runs against one environment used
to share `e2e-`, so whichever finished first deleted the other's accounts
mid-run — failures that read as flaky tests. Run by hand,
[`scripts/e2e-clean.sh`](../scripts/e2e-clean.sh) defaults to the suite's
prefix, because wanting all of them is the normal case there.

**The run id comes from `globalSetup`, not from a constant.** `fullyParallel`
means several worker *processes*, and a module-level value would be computed
once in each — every worker believing it was a separate run, with the failure
looking exactly like the convention working.

**A cleanup can still be refused**, and that is #295 rather than this: the admin
CLI will not delete an account that is signed in, which a test that ends
logged-in always is.

## Layout

- `playwright.config.ts` — Chromium, `baseURL` from `PLAYWRIGHT_BASE_URL`, no `webServer` (the app is external).
- `global-setup.ts` — computes this run's id before any worker starts.
- `global-teardown.ts` — best-effort call to `scripts/e2e-clean.sh`, for this run's accounts only.
- `tests/helpers.ts` — auth flows (register/login/logout) and the `T-e2e-<run>-` naming.
- `tests/smoke.spec.ts` — the first suite: register, login/logout, stay-logged-in, and Play-Greedy-Bot-renders-a-board (the flow whose skew bug prompted this suite).
