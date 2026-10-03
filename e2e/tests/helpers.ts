import { Browser, Page, expect } from '@playwright/test';
import { SUITE_PREFIX, accountName, runPrefixFor } from '../naming';

// Every player these tests create is named `T-e2e-<run>-<base>-<rand>` (#252 R1), so
// what created an account is readable from the account rather than guessed.
//
// | part | |
// | --- | --- |
// | `T-` | a test account, by convention only |
// | `e2e` | the suite. `check-rate-limits.sh` has its own |
// | `<run>` | one value for the whole run, from `global-setup.ts` |
// | `<base>` | the account within the run, as the test named it |
// | `<rand>` | distinguishes accounts sharing a base — see `naming.ts` |
//
// **Hyphens, not underscores, and the reason is the design's own constraint.**
// The suite registers through the same public API a player uses, so any rule on
// display names applies to it too — *"the API cannot special-case the suite"*.
// An earlier version used `T_e2e_…` on the grounds that excluding the
// underscore from display names (#332) would make the shape unavailable to a
// player. It would also have made it unavailable to **this suite**, and the
// server would have refused every account it tried to create.
//
// So the marker is a convention rather than a guarantee. A player could take a
// name of this shape; nothing here depends on them not doing so, because
// cleanup deletes what a *run* created rather than what merely looks like it.
//
// **Three prefixes fall out of it**, and `clean-test-accounts.sh --prefix`
// already takes any of them: `T-` is every test account anywhere, `T-e2e-` is
// this suite's, and `T-e2e-<run>-` is one run's. That is what lets two runs
// share an environment without deleting each other's accounts — the defect this
// replaces, where both matched `e2e-` and whichever finished first won.
//
// The run comes from the environment because it must be **one value across
// several worker processes**; see `global-setup.ts` for why a constant here
// would not be.
export const TEST_PASSWORD = 'e2e-playwright-password';

/** This run's id. Absent only if the suite is driven without its globalSetup. */
export function runId(): string {
  const id = process.env.E2E_RUN_ID;
  if (!id) {
    throw new Error(
      'E2E_RUN_ID is not set — global-setup.ts did not run. Every account this ' +
        'suite creates is named for its run, and inventing one per worker would ' +
        'silently split a single run into several.',
    );
  }
  return id;
}

/** The prefix identifying this run's accounts, which is what cleanup deletes. */
export function runPrefix(): string {
  return runPrefixFor(runId());
}

export function uniqueName(base: string): string {
  return accountName(runId(), base);
}

// Kept because tests still refer to "the test prefix"; it is the suite's now
// rather than one string shared by every run.
export const TEST_PREFIX = SUITE_PREFIX;

// The signed-out app shows a blocking auth modal with "Log in" / "Register"
// tabs. These helpers drive it via visible text / placeholders rather than
// brittle structural selectors.
export function authTab(page: Page, name: 'Log in' | 'Register') {
  return page.locator('.auth-panel-tabs button', { hasText: name });
}
function authSubmit(page: Page, name: 'Log in' | 'Register') {
  return page.locator('form.auth-form').getByRole('button', { name, exact: true });
}

export async function register(
  page: Page,
  name: string,
  opts: { password?: string; stayLoggedIn?: boolean } = {},
) {
  const password = opts.password ?? TEST_PASSWORD;
  await page.goto('/');
  await authTab(page, 'Register').click();
  await page.getByPlaceholder('User ID').fill(name);
  // Register requires an email (client-side validation rejects a blank one).
  await page.getByPlaceholder('Email').fill(`${name}@e2e.test`);
  await page.getByPlaceholder('Password', { exact: true }).fill(password);
  if (opts.stayLoggedIn) {
    await page.getByText('Stay logged in').click();
  }
  await authSubmit(page, 'Register').click();
  await expectSignedIn(page);
}

export async function logIn(page: Page, name: string, password = TEST_PASSWORD) {
  await authTab(page, 'Log in').click();
  await page.getByPlaceholder('User ID').fill(name);
  await page.getByPlaceholder('Password', { exact: true }).fill(password);
  await authSubmit(page, 'Log in').click();
  await expectSignedIn(page);
}

export async function logOut(page: Page) {
  await page.getByRole('button', { name: 'Log out' }).click();
  // The blocking auth modal returns once signed out.
  await expect(page.locator('.auth-panel')).toBeVisible();
}

// "Signed in" is unambiguous: the auth modal is gone and the Log out control
// is present.
export async function expectSignedIn(page: Page) {
  await expect(page.getByRole('button', { name: 'Log out' })).toBeVisible();
  await expect(page.locator('.auth-panel')).toHaveCount(0);
}

// The blocking auth modal is what a signed-out visitor gets.
export async function expectSignedOut(page: Page) {
  await expect(page.locator('.auth-panel')).toBeVisible();
}

/// Click a control that only appears once this player's games list has caught
/// up with the other player, refreshing on each attempt rather than waiting out
/// a single timeout.
async function refreshUntilClickable(page: Page, name: 'Accept' | 'Start') {
  await expect(async () => {
    await page.getByRole('button', { name: 'Refresh' }).click();
    await expect(page.getByRole('button', { name, exact: true })).toBeVisible({ timeout: 2_000 });
  }).toPass({ timeout: 30_000 });
  await page.getByRole('button', { name, exact: true }).click();
}

/// Two signed-in players in one started game, in separate browser contexts.
///
/// Needed because unread only counts messages you *received* — the #86 rework
/// stopped marking your own (`games.rs` filters the caller out of
/// `last_message_received_at`). A single player in a bot game cannot receive
/// anything, and Greedy Bot does not chat, so there is no cheaper rig than two
/// real accounts.
export async function startTwoPlayerGame(browser: Browser) {
  const hostContext = await browser.newContext();
  const guestContext = await browser.newContext();
  const host = await hostContext.newPage();
  const guest = await guestContext.newPage();

  const guestName = uniqueName('guest');
  await register(guest, guestName);
  await register(host, uniqueName('host'));

  await host.getByRole('button', { name: 'Play Friend' }).click();
  const field = host.locator('.name-autocomplete input').first();
  await field.click();
  // The whole name, and the suggestion matched by exact text rather than
  // `.first()`. Every generated guest shares the prefix `e2e-guest-`, so a
  // truncated query plus "take the first" invites whichever old account the
  // dropdown happened to list first — invisible on dev, where e2e-clean wipes
  // test users between runs, and reliably wrong on preview, where they
  // accumulate (#128). The symptom is an invitation the guest never receives.
  await field.type(guestName, { delay: 20 });
  const suggestion = host.locator('.name-autocomplete-item', { hasText: guestName });
  await expect(suggestion).toBeVisible();
  await suggestion.click();
  await host.getByRole('button', { name: 'Invite', exact: true }).click();

  // Each step waits on the *other* player's list catching up, which happens on
  // a ten-second poll. A plain click hopes the poll lands inside its own
  // timeout — true when the suite runs this test alone, false under parallel
  // workers, which is exactly how this failed in CI and not locally. Refreshing
  // on every attempt makes the handshake driven rather than hoped for.
  await refreshUntilClickable(guest, 'Accept');
  await refreshUntilClickable(host, 'Start');
  await expect(host.locator('.rack-panel')).toBeVisible();

  // The guest has to have the game open to reach its chat composer.
  await expect(async () => {
    await guest.getByRole('button', { name: 'Refresh' }).click();
    await expect(guest.locator('.game-row').first()).toBeVisible({ timeout: 2_000 });
  }).toPass({ timeout: 30_000 });
  await guest.locator('.game-row').first().click();

  return { host, guest, hostContext, guestContext };
}
