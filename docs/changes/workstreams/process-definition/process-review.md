# Process review: this project against published practice

A comparison of `docs/3.3` and `docs/3.4` against primary sources on release
engineering, run 2026-08-13. The question asked was blunt: **where have we
reinvented something that already had a standard answer, and where is the
divergence justified?**

The constraints that shape the answer: one developer with no reviewer, four
environments, a 1 GB production VM that cannot compile the workspace, and a
hobby project held to a professional standard deliberately.

Nothing here is a decision. It is the input to decisions.

## What already matches established practice

Most of it, under names we were not using.

| what we do | the named practice |
| --- | --- |
| version-named branch, scope frozen at the cut, feature branches merged in | **release branch** / **release train** ([Fowler](https://martinfowler.com/articles/branching-patterns.html), [TBD](https://trunkbaseddevelopment.com/branch-for-release/)) |
| the branch cut just-in-time, not maintained perpetually | TBD's branch-for-release — explicitly *not* GitFlow's permanent `develop` |
| deploys build a throwaway worktree of a commit, never the working tree | **hermetic builds** ([Google SRE](https://sre.google/sre-book/release-engineering/)) |
| `0.5.0+<sha>` | semver §10 build metadata, ignored in precedence ([semver.org](https://semver.org/)) |
| migrations as their own step before the container swap | expand/contract discipline; a bad migration is a stopped deploy, not an outage |
| the smoke test asserts the exact version, not a 200 | *test the deployment, not the site* (Humble & Farley) |
| normal / standard / emergency, with a retrospective issue for emergencies | **ITIL change enablement**, vocabulary and post-implementation review |
| no reviewer, mechanical gates instead | DORA found no evidence that formal external review lowers change-fail rate ([dora.dev](https://dora.dev/capabilities/streamlining-change-approval/)) |
| commit messages carry the *why* | kernel `SubmittingPatches`; [Google eng-practices](https://google.github.io/eng-practices/review/developer/cl-descriptions.html) |
| environment differences in compose files, never per-environment branches | Fowler calls environment branching "the classic example of an Anti Pattern" |
| preview keeps its volume, so migrations meet a non-empty database | [12factor X](https://12factor.net/dev-prod-parity), dev/prod parity |

The **preview/rehearsal split** stands up better than most published treatments.
The standing objection to staging environments — Charity Majors' "trying to
mirror your staging environment to production is a fool's errand" — is aimed at
staging that *pretends* to be production. Ours does not pretend; each
environment is scoped to a question it can actually answer.

## Divergences that the constraints justify

- **No pull-request review.** Unavoidable, and DORA removes the guilt.
- **Local build then `scp`, no registry.** Justified by the 1 GB VM and the
  deploy frequency, and 3.3 names the trigger for revisiting it.
- **Merge commits refused on a release branch.** Standard practice tolerates one
  and re-tests; our gates make re-testing expensive, so fast-forward is right.
- **No canary or blue-green.** Needs parallel infrastructure we do not have. The
  automatic rollback on smoke-test failure is the honest substitute.

## Reinvention — where there was a standard answer

### 1. We build the images twice

The significant one. `deploy.sh` builds from a worktree; the rehearsal deploy is
the same script and builds *its own*. So rehearsal proves that **a** build of
commit X works, and production then ships **a different** build of commit X.
Docker builds are not bit-reproducible: base-image tags move, apt mirrors move,
the toolchain resolves at build time.

The most-repeated rule in the continuous-delivery literature is **build once,
promote the artifact**. SLSA formalises it as provenance binding an artifact
digest to a source revision ([slsa.dev](https://slsa.dev/spec/v1.0/requirements)).

No registry is needed to fix it: keep the `docker save` tarball built for
rehearsal, ship *that file* to production, and have the gate compare image
digests rather than `/health` version strings. It strengthens the strongest gate
in the system at roughly no cost.

### 2. No rule about which side of the branch a fix goes on

3.3 covers forward-merges well. It never states the complementary rule, which
both primary sources give flatly:

> "You should not fix bugs on the release branch in the expectation of
> cherry-picking them back to the trunk." — trunkbaseddevelopment.com

The natural action while testing `0.6.0` is to fix on `0.6.0`. Forward-merging
rescues it eventually — but only **at release**. In between, `main` lacks the
fix, and `main` is where a fasttrack or emergency release comes from. That is a
live regression window. One paragraph closes it: reproduce on `main`, fix on
`main`, cherry-pick to the version branch.

### 3. No de-scoping rule, and the tooling fights it

What happens when testing finds that scoped work is not ready? The release-train
answer is that the train departs and the feature gets off. We have no rule — and
`deploy.sh` closes **every issue in the milestone** on deploy, so de-scoping
requires remembering to move a milestone by hand first. That is exactly the
class of silent manual step the rest of the process exists to remove.

### 4. The commit stamp occupies Conventional Commits' slot

`app 0.6.0 api 2.12: subject` sits where
[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/) sits, and
carries **state** (the version the tree already says) where the standard carries
**intent** (`feat:`, `fix:`, `!`). Consequences visible in our own tooling:

- the version a release should take cannot be derived from its commits, so
  `check-release-version.sh` reads GitHub labels instead of the log
- there is no path to a generated changelog
- the stamp is checkable only because it is redundant with `Cargo.toml`

It does catch a forgotten version bump — but so would a check on the bump
commit. Trailers are the standard slot for machine-readable metadata:
`Api-Version: 2.12` as a trailer, plus `feat:`/`fix:`/`!` in the subject, gives
the bump check, a derivable release version and a changelog for less ceremony
than we pay now.

### 5. `0.x` deferred to "the next structural change"

3.3 diagnoses this correctly — the leading zero describes "a state the service
left long ago" — then makes 1.0.0 contingent on a big change appearing. The
semver FAQ says the opposite: release 1.0.0 when the software is in production
and users depend on it, which has been true for a year. Until then the major
slot is unusable and three lanes run on two slots.

### 6. `API_VERSION` is a compatibility advertisement, not a routing version

Google's [AIP-185](https://google.aip.dev/185) is explicit that APIs must not
expose minor versions, because a version in the contract is a *routing*
dimension — `v1` and `v2` coexist so old clients keep working. Ours is not that;
it is a signal a client reads to decide whether to reload. That is reasonable
for a single first-party client, but the two are routinely confused and we do
not draw the distinction. Related: our "a new accepted *value* is additive" rule
has a citation — [AIP-180](https://google.aip.dev/180) — and a caveat: new
values in *response* enums warrant more caution than in requests, because
"user code does not handle new values gracefully". The edition registry is
heading toward being both.

### 7. Feature flags are nowhere in the documentation

The whole "when to merge, and what to hold back" section solves the problem the
industry solves with flags: merge continuously, ship dark, flip when ready.
Declining them for a hobby project is defensible; **not naming them** is not —
and it is a direct cost of our own convention *"say what we do, not what we
rejected"*. A considered rejection has nowhere to live, so it reads as an
oversight.

## Gaps, ranked by what would actually help

1. **There is no production monitoring.** No uptime check, no alerting, no error
   rate. The last thing that observes production is the smoke test at deploy
   time. Our own framing is "does it deploy" versus "is it any good" — and the
   process answers the second only *before* release. A free external check
   against `/health` with an email alert is fifteen minutes' work and converts
   "a user tells me" into "I know".

   > **Added after this report — closed 2026-08-13, #136.** Built entirely from
   > Oracle's own tooling rather than custom code. An OCI Notifications topic
   > `tile-lite-elite-alerts` emails the owner, and four things now publish to
   > it: an external Health Check on `https://tileliteelite.com/health` from
   > three vantage points, with an alarm at *two of three failing for 3
   > minutes*; and CPU > 90%, memory > 90% and instance-stopped alarms on the
   > production instance. Delivery was tested end to end with a published test
   > message, not assumed.
   >
   > The external probe is the part that closes the gap. The three host alarms
   > are published by an agent running on the host they report about, so if the
   > VM goes away, silence looks identical to health — and `RESEND_API_KEY`
   > lives on that same VM, so anything we wrote ourselves would have died with
   > the thing it was meant to report.
   >
   > Still open: filesystem free space, which `oci_computeagent` does not
   > publish and Oracle has no built-in metric for. Deferred at 13% used rather
   > than write a custom-metric cron job.

2. **Promote the artifact, not the commit** (above).
3. **Fix on trunk, cherry-pick to the branch** (above) — one paragraph.
4. **A de-scoping rule, and tooling that does not resist it** (above).
5. **Release notes.** No changelog, no `gh release`, no per-version summary.
   "What changed in 0.6.0" currently has no answer but reading a PR.
   `deploy.sh` already writes the tag; `gh release create` is one line.
6. **Deferred self-review** — the one practice the solo literature actually
   names: run the automation, take a break, read your own diff in a different
   tool the next day. We have the automation half and none of the cooling half.
7. **Feature flags** — low priority, but name the rejection.

## What is unusual and worth keeping

Four things are better than what is published.

**"A gate that can fail open gets a test, and CI runs it."** The
fail-open/fail-visible distinction as the *selection rule* for which scripts get
tested is sharper than the literature, which mostly says "test your CI" with no
criterion.

**`DEPLOY_GATES_ONLY=1`.** Making the refusal path cheap to exercise, because
nobody rehearses a deploy they expect to be refused. Two gates having failed
open is the evidence for it. The strongest piece of engineering in the process.

**Naming the CI run a gate consults.** Four runs on one commit, two green, and
the only completed e2e a failure — a real Actions failure mode most teams never
meet because branch protection hides it. With local merges and no branch
protection, `--run push:main --require e2e` is the correct compensating control.

**"Evidence follows what the change does, not its type."** Sharper than the
usual acceptance-criteria framing, and it names the real failure: evidence
inherited from a label cannot fail.

The **test-plan method** is closer to rediscovery — its parts 2 and 4 are the
category-partition method (Ostrand & Balcer, 1988), and "every refusal followed
by a success" is the intuition behind mutation testing. Naming the prior art
would make it shorter to explain, not less valuable.

## One structural observation

**3.3 is 1,965 lines.** Far outside any norm for a process document, and the
review-stamp mechanism exists because we already know it. The standard shape is
a short runbook plus a separate rationale document — and the runbook already
exists as the five commands. Everything from "Why the process is shaped this
way" downward is rationale for a reader who has hit a surprise.

The risk is not that it is wrong. It is that its single reader stops being able
to hold it, and then follows the parts he remembers.
