# Logs and backups: what we keep, where it lives, and how we know it works

The design for **project #174**, in the production operations workstream
(#189). It covers the project's two requirements — **R1** logs that survive a
deploy, and **R2** a database copy that survives the VM — because they answer the
same question about different data: *what survives, for how long, and who can
read it.* Issue #176 (nothing watches the disk) is adjacent and referenced where
it touches; it is not designed here.

**One design for the project**, per the owner, 2026-08-21: *"this is one project
and should have one design even if it covers multiple requirements and
deliveries."* The retention argument, the storage argument and the *expose a
condition, let OCI alert* argument are shared, so splitting would leave three
cross-references where there is now one document.

*Nothing here is built.* Reviewed on PR #177 and **provisionally approved**
2026-08-21.

## The state today, measured 2026-08-18

```text
container log lines, last 24h        2,922
  web  — Caddy admin API             2,858   (98%)
  web  — everything else                45
  server — the whole application        19

container log volume                 751 KB/day
journal (system logs)                43 M, capped at 50 M, oldest entry 9 days old
/var/log/syslog*                     5 weekly files, gzipped, ~1.3 M
production database                  1.7 M + 3.3 M WAL
pre-deploy snapshots                 5 files, 2.5 M, on the VM being protected
disk                                 45 G total, 5.7 G used (13%)
RAM                                  954 M, 437 M available
```

Four things are wrong, and they are independent:

1. **Container logs die at every deploy.** `json-file` writes inside the
   container; `deploy.sh` recreates it. Redeploying to fix a problem destroys
   the evidence of the problem.
2. **They carry personal data** — display names, and email addresses including
   those of people who are not users.
3. **They are 98% noise**, so nothing about their size means anything.
4. **Every copy of the database is on the machine that would be lost**, and the
   copies only happen when we deploy.

---

## Part 1 — What we log

### Identifiers only

> **Log identifiers, never names or addresses.** `player_id` and `game_id` are
> sufficient to diagnose. `scripts/admin.sh` resolves an id to a person on the
> rare occasion a human needs to know who it was.

Owner, 2026-08-18: *"Agree only ids stored. If we get an invalid email we don't
need to record it. If we have to diagnose an issue we can always add extra
logging for that specific purpose."*

That last clause is the part that makes the rule affordable: the logs do not
have to anticipate every investigation, because a targeted, temporary log line
is a one-line change and a deploy away.

#### What changes

| where | logs today | becomes |
| --- | --- | --- |
| `auth.rs:47` player registered | `player_id`, `display_name` | `player_id` |
| `auth.rs:101` player logged in | `player_id`, `display_name` | `player_id` |
| `auth.rs:71` login rejected | `display_name`, `reason` | `reason` only — the name may not be an account at all |
| `auth.rs:352` reset for unknown email | **the email address** | the event and nothing else |
| `email.rs:160/165/168` mail sent/failed | recipient address, subject | `player_id`, message kind |

Everything else in the server already logs identifiers only: `game_id`,
`player_id`, `invitation_id`, `seat`, `winner_seat`.

#### What we are not doing, and why it matters that it is written down

**No HTTP access logs exist today.** Caddy's `log` directive is not configured,
and the server's `TraceLayer` emits at `debug` under an `info` filter. So no IP
addresses and no request paths are recorded anywhere.

That is a decision by accident, and it should become one on purpose: **if access
logging is ever added, IP addresses are omitted or truncated**, and the same
rule applies to the client's URL, which carries game and player ids.

#### The limit of the claim

`player_id` is **pseudonymous, not anonymous** — we hold the table that resolves
it. This minimises what a leaked log is worth and shortens the retention
conversation; it does not put the logs outside data protection. Stating that here
so nobody later reads "ids only" as "not personal data".

### Where the events are written down

One place, as asked: **`docs/4.7-log-events.md`** — 4.x is reference, per the
numbering convention.

With JSON output the catalogue *is* the schema: for each event, the `target`, the
message, the level, and its fixed set of fields. That serves both readers — a
person looking for what a line means, and a parser needing to know what fields
exist.

**Keeping it true was the open question, and the owner's answer is better than
either option I offered.** Owner, 2026-08-21: *"Can we be a bit smarter? In the
document have the JSON schema in a form that can be compared mechanically to the
logs. Then the review just has to check that the schema and the documented fields
match, and if they don't then a reader can quickly see the gap."*

**The document becomes the artefact under test**, rather than something a test
tries to keep up with. The schema lives in `docs/4.7-log-events.md` as a fenced
`json` block; a test extracts that block and compares it against the fields the
code actually emits. Divergence fails CI, and the failure names the field.

| what I proposed | what this replaces it with |
| --- | --- |
| scan every `tracing::` call site and compare the *set of events* to the document | serialise each event and compare its **fields** to the schema the document declares |
| a source scan, fiddly and brittle — it must parse Rust to find what is logged | no parsing: the events are constructed in the test and rendered through the real JSON layer, so what is compared is **what would actually be written** |
| tells you an event is missing from the catalogue | tells you an event gained a field nobody documented — **which is the leak this part exists to prevent** |

The second row is why it is smarter and not merely tidier. A source scan proves
the *list* is complete; it says nothing about whether an event quietly acquired a
`display_name`. Comparing the rendered output to a declared schema catches
exactly that, and catches it on the commit that introduces it.

**And it makes review cheap, which was the stated goal.** A reviewer does not
read code to check the catalogue. They read two lists that a machine has already
proved identical, and the only judgement left is whether a documented field
*should* be there — which is the judgement a person is actually for.

*Not a new mechanism*: this is 3.3's rule — *wherever a rule can be checked by
the tooling, check it there* — applied to a document rather than to code, which
is the first time we have pointed it that way round.

---

## Part 2 — How we log it

### JSON, because "deserialise" was the requirement

`tracing_subscriber::fmt().json()` with `.with_ansi(false)`, selected by
environment so development keeps its colours:

```text
TILE_LITE_ELITE_LOG_FORMAT=json     set in docker-compose.yml and .preview.yml
unset                                human-readable, as now — cargo run, dx serve
```

Today's output is worse than merely unstructured: every field is wrapped in ANSI
escape sequences, because `fmt()` colours by default and nothing turns it off in
the container. Any parser has to strip them first.

**Caddy already emits JSON**, so this makes the two containers consistent rather
than introducing a new idea.

#### Human-readable is a rendering, not a second copy

One store, two readings — not two sinks, which would be two things to size and
rotate and two versions of what happened:

```text
journalctl CONTAINER_NAME=tile-lite-elite-server-1 --since "1 hour ago" -o cat \
  | jq -r '"\(.timestamp[11:19]) \(.level) \(.target) \(.fields.message) …"'
```

That reads better than what we have now, because what we have now is the same
line wrapped in eleven escape sequences. The filter goes in `docs/3.4` beside the
`game_id` recipe from #166.

The honest cost: `docker compose logs -f` while watching a deploy shows raw JSON
unless piped. That is the one moment the rendering is inconvenient.

#### Rejected: native journal fields

`tracing-journald` would make fields queryable directly (`journalctl GAME_ID=…`)
with no parsing at all. Rejected on the owner's instruction — *"I would rather
not tie ourselves into systemd to read the logs, json is more flexible"* — and
the reasoning is worth keeping: with JSON, systemd is only transport, and the
same bytes parse identically out of a file, a pipe or object storage if the
transport is ever replaced.

---

## Part 3 — Health checks

### Both services get a real one, and neither talks to the application log

Owner, 2026-08-18: *"We should have health checks for both the web site and the
api server. Health logs should not be in the same log file as application
events."*

#### What is wrong now

| | checks | logs |
| --- | --- | --- |
| server | `curl -f localhost:3000/health` | nothing — the server does not log requests |
| web | `wget --spider 127.0.0.1:2019/config/` — Caddy's **admin API** | every probe, at `info`: **2,858 lines a day** |

The web check is weak as well as loud: the admin API answering proves the process
is alive, not that the site serves. And it makes application events unfindable —
19 real lines hidden among 2,858.

#### What replaces it

**Point the web check at the site's own files** — but **not at the public site**,
which cannot be probed from inside the container at all. The `Dockerfile`'s own
comment already recorded why, and the design missed it: Caddy's global
HTTP→HTTPS redirect fires for any `Host` on `:80`, and the TLS handshake on
`:443` then fails because no certificate matches `127.0.0.1`. That is precisely
why the check had moved to the admin API in the first place.

**So the Caddyfile gains a loopback-only listener**, four lines, serving the same
root with the redirect disabled for that site alone:

```caddyfile
http://127.0.0.1:2020 {
    root * /srv
    file_server
}
```

and the health check probes `http://127.0.0.1:2020/version.txt`. It proves
routing, the file server and the static build — a broken static root fails it —
and it is **silent**, because access logging is off. Not published by
docker-compose, so it is reachable only from inside the container.

**What it deliberately does not prove** is the public path: TLS, the real
hostname, the redirect. Nothing running on loopback can, and the OCI health check
probes that from three regions, which is the only place it can honestly be proved
from.

**Built and verified 2026-08-21**, in a container with this Caddyfile:

| | |
| --- | --- |
| the probe passes | `wget --spider …/version.txt` → exit 0 |
| **a broken static root fails it** | a missing file → exit 1, which the admin-API check could never do |
| it is silent | **0 log lines** from the health listener over the run |
| the public site really is unprobeable from inside | `…:80/version.txt` → *connection reset by peer*, as the Dockerfile comment said |

The server's check already hits `/health` and already logs nothing.

That satisfies the requirement in its strongest form: health checks and
application events are not in the same file because health checks are not in a
file at all.

**Where the health record lives instead:** OCI's external check (#136) already
probes `/health` from three regions and keeps the history — the record we would
be writing locally, kept off the box, which is where a health record belongs.
Docker also keeps the last five probe results in
`docker inspect --format '{{json .State.Health}}'` for the local question.

If review wants health probes recorded locally anyway, the alternative is a
separate Caddy logger writing them under their own syslog identifier so they
land beside, not among, the application events — more configuration, and a record
that duplicates one OCI already keeps.

#### Why this is in the logging design at all

Because it decides every number in Part 4. Fixing it drops container output from
~750 KB/day to roughly 15 KB/day. Sizing the journal before fixing it means
sizing it for a `wget`.

---

## Part 4 — Where logs live, and for how long

### journald as the transport, with the ceiling raised as a backstop

```yaml
# docker-compose.yml and docker-compose.preview.yml, both services
logging:
  driver: journald
```

```ini
# /etc/systemd/journald.conf.d/zz-tile-lite-elite.conf
[Journal]
SystemMaxUse=100M
MaxRetentionSec=7d
```

**Why journald.** The store belongs to the host, so it survives the container
recreation that discards everything today; it already runs, already persists to
`/var/log/journal`, and already rotates. Its rate limit (10,000 messages per 30
seconds) is four orders of magnitude above our traffic.

**Why 7 days.** Owner: *"7d is more than sufficient… although we could increase
the retention period if we needed longer to investigate a particular issue."*
Retention is a knob, and this is where it is set.

**Why 100 M when 7 days needs about 100 KB.** Purely as a backstop. If volume
grows, the *size* cap binds before the age rule and retention silently drops
below the seven days without anything saying so. 100 M keeps seven days true up
to about 14 MB/day. The existing cap is 50 M and was set deliberately — see
below — so this doubles it rather than removing it.

#### The 50 M cap, and why it is being changed rather than deleted

`/etc/systemd/journald.conf.d/50-cap.conf` sets `SystemMaxUse=50M`. It was
written on 2026-07-30 during housekeeping, for a real reason: *59 MB of logs on
a 954 MB box, and journald grows its own footprint with the journal it maps.* The
box still has 954 MB.

The memory cost of a larger journal is file-backed page cache, which the kernel
reclaims under pressure — so 100 M is a bounded, reclaimable cost rather than
anonymous memory. That is the argument for doubling it; it is not an argument for
removing the cap.

**It is also the best example this workstream has of the problem in Part 6:** a
production setting that would have silently defeated the requirement, made by
hand three weeks ago, recorded nowhere.

#### `/var/log/syslog` stays on

`ForwardToSyslog=yes` is already set, so everything journald receives is also
written to `/var/log/syslog`, rotated weekly by logrotate, four kept and gzipped
— about five weeks in plain files, readable with `grep`, `zgrep`, `zcat | jq` and
anything else that reads a file. **No `journalctl` required**, which is the
non-systemd path the owner asked for, and it costs about 1 MB/day on a 13%-full
disk.

**One point for review.** The journal keeps 7 days and syslog keeps ~5 weeks.
Those agree only if "7 days" means *enough for diagnosis*. If it means *we do not
keep logs about people for longer than a week*, logrotate must match — `daily`,
`rotate 7` — and the difference is a promise versus a capacity choice.

#### Reading, after the change

| question | command |
| --- | --- |
| what is happening now | `docker compose logs -f server` (unchanged) |
| what happened before the last deploy | `journalctl CONTAINER_NAME=tile-lite-elite-server-1 --since "3 days ago"` |
| human-readable | the `jq` filter above |
| without systemd | `zgrep … /var/log/syslog*` |

`docs/3.4:246` says logs are `docker compose logs server` today. That is true only
for the running container — compose can only show containers that still exist,
under any driver — so the document gains the `journalctl` form.

---

## Part 5 — Backups (#175)

### The database is the only irreplaceable thing

Everything else on the VM rebuilds: images come from a `docker save` bundle the
deploy carries, the compose file and Caddyfile are in git, Caddy's certificates
re-issue from Let's Encrypt. **`/data` is the only state that cannot be
regenerated**, which keeps the scope small.

### Snapshot files, not volume images

A block-volume backup is *crash-consistent* — the bytes as they are at that
instant, mid-checkpoint if that is when it lands, with 3.3 M currently sitting in
the WAL. SQLite recovers from that most of the time, and "most of the time" is
not a property to want on the day you need it.

The owner's observation settles it: *"we can take local snapshots as easily as
remote ones, and the local snapshots should not be corrupt."* So the thing we
ship offsite is a **snapshot file**, taken the way `deploy.sh` already takes one.

Volume backups remain useful for rebuilding an *instance* quickly; they are never
the database's source of truth.

### Daily, consistent, verified, generational

```bash
sqlite3 /data/tile-lite-elite.sqlite3 "VACUUM INTO '/tmp/backup.sqlite3'"   # consistent, no downtime, compacted
sqlite3 /tmp/backup.sqlite3 "pragma integrity_check"                        # expect: ok — costs a second at 1.7 M
# on ok:   upload
# on fail: alert, and keep the previous upload
gzip -c /tmp/backup.sqlite3 | curl -T - "<pre-authenticated request URL>"
```

- **`VACUUM INTO`, never `cp`.** `cp` under a hot WAL is the classic way to get a
  backup that restores to a corrupt database.
- **Verify before uploading**, because at this size verification is free and it
  turns "we have backups" into "we have backups that open".
- **Generational, not one slot** — 7 daily plus 4 weekly is about 7 MB at
  today's size. A corruption that goes unnoticed for three days must not have
  eaten every good copy.

### Where it goes

**OCI Object Storage**, written with a pre-authenticated request URL so the VM
needs no OCI CLI and holds no credentials beyond the URL itself.

| rejected | why |
| --- | --- |
| the Rehearsal VM | owner: *"a backup solution that doesn't repurpose another VM"* — and it is #40, production user data on the public-IP box, made nightly. Same tenancy, same region |
| the development laptop | owner: *"my laptop is not part of the production service"* |
| volume backup as the primary | crash-consistent, above |

#### The bucket, and the credential

Settled 2026-08-21, and **measured rather than assumed** — the console questions
this section used to carry are answered below.

| | |
| --- | --- |
| namespace · bucket | `axbbaaptgyab` · `tile-lite-elite-backups` |
| region · compartment | `uk-cardiff-1` (UK West, Newport) · `stephenmor (root)` |
| tier · visibility | Standard · private |
| **credential** | a **bucket-scoped PAR, access type *permit object writes*, object listing off** |
| **on the bucket** | **object versioning on** |

**The credential cannot destroy what it writes**, and that is the whole point of
choosing it. Tested from the production VM on 2026-08-21 against a throwaway
seven-day PAR:

```text
PUT     200  (0.128s)     upload works, and the VM reaches object storage
GET     404               a write PAR cannot read
LIST    404               a write PAR cannot list
DELETE  404               a write PAR cannot delete
HEAD    404               it cannot even confirm an object exists
PUT2    200               but it CAN overwrite an existing name
```

So the threat this whole part exists to answer — *the VM holds the credential,
so whatever can upload can also destroy* — does not apply. An attacker on the
box, or a bug in our own script, cannot delete a backup. Oracle's documentation
says so (*"pre-authenticated requests can't be used to delete buckets or
objects"*) and the 404 above is that sentence observed.

**Three consequences worth stating, because none of them is obvious:**

- **the refusals are 404, not 403.** Object Storage will not distinguish *"you
  may not"* from *"there is nothing there"*, so a leaked write-only URL reveals
  nothing about the bucket's contents — not even whether a guessed name exists
- **overwrite is the one remaining way to damage a backup**, and it returned
  200. **Object versioning is therefore not optional and is also sufficient**: a
  `PUT` over an existing name creates a version and the original bytes survive.
  A retention rule adds nothing against *this* threat — only against a mistake
  made from the console with real credentials
- **revocation is immediate.** Deleting the PAR in the console turned the same
  `PUT` into a **401** on the next attempt. So if the VM is ever compromised,
  one click in the console stops the bleeding without touching the instance

**The restore path is therefore asymmetric by construction.** The VM can write
backups and cannot read them; restoring is done from the console or a laptop
with real credentials. That is a feature and not an inconvenience — it means no
credential on the production host can be used to exfiltrate the database.

#### Capacity, and expiry

**Capacity is a non-issue**, measured 2026-08-21: the production database is
**1.7 MB**. A year of daily backups is ~620 MB uncompressed, against an Always
Free allowance of **20 GB combined** across Standard, Infrequent Access and
Archive — under 1%. The tenancy's *service* limit reads `Unlimited`, which is a
different thing from the free allowance and is the reason a **retention rule
matters as policy** even though capacity does not: an unbounded loop against an
unlimited limit is the one way this turns into a bill.

**Expiry has no maximum.** Oracle: *"Expiration date is required, but has no
limits. You can set them as far out in the future as you want."* So the original
worry — a URL that quietly expires two months after it is built — is ours to
create or avoid, and the opposite one replaces it: a PAR set twenty years out is
a permanent bearer credential nobody revisits.

**The answer is an alarm rather than a long date.** A deliberate expiry recorded
in `docs/3.4`, and the upload alerting on failure, so an expired PAR announces
itself the next morning instead of being discovered when the database is gone.

### Restoring, which is the part that is currently a hypothesis

`rollback.sh` restores a snapshot into a *running* deployment, so that path is
proven. **Restoring onto a new instance is not**, and a backup strategy is a
hypothesis until it has been done once. That drill is part of this work, not a
follow-up: build a throwaway VM, restore the newest backup, confirm the site
serves and the data is there.

---

## Part 6 — The half that does not travel

The compose `logging:` block is in the repository and rides the deploy. The
journald drop-in, the logrotate stanza and the backup job are **VM
configuration** — they do not travel, and a rebuilt host loses them silently.
`50-cap.conf` is the proof: it has shaped production for three weeks and the
repository has never heard of it.

**Ship the files, check them at deploy, apply them from documentation:**

```text
deploy/journald.conf.d/zz-tile-lite-elite.conf     in the repository
deploy.sh → ssh 'systemd-analyze cat-config systemd/journald.conf'  → compare, fail loudly
docs/3.4                                            how a new host gets them
```

Checking is cheap and failing loudly is the whole point. *Applying* on every
deploy would widen `deploy.sh` into host configuration management and would need
`systemctl restart systemd-journald` in the middle of a release.

**A filename trap worth recording:** journald drop-ins are ordered by filename
across all directories, and `/etc` beats `/usr` only for the *same* name. A file
called `99-tile-lite-elite.conf` sorts **before** the vendor's `syslog.conf`
(`9` < `s`) and loses. Hence `zz-`.

---

## Part 7 — Aggregates and capacity (adjacent, #176)

Recorded here because it came out of this discussion and the design must not
contradict it; the work belongs to #176.

**Aggregates outlive the detail, and they do not come from the logs.** #90
already built the mechanism: `database_size_history`, one row per day, in the
database — so it is snapshotted before every deploy, restored by rollback, and
covered by Part 5. It gains columns rather than a new system: disk used and free,
error counts by level, and the sweep counters #166 wants.

**The trap:** the server can measure `/data`'s filesystem from inside the
container, but **cannot see the journal or `/var/log`** — those are outside its
namespace. Log size therefore comes from the report at read time on the host, not
from the daily writer.

**The report derives; the table stores.** Green/amber/red is computed from
thresholds that live in one place, exactly as `roadmap.sh` derives rather than
maintaining. The alert is a flag meaning *look at the capacity report*.

**Where the flag goes.** #166 also needs to expose a condition (sweep freshness).
Two conditions now, a third later, argues for one endpoint carrying named
conditions with a severity each — `/status` — rather than fields accreting on
`/health`, which **LIMIT-4** requires to stay a liveness probe that answers while
everything else refuses.

---

## Part 8 — Test approach

Named as such under D17: a **test approach** states the environment, the tools,
and what is measured against what criteria. It is not a test plan — the standards
reserve that for a management document of scope, schedule and resources, which a
one-developer project does not write.

### The two questions every delivery answers (D15)

| | |
| --- | --- |
| **does this involve functional changes that require user testing?** | **Barely.** Almost nothing here is visible by using the site. The one exception is the health-check change, whose user-facing test is *the site still serves* — which the smoke test already asserts. So preview has very little to look at, and this is the release where `DEPLOY_SKIP_PREVIEW` is close to honest rather than convenient |
| **does this involve technical changes that require technical testing?** | **Almost entirely.** Output format, journal retention, a credential's permissions, a restore from cold. None of it can be judged by a person using the application, and most of it needs production-like hardware or a real host |

**Which is the useful finding**, not a formality: this project's evidence is
nearly all technical, so the effort belongs in rehearsal and in CI, and the
preview step should not be padded out to look busy.

### Environment and tools

| where | what it judges | tools |
| --- | --- | --- |
| **CI** | the log schema matches what the code emits; nothing regressed | `cargo test`, and the new schema-comparison test below |
| **preview** | the stack comes up, logs are readable, a deploy does not discard them | `deploy-preview.sh`, `journalctl`, `jq` |
| **rehearsal** | the things needing a real host: journald retention, the backup upload, the alarm | `journalctl --disk-usage`, `curl`, the backup script itself |
| **a throwaway instance** | the restore, which is the only claim that cannot be tested anywhere else | a fresh VM, the newest backup, and a browser |
| **production** | that the failure alarm actually fires | OCI, and a deliberately broken upload |

### Test tooling this builds

**Two new things, and both are artefacts** (D25). Asked by the owner,
2026-08-21: *"do the artefacts include any scripts written to execute the tests
described in section 8?"* — one was listed, one was not.

**1 · The log-schema comparison test.** Renders every log event through the real
JSON layer and compares the field names against the schema declared in
`docs/4.7-log-events.md`. Owner's idea: *"in the document have the JSON schema in
a form that can be compared mechanically to the logs."*

It is the control that makes *identifiers only* durable rather than aspirational —
a source scan proves the list of events is complete and says nothing about an
event quietly acquiring a `display_name`. This catches that on the commit that
introduces it.

#### How the test gets at what the code emits — read the real logs

Owner, 2026-08-21: *"I was thinking the test would use a recent log file, or even
run through all the log files if that didn't take too long. Are the log files
accessible?"*

**Yes, and it is a better answer than either option I offered.** Both of mine
compared the document to something *modelled* — a test restating the fields, or a
typed module the test drives. His compares it to **what was actually written**,
which is the only thing that cannot be wrong about itself. And it needs no
refactor at all.

**Accessible, and cheap.** Measured on production, 2026-08-21:

| | |
| --- | --- |
| lines available | **12,539**, back to `2026-08-17T13:36:28Z` — the moment the last deploy recreated the containers |
| time to read them all | under a second. *"If that didn't take too long"* turns out not to be a constraint |
| how | `docker compose logs` over ssh today; `journalctl CONTAINER_NAME=…` once Delivery 1 lands, with seven days' retention |

**Those are today's numbers, and this project changes two of them** — which is
the owner's point, 2026-08-21: *"I thought part of this project was to remove
health messages from the log files, and to ensure we didn't lose the log files
after a redeploy?"* It is, and both land in Delivery 1:

| | today | after Delivery 1 |
| --- | --- | --- |
| **health-check noise** | 2,858 of 2,922 lines a day | **none** — the probe is silent |
| **how far back the log goes** | to the last deploy, which was four days ago **by luck** | a rolling **seven days**, whatever deploys happen |

**So I framed the coverage argument wrongly.** *"Only 69 of 12,539 lines"* is a
signal-to-noise figure, and I used it as if it were a coverage figure. Noise does
not hide events from a script — it only makes the file bigger, and a script does
not squint. The two are different problems and this project fixes the one I
quoted while the other stands.

**What actually limits coverage is that rare events are rare**, and retention
helps rather than solves it:

| | |
| --- | --- |
| events per day | about **16**, measured — 30 `app::games`, 21 `app::sweeps`, 11 `app::auth`, 6 elsewhere, over 4.2 days |
| a nightly run therefore sees | ~16 events, from perhaps eight or ten types |
| a seven-day window sees | ~115 — **better, and reliably seven days rather than however long since the last deploy**, which is the retention half genuinely paying |
| what it still will not see | *password reset requested for unknown email*, *token expired*, *email send failed* — the paths that fire when somebody mistypes an address or a provider has a bad afternoon |

**And those are the events most likely to carry something they should not**,
because they are the ones nobody looks at. Which is why the second half below
exists — not because the log is noisy, but because waiting for a rare event is
not a test.

##### So: the regression suite drives it, and production only reads

Owner, 2026-08-21: *"the production check should just check the production logs,
and write its own exception log. Our normal regression tests will generate all of
the log messages anyway, so running the check as part of CI should cover it."*

**Both halves are right, and together they delete a script I was about to
write.** I had `check-log-hygiene.sh` driving register, login, failed login,
reset and invitation against a live stack to reach the rare paths. **The
regression suite already drives them, better**, and it runs on every push:

| path | tests that reach it |
| --- | --- |
| registration | 135 references |
| invitations | 100 |
| login, including *an unknown name still pays for a password check* | 34 |
| password reset — and the rare branches by name: `rejects_an_unknown_token`, `rejects_an_expired_token`, `rejects_a_token_already_used_once` | 30 |

**Those are exactly the events a week of production would not show**, and the
suite reaches them every single run. Driving them a second time from a shell
script would be a worse copy of a thing that already exists.

**And driving flows against production was never right anyway** — it would create
accounts and send real email to reach a code path. The owner's split is the
correct one: **CI drives, production reads.**

| where | what it does |
| --- | --- |
| **CI** | run the suite with the JSON subscriber capturing to a file, then validate every captured line against the schema. Fails the build on a field `4.7` does not declare |
| **production** | nightly, read the day's journal, validate, and **write its own exception log**. It creates nothing and touches nothing |

**The exception log rather than an alert** is the same instinct as D5's
rejection of email: a channel that fires rarely and is read
never is not a control. Exceptions accumulate somewhere greppable, and
`status.sh` surfaces a non-empty one the way it now surfaces failing document
checks — where somebody is already looking.

**What is left uncovered** is honest and small: error branches needing an email
provider to return 500 or a database to fall over. Those carry `error` and
`status`, not names or addresses, and forcing them is more machinery than the
risk deserves.

**The unit test stays, and shrinks** to the one assertion that needs no logs at
all — that every object in the schema sets `additionalProperties: false`. That is
the meta-check, and it belongs in CI where it costs nothing.

##### And on production it runs nightly

Owner, 2026-08-21: *"if this is a nightly check, say, then it could do that day's
files. Or it could be more frequent."*

**Nightly, over the day's journal**, as a **category 3** artefact — triggered, on
a schedule, by a systemd timer beside the backup's. Same mechanism, same
delivery, and it turns the coverage argument round: any event that occurs on any
day is validated that night, so over a month the check has seen everything
production actually does, rather than everything a test thought to try.

**Why not more frequent.** Three reasons, and the third is the one that decides
it:

- **the day's volume is trivial** — about nineteen application lines once the
  health check stops shouting, so an hourly run reads almost nothing
- **the check is retrospective by nature.** Whatever it finds is already written;
  no frequency prevents the first leaked line. What a check buys is stopping it
  *continuing*, and a day is fast enough for that
- **an hourly check that alerts would fire twenty-four times for one leak.** A
  control that repeats itself becomes noise, and noise is what stops a channel
  working — the same reason D5 rejected
  email as a channel

**It alerts the way production already alerts**, through the same OCI mechanism
as the backup, rather than inventing a channel nobody reads.

**And the check only works because of what the rest of the project does.** It
reads a **seven-day** window rather than *"since whenever we last deployed"*, and
every line in it is a real event rather than one in forty-five. Neither is true
today. **The project builds the thing that verifies it** — which is worth
noticing, because it means Delivery 1 has to land before the check is worth
installing, and the ordering in Part 9 already has it that way.

##### A correction: the logs are not backed up

I wrote, when guarding the email body, that an unset API key would put reset
links *"into a log we are about to copy off the box nightly."* **That is wrong.**
Part 5 is explicit that `/data` is the only thing backed up — the database. The
logs stay on the host and expire after seven days.

The guard is still right, and for reasons that survive the correction: a log with
seven days' retention is seven days of reset links on a public-facing box, and
the journal is readable by anyone who can read the host. But the argument I gave
was inflated, and an inflated argument is worse than a plain one, because the
next person to check it stops trusting the ones around it.

#### Where the schema lives

Owner, 2026-08-21: *"presumably that will live outside the document and be
included, like diagrams? I am thinking it needs to be accessible by the test
script."*

**The diagram analogy does not carry, and the reason is worth stating.** A
diagram has a real asymmetry: `.mmd` is the source, `.svg` is a build artefact
nobody could author by hand, so two files with a re-render step is the only
option. **A JSON schema has no such asymmetry** — the JSON is the readable form.

And markdown has no include: a document cannot pull in a file, only *link* to it
or *contain* it. So the three real options are:

| | | |
| --- | --- | --- |
| **the schema is a fenced block in `docs/4.7`, and the test extracts it** | one copy, authoritative, and **visible where it is reviewed** | the test parses markdown — about five lines |
| a `.json` file the document links to | one copy, trivially readable by the test | the reader has to open another file to see the thing they are reviewing |
| a `.json` file copied into the document, with a check that they match | both, at the cost of a generator and a gate | two copies, which is the arrangement this project keeps deciding against |

**Recommended: the first.** The schema has to be *in* the document, because
reading it **is** the control — the test proves code and document agree, so if
the document is a link nobody follows, the whole arrangement checks that the code
agrees with something unread.

**One practical detail, because the obvious version breaks.** The extractor must
not be *"the first ```json block"* or *"the only one"* — the first example added
to that document silently becomes the schema. The block carries an explicit
marker:

```text
<!-- log-schema -->
~~~json
{ ... }
~~~
```

so the test fails loudly with *"no block marked `log-schema`"* rather than
quietly validating against an example.

##### Which direction the inclusion runs

**Nothing is included into the markdown.** The document is a plain file that a
person reads; the *Rust test* reaches into it. `include_str!` is a Rust macro,
not a markdown feature — markdown has no include at all, which is why the schema
is contained in `docs/4.7` rather than pulled into it.

```text
docs/4.7-log-events.md      the schema, in a marked fenced block — the source
        ↑
        │ include_str! at compile time
        │
crates/server-game/tests/   extracts the block, parses it, compares it to what
                            the code actually emits
```

**And the test embeds the document at compile time.** `include_str!` takes a
**string literal that is a path** — it reads the file while compiling and embeds
the contents as a `&'static str`. The literal is required: it cannot be a
variable, and the path resolves relative to the source file containing the macro,
not to the crate root or the working directory.

Which makes the plain form brittle — `include_str!("../../../docs/4.7-…")` moves
if the test file does — so it is anchored to the crate instead:

```rust
const EVENTS_DOC: &str =
    include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs/4.7-log-events.md"));
```

`concat!` and `env!` are expanded before `include_str!` sees them, so this is
still a literal by the time it matters.

**Verified rather than assumed**, 2026-08-21, in a scratch crate:

| claim | observed |
| --- | --- |
| a missing file fails the **build**, not the test | `error: couldn't read …/nope.txt: No such file or directory` |
| editing the included file triggers a rebuild | `Compiling inc v0.1.0` on the next `cargo build` |

The second is the one worth checking: without it the test would keep validating
against a schema embedded weeks ago, which is precisely the staleness this whole
arrangement exists to prevent.

*One caveat seen while testing it*: cargo's change detection is mtime-based, and
an edit made in the same second as the previous build can be missed. General to
cargo rather than to `include_str!`, and it resolves itself on the next build.

#### Getting the schema right, and the field that must not be optional

Owner, 2026-08-21: *"I presume amending the JSON schema would be straightforward,
Rust would report parsing errors? It may take a few iterations to get the schema
right. Also we would need to disallow unexpected fields
(`additionalProperties: false`)."*

**Yes, and the loop is `cargo test` rather than a deploy.** A malformed schema
fails the test with `serde_json`'s line and column, not with something vague — and
parsing into a **typed** structure rather than `serde_json::Value` makes the
errors better again: *"missing field `properties`"* beats *"expected object"*.
`serde_json` is already a dependency of `server-game`, so the iterating half
costs nothing.

##### `additionalProperties: false` is the whole point, so the test checks it too

**Right, and it is the one line that carries the guarantee.** Without it a schema
happily validates an event that has gained a `display_name`, which is precisely
the leak this test exists to catch — the schema would pass and the log would be
wrong.

**Which makes forgetting it on one object the real risk.** JSON Schema is
permissive by default, so the property has to be repeated on every event, and a
single omission is a silent hole in exactly the place nobody looks.

**So the test asserts it about the schema, not only with it:**

| the test does | catches |
| --- | --- |
| validate each emitted event against its schema | a field that appears in the code and not the document |
| **assert every object in the schema sets `additionalProperties: false`** | **a schema that has quietly stopped guarding** |

The second is four lines and it is the difference between a control and the
appearance of one.

##### Existing tooling for the standard part, our own only for the policy

Owner, 2026-08-21: *"it must be less maintenance to use existing JSON schema
tooling than writing our own tooling."* Agreed, and it is the same instinct as
issue #160, and as the morning `check-docs.sh` grew a second copy of CI's
markdown lint.

**But taken absolutely it removes the meta-check**, and the meta-check is the
thing that closes the hole. So the line is:

| | who does it |
| --- | --- |
| validate an event against a schema | **a library** — `jsonschema` is the obvious candidate. Draft handling, `$ref`, error paths: all solved, none of it ours |
| assert every object sets `additionalProperties: false` | **us, in four lines** — it is a policy about *our* schema, and no validator has an opinion about it |

**Use the library for the standard part and write only the policy the library
cannot express.** That is a narrower rule than *"don't build tooling"*, and it is
the one that survives contact with cases like this.

##### And the schema stays hand-written, which is the maintenance worth having

The tempting next step is `schemars` — derive the schema from the Rust types and
stop maintaining it by hand. **It would make the test worthless.**

The test's value is that the schema is an **independent statement** of what may be
logged. Generate it from the code and the test compares the code to itself: it
passes on the commit that adds `display_name`, because the schema gained the
field at the same moment. The green tick would be the strongest evidence
available, and it would mean nothing.

**So writing the schema by hand is not a cost to optimise away — it is the
control.** Ten-odd events, each a handful of field names, changed only when
logging changes. The same reason a test derived from the code proves nothing
about whether the code is right.

**The alternative, considered and not taken:** a plainer declaration — event name
to a list of field names — compared by **set equality**, which has the same
property by construction and needs no `additionalProperties` at all. It is
smaller, and it was rejected because JSON Schema is the standard form, expresses
types as well as names, and the meta-check above closes the only gap that made
the simpler option attractive.

**Its limit, which matters:** it proves the code and the document **agree**, not
that the document is **right**. A `display_name` added to both would pass. The
control for that is a person reading `docs/4.7` — so the schema is not a field
list to skim in review; it is the thing being reviewed.

**2 · A project test script**, `scripts/check-log-hygiene.sh`. Owner,
2026-08-21: *"I see a new test that will run in production, but not one for the
project testing."* Right — the restore script is an **operational** tool that
outlives the project, and the tests that prove *this project's changes work* had
no script at all. I had written them off as one-off confirmations, and three of
them are not.

Run against a preview or rehearsal stack, it asserts:

| claim | how |
| --- | --- |
| **every line is machine-readable** | `journalctl -o cat` over the run, each line through `jq -e .` |
| **no personal data remains** | drive register · login · failed login · reset · invitation, then fail on an `@`, or on the display name used, anywhere in what was written |
| **logs survive a deploy** | deploy twice, assert the oldest entry predates the second deploy |

**The middle row is the one that earns the script.** It is the most important
claim in the project — it is why the offsite copy is safe to make — and by hand
it is a grep and a squint at the right moment, which is exactly the check that
rots. `check-rate-limits.sh` is the precedent: a script written to test a change,
run against rehearsal, kept afterwards because the claim it asserts stays true or
stops being true.

**3 · A restore script**, which the artefact list was also missing. Part 5's drill —
build a throwaway VM, restore the newest backup, confirm the site serves — was
written as a one-off, and a one-off restore proves the backup worked **once**. Six
months later it is a hypothesis again.

So the scriptable half becomes a script: fetch the newest object, verify it
opens, load it into a fresh volume and report. **The VM provisioning stays
manual** — it is a handful of console clicks and scripting it would be building a
deployment tool to test a backup.

That makes the drill re-runnable at each release, or quarterly, at the cost of
one command — and it is the difference between *"we restored it in August"* and
*"we restore it routinely."*

### All three are kept, and each says when it runs

Owner, 2026-08-21: *"are these new scripts temporary or will we keep them after
the project?"*

**All three are kept, and none of them is in the first category.** Against the
three categories in `docs/3.6`:

| script | category | when it runs | **what fires it** |
| --- | --- | --- | --- |
| the schema comparison test | **2 · regression** | every push | CI. Nobody decides |
| `check-log-hygiene.sh` | **3 · triggered** | in the release path, when a release touches the server's logging or auth paths | **a deploy gate**, conditional on the changed paths — to be built with it |
| `restore-backup.sh` | **3 · triggered** | quarterly, and after any change to the backup mechanism | **nothing yet** — see below |

**Neither is category 4**, which is where I had put them. The distinction the
owner drew is between a test something can fire and a test somebody has to
remember, and both of these have a real trigger available.

**`restore-backup.sh` has no trigger yet, and that is the honest gap.**
*"Quarterly"* with nothing scheduling it is category 4 wearing category 3's
clothes — and the year nobody notices it has not run is the year the backup does
not restore. Three ways to fire it, cheapest first:

| | |
| --- | --- |
| **an OCI alarm on the age of the newest *verified* restore** | the backup script writes a marker object on a successful drill; the alarm fires when it is older than 100 days. Uses machinery already built for #136, and it alerts rather than reminds |
| a calendar reminder | works, and depends on one person reading it |
| every Nth release | ties an interval to a cadence that varies, so it means nothing in a quiet quarter |

**Recommended: the alarm**, and it goes in the same delivery as the backup
alerting, because it is the same mechanism pointed at a different object.

**This project produces nothing in the first category** — no one-off migration
check, nothing true once. Worth stating rather than leaving to be inferred from
an absence.

**Why neither is category 2, since anything outside it owes that reason:** both
need a **running stack on real hardware**. `check-log-hygiene.sh` drives auth
flows and then reads the host's journal; `restore-backup.sh` needs somewhere to
restore *to*. Neither can run on a CI runner as things stand.

**And the first of those reasons could stop being true.** The e2e suite already
stands up the preview stack in CI, so if the journal became readable from there,
`check-log-hygiene.sh` belongs in the second category and should be moved — the
personal-data claim is important enough that *"somebody remembers to run it"* is
the weakest acceptable answer, not the preferred one.

**Saying when each runs is not bookkeeping.** A kept script with no trigger
becomes a script nobody has run since the release it was written for — and that
is *worse* than not having it, because it reads as coverage. The repository would
show a test for personal data in the logs, and the logs would have personal data
in them.

**What stays manual, and why.** Stopping the server to prove the health check
fails, and pointing the uploader at a bad URL to prove the alarm fires: both are
destructive one-offs against a live stack, confirming a mechanism rather than a
property. Retention — *seven days is still seven days* — is checked a week after
landing, which no script run during the project can do.

### What is measured, against what criteria

| claim | how it is shown |
| --- | --- |
| the server starts and logs under the new format | preview stack up, `journalctl CONTAINER_NAME=…` returns lines |
| every line is machine-readable | `journalctl -o cat \| jq -e . >/dev/null` over a run |
| no personal data remains | grep the audit's five call sites; a preview run through register / login / failed login / reset / invitation, inspecting what was written |
| logs survive a deploy | deploy preview twice, read across the boundary |
| retention is what we set | `journalctl --disk-usage` and the oldest entry, a week after landing |
| the health check still detects a broken site | stop `server`, confirm the web check fails; break the static root, confirm it fails |
| the backup restores | the new-instance drill in Part 5, run by the restore script |
| the daily backup keeps running | the failure path alerts — tested by pointing it at a bad URL |

| **the log schema and the code agree** | the new test, in CI, on every push |
| **no address or display name reaches the log** | `check-log-hygiene.sh`, against preview and again against rehearsal |
| a leaked write-only credential cannot destroy a backup | **already shown**, 2026-08-21, from the production VM: `PUT 200`, `GET 404`, `LIST 404`, `DELETE 404`, `HEAD 404`, and `401` after revocation |

The existing test suites should pass unchanged; nothing here touches game logic.

---

## Part 9 — Deliveries

**Three deliveries, each an ordered sequence rather than a set** (D22), because
a host step assumes the artifact already deployed and a service step assumes the
host script exists to use it.

**It was two until 2026-08-23**, when the restore drill was split out of
Delivery 2. Owner: *"We can make the restore drill a 3rd delivery and update the
scopes… better to close down what we have done tonight as a completed delivery
than have it split over days."* The drill needs a read pre-authenticated request
created in the console, and everything before it was finished and proven — so
holding Delivery 2 open overnight would have left a delivery nobody could point
at and say what it contained.

| | id | what | |
| --- | --- | --- | --- |
| **1** | `0.7.0` | logging and health | 2026-08-22 |
| **2** | `0.7.0a` | backups running | 2026-08-23 |
| **3** | `0.7.0b` | the restore drill | 2026-08-24 |

The lettered identifiers are D34: a delivery that ships no application code
takes the production version plus a letter, and is closed by hand — `deploy.sh`
reads its milestone from `Cargo.toml`, so a lettered milestone can never be
matched by a deploy. Recorded in `docs/4.9-delivery-log.md`.

### Delivery 1 — logging and health

**Four deploys, not eight.** Owner, 2026-08-22, on the two-round shape the
documents implied: *"that is a better balance. It is more work if we hit an issue
in Rehearsal, but that is unlikely since we have already tested things there and
in preview."* The trade is stated because it is real: a problem found in
rehearsal means fixing on the branch, re-merging and re-testing. It is accepted
because preview from the branch has already exercised the same tree.

#### 0 · Pre-flight

```bash
# The work is on a branch; deploy.sh builds a commit of main.
git rev-list --count issue-174-logs-and-backups..main    # must be 0, so the
#                                                          merge is a fast-forward
#                                                          and the tested commit
#                                                          IS the shipped commit

# minor-function, so a MINOR release. Dev is 0.6.3; this is 0.7.0.
# Create milestone 0.7.0 and put #174 in it — deploy.sh closes the milestone's
# issues, so the milestone is the shipping list.
./scripts/check-release-version.sh 0.7.0     # "functional change is expected"
```

Then bump the workspace version to `0.7.0` and commit it on the branch.

#### 1 · Preview, from the branch

**Not a gate — a cheap look before anything reaches `main`.** Two things here can
stop a container starting: the new health check, and the journald driver.

```bash
./scripts/deploy-preview.sh at prod                       # today's production code
./scripts/deploy-preview.sh at issue-174-logs-and-backups # the switch happens here
./scripts/deploy-preview.sh at issue-174-logs-and-backups # and now the real test
```

**The middle deploy loses the log, correctly and once** — the lines before it
were in the old driver's file, inside a container that dies. The third deploy is
where *logs survive a deploy* becomes demonstrable.

```bash
journalctl CONTAINER_TAG=tle-preview-server -o cat | jq . | head
journalctl CONTAINER_TAG=tle-preview-web --since "5 min ago" | wc -l   # ~0: silent
TILE_LITE_ELITE_LOG_CAPTURE=/tmp/c.jsonl cargo test -p server-game --quiet \
  && python3 scripts/check-log-hygiene.py /tmp/c.jsonl
```

#### 2 · Merge, fast-forward only

```bash
git checkout main && git merge --ff-only issue-174-logs-and-backups && git push origin main
```

**`--ff-only` rather than our usual written merge commit**, because a merge
commit changes the sha and the commit tested would stop being the commit shipped.
The branch's own messages carry the story. **The branch is not deleted** —
Delivery 2 is still to come, and D24 keeps it until the project is live.

Wait for CI on `main` before going further: `./scripts/ci-status.sh --run push:main --wait`

#### 3 · Preview, from `main` — the user testing

```bash
./scripts/deploy-preview.sh          # HEAD of main
```

**There is almost nothing to look at, and that is the honest answer** (D15).
Nobody can see JSON logging or a health probe. What a person judges here is that
**the site still serves** — which is exactly what the health-check change could
break.

#### 4 · Rehearsal — the host step first, then the deploy

**The drop-in is rehearsed before production sees it.** A host step applied for
the first time on production is the one part of this delivery nobody has
practised — and rehearsing it found two defects in this runbook, below.

```bash
ssh tile-lite-elite-rehearsal 'sudo mkdir -p /etc/systemd/journald.conf.d && \
  printf "[Journal]\nSystemMaxUse=100M\nMaxRetentionSec=7d\n" \
  | sudo tee /etc/systemd/journald.conf.d/zz-tile-lite-elite.conf && \
  sudo systemctl restart systemd-journald && \
  systemd-analyze cat-config systemd/journald.conf | grep -E "SystemMaxUse|MaxRetention"'
```

**`mkdir -p` is not defensive — it is required.** `/etc/systemd/journald.conf.d/`
**does not exist on rehearsal**. It exists on production only because
`50-cap.conf` was put there by hand on 2026-07-30. `tee` cannot create a parent
directory, so the first attempt at this step failed — and failed *quietly*, because
the restart afterwards succeeded and printed nothing alarming. The one error line
scrolled past and the step looked done.

**One `ssh` with a quoted command, not a session followed by lines.** The first
version opened an interactive session and left `exit` at the end. Pasted as a
block that closed the operator's terminal, and left it unclear what had run.

**`&&` throughout**, so a failed write stops before the restart. That is the
difference between this failing loudly and failing the way it did the first time.

**Read the last two lines of output** — that is the *effective* configuration
after every drop-in is merged, not the file you just wrote. On rehearsal it is
`SystemMaxUse=100M` and `MaxRetentionSec=7d`, after the commented-out defaults.

```bash
./scripts/deploy-rehearsal.sh        # the deploy mechanism, on production's shape
```

Then the technical tests, which is what rehearsal is for:

```bash
ssh tile-lite-elite-rehearsal 'journalctl CONTAINER_TAG=tle-server -o cat -n 20' | jq -e . > /dev/null \
  && echo "every line parses"
ssh tile-lite-elite-rehearsal 'journalctl CONTAINER_TAG=tle-server -o cat' \
  | python3 scripts/check-log-hygiene.py --source production -
ssh tile-lite-elite-rehearsal 'journalctl CONTAINER_TAG=tle-web --since "3 min ago" | wc -l'
```

**Take the web reading over a window that excludes the restart.** Caddy writes
about twenty lines when a container starts, so a ten-minute window straight after
a deploy reads as noise when the steady state is silence. Three minutes later it
was **1**.

#### 5 · Production

```bash
ssh tile-lite-elite 'sudo mkdir -p /etc/systemd/journald.conf.d && \
  printf "[Journal]\nSystemMaxUse=100M\nMaxRetentionSec=7d\n" \
  | sudo tee /etc/systemd/journald.conf.d/zz-tile-lite-elite.conf && \
  sudo systemctl restart systemd-journald && \
  systemd-analyze cat-config systemd/journald.conf | grep -E "SystemMaxUse|MaxRetention"'
```

**The same command as rehearsal, and `50-cap.conf` is not edited.** An earlier
version of this runbook used `sed` to raise it from 50 M. That is unnecessary and
riskier than it looks: drop-ins are applied in **lexical order** and later files
win for the same key, which is why ours is named `zz-`. `SystemMaxUse=100M`
overrides the 50 M without touching the older file, and adding a file is a safer
operation than editing one in place.

```text
production's 50-cap.conf, unchanged:
  [Journal]
  SystemMaxUse=50M
  RuntimeMaxUse=16M      ← the volatile /run journal; nothing to do with retention
```

**What to read in the output**: `50M` **then** `100M`, ours last. That order is
the override working. If `50M` comes last, stop — the drop-in is not winning and
seven days would be quietly untrue.

```bash
./scripts/deploy.sh
```

This one is the release: `prod-0.7.0` tagged, milestone 0.7.0 closed, dev bumped
to 0.7.1.

#### 6 · Confirm

```bash
./scripts/verify.sh
ssh tile-lite-elite 'journalctl CONTAINER_TAG=tle-server -o cat -n 5' | jq .
ssh tile-lite-elite 'journalctl CONTAINER_TAG=tle-web --since "10 min ago" | wc -l'
```

**Not a second production deploy.** *Logs survive a deploy* was proved on preview,
where a deploy costs nothing; on production the next release proves it again for
free. What is confirmed here is that the lines are JSON, in journald, and that
the web probe has gone quiet — 2,858 lines a day to nearly none.

**A week later**, the one claim nothing can check today:

```bash
ssh tile-lite-elite 'journalctl CONTAINER_TAG=tle-server --since "8 days ago" -o cat | head -1'
ssh tile-lite-elite 'journalctl --disk-usage'
```

### Delivery 2 — backups

**Step 1 is in the console** and produces a credential that must be copied
straight to the host, because it is shown once.

```text
1a  Bucket tile-lite-elite-backups → Details → Object Versioning → Enable
1b  → Management → Pre-Authenticated Requests → Create
      target       Bucket
      access       Permit object writes
      listing      off
      expiry       two years — record the date in docs/3.4
1c  Copy the URL. It is shown once.
```

```bash
# 1d — on the host, straight away. 0600 because it is a bearer token, and a file
#      rather than an environment variable because `systemctl show` is world readable.
ssh tile-lite-elite
umask 077 && printf '%s\n' 'PASTE_THE_URL' > ~/.tile-lite-elite-backup-par

# 2 — the scripts and their units. Three files travel together, because the
#     validator is useless without the schema and there is no checkout here.
# sqlite3 on the **host**, not just in the image. It was added to runtime-server
# for #138; the backup's integrity check runs on the host against the copy it
# pulled out, so the host needs it too. Missing this failed the first real run.
sudo apt-get update -qq && sudo apt-get install -y sqlite3
sudo install -d -o ubuntu -g ubuntu /opt/tile-lite-elite
# from the development machine:
scp scripts/backup-to-oci.sh scripts/check-log-hygiene-nightly.sh \
    scripts/check-log-hygiene.py docs/4.7-log-events.md \
    tile-lite-elite:/opt/tile-lite-elite/
scp scripts/systemd/* tile-lite-elite:/tmp/
# back on the host:
sudo mv /tmp/tile-lite-elite-*.service /tmp/tile-lite-elite-*.timer /etc/systemd/system/
sudo usermod -aG systemd-journal ubuntu        # the log check reads the journal
sudo systemctl daemon-reload
sudo systemctl enable --now tile-lite-elite-backup.timer tile-lite-elite-log-check.timer
systemctl list-timers 'tile-lite-elite-*'

# 3 — prove it before waiting a night for it
sudo systemctl start tile-lite-elite-backup.service
journalctl -u tile-lite-elite-backup.service -n 20 --no-pager
```

```text
4  NOT BUILDABLE AS WRITTEN — see #201. Attempted 2026-08-23.

   The intent stands: three alarms, each on the age of a marker object, all
   firing on absence of success — which also catches a crashed script, a timer
   nobody enabled, a host that is down, or an expired credential.

     backup did not arrive          marker-backup-ok    older than 26 hours
     no clean log check recently    marker-logcheck-ok  older than 36 hours
     no verified restore recently   marker-restore-ok   older than 100 days

   OCI cannot express any of them. Object Storage publishes exactly two
   metrics — Bucket Size and Number of Objects — both per *bucket*. No
   object-level dimension, no age, and the three markers are indistinguishable
   to OCI. The metrics were also observed lagging by over an hour.

   This design said the alarms "use machinery already built for #136". That was
   wrong: #136 works because oci_healthchecks and oci_computeagent publish the
   exact quantity its alarms need. oci_objectstorage has no equivalent.

   #201 carries the redesign; the recommendation there is a custom metric
   posted by the host under an instance principal, alarmed on absent().
```

### Delivery 3 — the restore drill

*Split out of Delivery 2 on 2026-08-23, so that delivery could close the same
evening rather than spanning days. Delivered `0.7.0b`, 2026-08-24.*

**A backup nobody has restored is a hypothesis**, which is why this is a
delivery rather than a follow-up. It restored `db-20260824T031435Z` — the
backup the timer made **unattended** at 03:14, not one triggered by hand —
reporting `integrity ok, 6 players, 26 games`.

**It proved more than the restore path.** The two backups either side of that
night differ by exactly one game, 27 at 18:45 and 26 at 03:14, and the journal
names the cause at 20:19:47: *terminal game auto-deleted after 7 days*. A
backup that faithfully records a change nobody made by hand is better evidence
that it is real than any assertion about it.

**The recurring procedure now lives in `docs/3.4` under *Restoring***, because
it is operational rather than part of this delivery — including the dependency
nobody had written down: **a restore starts in the OCI console, every time**,
because no standing read credential exists anywhere. Whatever protects the
Oracle account also protects the backups.

```bash
# 5 — the restore drill, from the DEVELOPMENT machine. Not the host: a read PAR
#     on the production VM defeats the one property this design exists for.
#     (It happened on the first drill, 2026-08-24. The habit comes from step 1,
#     which does say ssh — for the *write* PAR, which belongs there.)
umask 077 && printf '%s\n' 'PASTE_THE_READ_PAR' > ~/.tle-restore-par
./scripts/restore-backup.sh "$(< ~/.tle-restore-par)"
shred -u ~/.tle-restore-par        # then delete the PAR in the console

# Refresh the marker from the host rather than with --mark, so the write PAR
# stays in its 0600 file and never reaches a command line or a `ps` listing.
ssh tile-lite-elite 'PAR="$(< ~/.tile-lite-elite-backup-par)"
  printf "%s\n" "$(date -u +%Y%m%dT%H%M%SZ)" > /tmp/m
  curl --fail -sS -T /tmp/m "${PAR}marker-restore-ok"; rm -f /tmp/m'
```

**The procedure now lives in `docs/3.4`**, under *Restoring*, because it is
operational and recurring rather than part of this delivery. What is here is the
record of the drill; what is there is what to do next time.

**Step 5 is not optional and not a follow-up.** A backup nobody has restored is a
hypothesis, and the 100-day alarm exists to make the drill recur rather than to
happen once in August.

**Only Delivery 1 is a release.** Its step 2 is; everything else is an
application, and gets a dated row in the delivery log — with an identifier
rather than no version, since D34 superseded D6 on 2026-08-23. That is what
makes the log worth keeping: most of these steps leave no other trace, and
`0.7.0a` was the first delivery in the programme with no `prod-*` tag to be
found under. `docs/4.9-delivery-log.md` was created for it.

### Sequencing against #71

**All of it goes before #71.** Owner, 2026-08-21: *"we can do those things ahead
of #71, we can do all of it ahead of #71 if that is easier."* It is easier —
splitting the project into an urgent third and a deferred remainder costs a
second pass over the same files, and the deferred half would have been rebased
over whatever #71 does to them.

The argument for the three urgent pieces stands as the reason this project goes
first at all:

| piece | size | why not to wait |
| --- | --- | --- |
| **the health-check fix** | one line in `Dockerfile` | it makes every other number in this document honest, and it is the difference between 19 useful lines a day and 2,922 |
| **personal data out of the logs** | ~5 call sites | every day it waits is another day of email addresses landing in a log that is about to gain seven-day retention *and* an offsite copy. The offsite copy is what changes this from tidiness to something worth doing first |
| **the backup** | a script and a bucket | the only failure in the whole workstream that is **unrecoverable**. Everything else here is discomfort; losing the VM today loses every game ever played, and the exposure grows with each day the site stays up |

**One interaction to be aware of, and it is now the only reason to hold anything
back.** `/status` (Part 7) and the sweep task (#166) touch the same area as #71's
chunk A, so building the endpoint before #71 risks rework. Nothing in the two
deliveries above touches it: the health check is a `Dockerfile` line, the logging
edits are five call sites, and the backup is entirely outside the application. So
**Part 7 is the piece that waits**, and it is adjacent work rather than part of
this project's scope.

---

## Part 10 — Impacted artefacts

Every artefact this project touches, and what it does afterwards that it did not
before (D27). **Provisional** until the test approach is agreed, since the schema
test is itself an artefact.

Named by D26's convention: a repository path where there is one, `production:`
plus an absolute path on the host, and the provider's own name for a cloud
resource.

### In the repository — six modified, two new

The diff carries the detail here; these summaries carry the intent above it.

| artefact | | what it does afterwards |
| --- | --- | --- |
| `Dockerfile` | modified | the web health check fetches `/version.txt` through a loopback-only listener instead of polling Caddy's admin API — it proves routing, the file server and the static build, and writes nothing |
| `Caddyfile` · `Caddyfile.preview` | modified | each gains `http://127.0.0.1:2020`, a loopback-only listener serving the same root with the HTTP→HTTPS redirect disabled, so the container can probe its own files |
| `crates/server-game/src/main.rs` | modified | the subscriber emits **JSON to stdout**. Human-readable output becomes a rendering applied at reading time rather than the stored form |
| `crates/server-game/src/app/auth.rs` | modified | four events stop carrying `display_name`, and the unknown-email reset stops carrying **the email address**. What is left identifies the account to somebody with database access and to nobody else |
| `crates/server-game/src/email.rs` | modified | mail events carry `player_id` and a message kind rather than the recipient address and subject |
| `docker-compose.yml` · `docker-compose.preview.yml` | modified | both services log through the **journald** driver, so the store belongs to the host and survives the container recreation that discards everything today |
| `docs/4.7-log-events.md` | **new** | the event catalogue, and — because of the test below — the **declared schema** the code is measured against. It is a reference document that is also a gate |
| `crates/server-game/tests/` — the schema comparison | **new** | renders every event through the real JSON layer and fails CI when a field appears that `4.7` does not declare. It proves code and document **agree**; whether the document is **right** is a person's job |
| `scripts/check-log-hygiene.sh` | **new** | validates a stream of log lines against `docs/4.7`'s schema and fails on an address, a display name, an undeclared field or a line that is not JSON. **Reads; never drives.** CI feeds it the suite's captured output, production feeds it the day's journal |
| `scripts/restore-backup.sh` | **new** | fetches the newest backup, verifies it opens, and loads it into a fresh volume — so the restore drill is re-runnable rather than a thing done once in August |
| `docs/3.4-production-environment.md` | modified | documents the host artefacts below, the backup procedure, the pre-authenticated request's expiry date, and the restore drill |

### Outside the repository — five, all new but one

**These entries are the record.** There is no diff anywhere, so what is written
here has to be enough to do it again from nothing — which is also what makes this
half of the table the answer to *"what else was on that box?"*

| artefact | | what it does afterwards |
| --- | --- | --- |
| `production:/etc/systemd/journald.conf.d/zz-tile-lite-elite.conf` | **new** | `SystemMaxUse=100M`, `MaxRetentionSec=7d`. Sets seven-day retention and a size backstop that will not bind before the age rule does |
| `production:/etc/systemd/journald.conf.d/50-cap.conf` | modified | the existing 50 M cap, set deliberately on 2026-07-30, doubled rather than deleted — 50 M would bind first and make seven days quietly untrue |
| `production:` the backup script and its systemd timer | **new** | takes a consistent snapshot daily, uploads it under a dated name, alerts on failure and keeps the previous upload if this one fails |
| `OCI bucket tile-lite-elite-backups` | **new**, created 2026-08-21 | holds the backups. Standard tier, private, **object versioning on** — which is what closes the one remaining way a leaked credential could destroy a backup |
| `OCI` write-only pre-authenticated request | **new** | lets the VM upload and nothing else. Tested: it cannot read, list or delete, and deleting it revokes access immediately. Its expiry date is recorded in `docs/3.4` |
| `OCI alarm` — backup did not arrive | **new** | mails the owner when a day passes without a new object. It is what makes the PAR's expiry announce itself rather than being discovered when the database is gone |
| `OCI alarm` — no verified restore recently | **new** | mails the owner when the newest restore marker is more than 100 days old. It is what turns *"quarterly"* from an intention into a trigger, and it is the same mechanism as the row above pointed at a different object |
| `OCI alarm` — no clean log check recently | **new** | mails the owner when the nightly log validation has not written a clean marker for about 36 hours. Alerts on **absence of success**, so it also catches a crashed check, a timer nobody enabled, a host that is down, or an expired credential |
| `production:` the nightly log-check script and its timer | **new** | validates the day's journal against `docs/4.7`, writes exceptions to its own log, and refreshes the marker only on a clean run |

**Twenty artefacts of which nine leave no trace in git**, which is the argument
for the table existing at all: a list that had quietly meant *files changed*
would have described half of this project.

**Three of the twenty are test tooling, and two of those were missing** until
the owner asked twice — first whether the tests in Part 8 produced any scripts,
then noticing that the one added *ran in production* and none tested the project
itself. That is D25's *"the list stays provisional until the test approach
settles"* happening in practice rather than in principle, and it is also the
answer to why the artefact list is worth a heading of its own: nobody spots a
missing row in a paragraph.

---

## Open questions for review

1. **Seven days: promise or capacity?** If a promise, logrotate matches it and
   syslog stops being a five-week archive (Part 4).
   **Answered: capacity.** Owner: *"if we only store ids then it is only
   identifiable with access to the database, in which case the logs don't
   matter."* Right, and it is consistent with *The limit of the claim* above: the
   ids are pseudonymous, so a leaked log on its own identifies nobody, and the
   sensitive copy is the database — which is governed separately and much more
   tightly. **So seven days is a disk-space number and may be tuned freely**,
   logrotate need not be made to match it, and syslog's five-week archive stops
   being a problem to solve.
2. **The catalogue test** — build the source scan, or rely on discipline
   (Part 1)?
   **Answered: neither — the document declares the schema and a test compares
   the emitted fields to it.** Written up in Part 1; it is a better answer than
   either option offered, because it catches an undocumented *field* and not
   merely a missing event.
3. **Health probes recorded locally, or only in OCI** (Part 3)?
   **Answered: OCI only.** Owner: *"I don't see any value in storing health
   checks if OCI records outages."* Agreed — and it removes the largest single
   source of log volume rather than merely bounding it. What is given up is the
   near-miss: a probe that answered slowly is a signal OCI's up/down view does
   not carry. Not worth a local log; if it ever matters, it is a latency metric
   and not a line of text.
4. **Sequencing** — do the three early pieces stand, or does everything wait for
   #71 (Part 9)?
   **Answered: all of it goes before #71.** Owner: *"we can do those things ahead
   of #71, we can do all of it ahead of #71 if that is easier."* It is easier —
   splitting the project into an urgent third and a deferred remainder costs a
   second pass over the same files, and the deferred part would have been rebased
   over whatever #71 does to them.
5. **One note or two** — this covers #174 and #175; splitting is easy if review
   prefers a document per issue.
   **Answered: one.** Owner: *"this is one project and should have one design
   even if it covers multiple requirements and deliveries."* Which is a general
   rule rather than an answer about this document, and it is now recorded as such
   in the glossary under D18 — **the design belongs to the project**, and #174
   and #175 are two requirements of one project, not two projects.

Refs #174, #175, #176, #166, #90, #136, #40
