#!/usr/bin/env python3
"""Compare two per-move benchmark runs, excluding the hypervisor's outliers.

A percentile taken on a shared VM is not evidence about this code: on
2026-09-04 the VM's p99 was 12.9x the laptop's while its median was 1.6x, and
the difference was moves the hypervisor descheduled. Those moves are a
different set every run — four runs flagged 102 distinct moves between them and
exactly one in common — so they cannot be excluded by naming them. They are
excluded by pairing.

The games are seeded, so `(game, turn)` is the same position in both runs. A
move whose ratio between the two machines is far above the machine's own factor
did not become harder; it waited. The cut is not chosen: the per-move ratio has
a natural break, p97 at 2.7x and p98 at 10.4x, and any threshold between 3x and
8x isolates the same moves.

Excluding by ratio biases the result, and the owner spotted it: a genuinely
slow move lasts longer and so is likelier to overlap a descheduling event, so
the exclusion removes the expensive positions preferentially. Measured over five
runs, the dropped positions cost 1.20 ms elsewhere against 0.40 ms for all
positions — three times typical — and the single-run figures understate by 5%
at the median and 27% at the p99.

The unbiased form takes several runs of the subject. Each position is reduced to
the mean of its own timings, discarding any above three times that position's
median across the runs, and the statistics are taken over those per-position
means. No position is dropped, so nothing is selected out.

Both sides take as many runs as you have. Comparing two engines means several
runs of each on the same machine, which is the `--` form.

`--wide FILE` also writes every run given into one CSV, a row per position and
a `wall`/`cpu` column pair per run, so the runs can be analysed side by side
without joining files first.

Usage:
  bench-compare.py ref.csv sub.csv                    single run each, biased
  bench-compare.py ref.csv sub1.csv sub2.csv ...      unbiased subject
  bench-compare.py a1.csv a2.csv -- b1.csv b2.csv     unbiased both sides
  bench-compare.py ... --wide moves-wide.csv          plus the merged CSV
"""

import csv
import statistics
import sys


def load(path):
    with open(path) as handle:
        return {
            (row["game"], row["turn"]): row for row in csv.DictReader(handle)
        }


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, int(fraction * (len(ordered) - 1)))
    return ordered[index]


def summarise(rows, keys):
    walls = [float(rows[k]["wall_ms"]) for k in keys]
    return (
        statistics.median(walls),
        percentile(walls, 0.95),
        percentile(walls, 0.99),
        max(walls),
    )


def per_move_means(subjects, keys, factor=3.0):
    """One value per position: the mean of its timings, less any stall.

    The baseline is the position's **minimum** across the runs, not its median.
    A stall only ever adds time, so the fastest observation is the best estimate
    of what the position costs when nothing interrupts it, and a timing above
    `factor` times that is a stall rather than a slower position.

    The median looks like the robust choice and is not. With two runs the median
    is their mean, so a stall drags the baseline up with it and escapes
    rejection: splitting five runs of the same engine two against three gave
    0.390x at the p95, where a correct rule must give 1.0. The minimum gives
    1.077 on the same split and 1.017 the other way round.

    The position is its own control, so no reference machine is needed and no
    position is discarded.
    """
    means, dropped = {}, 0
    for key in keys:
        values = [float(s[key]["wall_ms"]) for s in subjects]
        baseline = min(values)
        good = [v for v in values if v <= factor * baseline]
        dropped += len(values) - len(good)
        means[key] = statistics.mean(good or values)
    return means, dropped


def write_wide(path, references, subjects, keys, factor=3.0):
    """Every run in one CSV, with the per-move analysis on the same row.

    A row per position: the raw `wall`/`cpu` pair for each run, then that
    position reduced — its minimum, how many timings were discarded as stalls,
    and the mean of what survived. Statistics are then a column, not a join.

    Reduced per side. A mean across a laptop run and a VM run would be an
    average of two machines and mean nothing, so the sides are kept apart and
    the ratio between their means is the last column: `ratio_mean_wall` is
    subject divided by reference, so above 1 means the subject is slower.

    Columns are named by each run's own id, the `run` value its summary row
    carries, so the file says which runs it holds without a separate legend.

    The position's fixed properties are written once and checked rather than
    assumed: the games are seeded, so `blanks` and `rack_tiles` must agree
    across every run, and if they do not then these are not runs of one thing.
    """

    def reduce_at(runs, key):
        walls = [float(r[key]["wall_ms"]) for r in runs]
        cpus = [float(r[key]["cpu_ms"]) for r in runs]
        baseline = min(walls)
        keep = [i for i, w in enumerate(walls) if w <= factor * baseline]
        if not keep:
            keep = list(range(len(walls)))
        return (
            len(walls),
            baseline,
            len(walls) - len(keep),
            statistics.mean(walls[i] for i in keep),
            statistics.mean(cpus[i] for i in keep),
        )

    sides = [("ref", references), ("sub", subjects)]
    header = ["game", "turn", "seat", "blanks", "rack_tiles"]
    for name, runs in sides:
        for run in runs:
            run_id = next(iter(run.values()))["run"]
            header += [f"{name}_wall_{run_id}", f"{name}_cpu_{run_id}"]
    for name, _ in sides:
        header += [
            f"{name}_runs",
            f"{name}_min_wall_ms",
            f"{name}_stalls_dropped",
            f"{name}_mean_wall_ms",
            f"{name}_mean_cpu_ms",
        ]
    header.append("ratio_mean_wall")

    with open(path, "w", newline="") as handle:
        # csv.writer defaults to CRLF. Every other CSV here is written by the
        # Rust benchmark with plain newlines, and a file that silently differs
        # breaks the next grep or awk somebody points at it — which is how this
        # was found.
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        for key in keys:
            first = (references + subjects)[0][key]
            for other in references + subjects:
                if (other[key]["blanks"], other[key]["rack_tiles"]) != (
                    first["blanks"],
                    first["rack_tiles"],
                ):
                    raise SystemExit(
                        f"position {key} has a different rack between runs — "
                        "these are not runs of the same benchmark"
                    )
            row = [key[0], key[1], first["seat"], first["blanks"], first["rack_tiles"]]
            for _, runs in sides:
                for run in runs:
                    row += [run[key]["wall_ms"], run[key]["cpu_ms"]]
            reduced = {}
            for name, runs in sides:
                reduced[name] = reduce_at(runs, key)
                count, baseline, dropped, mean_wall, mean_cpu = reduced[name]
                row += [count, f"{baseline:.4f}", dropped, f"{mean_wall:.4f}", f"{mean_cpu:.4f}"]
            ref_mean, sub_mean = reduced["ref"][3], reduced["sub"][3]
            row.append(f"{sub_mean / ref_mean:.4f}" if ref_mean > 0 else "")
            writer.writerow(row)
    return len(references) + len(subjects)


def main(argv):
    if len(argv) < 3:
        print("usage: bench-compare.py <reference.csv> <subject.csv> [more-subject.csv ...]", file=sys.stderr)
        return 2
    cut = 5.0
    if "--cut" in argv:
        cut = float(argv[argv.index("--cut") + 1])
    args = argv[1:]
    if "--cut" in args:
        i = args.index("--cut")
        del args[i : i + 2]
    wide = None
    if "--wide" in args:
        i = args.index("--wide")
        if i + 1 >= len(args):
            print("--wide needs a file to write to", file=sys.stderr)
            return 2
        wide = args[i + 1]
        del args[i : i + 2]

    if "--" in args:
        split = args.index("--")
        ref_paths, sub_paths = args[:split], args[split + 1 :]
    else:
        ref_paths, sub_paths = args[:1], args[1:]
    if not ref_paths or not sub_paths:
        print("usage: bench-compare.py ref.csv sub.csv [more...] [-- more-ref-runs]", file=sys.stderr)
        return 2

    references = [load(p) for p in ref_paths]
    subjects = [load(p) for p in sub_paths]
    reference, subject = references[0], subjects[0]
    keys = sorted(
        set(reference).intersection(*[set(s) for s in references + subjects])
    )
    if not keys:
        print("no moves in common — are these runs of the same benchmark?", file=sys.stderr)
        return 1
    missing = len(set(reference) ^ set(subject))
    if missing:
        print(f"warning: {missing} moves appear in only one run", file=sys.stderr)

    outliers = [
        k
        for k in keys
        if float(reference[k]["wall_ms"]) > 0
        and float(subject[k]["wall_ms"]) / float(reference[k]["wall_ms"]) > cut
    ]
    kept = [k for k in keys if k not in set(outliers)]

    if wide:
        n_runs = write_wide(wide, references, subjects, keys)
        print(f"wrote {wide}: {len(keys)} rows, {n_runs} runs, with each move reduced on its own row")
        print()

    print(f"paired on (game, turn): {len(keys)} moves")
    print(f"excluded: {len(outliers)} ({100 * len(outliers) / len(keys):.1f}%) over {cut:g}x the reference")
    print()
    header = f"{'':26}{'median':>9}{'p95':>9}{'p99':>9}{'max':>9}"
    print(header)
    ref = summarise(reference, keys)
    raw = summarise(subject, keys)
    clean = summarise(subject, kept)
    for name, stats in (("reference", ref), ("subject, all moves", raw), ("subject, cleaned", clean)):
        print(f"  {name:24}" + "".join(f"{v:9.2f}" for v in stats))
    print()
    print("  ratio, cleaned:          " + "".join(
        f"{c / r:8.3f}x" for c, r in zip(clean[:3], ref[:3])
    ))
    print("  ratio, all moves:        " + "".join(
        f"{a / r:8.3f}x" for a, r in zip(raw[:3], ref[:3])
    ))
    print()
    if len(subjects) > 1 or len(references) > 1:
        means, dropped_timings = per_move_means(subjects, keys)
        ref_means, ref_dropped = per_move_means(references, keys)
        ref_values = [ref_means[k] for k in keys]
        ref = (
            statistics.median(ref_values),
            percentile(ref_values, 0.95),
            percentile(ref_values, 0.99),
            max(ref_values),
        )
        if len(references) > 1:
            print()
            print(f"  {'reference, per-move means':24}" + "".join(f"{v:9.2f}" for v in ref))
        values = [means[k] for k in keys]
        unbiased = (
            statistics.median(values),
            percentile(values, 0.95),
            percentile(values, 0.99),
            max(values),
        )
        print()
        print(f"  {len(subjects)} subject runs, per-move means, {dropped_timings} stalled timings discarded "
              f"({100 * dropped_timings / (len(keys) * len(subjects)):.2f}%), no position dropped")
        print(f"  {'subject, per-move means':24}" + "".join(f"{v:9.2f}" for v in unbiased))
        print("  ratio, per-move means:   " + "".join(
            f"{u / r:8.3f}x" for u, r in zip(unbiased[:3], ref[:3])
        ))
        print()
        print("The per-move means are the figure to quote. Excluding whole moves biases")
        print("the result: a slow move lasts longer, so it is likelier to be descheduled,")
        print("and dropping it removes the expensive positions preferentially.")
    else:
        print("One run, so whole moves are excluded and the result is biased low —")
        print("a slow move is likelier to be descheduled and so likelier to be dropped.")
        print("Pass several subject runs for the unbiased per-move means.")

    if outliers:
        ref_cost = statistics.median(float(reference[k]["wall_ms"]) for k in outliers)
        with_blank = sum(1 for k in outliers if int(subject[k]["blanks"]) > 0)
        print()
        print(f"The excluded moves cost {ref_cost:.2f} ms on the reference, against its")
        print(f"{ref[0]:.2f} ms median, and {with_blank} of {len(outliers)} held a blank. Ordinary positions,")
        print("in other words, rather than hard ones.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
