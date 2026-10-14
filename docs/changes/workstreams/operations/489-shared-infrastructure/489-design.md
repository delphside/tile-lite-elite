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

## Options

### 1. How two applications share ports 80 and 443

Only one process on a host can listen on 80 and 443. Each application has its
own subdomain and its own Caddy.

1. **The second application's Caddy listens on other ports and obtains
   certificates by DNS challenge.** This is the route agreed in principle on
   D73. *Constrains:* the second application's URLs carry a port number
   (`https://wow.tileliteelite.com:8443`); a DNS provider API token becomes a
   secret on the host; Caddy is built with that provider's module. GoDaddy's
   API access for small accounts has been restricted in the past, so this
   must be checked before it is relied on. The fallback is to move DNS hosting
   to a provider with an open API, keeping the registration where it is.
2. **A small front proxy owned by the infrastructure application holds 80 and
   443, and routes each connection by name to the right application's
   Caddy**: on 443 by the TLS server name, passing TLS through untouched, and
   on 80 by the HTTP host. Each Caddy keeps its own certificates, still
   obtained by the challenges it uses today, because the proxy forwards those
   by name too. *Constrains:* Tile Lite Elite's Caddy moves
   off 80 and 443, which is a production release of TLE and so a requirement
   raised on it; the proxy is a single component every hosted application
   passes through, so its failure is every application's outage; it costs
   some memory, to be measured. No DNS secret is needed and every URL keeps
   its standard port. An application that later moves to a host of its own
   takes 80 and 443 back and no longer needs the proxy.

Claude's recommendation: 2. Standard ports matter for anything players or
other tools reach, and it avoids putting a DNS credential on the host. It is
also the only option where the two applications are symmetrical.

### 2. How the infrastructure application's deliveries are versioned

Its deliveries change hosts, not images, so it has no build to version.

1. **Its own semver**, bumped per delivery, with its own delivery log.
2. **Letter milestones on its own last version**, as `Other` deliveries are
   numbered today, but against the infrastructure application rather than
   TLE.

To settle with docs/5.1's letter-milestone rule and §2.2.1's routine-update
table, which both assume host work rides an application's version.

### 3. What happens if the second application does not fit

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
| capacity | the combined capacity plan carries every hosted application against each host's 954 MB ceiling. The front proxy (option 1.2) and the second application are measured on rehearsal before production |
| failure | with option 1.2, the front proxy is shared: its failure takes every hosted application down, so it is monitored and verified like an application, and `verify.sh` for each application exercises the path through it |
| limits and timeouts | none new, because the proxy passes connections through and adds no timeout of its own; to confirm against the chosen proxy's defaults |
| secrets and access | option 1.1 adds a DNS provider API token on the host; option 1.2 adds none. Production access stays the owner's to run |

## Still to design

- which documents and scripts move from this repository to
  `delphside/infrastructure`: docs/3.4's host sections, `check-hosts.sh`, the
  host rows of docs/4.8, the capacity plan;
- how `verify.sh` in each application is triggered after a host delivery;
- the test approach for a host delivery that two applications sit on.
