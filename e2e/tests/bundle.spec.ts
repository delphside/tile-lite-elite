import { test, expect } from '@playwright/test';
import { uniqueName, TEST_PASSWORD } from './helpers';

/// #67's original reproduction: a tab idle across a deploy, which then
/// *interacts* — and must notice without a manual refresh.
///
/// The issue's claim was not that an idle tab goes stale. It was that
/// "nothing it does afterwards makes it notice": a tab left on the landing
/// page still reported the old build "after starting a game and playing a
/// move. Only a manual refresh moved it."
///
/// So this waits for the deploy from outside the page (polling version.txt
/// through a separate request context, which the page never sees), then does
/// the first thing that talks to the server.
test('an idle tab notices a new bundle as soon as it interacts', async ({ page, request, baseURL }) => {
  // Guarded, not merely documented. This waits up to twenty minutes for a
  // deploy to land underneath it, which never happens in CI — where it simply
  // burns the job's time and then fails. A comment saying "not for CI" stops
  // nothing; this does.
  test.skip(
    !process.env.EXPECT_DEPLOY,
    'needs a real deploy mid-test: run with EXPECT_DEPLOY=1 against Rehearsal',
  );
  test.setTimeout(25 * 60_000);

  await page.goto('/');
  const versionLine = page.locator('.topbar-version');
  await expect(versionLine).toBeVisible();
  const before = (await versionLine.innerText()).trim();
  const servedBefore = (await (await request.get(`${baseURL}/version.txt`)).text()).trim();
  console.log('BEFORE page:', before, '| served:', servedBefore);

  // Wait for a deploy to land. Deliberately not through the page: nothing here
  // may touch it, or the test does the noticing instead of the client.
  // The host goes briefly unreachable mid-deploy — containers restarting — so
  // a throwing request must be treated as "not yet", not as a failure. An
  // earlier version let EHOSTUNREACH propagate and aborted the test during the
  // very event it was waiting for.
  const served = async () => {
    try {
      return (await (await request.get(`${baseURL}/version.txt`, { timeout: 5_000 })).text()).trim();
    } catch {
      return servedBefore;
    }
  };
  await expect
    .poll(served, { timeout: 20 * 60_000, intervals: [10_000], message: 'waiting for a deploy' })
    .not.toBe(servedBefore);
  const servedAfter = await served();
  console.log('DEPLOYED:', servedBefore, '->', servedAfter);

  const stillStale = (await versionLine.innerText()).trim();
  console.log('BEFORE-INTERACTION page still shows:', stillStale);

  // The interaction. Registering is the first thing that talks to the server.
  await page.locator('.auth-panel-tabs button', { hasText: 'Register' }).click();
  await page.getByPlaceholder('User ID').fill(uniqueName('b67'));
  await page.getByPlaceholder('Email').fill('b67@e2e.test');
  await page.getByPlaceholder('Password', { exact: true }).fill(TEST_PASSWORD);
  await page.locator('form.auth-form').getByRole('button', { name: 'Register', exact: true }).click();

  await expect
    .poll(async () => (await versionLine.innerText().catch(() => before)).trim(), {
      timeout: 60_000,
      intervals: [2_000],
      message: 'after interacting, the tab must pick up the new bundle without a refresh',
    })
    .not.toBe(before);

  console.log('AFTER-INTERACTION page shows:', (await versionLine.innerText()).trim());
});
