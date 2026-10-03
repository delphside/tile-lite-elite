import { test, expect } from '@playwright/test';
import { register, uniqueName } from './helpers';

/// Accepting an invitation must be *pushed* to the inviter (#149).
///
/// **The four-second window is the test.** The games list polls every ten
/// seconds, so a generous timeout is satisfied by the poll whether the push
/// works or not — an earlier draft used twenty-five and proved nothing. This
/// window is short enough that only a push can meet it.
///
/// Written after the owner reported acceptances not reaching the inviter until
/// he refreshed. It passes, which is itself the finding: the mechanism works on
/// a sound connection, and the reports track an unreliable wifi rather than the
/// code. Kept because it is the guard that was missing — nothing else in the
/// suite would notice if this stopped being pushed, and `startTwoPlayerGame`
/// deliberately refreshes its way past this step so it cannot.
test('an accepted invitation is pushed to the inviter', async ({ browser }, testInfo) => {
  test.skip(testInfo.project.name !== 'chromium', 'builds its own contexts');
  test.slow();

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
  await field.type(guestName, { delay: 20 });
  const suggestion = host.locator('.name-autocomplete-item', { hasText: guestName });
  await expect(suggestion).toBeVisible();
  await suggestion.click();
  await host.getByRole('button', { name: 'Invite', exact: true }).click();

  // Reaching the guest is a separate question; refreshing here keeps this test
  // about the reply.
  await expect(async () => {
    await guest.getByRole('button', { name: 'Refresh' }).click();
    await expect(guest.getByRole('button', { name: 'Accept', exact: true })).toBeVisible({
      timeout: 2_000,
    });
  }).toPass({ timeout: 30_000 });
  await guest.getByRole('button', { name: 'Accept', exact: true }).click();

  await expect(
    host.getByRole('button', { name: 'Start', exact: true }),
    'the inviter must be pushed the acceptance, not left for the ten-second poll',
  ).toBeVisible({ timeout: 4_000 });

  await hostContext.close();
  await guestContext.close();
});
