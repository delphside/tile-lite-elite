import { test, expect } from '@playwright/test';
import { accountName, runPrefixFor, SUITE_PREFIX } from '../naming';

// Pure assertions about how a test account is named (#252 R1). No browser and
// no server: these are properties of a string, and they are here rather than
// left to the suite because the suite discovered the defect *by failing
// nineteen tests in CI* with an error that pointed at a missing "Log out"
// button. A name that collides fails registration, and a failed registration
// looks like a broken page.

test.describe('test account naming', () => {
  test('two accounts sharing a base do not share a name', () => {
    // Both Playwright projects run the same specs, so this call happens twice
    // within one run — once under chromium and once under mobile. Without a
    // discriminator the two names are identical, `players.display_name` is
    // unique, and the second registration is refused.
    const a = accountName('run1', 'reg');
    const b = accountName('run1', 'reg');
    expect(a).not.toBe(b);
  });

  test('but they do share the run prefix, which is what cleanup deletes', () => {
    const prefix = runPrefixFor('run1');
    expect(accountName('run1', 'reg').startsWith(prefix)).toBe(true);
    expect(accountName('run1', 'host').startsWith(prefix)).toBe(true);
  });

  test('a different run does not match this run prefix', () => {
    // The defect this replaces: two runs sharing one prefix, so whichever
    // finished first deleted the other's accounts mid-run.
    expect(accountName('run2', 'reg').startsWith(runPrefixFor('run1'))).toBe(false);
  });

  test('every run matches the suite prefix, for cleaning up by hand', () => {
    expect(accountName('run1', 'reg').startsWith(SUITE_PREFIX)).toBe(true);
    expect(accountName('run2', 'reg').startsWith(SUITE_PREFIX)).toBe(true);
  });

  test('no underscores, because the suite is bound by display-name rules too', () => {
    // The suite registers through the same public API a player uses, so a rule
    // excluding the underscore would exclude it here as well (#332).
    expect(accountName('run1', 'reg')).not.toContain('_');
  });

  test('the run sorts by when it ran, since the timestamp leads', () => {
    // Real millisecond values, not small integers. Base36 sorts lexically only
    // while the strings are the same length, and `Date.now().toString(36)` is
    // eight characters until **2059-05-25**. The first version of this test
    // used 1000 and 2000 — "rs" and "1jk" — and failed for that reason rather
    // than for anything wrong with the code.
    const now = Date.now();
    const earlier = runPrefixFor(now.toString(36));
    const later = runPrefixFor((now + 60_000).toString(36));
    expect([later, earlier].sort()).toEqual([earlier, later]);
  });
});
