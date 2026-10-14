<!-- markdownlint-disable-file MD041 -->
<!--
The artefact register: everything under change control that leaves no trace in
git. The rule is docs/5.1 §2.13 (naming, and what counts as an artefact) and
§2.15 (route). The instance is a programme record and changes on main. Delete
these comments.
-->

# Artefacts outside the repository

The register of everything under change control that leaves no trace in git.
For these, this file is the only record, so each entry carries enough to
recreate it.

## *Where they live: a host, a cloud provider, a hosted service*

*When and how this list was last verified.*

| artefact | route | what it is | why it is not in the repository |
| --- | --- | --- | --- |
| *canonical name (5.1 §2.13)* | *Production Release, or Other* | *what it does* | *a secret, a console setting, a copy made by a deploy* |

## What a script's exit status means

| script | 0 | non-zero |
| --- | --- | --- |
| *script* | *what success means* | *what each failure means* |

## Not yet recorded

*Artefacts known to exist and not yet described, each with the issue that will
record it.*
