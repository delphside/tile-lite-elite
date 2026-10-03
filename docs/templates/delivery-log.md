<!-- markdownlint-disable-file MD041 -->
<!--
The delivery log: one row per project delivery, appended, oldest first. The
rule is docs/5.1 §2.14, "The delivery log row is part of the delivery", and
the identifiers are 5.1, "A delivery that ships no application code". The
instance is a programme record. Delete these comments.
-->

# Delivery log

*One paragraph: where the log starts, and what earlier record covers anything
before it.*

## The deliveries

| id | date (UTC) | kind | where | what | outcome |
| --- | --- | --- | --- | --- | --- |
| *the release version, or production's version plus a letter* | *when it reached its users* | *release, image, host, drill, service or repository* | *the environment or service it reached* | *the project and delivery, and what it changed* | ***done**, or what was descoped, and how it was proved* |

## What each delivery left behind that git does not show

*For a delivery whose change lives outside git: what it found or left, and
where that is recorded.*
