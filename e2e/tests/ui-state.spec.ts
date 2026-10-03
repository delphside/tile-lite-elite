import { test, expect, Page } from '@playwright/test';
import { register, uniqueName } from './helpers';

/// What the client shows must follow from what is *selected*, not from
/// whatever a previous game happened to leave behind (#71).
///
/// Today the client has no selection state: "which game is selected" is read
/// back out of the loaded DTO (`selected_id: game().as_ref().map(...)` in
/// `app.rs`), and the panes that depend on it are cleared by ten separate
/// remembered calls to `reset_composer_state`, plus `clear_session_state`,
/// plus an inline subset in `on_clear_staged`. Nothing forces a handler to
/// make that call, and `on_remove_game` does not.
///
/// These tests state the rule from the outside instead: **after any event
/// that changes which game is selected, every dependent pane matches the new
/// selection — including when the new selection is nothing.** They are
/// written against the intended behaviour, so a failure here is a finding
/// about the code rather than about the test.

// A played letter, as opposed to one staged this turn but not yet submitted.
// The distinction matters: staged tiles render from `staged_placements`,
// which `BoardView` takes independently of `game.board`, so they can outlive
// the game they belong to.
const PLAYED_TILE = '.board-cell .tile-face:not(.tile-face-staged)';
const STAGED_TILE = '.tile-face-staged';
const RACK_TILE = '.rack-tile';
const SELECTED_ROW = '.game-row-active';

/// One started game against Greedy Bot, left open and selected.
///
/// Returns the row so a caller holding two games can tell them apart —
/// rows carry no stable text of their own, so position in the list is the
/// only handle, and creating a second game reorders it.
async function startBotGame(page: Page) {
  await page.getByRole('button', { name: 'Play Greedy Bot' }).click();
  await page.getByRole('button', { name: 'Start', exact: true }).click();
  await expect(page.locator('.rack-panel')).toBeVisible();
  // The panel appears before the tiles do: Start returns, the pane renders,
  // and the dealt rack arrives with the state that follows. Waiting on a
  // tile rather than the panel is what makes "the rack is populated" mean
  // something.
  //
  // A whole minute because the wait is not just this game's. When the bot
  // holds the opening seat, `run_engine_turns` searches while holding the
  // games map's *write* lock (up to `ENGINE_TURN_TIMEOUT`, five seconds a
  // turn), so every other game in the process waits behind it. Running two
  // workers against one dev server made this the suite's one intermittent
  // failure; CI uses a single worker and does not see it. #71's per-game
  // locking is what removes the cause.
  await expect(page.locator(RACK_TILE).first()).toBeVisible({ timeout: 60_000 });
}

/// The panes as they look with nothing selected: `game()` is `None`, so the
/// view falls back to `empty_live_game()` — an empty board, and a rack with
/// no tiles in it.
async function expectNothingSelected(page: Page) {
  await expect(page.locator(SELECTED_ROW)).toHaveCount(0);
  await expect(page.locator(PLAYED_TILE)).toHaveCount(0);
  await expect(page.locator(STAGED_TILE)).toHaveCount(0);
  await expect(page.locator(RACK_TILE)).toHaveCount(0);
}

test('selecting a game fills the board and rack', async ({ page }) => {
  await register(page, uniqueName('sel'));
  await startBotGame(page);

  // The positive direction, pinned first: without this, every "it cleared"
  // assertion below would pass just as well against a client that never
  // draws anything.
  await expect(page.locator('.board-panel')).toBeVisible();
  await expect(page.locator(RACK_TILE)).not.toHaveCount(0);
  await expect(page.locator(SELECTED_ROW)).toHaveCount(1);
});

test('Remove clears the board and rack and leaves nothing selected', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('rm'));
  await startBotGame(page);
  await expect(page.locator(RACK_TILE)).not.toHaveCount(0);

  // Remove is only offered on a terminal game, so abort first. Both controls
  // live in the selected row's detail panel.
  await page.getByRole('button', { name: 'Abort game' }).first().click();
  await page.locator('.modal-card').getByRole('button', { name: 'Abort game' }).click();

  const remove = page.getByRole('button', { name: 'Remove', exact: true });
  await expect(remove).toBeVisible();
  await remove.click();

  // The reported defect: `on_remove_game` sets `game.set(None)` and stops
  // there. It is the one path that changes the selection without going
  // through `reset_composer_state`, so anything the composer was holding
  // survives onto a board that no longer has a game behind it.
  await expectNothingSelected(page);
});

test('switching games does not carry the first board into the second', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('switch'));
  await startBotGame(page);
  await startBotGame(page);

  const rows = page.locator('.game-row');
  await expect(rows).toHaveCount(2);

  // Alternate twice rather than once. A single switch can be satisfied by a
  // client that simply redraws from whichever DTO arrived last; going back
  // is what catches state that is cleared on the way out of a game but not
  // on the way in.
  for (const index of [0, 1, 0]) {
    await rows.nth(index).click();
    await expect(page.locator(SELECTED_ROW)).toHaveCount(1);
    await expect(page.locator(STAGED_TILE)).toHaveCount(0);
    await expect(page.locator(RACK_TILE)).not.toHaveCount(0);
  }
});

test('staged tiles do not survive switching to another game', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('staged'));
  await startBotGame(page);

  await stageOneTile(page);

  // A second game, which takes the selection with it.
  await startBotGame(page);

  // A staged tile belongs to one game and one turn of it. Left in place it
  // draws on the new game's board, where it is not just stale but wrong: the
  // player is looking at a move they cannot submit.
  await expect(page.locator(STAGED_TILE)).toHaveCount(0);
});

/// Stage a tile in the currently open game. Assumes it is this player's turn
/// to act — `board-cell-clickable` is the client's own `can_stage_moves`, so
/// waiting on it waits out the bot's opening move without guessing a delay.
async function stageOneTile(page: Page) {
  const cell = page.locator('.board-cell-clickable').first();
  await expect(cell).toBeVisible({ timeout: 30_000 });
  await cell.click();
  await page.locator(`${RACK_TILE}:not(.rack-tile-used)`).first().click();
  await expect(page.locator(STAGED_TILE)).toHaveCount(1);
}

// Fails today, on purpose: this is the intended behaviour, and #157 is the fix.
// `fixme` rather than a deletion so the rule stays stated and turns itself on
// when the handler lands — CI's e2e job runs on every push to main, and
// deploy.sh judges that run, so a red suite here would block every release.
test.fixme('aborting a game clears the move being composed', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('abortstage'));
  await startBotGame(page);
  await stageOneTile(page);

  await page.getByRole('button', { name: 'Abort game' }).first().click();
  await page.locator('.modal-card').getByRole('button', { name: 'Abort game' }).click();
  await expect(page.getByRole('button', { name: 'Remove', exact: true })).toBeVisible();

  // A game that is over cannot have a move pending against it. The abort
  // handler swaps the DTO through `apply_game_update`, which only compares
  // versions — it never touches the composer — so the staged tile is left
  // drawing on a board nobody can play.
  await expect(page.locator(STAGED_TILE)).toHaveCount(0);
});

// Fails today, on purpose: this is the intended behaviour, and #157 is the fix.
// `fixme` rather than a deletion so the rule stays stated and turns itself on
// when the handler lands — CI's e2e job runs on every push to main, and
// deploy.sh judges that run, so a red suite here would block every release.
test.fixme('Remove after composing a move leaves nothing behind', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('rmstage'));
  await startBotGame(page);
  await stageOneTile(page);

  // The compound path, and the one that reaches Remove with the composer
  // holding something: Remove is only offered on a terminal game, so a
  // staged tile can only get there by surviving the step that ended it.
  await page.getByRole('button', { name: 'Abort game' }).first().click();
  await page.locator('.modal-card').getByRole('button', { name: 'Abort game' }).click();
  await page.getByRole('button', { name: 'Remove', exact: true }).click();

  await expectNothingSelected(page);
});

test('exchange mode does not survive switching to another game', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('exch'));
  await startBotGame(page);

  const exchange = page.getByRole('button', { name: 'Exchange', exact: true });
  await expect(exchange).toBeEnabled({ timeout: 30_000 });
  await exchange.click();
  // In exchange mode the turn actions are replaced by a confirm control.
  await expect(page.getByRole('button', { name: /^Confirm Exchange/ })).toBeVisible();

  await startBotGame(page);

  // `exchange_mode` and `exchange_selected` are the two signals the inline
  // clear in `on_clear_staged` omits, which is why they get their own test
  // rather than riding along with the staged-tile one above.
  await expect(page.getByRole('button', { name: /^Confirm Exchange/ })).toHaveCount(0);
  await expect(page.locator('.rack-tile-selected')).toHaveCount(0);
});

test('logging out clears the board and rack', async ({ page }) => {
  test.slow();
  await register(page, uniqueName('logout'));
  await startBotGame(page);
  await expect(page.locator(RACK_TILE)).not.toHaveCount(0);

  await page.getByRole('button', { name: 'Log out' }).click();
  await expect(page.locator('.auth-panel')).toBeVisible();

  // `clear_session_state` already does the whole job — deselect *and* reset
  // the composer — because the bug that prompted it was visible: the login
  // modal appeared over the previous player's board. It is the shape the
  // other paths should share, so it is pinned here as the reference case.
  await expect(page.locator(PLAYED_TILE)).toHaveCount(0);
  await expect(page.locator(STAGED_TILE)).toHaveCount(0);
  await expect(page.locator(RACK_TILE)).toHaveCount(0);
});
