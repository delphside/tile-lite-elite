# Diagram sources

Each `.mmd` here is the source for the `.svg` beside it. Edit the `.mmd`,
re-render, and commit both.

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

Diagrams that *are* simple enough for dagre stay inline in the docs, where
GitHub renders them from source — see the sequence diagram in
[3.3](../3.3-testing-ci-and-release.md). Inline is preferable when it works:
no rendering step, and the source is the thing you read.
