import { defineConfig, devices } from '@playwright/test';
import { execSync } from 'node:child_process';

// The suite runs against an ALREADY-RUNNING dev environment — runbook step 2
// (`services.sh restart-server` / `restart`) starts server (:3000) and web
// (:8080), and step 3 runs these tests against it. Point elsewhere (e.g.
// preview on :8081) with PLAYWRIGHT_BASE_URL. There is deliberately no
// `webServer:` block: this suite does not own the app's lifecycle.
const baseURL = process.env.PLAYWRIGHT_BASE_URL || 'http://localhost:8080';

// Rehearsal is closed by the Caddyfile (#240): everything but `/health` answers
// 403 before the request reaches the application, so a suite pointed at it
// fails every test at the door — and a closed gate and a broken application
// refuse identically. #371.
//
// The key comes from `scripts/rehearsal-key.sh`, which is the one place that
// knows how to get it; set `REHEARSAL_ACCESS_KEY` to skip the ssh.
//
// **A header rather than the cookie jar, and that is safe here for a reason
// that could change**: the client keeps its session in `localStorage`, never in
// a cookie (`crates/ui/src/local_storage.rs`), so overriding `Cookie` cannot
// disturb a logged-in session. If the app ever sets a cookie of its own this
// must become `storageState` instead.
function gateHeaders(): Record<string, string> {
  if (!/rehearsal|84\.183/.test(baseURL)) return {};
  const fromEnv = process.env.REHEARSAL_ACCESS_KEY;
  const key =
    fromEnv ??
    execSync(`${__dirname}/../scripts/rehearsal-key.sh`, { encoding: 'utf8' }).trim();
  if (!key) throw new Error('rehearsal is gated and no access key could be obtained');
  return { Cookie: `rehearsal=${key}` };
}

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: [['list'], ['html', { open: 'never' }]],
  // Computes this run's identifier before any worker starts (#252 R1). It must
  // be one value shared by every worker, and `fullyParallel` means there are
  // several — so it cannot be a module-level constant in the helpers.
  globalSetup: './global-setup.ts',
  // Best-effort removal of the test users/games this run created.
  globalTeardown: './global-teardown.ts',
  use: {
    baseURL,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    // The wasm client takes a moment to boot and hydrate on first load.
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    extraHTTPHeaders: gateHeaders(),
  },
  // Two form factors. Layout regressions are invisible to the desktop run —
  // the board, the games panel and the top bar all reflow at phone width —
  // and CI minutes are free on a public repo, so the whole suite runs twice
  // rather than a hand-picked subset that would drift out of date.
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'mobile', use: { ...devices['Pixel 5'] } },
  ],
});
