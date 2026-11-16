# Diagram sources

The Mermaid sources of the pre-rendered diagrams, how to re-render them and the
conventions every Tile Lite Elite diagram follows, inline or here.

| Diagram | Source | Shows | Embedded in |
| --- | --- | --- | --- |
| [`release-flow.svg`](release-flow.svg) | [`release-flow.mmd`](release-flow.mmd) | the release runbook's steps as numbered arrows between the environments and the repositories | [4.3.3](../4.3.3-testing-ci-and-release.md#the-pipeline) |
| [`flavour-a-pre-approved.svg`](flavour-a-pre-approved.svg), [`flavour-b-repository-change.svg`](flavour-b-repository-change.svg), [`flavour-c-single-delivery-release.svg`](flavour-c-single-delivery-release.svg), [`flavour-d-multi-delivery-release.svg`](flavour-d-multi-delivery-release.svg) | the `.mmd` of the same name | the steps each shape of delivery runs | [4.3.3](../4.3.3-testing-ci-and-release.md#which-steps-each-shape-runs) |
| [`version-lifecycle.svg`](version-lifecycle.svg) | [`version-lifecycle.mmd`](version-lifecycle.mmd) | where each version comes from, and the two comparisons a running tab makes | [4.4.1](../4.4.1-configuration.md) |
| [`roadmap.svg`](roadmap.svg) | the board ([the roadmap](#the-roadmap)) | when work happens: workstreams as swimlanes, sequencing left to right | [4.1.5](../4.1.5-work-in-progress.md) |
| [`mermaid-config.json`](mermaid-config.json) | itself | the render settings ([settings](#settings)) | none |

These are process diagrams, which take no view.

## Which view a diagram takes, and saying so

**A diagram of the system declares its view in the line above it**, so a reader
knows what they are looking at without inferring it from the contents. The
views are C4's, with five from other frameworks that C4 lacks:

| View | From | Shows | Drawn in |
| --- | --- | --- | --- |
| System Context | C4 | the service and who uses it | none yet |
| Container | C4 | the deployable processes and what each is responsible for (logical) | [4.2.0](../4.2.0-design-map.md) |
| Component | C4 | what is inside one container | [4.2.0](../4.2.0-design-map.md) |
| Code | C4 | inside one component: the modules and functions that own its logic | none yet |
| Deployment | C4 | which containers run on which infrastructure, per environment (physical) | [4.1.1](../4.1.1-architecture.md), [4.3.4](../4.3.4-production-environment.md) |
| Dynamic | C4 | how elements interact over time: a sequence or a collaboration | [4.1.2](../4.1.2-components-and-interactions.md), [4.4.3](../4.4.3-api-schema.md#sequence-diagrams-every-endpoint-with-context)'s sequence diagrams |
| Concurrency | Rozanski and Woods | what can run at the same time and how it is bounded: the semaphores, the sweeps, the scheduler | none yet |
| Information | Rozanski and Woods | the data: what is stored, its shape and who owns it, and how it flows | [4.4.2](../4.4.2-database-schema.md)'s entity-relationship diagram, [4.4.4](../4.4.4-snapshot-json-schema.md)'s class diagram |
| State machine | UML | the lifecycle of one thing: its states and the transitions between them | none yet |
| Use case | UML | who uses the service, and what each may do | none yet |
| Activity | UML | a user's journey through the service, step by step | none yet |

- **Information**: the data's structure is an entity-relationship diagram. Its
  flows go on the arrows of the other views, each arrow labelled with the data
  it carries: a data transfer object (DTO), a row or an event. So the Container
  and Component views show them without a diagram of their own. A separate
  data flow diagram is the fallback, for the part of a system whose arrows
  carry too many flows to read.
- **State machines** label a transition with the method or event that causes it,
  so the diagram also says where each state change is handled.
- **Use case diagram**: one, for the whole service.
  - Its actors include a role held in one game (its creator), bots and a clock
    actor for scheduled events (expiry, reminders).
  - Each line is a permission, and each use case has an activity diagram.
  - Mermaid has no use case diagram, so it is a flowchart: actors outside a
    subgraph for the system boundary, use cases inside it as stadium shapes.
- **Activity diagrams** sit between the text requirements and the architecture.
  Each step either causes a state machine transition or only reads state, and
  cites the [4.1.0](../4.1.0-rules.md) rules it exercises, so the end-to-end
  tests come from them.
- **Code** is drawn only for a component with real rules in it, such as the game
  service or the rules engine.
- **Container and Deployment**: a missing environment shows only in a
  Deployment view.

### Change state

**A diagram of a change colours every box by what happens to it**, in these
classes. A diagram of a change is one in a change document that shows what the
change does to the system; a process diagram keeps its
[category colours](#conventions-of-the-process-diagrams). A line's state goes
in its label (`-- new -->`, `-- changed -->`); a removed line is dotted with a
`removed` label, because an absent line looks like one nobody drew.

| Class | Means |
| --- | --- |
| `unchanged` | it exists and this change leaves it as it is |
| `new` | this change adds it |
| `changed` | it exists and this change modifies it |
| `removed` | it exists and this change takes it away |

```text
classDef unchanged    fill:#f6f8fa,stroke:#8c959f,color:#1f2328
classDef new          fill:#dafbe1,stroke:#1a7f37,color:#0a3622
classDef changed      fill:#fff8c5,stroke:#9a6700,color:#4d2d00
classDef removed      fill:#ffebe9,stroke:#cf222e,color:#6e0a12
```

## Conventions of the process diagrams

- **Colour is a category**: blue for what runs code (`classDef env`), sand for
  what stores it (`repo`), green for a branch (`branch`), amber for a gate a
  script refuses on (`gate`). A box joins a category through its class; the
  GitHub group (`GH`) is styled on its own.
- **Bold is an action somebody takes**; normal weight happens on its own. Bold
  is a Mermaid markdown string (a backtick-quoted label, `**bold**` inside), as
  `<b>` is printed literally while `htmlLabels` is false.
- **Line shape carries meaning structurally**: a solid arrow moves code, a
  dotted arrow returns an answer, and a diamond is a decision taken during an
  action.
- **Marks in a label**:

  | Mark | Means |
  | --- | --- |
  | `$` before a command | you type it |
  | `(automatic)` | done on your behalf |
  | a non-breaking space after `$`, in `release-flow` | keep a long command on one line |

- **Arrow numbers are the runbook's step numbers**, as
  [4.3.3](../4.3.3-testing-ci-and-release.md#the-pipeline) defines them.
- **`release-flow.mmd` has no `linkStyle`.** Its edge indices count invisible
  `~~~` links, so one new arrow moves the colouring onto the wrong lines.

## Inline diagrams

A diagram that reads clearly with Mermaid's default layout, dagre, stays inline
in its document, where GitHub renders it from source, and needs no rendering
step. One that needs ELK is pre-rendered here ([settings](#settings)).

## Rendering

Each `.mmd` here is the source for the `.svg` beside it.

1. Edit the `.mmd`.
2. Re-render it from the repository root, with `d` set to the diagram's name:

   ```bash
   d=release-flow
   npx -y @mermaid-js/mermaid-cli@11.17.0 -i "docs/diagrams/$d.mmd" \
     -o "docs/diagrams/$d.svg" -c docs/diagrams/mermaid-config.json -b white
   ```

3. Commit both.

| Symptom | Cause | Fix |
| --- | --- | --- |
| the command writes nothing and exits 1 with no message | empty version directories in `~/.cache/puppeteer`: Puppeteer launches no Chromium and `mermaid-cli` swallows the error; clearing the cache does not help when the re-download fails | render in Docker, which carries its own browser (the Docker command, with `d` as in step 2) |

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/docs/diagrams":/data \
  minlag/mermaid-cli:11.17.0 -i "/data/$d.mmd" -o "/data/$d.svg" \
  -c /data/mermaid-config.json -b white
```

### The roadmap

**`roadmap.svg` has no `.mmd`.** The board is its source:
`programme/scripts/board/roadmap-diagram.py --write` regenerates it and the
block in [4.1.5](../4.1.5-work-in-progress.md) that embeds it, and the next run
overwrites a hand edit. `programme/scripts/board/roadmap.py` draws it with
presentation attributes and polygon arrowheads, because GitHub's SVG sanitiser
removes `<style>`, `<defs>` and `<marker>`.

### Settings

| Setting | Where | Why |
| --- | --- | --- |
| `htmlLabels: false` | `mermaid-config.json` | GitHub shows an embedded SVG containing `foreignObject`, which Mermaid emits for HTML labels, as a blank box. |
| `wrappingWidth: 320` | `mermaid-config.json` | It keeps a long command on one line. |
| `layout: elk` | the `.mmd` header | ELK (Eclipse Layout Kernel) routes orthogonally and places labels without collisions, which dagre does not for these graphs. It needs `@mermaid-js/layout-elk`, which `mermaid-cli` 11.17.0 bundles and GitHub's Mermaid does not, so these diagrams are pre-rendered. |

### Mermaid parse errors

A syntax error renders as a bomb icon reading *Syntax error in text*, with no
line number and nothing on stderr; bisect the source to find the line.

- A bare `%%` line is parsed as a node. Use `%% .` for a blank line in a comment
  block.
- A `gitGraph` branch name that starts with a digit is quoted:
  `branch "297-lockfile"`, as every `<issue>-short-name` branch is.
- A `gitGraph` `merge` takes an `id:` or a `tag:`, not both.
- `linkStyle`'s `color:` does not reach label text while `htmlLabels` is false.

## Design notes

- **Why C4 is the base**: it is built for this size, and *Container* means a
  deployable or runnable unit. 4+1's development view is module ownership across
  teams, an empty box for one developer and one repository; arc42 is a
  twelve-section document template, which the numbered documents already are;
  Rozanski and Woods' seven viewpoints are heavier than C4's views plus the
  five added here.
- **Why a change diagram has four states and not two**: a key of affected and
  unaffected also folds `removed` into affected, and loses the difference
  between a new box and a changed one, which matters in the Component and Code
  views.
- **Why `roadmap.svg` is not Mermaid**: Mermaid has no swimlanes, and the three
  ways to fake them fail:
  - a `flowchart` with a `subgraph` per lane draws a dependency inside a lane
    top to bottom;
  - a `flowchart` with `direction LR` lays the lanes out as columns once an edge
    crosses lanes;
  - `gantt` has no dependency arrows.
