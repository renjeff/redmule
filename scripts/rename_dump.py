#!/usr/bin/env python3
"""Rename fresh VSIM dump artifacts by appending a suffix.

This script intentionally targets only:
- transcript (no extension)
- *.csv
- *.txt
"""

import argparse
import fnmatch
import os
import sys
from pathlib import Path


DEFAULT_GLOBS = [
    "transcript",
    "engine_boundary_trace.csv",
    "engine_compute_trace.csv",
    "engine_feed_trace.csv",
    "engine_ingress_ctrl_trace.csv",
    "w_path_cycle_trace.csv",
    "z_path_trace.csv",
    "engine_w_inputs.txt",
    "engine_x_inputs.txt",
    "engine_z_outputs.txt",
    "mx_decoder_exponents.txt",
    "mx_decoder_fp16_outputs.txt",
    "mx_decoder_targets.txt",
    "mx_encoder_exponents.txt",
    "mx_encoder_fp16_inputs.txt",
    "mx_encoder_fp8_outputs.txt",
    "z_buffer_muxed_stream.txt",
    "z_buffer_q_stream.txt",
    "z_engine_source.txt",
    "z_engine_source_accepted.txt",
]


def parse_args():
    parser = argparse.ArgumentParser(
        description="Append suffix to fresh transcript/csv/txt files from the latest run."
    )
    parser.add_argument(
        "--suffix",
        required=True,
        help="Suffix to append (accepts 'mx96' or '_mx96').",
    )
    parser.add_argument(
        "--dir",
        default="target/sim/vsim",
        help="Directory containing run dump files (default: target/sim/vsim).",
    )
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=180.0,
        help="Include files within this many seconds of newest candidate (default: 180).",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Rename all matching files instead of only latest-run files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show rename plan without modifying files.",
    )
    parser.add_argument(
        "--conflict",
        choices=["skip", "overwrite", "fail"],
        default="skip",
        help="What to do if destination exists (default: skip).",
    )
    parser.add_argument(
        "--glob",
        action="append",
        dest="globs",
        help="Extra filename glob(s) to include; can be passed multiple times.",
    )
    return parser.parse_args()


def normalize_suffix(raw):
    clean = raw.strip()
    while clean.startswith("_"):
        clean = clean[1:]
    if not clean:
        raise ValueError("Suffix is empty after removing leading underscores.")
    return clean


def load_candidates(root, patterns):
    candidates = []
    for path in root.iterdir():
        if not path.is_file():
            continue
        name = path.name
        if any(fnmatch.fnmatch(name, pat) for pat in patterns):
            candidates.append(path)
    return candidates


def build_destination(path, suffix):
    stem = path.stem
    ext = path.suffix
    if not ext:
        if path.name.endswith("_" + suffix):
            return None
        return path.with_name(path.name + "_" + suffix)

    if stem.endswith("_" + suffix):
        return None
    return path.with_name(stem + "_" + suffix + ext)


def select_latest_run(files, window_seconds):
    if not files:
        return []
    newest = max(p.stat().st_mtime for p in files)
    threshold = newest - window_seconds
    return [p for p in files if p.stat().st_mtime >= threshold]


def main():
    args = parse_args()
    suffix = normalize_suffix(args.suffix)
    root = Path(args.dir)

    if not root.exists() or not root.is_dir():
        print("Error: directory not found:", root, file=sys.stderr)
        return 2

    patterns = list(DEFAULT_GLOBS)
    if args.globs:
        patterns.extend(args.globs)

    candidates = load_candidates(root, patterns)
    if not args.all:
        candidates = select_latest_run(candidates, args.window_seconds)

    plan = []
    for src in candidates:
        dst = build_destination(src, suffix)
        if dst is None or dst == src:
            continue
        plan.append((src, dst))

    plan.sort(key=lambda pair: (pair[0].stat().st_mtime, pair[0].name))

    if not plan:
        print("No files matched rename criteria.")
        return 0

    if args.conflict == "fail":
        conflicts = [dst for _, dst in plan if dst.exists()]
        if conflicts:
            print("Conflict(s) found. Aborting because --conflict=fail:")
            for dst in conflicts:
                print("  ", dst)
            return 3

    renamed = 0
    skipped = 0

    for src, dst in plan:
        if dst.exists():
            if args.conflict == "skip":
                print("SKIP (exists): {} -> {}".format(src.name, dst.name))
                skipped += 1
                continue
            if args.conflict == "overwrite":
                if args.dry_run:
                    print("DRY-RUN OVERWRITE: {} -> {}".format(src.name, dst.name))
                    continue
                dst.unlink()

        if args.dry_run:
            print("DRY-RUN: {} -> {}".format(src.name, dst.name))
            continue

        os.replace(str(src), str(dst))
        print("RENAMED: {} -> {}".format(src.name, dst.name))
        renamed += 1

    if args.dry_run:
        print("Dry run complete. Planned operations:", len(plan))
    else:
        print("Done. Renamed: {}, skipped: {}".format(renamed, skipped))

    return 0


if __name__ == "__main__":
    sys.exit(main())
