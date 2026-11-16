# End-to-end UI tests (Playwright)

Browser tests that drive the real (Wasm) web client against a running backend,
so they catch client and server contract breaks, which the Rust tests miss. The
suite is a Node project outside the cargo workspace.

## Layout

What each file holds:

| File | Holds |
| --- | --- |
| [`playwright.config.ts`](playwright.config.ts) | Chromium, `baseURL`, the two projects ([*Running*](#running)), the rehearsal access cookie |
| [`global-setup.ts`](global-setup.ts) | the run ID ([*Test data and cleanup*](#test-data-and-cleanup)) |
| [`global-teardown.ts`](global-teardown.ts) | best-effort call to [`scripts/develop/e2e-clean.sh`](../scripts/develop/e2e-clean.sh) for this run's accounts |
| [`naming.ts`](naming.ts) | the one definition of a test account's name |
| [`tests/helpers.ts`](tests/helpers.ts) | auth flows (register, log in, log out), `startTwoPlayerGame` and the naming helpers |
| [`tests/smoke.spec.ts`](tests/smoke.spec.ts) | registering, logging in and out, staying logged in, a bot game's board, unread chat, the invite-by-name dropdown, cache headers and layout at phone widths |
| [`tests/ui-state.spec.ts`](tests/ui-state.spec.ts) | the panes follow the selected game, including after **Remove** and **Log out** |
| [`tests/live.spec.ts`](tests/live.spec.ts) | an accepted invitation is pushed to the inviter |
| [`tests/bundle.spec.ts`](tests/bundle.spec.ts) | an idle tab notices a new bundle after a deploy |
| [`tests/naming.spec.ts`](tests/naming.spec.ts) | the account-name format, with no browser or server |

## Running

The suite runs against an environment that is already up. For a local run,
start the server (`:3000`) and the web client (`:8080`) first
([4.3.2](../docs/4.3.2-development.md#quick-start-scripts)). CI runs it against
the preview stack
([4.3.7](../docs/4.3.7-how-testing-and-release-work.md#3-continuous-integration)).

```bash
cd e2e
npm install                       # first time only, not in a cloud session
npx playwright install chromium   # as above; downloads the browser
npm test                          # the suite against http://localhost:8080
PLAYWRIGHT_BASE_URL=http://localhost:8081 npm test   # against preview
npm run test:headed               # watch it in a browser window
npm run report                    # open the last HTML report
```

The variables it reads:

| Variable | Effect |
| --- | --- |
| `PLAYWRIGHT_BASE_URL` | the environment to test, default `http://localhost:8080` |
| `PLAYWRIGHT_CHROMIUM_EXECUTABLE` | a browser binary to use in place of Playwright's own; set in a cloud session by `.claude/cloud-setup.sh` |
| `REHEARSAL_ACCESS_KEY` | rehearsal's access key; when the URL names rehearsal and this is unset, `playwright.config.ts` runs `scripts/deliver/rehearsal-key.sh` |
| `EXPECT_DEPLOY` | set to `1` to run `bundle.spec.ts`, which skips without it |

Every run:

- **Projects**: every spec runs in two, `chromium` (Desktop Chrome) and
  `mobile` (Pixel 5), because layout regressions show only at phone width.
  - A test that builds its own browser contexts runs in `chromium` only.
  - The rack-width tests, which set their own viewport, run in `mobile` only.
- **Workers and retries**: one worker and two retries in CI; Playwright's
  default worker count and no retries locally.

To run `bundle.spec.ts`:

1. Start the run against rehearsal, whose URL is `REHEARSAL_URL`'s default in
   [4.4.1](../docs/4.4.1-configuration.md#environment-variables):

   ```bash
   EXPECT_DEPLOY=1 PLAYWRIGHT_BASE_URL=<rehearsal URL> npx playwright test tests/bundle.spec.ts
   ```

2. In a second shell, deploy to rehearsal
   ([4.3.3 §1.5.1](../docs/4.3.3-testing-ci-and-release.md#151-test-deployment-on-rehearsal));
   the spec polls for up to 20 minutes for the deploy to land.

## Test data and cleanup

Every account a test creates is named `T-e2e-<run>-<base>-<rand>`, so an
account's name says which run made it and what the test called it. Its parts:

| Part | Meaning |
| --- | --- |
| `T-` | a test account, by convention: a player can take a name of this shape, so a prefix delete can match accounts no test made |
| `e2e` | the suite |
| `<run>` | the *run ID*, one value for the whole run: a base36 timestamp and four random characters, timestamp first, so sorting names sorts the runs |
| `<base>` | the account within the run, as the test named it |
| `<rand>` | five random characters, because both projects run the same specs and `display_name` is unique |

**The name gives three prefixes**, and
[`clean-test-accounts.sh`](../scripts/deliver/clean-test-accounts.sh)
`--prefix` takes any of them:

| Prefix | Matches |
| --- | --- |
| `T-` | every account named `T-…` in the target, a player's included |
| `T-e2e-` | this suite's accounts, from every run |
| `T-e2e-<run>-` | one run's accounts |

- **The teardown deletes only its own run**, so a parallel run's accounts are
  safe. `global-teardown.ts` runs
  [`scripts/develop/e2e-clean.sh`](../scripts/develop/e2e-clean.sh) with the
  run's prefix and the target environment.
- **A run by hand** of `e2e-clean.sh` (or `npm run clean`):
  - by default deletes every account matching `T-e2e-`, the whole suite's,
    whoever made it;
  - takes a narrower prefix from `E2E_PREFIX`, for example `T-e2e-<run>-`;
  - cleans `E2E_TARGET`, else `PLAYWRIGHT_BASE_URL`, else local
    (the dev server).
- **One run ID serves every worker**, because `global-setup.ts` runs once
  before any starts, and it keeps a run ID already in `E2E_RUN_ID`.
- **Where the cleanup acts** depends on the target:

  | Target | Cleaned by | What it does |
  | --- | --- | --- |
  | local: the dev server, `:8080` or `:3000` | `e2e-clean.sh`, editing the database file directly | deletes every matching account (SQL `LIKE`, so case-insensitive) and every game a matching account took part in, even one with a real player in it; prints `skipping` and exits 0 when `sqlite3` is missing |
  | any other | `clean-test-accounts.sh` | refuses production and a target it cannot identify; otherwise deletes each game whose human seats all match the prefix, signs each account out and deletes it, and reports an account that still holds a game it cannot remove |

- **A failed cleanup warns and does not fail the suite**, so a green run can
  leave accounts behind; read the `CLEANUP FAILED` line.
