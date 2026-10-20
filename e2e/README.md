# End-to-end UI tests (Playwright)

Browser tests that drive the real (wasm) web client against a running backend,
so they catch client and server **contract** breaks that the Rust tests cannot
see: those never render the client or cross the wire. It lives in this
directory, outside the cargo workspace.

## Running

The suite does not start the app: it runs against an environment that is
already up. For a local run, start the server (`:3000`) and the web client
(`:8080`) first
([4.3.2](../docs/4.3.2-development.md#quick-start-scripts)). CI runs it against
the preview stack ([4.3.3](../docs/4.3.3-testing-ci-and-release.md#23-continuous-integration)).

```bash
cd e2e
npm install                       # first time only
npx playwright install chromium   # first time only: downloads the browser
npm test                          # the suite against http://localhost:8080
PLAYWRIGHT_BASE_URL=http://localhost:8081 npm test   # against preview
npm run test:headed               # watch it in a browser window
npm run report                    # open the last HTML report
```

| Variable | Effect |
| --- | --- |
| `PLAYWRIGHT_BASE_URL` | the environment to test, default `http://localhost:8080`; preview is `http://localhost:8081` |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE` | a browser binary to use in place of Playwright's own; set in a cloud session by `.claude/cloud-setup.sh` |
| `REHEARSAL_ACCESS_KEY` | rehearsal's access key; when the URL names rehearsal and this is unset, `playwright.config.ts` runs `scripts/deliver/rehearsal-key.sh` |
| `EXPECT_DEPLOY` | set to run `bundle.spec.ts`, which polls for up to 20 minutes for a deploy to land underneath it, so it is for Rehearsal; it skips otherwise |

- **Projects:** every spec runs twice, as `chromium` (Desktop Chrome) and
  `mobile` (Pixel 5), because layout regressions show only at phone width.
- **In CI:** one worker and two retries. A local run has no retries and
  Playwright's default worker count.

## Test data and cleanup

Every player a test creates is named **`T-e2e-<run>-<base>-<rand>`**, so what
made an account can be read from the account.

| Part | Meaning |
| --- | --- |
| `T-` | a test account, by convention: a player can take a name of this shape, so a prefix delete can match accounts nobody's test made |
| `e2e` | the suite |
| `<run>` | one value for the whole run, from `global-setup.ts`: a base36 timestamp and four random characters, **timestamp first, so sorting names sorts the runs** |
| `<base>` | the account within the run, as the test named it |
| `<rand>` | five random characters; both projects run the same specs, and `display_name` is unique |

**Three prefixes fall out of it**, and `clean-test-accounts.sh --prefix` takes
any of them:

| Prefix | Matches |
| --- | --- |
| `T-` | every test account anywhere |
| `T-e2e-` | this suite's accounts, from every run |
| `T-e2e-<run>-` | one run's accounts |

- **The teardown deletes only its own run.** `global-teardown.ts` runs
  `scripts/develop/e2e-clean.sh` with the run's prefix and the target
  environment; two runs against one environment cannot delete each other's
  accounts.
- **A run by hand** of [`e2e-clean.sh`](../scripts/develop/e2e-clean.sh) defaults
  to `T-e2e-`, the whole suite's, and deletes every account that matches it,
  whoever made it. For a local target the match is case-insensitive (SQL `LIKE`).
- **The run id comes from `globalSetup`, not a module-level constant**, because
  `fullyParallel` starts several worker processes. A run id already in
  `E2E_RUN_ID` is kept.
- **Where the cleanup acts:** for a local target `e2e-clean.sh` edits the
  database file directly, and prints `skipping` and exits 0 when `sqlite3` is not
  installed. For any other target it calls
  [`clean-test-accounts.sh`](../scripts/deliver/clean-test-accounts.sh), which
  refuses production and a target it cannot identify. It deletes each game whose
  human seats all match the prefix, then signs each account out and deletes it,
  and reports an account that still holds a game it cannot remove.
- **A failed cleanup warns and does not fail the suite**, so a green run can
  leave accounts behind; read the `CLEANUP FAILED` line.

## Layout

| File | Holds |
| --- | --- |
| `playwright.config.ts` | Chromium, `baseURL`, the two projects, no `webServer`, the rehearsal access cookie |
| `global-setup.ts` | this run's id, computed before any worker starts |
| `global-teardown.ts` | best-effort call to `scripts/develop/e2e-clean.sh` for this run's accounts |
| `naming.ts` | the one definition of a test account's name |
| `tests/helpers.ts` | auth flows (register, log in, log out), `startTwoPlayerGame` and the naming helpers |
| `tests/smoke.spec.ts` | registering, logging in and out, staying logged in, a bot game's board, unread chat, the invite-by-name dropdown, cache headers and layout at phone widths |
| `tests/ui-state.spec.ts` | the panes follow the selected game, including after Remove and log out |
| `tests/live.spec.ts` | an accepted invitation is pushed to the inviter |
| `tests/bundle.spec.ts` | an idle tab notices a new bundle after a deploy |
| `tests/naming.spec.ts` | the account-name format, with no browser or server |
