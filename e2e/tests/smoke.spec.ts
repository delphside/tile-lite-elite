import { test, expect } from '@playwright/test';
import {
  register,
  logIn,
  logOut,
  expectSignedIn,
  expectSignedOut,
  uniqueName,
  authTab,
  TEST_PASSWORD,
  startTwoPlayerGame,
} from './helpers';

// A signed-out user is shown a blocking auth modal; everything else needs a
// signed-in player. Each test registers its own e2e-* player so tests stay
// independent (cleanup happens in global teardown / scripts/e2e-clean.sh).

test('registers a new player and lands signed in', async ({ page }) => {
  await register(page, uniqueName('reg'));
  await expectSignedIn(page);
});

test('unread chat survives being off screen, and clears once watched', async ({ browser }, testInfo) => {
  // One project only. This test builds its own contexts, and
  // `browser.newContext()` does not inherit project options — so the mobile
  // project would run a byte-identical desktop copy, buying no coverage and
  // doubling the chance of a flake. The off-screen case it cares about is
  // simulated by resizing within the test regardless.
  test.skip(
    testInfo.project.name !== 'chromium',
    'creates its own contexts, so another project would run an identical copy',
  );

  // #86. The watermark used to advance the instant a message arrived into an
  // open game — "watching the panel counts as reading it" — so a message
  // landing in a background tab, or in a panel scrolled off a phone, was marked
  // read by nobody. The whole issue is that visible is not the same as seen.
  //
  // Two accounts, because the rework also stopped marking *your own* messages
  // unread, which is what a single player in a bot game can only ever produce.
  // The requirement is about *time passing* — a 12-second wait to prove the
  // messages stay unread, plus the ten-second clock afterwards. That lands a
  // few seconds under the 30s default, which is not a margin: it passed alone
  // and failed in the full suite, where parallel workers make everything
  // slower. Tripled rather than trimmed, because the waits are the test.
  test.slow();

  const { host, guest, hostContext, guestContext } = await startTwoPlayerGame(browser);

  await guest.getByPlaceholder('Say something...').fill('does anyone read these');
  await guest.getByRole('button', { name: 'Send', exact: true }).click();

  // Marked unread in both places, from one signal. (There was a third, an
  // envelope above the messages; it was removed during the rework because the
  // game already carries one and its appearing and disappearing made
  // everything below it jump.)
  await expect(host.locator('.chat-message-unread')).toHaveCount(1);
  await expect(host.locator('.rack-scores-unread')).toHaveCount(1);

  // Scroll the chat out of view for longer than the ten seconds. Nothing may
  // clear: the clock only runs while somebody could actually be looking, and on
  // a phone this is the ordinary case — the panel is simply off the bottom.
  //
  // Scrolling rather than backgrounding the tab because Playwright's
  // `bringToFront` does not flip `document.hidden` here (checked), so that test
  // would have passed against a broken implementation. The hidden-tab half is
  // `document.hidden` in `chat_messages_are_visible`, covered by SeenClock's
  // own tests; this covers the wiring.
  await host.setViewportSize({ width: 900, height: 400 });
  await host.evaluate(() => {
    document.querySelector('.board-panel')?.scrollIntoView({ block: 'start' });
    window.scrollTo(0, 0);
  });
  // Read the *pseudo-element*: the rework moved the fade to an `::after`
  // overlay driven by an inline `--chat-fade-state`, so asserting
  // `animation-play-state` on the message itself inspects an element that no
  // longer animates and passes whatever the implementation does.
  await expect
    .poll(
      () =>
        host.evaluate(() => {
          const message = document.querySelector('.chat-message-unread');
          return message ? getComputedStyle(message, '::after').animationPlayState : null;
        }),
      { message: 'the fade must be paused while the messages are off screen', timeout: 5_000 },
    )
    .toBe('paused');

  await host.waitForTimeout(12_000);
  await expect(
    host.locator('.chat-message-unread'),
    'messages nobody can see must not be marked read',
  ).toHaveCount(1);

  // Back in view, and the clock resumes.
  await host.setViewportSize({ width: 1280, height: 900 });
  await host.evaluate(() => document.querySelector('.chat-messages')?.scrollIntoView());

  // Now watched, so it clears — and both clear together.
  await expect(host.locator('.chat-message-unread')).toHaveCount(0, { timeout: 20_000 });
  await expect(host.locator('.rack-scores-unread')).toHaveCount(0);

  await hostContext.close();
  await guestContext.close();
});

test('the invite-by-name dropdown is visible, not merely rendered', async ({ page }) => {
  // #76. The suggestion list is absolutely positioned, so it lives outside its
  // cell's box — and the pre-creation builder lays seats out in a table whose
  // cells set `overflow: hidden` to ellipsis long names. The list rendered,
  // sized and positioned correctly, and was clipped to nothing.
  //
  // So this asserts what a person can *see*. Counting nodes, or asking whether
  // the element exists, passes against the clipped version — which is exactly
  // how this was missed three times while the DOM said everything was fine.
  const me = uniqueName('dd');
  await register(page, me);
  await page.getByRole('button', { name: 'Play Friend' }).click();

  const field = page.locator('.name-autocomplete input').first();
  await field.click();
  // Their own name is guaranteed to match, so the suite does not depend on
  // whatever other players happen to exist.
  await field.type(me.slice(0, 6), { delay: 60 });

  const item = page.locator('.name-autocomplete-item').first();
  await expect(item).toBeVisible();

  // Hit-test, not `toBeVisible`. Playwright calls a clipped element visible —
  // it checks visibility styles and a non-empty box, neither of which an
  // ancestor's `overflow: hidden` changes. Asking the browser what is actually
  // painted at the suggestion's own centre is the only assertion here that
  // fails against the clipped version; every cheaper one passed against it.
  const box = await item.boundingBox();
  expect(box).not.toBeNull();
  const hit = await page.evaluate(
    ({ x, y }) => {
      const el = document.elementFromPoint(x, y);
      return el ? !!el.closest('.name-autocomplete-dropdown') : false;
    },
    { x: box!.x + box!.width / 2, y: box!.y + box!.height / 2 },
  );
  expect(hit, 'the suggestion is painted where it claims to be, not clipped away').toBe(true);
});

test('logs out and back in with the same credentials', async ({ page }) => {
  const name = uniqueName('login');
  await register(page, name);
  await logOut(page);
  await logIn(page, name);
  await expectSignedIn(page);
});

// The credentials must not survive the session that used them (#50): the modal
// is emptied when it is hidden, so every later session end finds it empty.
//
// **This guards the behaviour; it does not reproduce the bug.** It passes
// against the unfixed code too, because ending the session this way clears the
// fields for some reason not yet understood — where a session ending by
// *expiry* did not, which is how the bug was found (by hand, forcing
// `expires_at = 0` in the database). Reaching expiry from a browser needs a
// write to the server's database, which couples the test to one environment,
// so it is not attempted here. Worth revisiting: a test that cannot fail is
// worth less than it looks.
test('the auth modal comes back empty when a session ends', async ({ page }) => {
  const name = uniqueName('empty');
  await register(page, name);

  await page.getByRole('button', { name: 'Edit user details' }).click();
  await page.getByPlaceholder('Current password').fill(TEST_PASSWORD);
  await page.getByPlaceholder('New password', { exact: true }).fill(`${TEST_PASSWORD}-2`);
  await page.getByPlaceholder('Confirm new password').fill(`${TEST_PASSWORD}-2`);
  await page.getByRole('button', { name: 'Update password' }).click();

  // A password change invalidates every session for the player, this one
  // included, so the modal returns.
  await expect(page.locator('.auth-panel')).toBeVisible();

  await expect(page.getByPlaceholder('Password', { exact: true })).toHaveValue('');
  // "Remember me" was never ticked, so nothing is asking the name to stay.
  await expect(page.getByPlaceholder('User ID')).toHaveValue('');
  // Email exists only on the Register tab, which the reset also returns from.
  await authTab(page, 'Register').click();
  await expect(page.getByPlaceholder('Email')).toHaveValue('');
});

test('"Stay logged in" survives a reload', async ({ page }) => {
  await register(page, uniqueName('stay'), { stayLoggedIn: true });
  await page.reload();
  // No re-login prompt: the persisted token is re-validated on boot.
  await expectSignedIn(page);
});

// The two storage lifetimes, pinned from both sides. "Stay logged in"
// chooses between localStorage (survives the browser closing) and
// sessionStorage (survives a reload, dies with the tab) — so a test that
// only checked "still signed in after reload" would pass just as well if
// the token were wrongly made permanent. The new-tab cases are what tell
// the two stores apart.
test('a reload keeps you signed in even without "Stay logged in"', async ({ page }) => {
  await register(page, uniqueName('reload'), { stayLoggedIn: false });
  await page.reload();
  // Regression: the token used to live only in memory when the box was
  // unchecked, so any refresh — including the client's own auto-reload on
  // api skew after a deploy — dropped you back to the login screen
  // mid-game.
  await expectSignedIn(page);
});

test('without "Stay logged in", a new tab starts signed out', async ({ context, page }) => {
  await register(page, uniqueName('newtab'), { stayLoggedIn: false });
  await expectSignedIn(page);

  // Same browser context, so localStorage is shared but sessionStorage is
  // not. Signed out here is what proves the token went to the per-tab
  // store rather than the persistent one.
  const other = await context.newPage();
  await other.goto('/');
  await expectSignedOut(other);
  await other.close();
});

test('with "Stay logged in", a new tab is already signed in', async ({ context, page }) => {
  await register(page, uniqueName('newtabstay'), { stayLoggedIn: true });

  const other = await context.newPage();
  await other.goto('/');
  await expectSignedIn(other);
  await other.close();
});

test('Play Greedy Bot starts a game and renders the board', async ({ page }) => {
  await register(page, uniqueName('bot'));

  // "Play Greedy Bot" opens the game draft (creator + engine seat); the draft's
  // submit is "Start" once every seat is filled (no invitations needed).
  await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
  await page.getByRole('button', { name: 'Start', exact: true }).click();

  // The in-game view rendered: board grid + the player's rack with tiles.
  // The rack having tiles is the reliable "this is a real, playable game for
  // me" signal — unlike the turn-indicator text, which is timing-sensitive and
  // ambiguous (the words "Your turn" also appear as a games-list section
  // heading in the sidebar).
  await expect(page.locator('.board-panel')).toBeVisible();
  await expect(page.locator('.rack-panel')).toBeVisible();
  await expect(page.locator('.board-cell').first()).toBeVisible();
  await expect(page.locator('.rack-tile').first()).toBeVisible();
});

/// Caching headers, asserted against the running stack rather than read off the
/// config (#145).
///
/// `index.html` had no `Cache-Control` at all, on the assumption that saying
/// nothing meant "do not cache". It does not: a browser with no directive
/// applies heuristic freshness, and one was found serving a months-old bundle
/// against a current server. Because index.html names the current asset hashes,
/// holding it holds the entire client — and the poller that would have noticed
/// a new build lives inside the very bundle being held.
///
/// Technical rather than visual, so it belongs here where CI runs it on every
/// change, not in a round of looking at Preview.
test('the document revalidates and hashed assets do not', async ({ request, baseURL }) => {
  const index = await request.get(`${baseURL}/`);
  expect(index.ok()).toBe(true);

  // These headers are Caddy's, and dev is `dx serve` with no Caddy in front of
  // it — so against dev there is no configuration here to be right or wrong.
  // Identified positively by the server that sets them rather than by guessing
  // from the port, and CI runs the suite against the preview stack, so this
  // never quietly skips there.
  test.skip(
    !/caddy/i.test(index.headers()['server'] ?? ''),
    'asserts the deployed stack\'s cache headers; dev serves the client directly',
  );
  expect(
    index.headers()['cache-control'],
    'index.html must revalidate: it names the current asset hashes',
  ).toContain('no-cache');

  // The SPA fallback serves index.html for unknown paths, and it must carry
  // the same header — a deep link is how plenty of sessions start.
  const deep = await request.get(`${baseURL}/some/spa/route`);
  expect(deep.headers()['cache-control'], 'the SPA fallback is index.html too').toContain(
    'no-cache',
  );

  // The counterpart: content-hashed names can never change, so revalidating
  // them is pure cost. If this ever stops being immutable, every load pays for
  // conditional GETs it does not need.
  const body = await index.text();
  const asset = body.match(/\/assets\/[^"']+\.js/)?.[0];
  expect(asset, 'an asset URL to check').toBeTruthy();
  const assetResponse = await request.get(`${baseURL}${asset}`);
  expect(assetResponse.headers()['cache-control']).toContain('immutable');

  // The deploy poller reads this; a cached copy reports the old build forever.
  const version = await request.get(`${baseURL}/version.txt`);
  expect(version.headers()['cache-control']).toContain('no-store');
});

/// A full rack is seven tiles, and they must stay on one row (#12).
///
/// At a fixed 52px they need 7 x 52 + 6 x 10 = 424px, and a mobile media query
/// pinned them to 44px, which still needs 368px. So on every phone the row
/// broke after six and the seventh took a whole second row to carry one tile —
/// in the most contested vertical space on the screen.
///
/// Asserting the *number of rows* rather than a width, because the fix is
/// "they fit" and any particular tile size is an implementation detail that
/// should be free to change.
for (const width of [320, 360, 393, 414]) {
  test(`the rack is one row at ${width}px`, async ({ page }, testInfo) => {
    // One project. The width is set explicitly below, so the project's own
    // viewport is irrelevant and running these in both is a duplicate — which
    // also doubles the number of bot games started at once, and the first bot
    // move is slow enough that eight concurrent ones starve each other.
    test.skip(
      testInfo.project.name !== 'mobile',
      'sets its own viewport, so another project would run an identical copy',
    );
    await page.setViewportSize({ width, height: 720 });
    await register(page, uniqueName(`rack${width}`));

    await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
    await page.getByRole('button', { name: 'Start', exact: true }).click();
    await expect(page.locator('.rack-panel')).toBeVisible();
    // The panel renders before its tiles do, so measuring on the panel alone
    // reads an empty rack and fails on the count rather than the layout.
    await expect(page.locator('.rack-tile')).toHaveCount(7, { timeout: 20_000 });

    const { rows, count } = await page.evaluate(() => {
      const tiles = [...document.querySelectorAll('.rack-tile')] as HTMLElement[];
      return {
        // Distinct top offsets: one row means one distinct top.
        rows: new Set(tiles.map((tile) => Math.round(tile.getBoundingClientRect().top))).size,
        count: tiles.length,
      };
    });

    expect(count, 'a full rack to measure').toBe(7);
    expect(rows, 'seven tiles on one row, not six and a stray').toBe(1);
  });
}

/// Layout must survive phones narrower than the one it was designed on.
///
/// The scores row, the offline pill and the rack were all sized against a
/// single handset (~393 CSS px). A narrower screen is where a fixed width or
/// a non-shrinking flex item stops fitting — and the failure is horizontal
/// scrolling, which is far worse on a phone than a wrapped line.
///
/// 320px is the narrowest in common use (iPhone SE and similar). Asserting
/// "the document is no wider than the viewport" catches the whole class
/// rather than the one element that happened to break.
for (const width of [320, 360, 414]) {
  test(`no horizontal overflow at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 720 });
    await register(page, uniqueName(`w${width}`));

    await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
    await page.getByRole('button', { name: 'Start', exact: true }).click();
    await expect(page.locator('.rack-panel')).toBeVisible();

    const { overflow, culprits } = await page.evaluate(() => {
      const viewport = document.documentElement.clientWidth;
      // Name what actually sticks out. A bare number says the page is too
      // wide; this says which element made it so, which is the difference
      // between a diagnosis and a puzzle — particularly on CI, where the
      // failure may not reproduce locally because font fallbacks differ.
      const culprits = Array.from(document.querySelectorAll('*'))
        .filter((el) => el.getBoundingClientRect().right > viewport + 1)
        .slice(0, 6)
        .map((el) => {
          const right = Math.round(el.getBoundingClientRect().right);
          const cls = typeof el.className === 'string' && el.className ? `.${el.className.trim().split(/\s+/).join('.')}` : '';
          return `${el.tagName.toLowerCase()}${cls} right=${right}`;
        });
      return {
        overflow: document.documentElement.scrollWidth - viewport,
        culprits,
      };
    });
    expect(
      overflow,
      `the page scrolls sideways by ${overflow}px at ${width}px wide.\n` +
        `Widest offenders:\n  ${culprits.join('\n  ')}`,
    ).toBeLessThanOrEqual(1);
  });
}
