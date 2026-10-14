# Shared infrastructure run as an application

The design for **project #489**, in the Operations & Infrastructure workstream.
It takes requirement #486, which applies D73 (#484): the programme runs a
second application on the hosts Tile Lite Elite uses today, and what the hosts
share becomes an application of its own.

*Nothing here is built.* This is the scope-stage design: the as-is, the target,
and the options still to choose. When it is complete, the design moves into
the programme's living documents (owner, 2026-10-14) and this note is deleted.

## The state today

Everything about the hosts is Tile Lite Elite's, and is described in its own
documents:

| what | where it is described | what assumes one application |
| --- | --- | --- |
| two Oracle Always Free VMs, `VM.Standard.E2.1.Micro`: 1 OCPU, 1 GB, x86_64 | docs/3.4 *Building a host* | the instructions build a host for this application |
| ingress TCP 22, 80, 443 and UDP 443 in the subnet's security list | docs/3.4, docs/4.8 | 80 and 443 are published by this application's Caddy container |
| the domain `tileliteelite.com`, registered at GoDaddy, an A record to production | `Caddyfile`'s header comment | one name, one site |
| HTTPS from Caddy's own Let's Encrypt HTTP and TLS-ALPN challenges | docs/3.4, `Caddyfile` | these challenges need ports 80 or 443, which only one process per host can hold |
| OS packages, reboots and Docker kept current | docs/3.4 *Keeping the hosts current*; `check-hosts.sh` | a host change is a delivery of this application, with a letter milestone on its production version |
| capacity: 469 MB used of a 954 MB ceiling, about 480 MB free | `docs/reports/capacity_plan/TLE_CP_2026_09.md` | the plan measures one application |

## The target

| | target |
| --- | --- |
| **who** | the infrastructure application, owned by Operations & Infrastructure, with its own repository `delphside/infrastructure` and its own GitHub project and board |
| **what it holds** | the hosts, networking (domain, DNS, ports, firewall), host security and the combined capacity plan. Its programme records live in its folder in `delphside/programme` (#485, R6) |
| **what it serves** | each hosted application, which depends on it only as its host. No hosted application depends on another |
| **how it changes** | a host change is its delivery. Afterwards each hosted application runs its own `verify.sh` |
| **how it coordinates** | a project that affects a hosted application, by a change or only by its regression testing, raises a requirement in that application's repository and coordinates the work. One team runs every board, so a requirement and its dependency link are enough |

## Decisions

### How the second application is reached: privately

The WoW analysis tool has one user, the owner, so it is not public (owner,
2026-10-14). Its server listens on the host's loopback only and is reached
through an SSH tunnel from the owner's machine. So no second application holds
or shares ports 80 and 443, nothing needs a certificate, the security list is
unchanged and Tile Lite Elite is untouched.

A WoW add-on runs inside the game client and has no network access of its own,
so publishing one would not make the server public either. If a public need
appears, the route is a small front proxy owned by the infrastructure
application, holding 80 and 443 and passing each connection by name to its
application's Caddy. That is designed then, not now.

### How infrastructure deliveries are numbered: by date

The infrastructure application keeps its own delivery log, and numbers each
delivery by date and the day's sequence, `YYYY.MM.DD-n` (owner, 2026-10-14).
Its deliveries change packages and configuration, not a build, so a semver's
parts would measure nothing. To apply to docs/5.1's letter-milestone rule and
§2.2.1's routine-update table, which assume host work rides an application's
version.

## Options

### What happens if the second application does not fit

Measured first, against the combined plan's ceiling.

1. **Stay on the shared hosts** if the measured footprint fits.
2. **Move the second application to a free-tier arm64 VM**, building for arm64
   from its first commit (GitHub arm64 runners, or cross-compilation). The
   infrastructure application then has hosts of two architectures.

Not a choice to make now: it follows from the measurement, and the second
application builds for both architectures from the start so either remains
open.

## Non-functional design

| question | answer |
| --- | --- |
| capacity | the combined capacity plan carries every hosted application against each host's 954 MB ceiling. The second application is measured on rehearsal before production |
| failure | none shared, because no component sits in front of both applications; each fails alone |
| limits and timeouts | none new, because nothing is added between a user and an application |
| secrets and access | the second application's deploy and tunnel use SSH, as Tile Lite Elite's do; whether each application gets its own Linux user is still to design. Production access stays the owner's to run |

## Still to design

- which documents and scripts move from this repository to
  `delphside/infrastructure`: docs/3.4's host sections, `check-hosts.sh`, the
  host rows of docs/4.8, the capacity plan;
- how `verify.sh` in each application is triggered after a host delivery;
- the test approach for a host delivery that two applications sit on;
- whether each application gets its own Linux user and deploy key, with an
  admin user for host changes. Membership of the `docker` group is equivalent
  to root, so separate users separate keys and files, not privileges, unless
  Docker runs rootless, one daemon per user, at a memory cost.
