# 206 — How we use GitHub

**Project #206**, under the process definition workstream (#188).
`phase:scope-and-design`. Nothing here is decided.

**Method**, owner 2026-08-25: *"I think we need to list the technical options
for individual things, like storing a field. Then put together complete options
to compare."* So Part 2 lists each choice on its own, and Part 3 assembles the
ones that hang together. Several constrain each other, which is why they cannot
be decided one at a time.

## Part 1 — What this project is about

### The requirements it carries

| | | from |
| --- | --- | --- |
| **R1** | approving a change should work wherever the owner can type it | #197 |
| **R2** | approving and merging should be one act | #198 |
| **R3** | Claude's pull requests should not be authored by the owner | #171 |
| **R4** | every issue attribute should be stored once, somewhere a tool can read it | #216 |
| **R5** | a release's notes should have exactly one home | #217 |

### The idea that makes them one project

Owner, 2026-08-25: *"we should distinguish storing data (each item should be
stored once) and reporting data (many reports could include the same information
in different formats for different purposes). So it is not a choice between
GitHub Project report and our own pipeline report, but it is about how data is
stored for each issue."*

**Many reports may read the same data.** A Project board, `pipeline.md`,
`roadmap.sh` and `actions.py` can all render the same facts for different
purposes, and none of that is in tension. **The tension is only where two of
them store an answer.**

Every requirement here is a case of that:

| | the duplication |
| --- | --- |
| R1, R2 | a review verdict kept in a label we maintain, when GitHub knows it natively |
| R4 | a size kept in prose, where nothing can read it — stored *nowhere*, which is the same failure inverted |
| R5 | release notes in `docs/4.9`, and in GitHub too if Releases were adopted |
| R3 | not duplication, but the reason R1 exists at all |

### Why the review machinery exists, which is the root

`gh` runs under the owner's token, so **every pull request Claude opens is
authored by the owner**, and GitHub refuses self-approval:

> Pull request authors can't approve their own pull requests

The parser in `docs.yml` was not chosen over GitHub's native review. **The
native one was unreachable**, for a reason that has nothing to do with review.

### Where each attribute is stored today

| attribute | stored in | queryable |
| --- | --- | --- |
| type | a label | yes |
| **release** | **the milestone** | yes |
| workstream | the sub-issue parent | yes |
| route | nowhere — derived from the artefact list (D26) | no, deliberately |
| **size** | free text in a triage comment | **no** |
| **impacted artefacts** | free text, then a project body | **no** |
| review verdict | the `approved` label, set by a comment parser | yes, and **duplicated** |

## Part 2 — The individual choices

Each is a decision on its own. Part 3 combines them.

### 2.1 Where an issue attribute is stored

| option | | |
| --- | --- | --- |
| **A. a label** | works today; free; queryable by `gh` and the API | one label per value, so a five-value attribute is five labels. No ordering, no numbers, and the list grows without structure |
| **B. a milestone** | already how `release` works | **one per issue**, so exactly one attribute can use it. `deploy.sh` depends on this one |
| **C. the sub-issue parent** | already how `workstream` works; structural, so it cannot disagree with itself | one parent, so again a single attribute |
| **D. a Project custom field** | sortable, filterable, groupable; available on a **personal** repo | the value lives in the Project, not the issue — an issue outside the Project has no value at all |
| **E. an issue field** | on the issue itself, where it belongs | **organisation only** |
| **F. free text in a comment** | costs nothing, says anything | not queryable, and drifts: `prod-tooling`, `prod tooling`, `production tooling` |

**D and E are *mechanisms*, not data types — and this is easy to muddle.**
*Single-select* is a **data type**, and **both** D and E offer it, along with
text, number and date. What differs is where the field lives and who can see it:

| | lives on | scope | data types it offers |
| --- | --- | --- | --- |
| **D. Project custom field** | a board | any account | single-select, text, number, date, **iteration** |
| **E. issue field** | the issue | **organisation only** | single-select, text, number, date, **multi-select** |

So *"a single-select field"* does not name an option. What we adopted in
Delivery 3 is **E** — issue fields — three of which happen to have the
`SINGLE_SELECT` data type: `Type of change`, `Effort` and `Priority`.

*Corrected 2026-08-26, after the wording here caused exactly that confusion in
review.*

**Today**: type = A, release = B, workstream = C, size and artefacts = F.

**The constraint that does not move**: `deploy.sh` reads the milestone to decide
what a deploy closes, so `release` stays B whatever else changes.

#### 2.1.1 A fine-grained token cannot read a user-owned Project — measured

**This is the constraint that reshapes the options**, and it is not in any of
the option descriptions above.

`gh api graphql` returns `FORBIDDEN` for `projectsV2`. The obvious fix — add the
permission — **is not available**: the fine-grained token's *Account permissions*
list has no **Projects** entry. Checked on 2026-08-25 by searching the picker
for `project`, which returned nothing. Alphabetically it would sit between
*Profile* and *SSH signing keys*, and there is nothing there.

Fine-grained tokens grant Projects at **organisation** level. A **user-owned**
Project — which is what `github.com/users/SteveStyle/projects/1` is — has no
corresponding permission.

| to read a user-owned Project | |
| --- | --- |
| **fine-grained PAT** | **not possible** |
| **classic PAT** with `read:project` | works — and classic tokens are all-or-nothing across the whole account, where today's token is scoped to one repository |
| an **organisation**-owned Project | fine-grained works, and per-repository scoping is kept |

**So 2.1D is not the cheap middle option it appears to be.** Storing anything in
a user-owned Project means either **widening the token to everything the account
owns**, to solve a reporting problem — or creating an organisation, which is
2.2B.

**And it applies to reporting, not only to storing.** The board that already
exists cannot be read by our tooling at all today, so even "leave the data where
it is and just render it from a Project" is blocked by the same wall.

**Confirmed after the move to an organisation, 2026-08-25.** A token whose
resource owner is the organisation still cannot read a **user-owned** project:
`user(login:…).projectsV2` returns `totalCount: 1` and `nodes: [null]`. So the
existing untitled board **did not come across** and remains unreadable. If
Projects are used at all, the project must be **org-owned** and created fresh —
the move does not rescue the old one.

| | needs |
| --- | --- |
| inspecting the board while designing | a classic token, or an org |
| `pipeline.py` reporting from Project fields | the same, **permanently** |
| trying fields out before deciding | write as well, and a **throwaway project** rather than the real board — the same shape as the read PAR made for a restore drill and deleted after |

**2.1A costs none of this.** A label needs nothing the token does not already
have, which is a point in its favour that was invisible until this was measured.

#### 2.1.2 What each field mechanism can actually do

From GitHub's documentation, checked 2026-08-25 (via Gemini, whose summary
matched the docs it cited — **not measured by us**, unlike 2.1.1):

| | Project custom fields | Organisation issue fields |
| --- | --- | --- |
| types | single-select, text, number, date, **iteration** | single-select, text, number, date |
| **visible on the issue page** | **no** — only inside the board | **yes**, in the sidebar beside labels and milestone |
| **settable when raising an issue** | **no** — add it to the board first, then fill it in | **yes**, at creation |
| scope | that one board | every repository in the organisation |
| account needed | any | **organisation** |

**Two consequences that matter more than the token constraint.**

**A Project field cannot be answered at raise time.** Type and release are asked
by the requirement form, at creation, and the whole point of the form is that
raising is a five-second act. A Project field would have to be filled in later,
on a board, after adding the issue to it. **So 2.1D can only ever hold
attributes decided *after* raising** — size, and little else. It is not a
candidate for type or release at all.

**A Project field is invisible where people look.** An attribute nobody sees on
the issue is an attribute that exists only for whoever opens the right board.
That is tolerable for a planning aid and wrong for a classification the process
depends on.

**Neither point rules out a Project as a *report*.** They rule it out as the
**store** for anything the form asks. Which is the storing/reporting split
again: a board is a fine view and a poor home.

### 2.2 Who owns the repository

| option | | |
| --- | --- | --- |
| **A. a personal account** | today. Nothing to do | no issue fields; a second user is an unrelated account |
| **B. an organisation** | issue fields become available; a second user is a member with a role; teams and per-repo permissions | a migration, and `gh`/token/CI settings move with it. Free for what we need |

**Two requirements point here independently** — R4 wants issue fields, R3 wants a
second user — which is why they are in one project. Neither *requires* an
organisation: 2.1D and 2.1A work without one, and a second personal account
works without one.

#### 2.2.1 What an organisation would actually cost — measured

The commonly cited disadvantages, checked against this repository on 2026-08-25
rather than taken as read. **Three are weaker than they appear and one does not
apply at all.**

| the claim | what is true here |
| --- | --- |
| **Actions minutes become a small shared pool** | **Does not apply.** This repository is **public**, so Actions are free and unlimited. It ran **1,104 workflow runs** in the last month — the one item that could have been a real cost is zero |
| **Repository URLs change and links break** | **Five references** in four files: `Cargo.toml`'s `repository` key, a docs link in each of the two issue templates, and `docs/3.1-setup.md`'s `git clone` line. Plus one `git remote`. `actions.py` and `pipeline.py` **derive** the repository from `gh repo view`, so they needed no change — which the migration on 2026-08-25 proved rather than asserted. *Measured as four before the move; the listing that produced that number excluded `.md` files* |
| **Token approval overhead every few months** | Real by default, and a **one-time setting**: an organisation owner can set the personal access token policy to not require approval. It is administration, not recurring administration |
| **Context switching, feature bloat** | True and subjective. Two settings dashboards instead of one, and an interface built for companies |

**So the migration cost is four string literals, one remote, and one policy
setting.** That is much smaller than the framing suggests, and it is worth
recording because the argument against an organisation is usually made in the
abstract.

**What it does not measure** is the thing that actually matters: whether a
second GitHub account and a second settings surface are worth maintaining
forever, for a project with one developer. That is a judgement, and 2.2.1 only
removes the false costs from around it.

### 2.3 How many GitHub users

| option | | |
| --- | --- | --- |
| **A. one** | today | every PR is authored by the owner, so **native Approve is impossible**, and attribution relies on Claude remembering a footer |
| **B. two** | native review works; attribution becomes structural rather than remembered | a second account, its token and permissions; and the commit trailer means something different once the author really is different |

### 2.4 How a review verdict is recorded

| option | | |
| --- | --- | --- |
| **A. our label, set by the comment parser** | today; works from anywhere a comment can be typed | a second store for what GitHub knows; **fails silently** in four of five places a verdict can be typed (#197) |
| **B. GitHub's native review state** | one store; every client; no parser | needs 2.3B, and has no equivalent of `/prov` |
| **C. both** | — | **rejected on sight**: two stores for one fact is the thing this project exists to stop |

#### 2.4.1 Native Approve is available — confirmed 2026-08-25

**Delivery 2 proved the premise the same day it was delivered.** PR #218, opened
by `SteveStyle-typed-by-Claude` on `delphside/tile-lite-elite`, presents an
**enabled Approve option** in GitHub's own review dialog. That has never been
possible on this repository: every previous pull request was authored by the
owner, and GitHub refuses self-approval.

So **R1 is solved natively, not by fixing anything.** GitHub's review works in
every client — the browser, the VS Code extension, the mobile app — because it
is the native mechanism rather than a slash command a parser has to notice.
**#197 may never need to be done**, which was the possibility this project was
raised to test.

**How the account is attached.** It is an **organisation member** of
`delphside`, and has **write on `tile-lite-elite`**.

*Corrected 2026-08-25.* This first said it was **not** a member, because
`gh api orgs/delphside/members` returned `[]`. That endpoint lists **publicly
listed** members only, to a caller that is not itself a member — and org
membership is private by default. The token is owned by the organisation rather
than being a member of it, so it saw nothing and I read nothing as *no*.
**Absence of data from an API probe is not absence of the fact**, which is the
second time that mistake has been made here.

**The privilege question is still worth asking**, now on the real state: an org
member can be given reach beyond this repository, where an outside collaborator
cannot. With one repository the distinction is theoretical. It stops being
theoretical the moment a second one exists — a stress harness (#91) or a bot
client (#10) — so it is worth revisiting then rather than now.

**`/prov` is the only outcome with no native equivalent**, and the owner closed
that gap on 2026-08-23: *"in the absence of provisional approval, I can use
[request] changes and approve when you say they are done."* Arguably better than
`/prov`, which merges work he has not seen.

### 2.5 Where release notes live

| option | | |
| --- | --- | --- |
| **A. `docs/4.9` only** | today; versioned, reviewed, read from `origin/main` | no notes on the tag itself; nothing on GitHub's Releases page |
| **B. GitHub Releases only** | notes on the tag; generated from merged PRs; a free-text field | a second surface to keep current, and it is not in git — so it needs a row in `docs/4.8` |
| **C. `docs/4.9` is the store, a Release is generated from it** | one store, two renderings — exactly the storing/reporting split | something has to generate it, most likely `deploy.sh` |

### 2.6 What applies an answer once it is decided

**The gap nothing currently owns**, seen three times:

| | |
| --- | --- |
| **D32** | the requirement form's dropdown answers do not become labels — *parked* |
| **#215** | applying a triage takes four manual actions; two were missed |
| 2026-08-25 | folding takes three; the third was missed on five issues |

| option | | |
| --- | --- | --- |
| **A. by hand** | today; nothing to build | it is forgotten, demonstrably, and the report is the only thing that notices |
| **B. a workflow reads the form and applies labels** | D32's original proposal | only covers raising, not triage or folding |
| **C. a workflow reads the triage comment's table** | covers the case that actually failed | parsing a comment is fragile — though the standard reply now lists valid values, which is what makes it possible at all |
| **D. fewer places to apply it** | if an attribute lives in one place, there is less to keep in step | not an option on its own; a consequence of 2.1 |

## Part 2.7 — Decision: Option 3

**Decided 2026-08-25.** Owner: *"we are spending time dealing with limitations
that come from not having an org and not having a second account. I would rather
spend the time setting them up. There may be other benefits we haven't thought
of yet."*

**So `2.2B` — an organisation — and `2.3B` — a second GitHub account.** The rest
of Part 3's Option 3 follows from those two but is not settled by them; see
*What is still open* below.

### Why, in the order the arguments actually carried

**The cost of not having them is already being paid.** Two sessions have gone on
working around their absence: a review verdict that only works from one of five
places a comment can be typed (#197), a parser maintaining what GitHub knows
natively, an attribute that cannot be stored anywhere readable (#216), and a
board that exists and cannot be read at all (2.1.1). None of that is
hypothetical, and none of it goes away on its own.

**The migration is smaller than the workarounds.** Measured in 2.2.1: four
string literals, one `git remote`, one policy setting. The item that could have
been expensive — Actions minutes — **costs nothing, because the repository is
public**.

**The alternatives got worse the more they were examined.** Option 2 needed a
classic token, widening access from one repository to everything the account
owns, and could then hold only *size* — because a Project field cannot be set
when an issue is raised and is not visible on the issue page (2.1.2). Option 1
works and leaves every one of R1 to R5 unmet except by hand.

**Optionality was a stated reason, and is worth naming as one.** *"There may be
other benefits we haven't thought of yet."* That is not measurable and should
not pretend to be — but a structure that makes future choices available is worth
something, and the measured cost of acquiring it is low enough that it does not
have to carry the argument alone.

### What is still open

Choosing the account structure does not choose the rest:

| | |
| --- | --- |
| **2.4** | whether native review fully replaces the parser, and what happens to `/prov` |
| **2.5** | ~~where release notes live~~ — decided 2026-08-27: **both**, and they answer different questions. `deploy.sh` publishes a GitHub Release per `prod-` tag with generated notes; `docs/4.9` stays the delivery log, because a delivery that ships no code has no tag |
| **2.6** | **what applies an answer once decided** — still the choice with no good option, and an organisation does not solve it |
| — | ~~what happens to `pipeline.py`~~ — decided 2026-08-27: deleted, Delivery 4 Part 2 |

**And one thing the decision does not license**: moving `release` off the
milestone. `deploy.sh` reads it.

## Part 3 — Complete options

Assembled from Part 2, in increasing order of change. Each is internally
consistent; the point of writing them out is that **choices constrain each
other** and a menu cannot show that.

### Option 1 — Stay as we are, and fix the parser

`2.1` unchanged · `2.2A` · `2.3A` · `2.4A` · `2.5A` · `2.6B or C`

Fix #197 so the command works from a review as well as a comment. Everything
else stays.

| | |
| --- | --- |
| **for** | smallest possible change; no migration; nothing to learn |
| **against** | R4 unmet — size and artefacts stay unqueryable. R2 unmet. Keeps a parser that duplicates what GitHub knows, and the #197 defect is the second silent failure in that job this month |

### Option 2 — Add Project fields, stay personal

`2.1D for size` · `2.2A` · `2.3A` · `2.4A` · `2.5A or C` · `2.6C`

A Project becomes the store for attributes labels handle badly. Type, release
and workstream stay where they are.

| | |
| --- | --- |
| **for** | R4 met without a migration; the table view is the spreadsheet asked for; the sub-issues progress column is a live workstream rollup we do not have |
| **against** | a value in a Project is not on the issue — an issue outside the board has none, and something must keep the board complete. R1, R2, R3 all unmet |
| **and the one that may kill it** | **our tooling cannot read a user-owned Project at all** (2.1.1). This option therefore requires a **classic token**, widening access from one repository to everything the account owns — to solve a reporting problem. That is a worse trade than it looked before it was measured |
| **and a second** | a Project field **cannot be set when an issue is raised** and **is not visible on the issue page** (2.1.2). So it could hold size, and never type or release — which narrows this option to one attribute |

### Option 3 — Move to an organisation

`2.1E for size and any new attribute` · `2.2B` · `2.3B` · `2.4B` · `2.5C` · `2.6B`

The repository moves to an organisation; Claude gets an account in it; native
review replaces the parser; issue fields hold what labels handle badly.

| | |
| --- | --- |
| **for** | every requirement met. The parser, the `approved` label and a whole class of silent failure are **deleted** rather than fixed. Attribution becomes structural. And it is the **only** way to store an attribute outside a label without widening the token (2.1.1) |
| **against** | the largest change, and the only one with a migration. Two accounts to manage. `/prov` is lost and replaced by an extra lap. Nothing here is urgent, and this is not a small step |

### Option 4 — Organisation, but keep our own review

`2.2B` · `2.3A` · `2.4A` · rest as Option 2

An organisation purely for issue fields, with the review machinery untouched.

| | |
| --- | --- |
| **for** | R4 met on the issue itself rather than in a Project |
| **against** | pays for the migration and collects only one of its benefits. Hard to argue against Option 3 once the org exists |

## Part 4 — What the design must answer

1. **Which option**, or which parts of which.
2. **What happens to `pipeline.py`** — it derives, so it cannot drift; a Project maintains, so it can. Both may live, but only if it is written down which is the store.
3. **Whether `/prov` survives** in some form, or the extra lap is accepted.
4. **What 2.6 does**, because every option leaves *something* applied by hand,
   and that is the failure that keeps recurring.
5. **Whether an organisation is worth it on its own merits**, separately from
   the two requirements that happen to want one.
6. **Whether implementation needs a branch**, which the chosen option decides
   rather than the project. Owner, 2026-08-25: *"no need for a branch yet. I am
   not sure if we will want one for development."* §2.2's test says a branch is
   needed only when the old version is required in the interim — so changing
   `docs.yml`'s `commands` job while still relying on it to approve things would
   need one, and adding a Project field would not. **This design note does not**,
   which is why it is on `main`.

## Part 4.5 — Deliveries

**Owner, 2026-08-25: *"let's set them up, then decide how to use them from
there."*** So the structure is delivered first and used later, and the split is
deliberate: **"the organisation and the account exist and nothing is broken"** is
a different claim from **"we now use them"**, and only the first is
hard to reverse.

### Delivery 1 — the organisation, and nothing is broken — **done, `0.7.0c`, 2026-08-25**

Nothing changes about how we work. At the end of it every existing thing does
what it did before, from a different URL.

| | who |
| --- | --- |
| create the organisation, Free plan | owner |
| transfer `tile-lite-elite` into it | owner — **the moment anything breaks, if it does** |
| update the `git remote` | Claude |
| update the four references: `Cargo.toml`'s `repository`, and a docs link in each issue template | Claude |
| set the organisation's personal access token policy to **not require approval** | owner |
| re-scope or reissue the fine-grained token against the organisation | owner |
| verify: CI runs, `deploy.sh`'s gates read CI, `actions.py` and `pipeline.py` still work | Claude |

**The second account moved out of this delivery** and became Delivery 2. It was
step 8 of the runbook, marked *can wait* — and a delivery is *one act of putting
change in front of whoever consumes it*. Creating an account, inviting it and
granting it access is a separate act with its own verification, and leaving it
inside Delivery 1 would have meant a delivery that was finished except for the
part nobody had done.

**Route**: `service` for the organisation and the account — neither leaves a
trace in git, so both want rows in `docs/4.8`. `repository` for the four
references.

**No release.** Nothing ships in the application.

### Delivery 1 runbook

**Written 2026-08-25, before doing it.** Owner's steps are the console ones;
Claude's follow the transfer.

#### What will and will not break — checked before writing this

| | |
| --- | --- |
| **git push/pull** | **keeps working.** The remote is SSH (`git@github.com:…`), which authenticates with your SSH key, not the token. Only the URL changes |
| **CI** | **keeps working.** No workflow references `secrets.*`; `GITHUB_TOKEN` is automatic. The repository is public, so Actions stay free |
| **`gh`, and everything Claude does with it** | **breaks at the transfer**, and stays broken until a new token exists. A fine-grained token is issued against a *resource owner*, and the repository will have a different one |
| **web links to the old URL** | redirect automatically |
| **`deploy.sh`** | its CI gates use `gh`, so it is unusable between the transfer and the new token. **Do not deploy during the migration** |

#### 1 · Create the organisation — owner

```text
https://github.com/organizations/plan  →  Free
  name     delphside
  email    your own
  belongs  "My personal account"
```

**Do not transfer anything yet.** Look around first: if the organisation is
wrong in some way, it is far easier to fix while it holds nothing.

#### 2 · Set the token policy before the repository moves — owner

```text
Organisation → Settings → Personal access tokens → Settings
  ✅ Allow access via fine-grained personal access tokens
  ⚪ Do not require administrator approval
```

**Before, not after.** Set afterwards, every token needs approving by hand at
the moment you most want things to work.

#### 3 · Issue the new token — owner, *before* the transfer

```text
Settings → Developer settings → Personal access tokens → Fine-grained tokens
  Resource owner    delphside          ← the change that matters
  Repository access Only select repositories → tile-lite-elite
  Permissions       match the current token, plus **Projects: Read-only**
  Expiry            your choice
```

Copy the token. It cannot be shown again.

**Why before**: the moment the repository moves, `gh` stops working. Having the
replacement already in hand turns an outage into a paste.

#### 4 · Transfer the repository — owner

```text
Repository → Settings → General → Danger Zone → Transfer ownership
  new owner   delphside
```

#### 5 · Point `gh` at the new token — owner

```bash
gh auth login --with-token          # paste, then Ctrl-D
gh repo view delphside/tile-lite-elite --json name    # should answer
```

#### 6 · The repository's own references — Claude

```bash
git remote set-url origin git@github.com:delphside/tile-lite-elite.git
```

and four string literals: `Cargo.toml`'s `repository` key, and one docs link in
each of `.github/ISSUE_TEMPLATE/requirement.yml` and `project.yml`.

#### 7 · Verify — Claude

| | |
| --- | --- |
| `git fetch` and a push | the SSH remote resolves |
| `scripts/verify.sh` | CI status, milestones and branches all read through `gh` |
| `scripts/actions.py` and `scripts/pipeline.py` | both derive the repository from `gh repo view` and should need no change — this proves it |
| `gh api graphql` on `projectsV2` | should stop returning `FORBIDDEN` |
| a trivial commit and push | CI runs under the new owner |

#### 8 · The second account — owner, and it can wait

```text
a new GitHub account:  SteveStyle-typed-by-Claude
  → invite it to the organisation
  → give it write access to tile-lite-elite
```

The reasoning from #171: the name *"states the relationship rather than implying
an independent contributor."* Nothing depends on this account until Delivery 2, so
it can follow later without holding anything up.

#### If it goes wrong

**The transfer is reversible** — transfer it back to `SteveStyle`. Nothing is
deleted, issues and history move with the repository, and the old URL redirects
either way. The only thing that cannot be undone by transferring back is a
token you have already destroyed, which is why step 3 comes before step 4.

### Delivery 2 — the second account exists — **2026-08-26**

#### How Claude authenticates as it, and why not by switching login

`gh auth login` is **machine-wide**: switching it would make the owner's own
`deploy.sh` and `verify.sh` runs act as the bot too. Instead the bot's token
lives in `~/.gh-bot-token` (0600) and is passed per command:

```bash
GH_TOKEN="$(< ~/.gh-bot-token)" gh pr create ...
```

Plain `gh` remains the owner. Three properties follow, and all three were the
reason for choosing it:

| | |
| --- | --- |
| the owner's login is untouched | anything he runs still acts as him |
| every bot action **says so in the command** | rather than depending on which account happens to be active |
| reverting is deleting one file | there is no auth state to unpick |

**The token's permissions**, deliberately minimal: Contents, Issues and Pull
requests write; Actions and Commit statuses read; Metadata. **Not** granted:
Administration, Secrets, Environments, Members. Workflows was left off — pushes
go over SSH, so a token-authenticated push never modifies `.github/workflows/`.

**Git still pushes as the owner**, over SSH with his key. That is not a gap: a
pull request's author is whoever **created the pull request**, which is what
gates self-approval — not who pushed the branch.

#### The original delivery steps

| | who |
| --- | --- |
| create `SteveStyle-typed-by-Claude` | owner |
| invite it to `delphside`, with write access to `tile-lite-elite` | owner |
| decide what the commit trailer says once the author is genuinely different | both |
| a pull request opened by it, approved natively by the owner — **the thing that proves it** | both |

**Nothing depends on it until then**, which is why it is a delivery of its own
rather than a prerequisite. The reasoning from #171 stands on the name: it
*"states the relationship rather than implying an independent contributor."*

**What it unlocks and does not yet do**: native Approve becomes possible. Whether
the parser is then deleted is 2.4, and still open.

### Delivery 3 — issue types and fields replace labels — **2026-08-26**

**What is stored where, after it:**

| attribute | store | enforced |
| --- | --- | --- |
| **level** | **issue type** — Requirement · Project · Workstream · Index | one only, natively |
| **type of change** | **issue field**, single-select, 7 options | **one only** — labels allowed two, and #157 had two |
| **effort** | issue field — High · Medium · Low, **empty means unknown** | R4's gap, closed |
| **priority** | issue field (GitHub's own) | see §3.4, which reversed |
| release | milestone, unchanged | `deploy.sh` reads it |
| workstream | the sub-issue parent, unchanged | structural |

**Two things a label could not do**, and they are why this was worth the churn:

- **Set at creation.** An issue field appears when an issue is raised, so the
  requirement form's answer *is* the stored value. Labels forced the form to put
  the answer in the body for somebody to apply by hand afterwards — D32, parked,
  and the gap that #215 records.
- **One value.** Nothing stopped two type labels, and #157 carried `bug` and
  `minor-function` until this exposed it.

**A hazard that disappeared rather than being handled.** `status.sh` matched
these as substrings of a comma-joined label string and carried a comment saying
`non-prod-tooling` had to be tested before `prod-tooling`, because one contains
the other. An exact field value removes the ordering entirely.

**The tooling**: `pipeline.py`, `actions.py` and `status.sh` read the type and
the field. `gh issue list --json` exposes neither, so `status.sh` moved to
GraphQL — and `{owner}`/`{repo}` expand in a REST path but **not** in a GraphQL
document, which cost a round of debugging.

**Delivered projects now come from search**, not the issues connection: with
190-odd closed issues returned newest-first in pages of 100, a project closed a
while ago fell off the end, and the report showed **zero** delivered while two
existed.

**All 194 issues were backfilled** — open and closed — from the labels that
already held the answers, so search and the report agree about history as well
as the present.

### Delivery 4 — the forms, the board, and release notes — **2026-08-27**

**One delivery in three parts.** All three were designed, built and merged on
the same day, in the same pull request (#227), and the repository route has
**one delivery moment** — the push to `origin/main` ([3.6](../../../../3.6-change-lifecycle.md)
§2.15). Owner, 2026-08-27: *"then the three changes went in one delivery."* They
were drafted as Deliveries 4, 5 and 6, which is why the parts below still read
as three separate arguments; what makes them one delivery is that nothing
reached anybody until the merge, and then all of it did at once.

It carries the identifier `0.7.0f` in [4.9](../../../../4.9-delivery-log.md), as
one row.

#### Part 1 — the forms, and the field set

**What this section used to be.** It was called *Delivery 4 onwards — what is
left*, and it listed three remaining things: 2.5, the requirement form, and
`pipeline.py`. All three are now decided, so it is a delivery rather than a
backlog. The earlier scorecard, kept because it says what landed where:

| | | |
| --- | --- | --- |
| 2.1 — where attributes are stored | **done** | Delivery 3 |
| 2.4 — native review replaces the parser | **done** | Delivery 2, and the parser deleted in #220 |
| 2.6 — what applies an answer once decided | **answered** as D36, applied in `docs/3.6` §2.18 | no delivery needed |
| deleting the ten labels | **done** | 2026-08-26, once #221 and #222 landed |

**The forms now set the issue type**, and the requirement form's `type` and
`release` dropdowns are gone. They collected answers into the issue **body**,
for somebody to apply as a label afterwards — D32's gap, and what #215 records
the cost of. The sidebar fields are set at creation and *are* the stored value,
so the dropdowns were collecting the same answers a second time into a place
nothing reads.

**And the whole field set was reviewed.** Measured first: on the 53 open issues
the issue type and parent were on all of them, `Type of change` on 44, and
`Priority`, `Effort`, `Start date` and `Target date` on none — all four created
within one second of the organisation, so GitHub's built-in starter set rather
than ours.

| | decision |
| --- | --- |
| **Phase** | a new issue field replaces the five `phase:` labels, and draws the projects board |
| **Effort** | the home for *how big, roughly*, with its native `high · medium · low`; **unset** means triage could not say |
| **workstream row** | leaves the triage table — the parent link is the home, and it draws the swimlanes |
| **Priority, Start date, Target date** | kept. Empty is not an argument against a field created two days earlier |
| **Release** | **no field, deliberately** — we will see whether we miss it |
| **labels** | `good first issue`, `help wanted` and `question` go with the five. Two remain: `needs-triage` and `folded` |

**A field cannot be restricted to an issue type**, but it can be **pinned** to
one — and an unpinned field is invisible on the issue, reachable only through
*Add field*. That is why `Effort` sat empty on 53 issues: nobody was ever asked
for it. `Type of change` and `Effort` are pinned to Requirement and Project,
`Phase` and `Priority` to Project alone, and the two dates to nothing, which is
how *kept but out of the way* is expressed.

**2.5 was answered on the same day** — Part 3. Nothing from the original six
questions is now open.

#### Part 2 — the board replaces the report

**`pipeline.py` is decommissioned.** Owner, 2026-08-27, after a day of trialling
the board: *"agreed, we have answered the question — we will use GH project views
and decommission `pipeline.py`."*

The trial board is org-owned, linked to the repository, and carries four views
that between them do what `pipeline.md` did:

| view | filter |
| --- | --- |
| **Needs triage** | `is:open type:Requirement no:type-of-change` |
| **Backlog** | `is:open type:Requirement`, grouped by parent |
| **Projects** | `is:open type:Project` — board layout, `Column by: Phase`, swimlanes by parent |
| **Delivered** | `is:closed type:Project` |

**What decided it was not feature count.** The report derives, so it cannot
drift, and that was its whole claim. The board turned out to derive too — every
column reads an issue field or an issue type through
`ProjectV2ItemIssueFieldValue`, so it is a view rather than a second store. Once
that was measured, the report's advantage was gone and the board's remained: you
can triage from it, and a row clicks through to the issue it describes.

**The views are pre-approved work with no record.** Owner, same message: *"we can
continue to tweak the project views as pre-approved work which doesn't need any
record."* A view is a saved filter over data that lives elsewhere; getting one
wrong loses nothing and is visible immediately. This is the clearest case yet of
[3.6](../../../../3.6-change-lifecycle.md) §2.2's *blast radius, not size*.

**The licence stops at the view.** Owner, same day: *"anything recorded against
issues which is used by the tooling needs to be documented and can't be changed
without a record."* A field, an option value, an issue type, a label or a
milestone lane is read by scripts that match it literally —
[4.8](../../../../4.8-artefacts.md) now lists which, and what each one breaks.

**One trap found and worth keeping.** An invalid view filter renders an **empty
view**, not an error — so a broken *Needs triage* filter is indistinguishable
from a clean backlog. The filter was proved by clearing one issue's
`Type of change`, watching it appear, and restoring it. Any view whose job is to
show a problem should be proved the same way.

**And issue fields are not searchable.** `type:Requirement` works in GitHub's
issue search; `Type of change` does not, in any syntax tried — one form returns
plausible-looking results that are simply wrong. Fields are readable through
GraphQL and project views only, which is why the board is now the only place
some questions can be asked.

#### Part 3 — release notes have a home

**2.5, the last of the six original questions: both, because they answer
different questions.** Owner, 2026-08-27: *"add `gh release create` to
`deploy.sh` and continue to maintain 4.9 as now."*

A **GitHub Release** hangs off a git tag and says *what shipped to players in
this version*. It is published by `deploy.sh` on the `prod-X.Y.Z` tag it already
pushes, with `--generate-notes`, so GitHub writes the changelog from the pull
requests merged since the previous release and nobody types it — a changelog
somebody has to remember to write is one that stops being written.

**`docs/4.9` stays the delivery log**, and is not replaceable by it: five of the
last six deliveries — `0.7.0a` to `0.7.0e` — shipped no code, so they have no tag
a release could hang on. The log answers *what did we put in front of anyone, and
when*.

| decision | why |
| --- | --- |
| `--notes-start-tag` when a predecessor exists | otherwise GitHub walks back to the first commit and the first release carries the whole history |
| the predecessor matched by **regex**, not the glob | a redeploy tag carries a timestamp suffix and would otherwise compete |
| **never fatal** | production is already serving by then; a failed changelog prints the command and the deploy exits 0 |
| **first-time tags only** | a redeploy would claim a changelog that already exists |

**It also answers #38** — *a download site for desktop builds, or a decision that
there isn't one* — because a Release takes file attachments, which is a download
site with no hosting to run.

The full account is in [3.3](../../../../3.3-testing-ci-and-release.md) §3.3.1.

## Part 5 — Impacted artefacts

*Provisional until the design is agreed.*

| artefact | new or modified | route |
| --- | --- | --- |
| `.github/workflows/docs.yml` — the `commands` job | modified, or **deleted** | repository |
| `scripts/actions.py` — reads the `approved` label | modified | repository |
| `scripts/pipeline.py` | **deleted** — Delivery 4, Part 2 | repository |
| `docs/3.6` §2.18 and §3.8 | modified | repository |
| `docs/4.8-artefacts.md` | modified — a configured Project, an organisation and a second account are all artefacts under change control | repository |
| `docs/4.9-delivery-log.md` | modified, if 2.5C | repository |
| the GitHub Project, its fields and workflows | new or modified | **service** |
| an organisation, if 2.2B | **new** | **service** |
| a second GitHub account and its token, if 2.3B | **new** | **service** |
| `.githooks/commit-msg` — the `Co-Authored-By` trailer | modified, if 2.3B | repository |

## Part 6 — Test approach

*To be agreed with the design.* What must be shown whichever option is chosen:

- the owner can approve from **every** client he uses, or is told plainly that a
  route does not work. **No command fails silently** — that is the defect, not
  which box works
- every attribute has **one** home, and it is written down which
- a report can show size, which today it cannot
- release notes exist in exactly one place
- a triage applied incompletely is **noticed** — by a check, or by the report
  disagreeing, but not by chance
- nothing stores change history. Owner, 2026-08-25: *"change history must be
  derived from git"*
