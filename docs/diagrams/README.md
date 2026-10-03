# Diagram sources

## Which view a diagram takes, and saying so

**Adopted 2026-09-22 (#406): C4, plus one view of our own.** A diagram of the
system declares its view in the line above it, so a reader knows what they are
looking at without inferring it from the contents.

| view | whose | shows |
| --- | --- | --- |
| **System Context** | C4 | the service and who uses it |
| **Container** | C4 | the deployable processes and what each is responsible for — *logical* |
| **Component** | C4 | what is inside one container |
| **Deployment** | C4 | which containers run on which infrastructure, per environment — *physical* |
| **Dynamic** | C4 | how elements interact over time: a sequence or a collaboration |
| **Concurrency** | Rozanski & Woods | what can run at the same time and how that is bounded — the semaphores, the sweeps, the scheduler |

**Nothing here is ours, and an earlier version of this table invented a view
called *Runtime* that C4 already had.** Corrected 2026-09-22. Owner, the same
day: *"we are too quick to invent our own thing rather than adopt industry
standards."* C4's supplementary diagrams — System Landscape, **Dynamic**,
**Deployment** — are part of the model, and *Dynamic* is precisely what *Runtime*
was invented to mean.

**Concurrency is the one C4 genuinely lacks**, so it is taken from Rozanski and
Woods rather than named afresh: *"the parts of the system that can run at the
same time and how this is controlled"*, which is `hash_limit` at 4,
`engine_limit` at 2, and the scheduler #400 will build. Borrowing one named
viewpoint from a second framework is a smaller cost than a name only this
repository knows.

**Why C4 as the base.** It is built for this size, and *Container* means a
deployable process, which is literally our two containers and the database.
4+1's *Development view* is module ownership across teams, an empty box for one
developer and one repository; arc42 is a twelve-section document template, and
the numbered documents already do that job; Rozanski's full seven viewpoints are
heavier than three plus two supplementary ones.

**Container and Deployment are different diagrams and the difference matters
here.** Container is logical — what the processes are and what each is for.
Deployment is physical — which of them run where, per environment. An earlier
version of this table called `1.1` a Container view when it is a Deployment
view, which is how the missing rehearsal environment stayed invisible: a logical
diagram has no environments to be missing from.

**Deployment is the level the roadmap is drawn at**, because architecture
change here is change to what runs where. A roadmap at Component would move
every release and say nothing; at Context it would never move at all.

### Change state: one key, and the roadmap adds a fifth value

**A diagram that shows a change colours every box and every line by what happens
to it.** Two diagrams use it: a project's single overview diagram (#406 R4) and
the roadmap drawn per horizon (#406 R3).

| state | class | means |
| --- | --- | --- |
| unchanged | `unchanged` | it exists and this change does not touch it |
| new | `new` | it does not exist yet |
| changed | `changed` | it exists and this change modifies it |
| removed | `removed` | it exists and this change takes it away |
| aspirational | `aspirational` | **roadmap only** — wanted, not committed |

```text
classDef unchanged    fill:#f6f8fa,stroke:#8c959f,color:#1f2328
classDef new          fill:#dafbe1,stroke:#1a7f37,color:#0a3622
classDef changed      fill:#fff8c5,stroke:#9a6700,color:#4d2d00
classDef removed      fill:#ffebe9,stroke:#cf222e,color:#6e0a12
classDef aspirational fill:#ffffff,stroke:#8250df,color:#3f1a7a
```

**Lines carry state too, and separately from boxes.** A change that touches no
component but changes a protocol between two of them is invisible if only boxes
are coloured. Mermaid has no `classDef` for edges, so an edge's state goes in its
label — `-- new -->`, `-- changed -->` — and a removed edge is drawn dotted with
a `removed` label rather than deleted, because a line that is simply absent is
indistinguishable from one nobody drew.

**Four values on a project diagram, not two.** An earlier note here said a
project diagram takes a two-value key, *affected* and *unaffected*. That was read
off the prior art's **context** diagram and missed that its **component** diagram
used *new, update, unchanged* — three. The detail level is where the distinction
earns its place, and one diagram per project means our one diagram is the detail
level. Corrected 2026-09-22.

**The roadmap's fifth value is the one that admits doubt.** *Aspirational*
marks something wanted and not committed, and the prior art drew such boxes with
`TBC ???` inside them rather than leaving them out — a diagram that omits what is
undecided reads as a plan with no gaps.

### A process diagram is not a view

**Most of the diagrams in this folder are not architecture at all.**
`release-flow`, `version-lifecycle` and the four delivery flavours show how a
*change* moves, not how the *system* is built, and `roadmap.svg` shows when work
happens. They take no C4 view and should not be labelled with one — the set
above describes the system, and a process diagram describes us.

### What each diagram is today

| diagram | view |
| --- | --- |
| [1.1](../1.1-architecture.md)'s deployment diagram | **Deployment** — which containers run in which environment |
| [1.2](../1.2-components-and-interactions.md)'s component diagram | **Component**, with the clients drawn as Context around it |
| 1.2's move-submission sequence | **Dynamic** |
| [3.3](../3.3-testing-ci-and-release.md)'s sequence diagram | process, not a view |
| `release-flow`, `version-lifecycle`, `flavour-a` to `flavour-d` | process, not a view |
| `roadmap.svg` | a plan, not a view — and note that #406 R3 will add a *Deployment* roadmap alongside it, answering *what will it look like* where this one answers *when does work happen* |

## Rendering

Each `.mmd` here is the source for the `.svg` beside it. Edit the `.mmd`,
re-render, and commit both.

**`roadmap.svg` is the exception: it has no `.mmd`.** Its source is the board,
and `scripts/roadmap-diagram.py --write` regenerates both it and the block in
[1.5](../1.5-work-in-progress.md) that embeds it. Do not edit it by hand — the
next run overwrites it. Why it is not Mermaid is below.

```bash
npx -y @mermaid-js/mermaid-cli -i docs/diagrams/release-flow.mmd \
  -o docs/diagrams/release-flow.svg -c docs/diagrams/mermaid-config.json -b white
```

**If that writes nothing and exits silently**, use Docker instead — it
carries its own browser and sidesteps the problem entirely:

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/docs/diagrams":/data \
  minlag/mermaid-cli -i /data/release-flow.mmd -o /data/release-flow.svg \
  -c /data/mermaid-config.json -b white
```

The silent failure is Puppeteer's: `~/.cache/puppeteer` can hold *empty*
version directories, so it believes Chromium is installed, tries to launch
nothing, and `mermaid-cli` swallows the error — no output, no file, exit 1.
Clearing the cache does not help if the re-download also fails. `-u` matters:
without it the container writes the SVG as root.

Colour carries meaning, so keep it consistent across diagrams: **blue for
things that run code** (environments), **sand for things that store it**
(repositories), **amber for a gate** a script refuses on. Boxes use
`classDef env` / `classDef repo` rather than per-node styles, so a new box
joins a category instead of picking its own colour.

**Bold means an action somebody takes**, normal weight means it happens on
its own. It comes from mermaid *markdown strings* — backtick-quoted labels,
`"` + backtick + `**bold**` — not `<b>`, which leaks literally while
`htmlLabels` is false. `wrappingWidth` and a non-breaking space after `$`
stop long commands wrapping mid-name.

Line shape carries meaning, and should carry it *structurally* rather than
by colour: a solid arrow moves code, a dotted arrow returns an answer, and
a diamond is a decision taken during an action. Labels do the rest — `$`
prefixes a command you type, `(automatic)` marks something done on your
behalf.

There is deliberately **no `linkStyle`** in `release-flow.mmd`. An earlier
version coloured the gates amber by edge index, and those indices count
from zero including invisible `~~~` links — so adding an arrow anywhere
above silently moved the colouring onto the wrong lines. It happened four
times, each caught only by looking at the render. Shapes need no indices.

Two more things learned by rendering rather than reading:

- A bare `%%` line is parsed as a **node**, not a comment. Use `%% .` for a
  blank line inside a comment block.
- `linkStyle`'s `color:` never reaches label text while `htmlLabels` is
  false, so an arrow can be recoloured but its label cannot.

Two things about `mermaid-config.json` that are not incidental:

- **`htmlLabels: false`.** Mermaid renders labels as `<foreignObject>` by
  default, and GitHub shows an embedded SVG containing `foreignObject` as a
  blank box. Without this the diagram renders perfectly in a browser and is
  invisible in the docs. It costs `<b>` markup in labels, which stops being
  interpreted and would appear literally.
- **The `layout: elk` line in the `.mmd` itself.** ELK routes orthogonally
  and places labels without collisions, which dagre could not manage for
  this graph. It needs `@mermaid-js/layout-elk`, which mermaid-cli bundles
  but GitHub's own mermaid does not — which is the other reason these are
  pre-rendered and embedded rather than written inline as ```` ```mermaid ````
  blocks.

**A `gitGraph` branch name starting with a digit must be quoted.** Every project
branch here is `<issue>-short-name`, so every one of them does:
`branch "297-lockfile"`, not `branch 297-lockfile`, which is a parse error. And
`merge` takes an `id:` **or** a `tag:`, never both — that is a second parse
error, and mermaid reports both the same way: a bomb icon reading *Syntax error
in text*, with no line number and nothing on stderr. Bisecting is the only way
to find which line it meant.

**Mermaid cannot draw swimlanes, and a `flowchart` with one `subgraph` per lane
is not a near miss.** The roadmap (R8) wants workstreams as bands and sequence
running left to right. Rendered and looked at, both encodings fail:

- **without `direction LR`** in the subgraph, a dependency inside a lane is
  drawn *top to bottom*, which inverts the one thing the chart is for;
- **with it**, a single edge between two lanes makes dagre lay the lanes out
  *side by side as columns* instead of stacking them as bands — the swimlanes
  are gone entirely.

The second is not a corner case: it is the board's shape, where
[#10](https://github.com/delphside/tile-lite-elite/issues/10) waits on packages
in two other workstreams. Flowcharts have no swimlane primitive, and `gantt`
has sections but no dependency arrows and insists on dates. So `roadmap.svg` is
drawn directly by `scripts/board/roadmap.py`, which is also why it uses
presentation attributes and polygon arrowheads and no `<style>`, `<defs>` or
`<marker>` — the same sanitiser that blanks `foreignObject` above.

Both failures were found by rendering with Playwright's Chromium, which is
already installed for `e2e/` and works where `mermaid-cli`'s own Puppeteer
download does not.

Diagrams that *are* simple enough for dagre stay inline in the docs, where
GitHub renders them from source — see the sequence diagram in
[3.3](../3.3-testing-ci-and-release.md). Inline is preferable when it works:
no rendering step, and the source is the thing you read.
