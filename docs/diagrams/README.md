# Diagram sources

## Which view a diagram takes, and saying so

**Adopted 2026-09-22 (#406): C4, plus one view of our own.** A diagram of the
system declares its view in the line above it, so a reader knows what they are
looking at without inferring it from the contents.

| view | whose | shows | zoom |
| --- | --- | --- | --- |
| **Context** | C4 | the service and who uses it | outermost |
| **Container** | C4 | deployable processes and where they run | |
| **Component** | C4 | what is inside one container | |
| **Runtime** | **ours** | concurrency, sweeps and message flow — what happens over time, and what happens without a request | across all three |

**Why C4.** It is built for this size, and *Container* means a deployable
process, which is literally our two containers and the database. Adopting it was
mostly a matter of declaring what the diagrams already were. 4+1's *Development
view* is module ownership across teams, an empty box for one developer and one
repository; arc42 is a twelve-section document template, and the numbered
documents already do that job.

**Why Runtime is ours and says so.** C4 treats process and concurrency as
supplementary rather than as a level, and much of this system's difficulty lives
there — `hash_limit` at 4 and `engine_limit` at 2, the sweeps that run from
`list_games`, the scheduler #400 will build. Naming it as a local extension is
the difference between adopting a standard and quietly diverging from one.

**Container is the level the roadmap is drawn at.** It is the one that changes
when the architecture changes and stays still when the code does: a roadmap at
Component would move every release and say nothing, and one at Context would
never move at all.

### A process diagram is not a view

**Most of the diagrams in this folder are not architecture at all.**
`release-flow`, `version-lifecycle` and the four delivery flavours show how a
*change* moves, not how the *system* is built, and `roadmap.svg` shows when work
happens. They take no C4 view and should not be labelled with one — the set
above describes the system, and a process diagram describes us.

### What each diagram is today

| diagram | view |
| --- | --- |
| [1.1](../1.1-architecture.md)'s deployment diagram | **Container** — environments and the processes in them |
| [1.2](../1.2-components-and-interactions.md)'s component diagram | **Component**, with the clients drawn as Context around it |
| 1.2's move-submission sequence | **Runtime** |
| [3.3](../3.3-testing-ci-and-release.md)'s sequence diagram | process, not a view |
| `release-flow`, `version-lifecycle`, `flavour-a` to `flavour-d` | process, not a view |
| `roadmap.svg` | a plan, not a view — and note that #406 R3 will add a *Container* roadmap alongside it, answering *what will it look like* where this one answers *when does work happen* |

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
