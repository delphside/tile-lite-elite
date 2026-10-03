---
name: ship-a-change
description: Take a change through preview, rehearsal and a production release, or apply a Repository Change or Other delivery. Use when a change is ready to go out, when a release is being cut, or when a lap is being run against preview or rehearsal.
---

# Shipping a change

The mechanics and the traps. **Whether a change should ship is a judgement and is
not here** — `docs/3.3` §1 is the authority for the steps and `docs/3.6` for the
rules. This is what those documents cost somebody who has to remember them.

## First, the route — it decides everything below

| route | what shipping means |
| --- | --- |
| **Production Release** | anything in the image, **and anything on the production host** (D52). Semver, branch, pull request, the full lap |
| **Repository Change** | anything else in the repository. Live on `origin/main`; **there is no deploy** |
| **Other** | a console, a cloud resource, preview or rehearsal. Whatever applying it takes, plus a row in `docs/4.9` |

**A delivery has one route.** Work spanning several splits into a delivery each,
and each is its own work package. Documentation is the exception: it rides on the
release it accompanies, one milestone, no second row.

**A Requirement never carries a release milestone** — only `pre-approved`. If the
thing shipping is a requirement, it needs a work package to own the delivery, or
the record says a delivery happened with nothing responsible for it.

## The lap, for a Production Release

Run in order. Each step's proof is its **exit status**, never its output.

```bash
./scripts/verify.sh                       # 1. the board and the environments agree
./scripts/deploy-preview.sh               # 2. preview, at the commit you will ship
cd e2e && npx playwright test --workers=1 # 3. against preview
./scripts/deploy-rehearsal.sh             # 4. the whole release, same script production gets
./scripts/deploy.sh                       # 5. production — run it bare
```

### The traps, each of which has cost a run

**Preview must be on the commit being shipped.** `deploy.sh` refuses otherwise,
and it is right to: a branch build is *nearly* the same code, and nearly is what
the check exists to catch. Rebase first, then redeploy preview, then ship.

**`--workers=1` against anything remote.** The engine holds the games map's write
lock while searching, so parallel workers queue and time out. CI already uses
one worker.

**Rehearsal refuses a suite at its rate limits.** Registration is 2/min with a
burst of 3 and the suite registers an account per test:

```bash
./scripts/rehearsal-limits.sh regression   # before
./scripts/rehearsal-limits.sh production   # after — always
```

**Leaving them relaxed is worse than forgetting to relax them**, because
`check-rate-limits.sh` then passes against numbers nobody ships.

**Clean up after a remote run**, or the next one inherits the accounts:

```bash
./scripts/clean-test-accounts.sh --prefix T- --target https://rehearsal.tileliteelite.com
```

**Read the milestone before deploying.** `deploy.sh` closes **every open issue in
it**, shipped or not. Move out anything that is not shipping first.

**Run `deploy.sh` bare.** Piping it into `tail` reports the *pipe's* exit status.
Redirect to a file if you need the output.

## Afterwards, and it is not automatic

| | |
| --- | --- |
| the delivery-log row | **written by hand** into `docs/4.9`. The release does not write it |
| a lettered milestone | closed by hand — the letter form is not valid semver, so nothing matches it |
| post-deployment checks | answered on the work package, each row, with `passed`, `cannot be tested` or `failed` |

## The other two routes

**Repository Change** is merged and done. No deploy, no milestone, no row —
its record is the commit.

**Other** is applied however it applies, then takes a work package, a lettered
milestone off **production's** current version (not the development one), and a
row in `docs/4.9`. A package upgrade and a reboot are two deliveries, because
either can fail alone and the record must say which did.

## An emergency

**Cut from the last `prod-*` tag, never from `main`** — `main` accumulates
tested-but-unshipped image changes, and deploying it ships all of them beside the
fix. `docs/3.3` §1.13 has the commands. It took **12 minutes 7 seconds** when it
was walked, of which 6 minutes was CI, which is not skipped. `rollback.sh` first:
it is seconds and needs no build.

Afterwards `main` does not have the fix. **Merge it back** — not rebase, which
rewrites `main` and orphans every artefact built from it, and not cherry-pick,
which leaves production running a commit that is not an ancestor of `main`.
