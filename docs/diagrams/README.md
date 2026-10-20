# Diagram sources

The Mermaid sources of the pre-rendered diagrams, how to re-render them and the
conventions every diagram here follows.

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
| Deployment | C4 | which containers run on which infrastructure, per environment (physical) | [4.1.1](../4.1.1-architecture.md) |
| Dynamic | C4 | how elements interact over time: a sequence or a collaboration | [4.1.2](../4.1.2-components-and-interactions.md) |
| Concurrency | Rozanski and Woods | what can run at the same time and how it is bounded: the semaphores, the sweeps, the scheduler | none yet |
| Information | Rozanski and Woods | the data: what is stored, its shape and who owns it, and how it flows | [4.4.2](../4.4.2-database-schema.md)'s entity-relationship diagram |
| State machine | UML | the lifecycle of one thing: its states and the transitions between them | none yet |
| Use case | UML | who uses the service, and what each may do | none yet |
| Activity | UML | a user's journey through the service, step by step | none yet |

- **Information:** the data's structure is an entity-relationship diagram. Its
  flows go on the arrows of the other views, each arrow labelled with the data
  it carries (a DTO, a row or an event), so the Container and Component views
  show them without a diagram of their own. A separate data flow diagram is the
  fallback, for the part of a system whose arrows carry too many flows to read.
- **State machines** label a transition with the method or event that causes it,
  so the diagram also says where each state change is handled.
- **Use case diagrams** are one for the service. The actors include a role held
  in one game (its creator), bots and a clock actor for scheduled events
  (expiry, reminders); each line is a permission, and each use case has an
  activity diagram. Mermaid has no use case diagram, so it is a flowchart:
  actors outside a subgraph for the system boundary, use cases inside it as
  stadium shapes.
- **Activity diagrams** sit between the text requirements and the architecture.
  Each step either causes a state machine transition or only reads state, and
  cites the `docs/4.1.0` rules it exercises, so the end-to-end tests come from
  them.
- **Code** is drawn only for a component with real rules in it, such as the game
  service or the rules engine.
- **Container and Deployment** differ: Container is logical and has no
  environments, so a missing environment shows only in a Deployment view.

A process diagram takes no view: `release-flow`, `version-lifecycle` and
`flavour-a-pre-approved` to `flavour-d-multi-delivery-release` show how a
*change* moves, and `roadmap.svg` shows when work happens.

### Change state

**A diagram of a change colours every box by what happens to it**, in the
classes below. A line's state goes in its label (`-- new -->`,
`-- changed -->`), because Mermaid has no `classDef` for edges; a removed line
is dotted with a `removed` label, because an absent line looks like one nobody
drew.

| Class | Means |
| --- | --- |
| `unchanged` | it exists and this change does not touch it |
| `new` | it does not exist yet |
| `changed` | it exists and this change modifies it |
| `removed` | it exists and this change takes it away |

```text
classDef unchanged    fill:#f6f8fa,stroke:#8c959f,color:#1f2328
classDef new          fill:#dafbe1,stroke:#1a7f37,color:#0a3622
classDef changed      fill:#fff8c5,stroke:#9a6700,color:#4d2d00
classDef removed      fill:#ffebe9,stroke:#cf222e,color:#6e0a12
```

## Rendering

Each `.mmd` here is the source for the `.svg` beside it. Edit the `.mmd`,
re-render and commit both. Render from the repository root:

```bash
npx -y @mermaid-js/mermaid-cli@11.17.0 -i docs/diagrams/release-flow.mmd \
  -o docs/diagrams/release-flow.svg -c docs/diagrams/mermaid-config.json -b white
```

| Symptom | Cause | Fix |
| --- | --- | --- |
| the command writes nothing and exits 1 with no message | `~/.cache/puppeteer` holds *empty* version directories, so Puppeteer believes Chromium is installed and launches nothing; `mermaid-cli` swallows the error, and clearing the cache fails too when the re-download fails | render in Docker, which carries its own browser (next command) |
| the SVG is owned by root | the container ran as root | pass `-u "$(id -u):$(id -g)"` |

```bash
docker run --rm -u "$(id -u):$(id -g)" -v "$PWD/docs/diagrams":/data \
  minlag/mermaid-cli:11.17.0 -i /data/release-flow.mmd -o /data/release-flow.svg \
  -c /data/mermaid-config.json -b white
```

**`roadmap.svg` has no `.mmd`.** The board is its source:
`programme/scripts/board/roadmap-diagram.py --write` regenerates it and the
block in [4.1.5](../4.1.5-work-in-progress.md) that embeds it, and the next run
overwrites a hand edit. `programme/scripts/board/roadmap.py` draws it.

### Conventions of the process diagrams

- **Colour is a category:** blue for what runs code (`classDef env`), sand for
  what stores it (`repo`), green for a branch (`branch`), amber for a gate a
  script refuses on (`gate`). A box joins a category through its class, not a
  per-node style.
- **Bold is an action somebody takes;** normal weight happens on its own. Bold
  is a Mermaid markdown string (a backtick-quoted label, `**bold**` inside), as
  `<b>` is printed literally while `htmlLabels` is false.
- **Line shape carries meaning structurally:** a solid arrow moves code, a
  dotted arrow returns an answer, and a diamond is a decision taken during an
  action.
- **Marks in a label:**

  | Mark | Means |
  | --- | --- |
  | `$` before a command | you type it |
  | `(automatic)` | done on your behalf |
  | a non-breaking space after `$`, and `wrappingWidth` | keep a long command on one line |

- **Arrow numbers are the runbook's section numbers** in
  [4.3.3](../4.3.3-testing-ci-and-release.md#1-what-to-type): arrow 1.5 is step
  1.5.
- **`release-flow.mmd` has no `linkStyle`.** Its edge indices count invisible
  `~~~` links, so one new arrow moves the colouring onto the wrong lines.

### Settings

| Setting | Where | Why |
| --- | --- | --- |
| `htmlLabels: false` | `mermaid-config.json` | GitHub shows an embedded SVG containing `foreignObject`, which Mermaid emits for HTML labels, as a blank box |
| `layout: elk` | the `.mmd` header | ELK routes orthogonally and places labels without collisions, which dagre could not for these graphs; it needs `@mermaid-js/layout-elk`, which `mermaid-cli` 11.17.0 bundles and GitHub's Mermaid does not, so these diagrams are pre-rendered and embedded |

### Mermaid parse errors

A syntax error renders as a bomb icon reading *Syntax error in text*, with no
line number and nothing on stderr; bisect the source to find the line.

- A bare `%%` line is parsed as a node. Use `%% .` for a blank line in a comment
  block.
- A `gitGraph` branch name that starts with a digit is quoted:
  `branch "297-lockfile"`, as every `<issue>-short-name` branch is.
- A `gitGraph` `merge` takes an `id:` or a `tag:`, not both.
- `linkStyle`'s `color:` does not reach label text while `htmlLabels` is false.

## Inline diagrams

A diagram simple enough for dagre stays inline in its document, where GitHub
renders it from source, and needs no rendering step.

## Design notes

- **Why C4 is the base:** it is built for this size, and *Container* means a
  deployable or runnable unit. 4+1's development view is module ownership across
  teams, an empty box for one developer and one repository; arc42 is a
  twelve-section document template, which the numbered documents already are;
  Rozanski and Woods' seven viewpoints are heavier than C4's views plus the
  five added here.
- **Why a change diagram has four states and not two:** an affected and
  unaffected key loses the difference between a new box and a changed one, which
  matters at the detail level.
- **Why `roadmap.svg` is not Mermaid:** Mermaid has no swimlanes, and the two
  ways to fake them fail:
  - a `flowchart` with a `subgraph` per lane draws a dependency inside a lane
    top to bottom;
  - with `direction LR`, it lays the lanes out as columns once an edge crosses
    lanes.

  `gantt` has no dependency arrows. `roadmap.py` draws the SVG directly, with
  presentation attributes and polygon arrowheads and no `<style>`, `<defs>` or
  `<marker>`, which GitHub's SVG sanitiser removes as it does `foreignObject`.
