#!/usr/bin/env python3
"""Run SW/HW build+sim sweep for dims and modes, then rename fresh dumps.

For each (mode, dim):
1) make -C golden-model gemm ...
2) make golden ...
3) make sw-build MX_ENABLE=...
4) make hw-build target=vsim
5) make hw-run target=vsim
6) rename fresh transcript/csv/txt with scripts/rename_dump.py
"""

import argparse
import subprocess
import sys
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(
        description="Run dim/mode VSIM sweep and save fresh dump files with suffixes."
    )
    parser.add_argument(
        "--dims",
        nargs="+",
        type=int,
        default=[32, 64, 96],
        help="Matrix dimensions to run (M=N=K). Default: 32 64 96",
    )
    parser.add_argument(
        "--modes",
        nargs="+",
        choices=["mx", "base", "baseline"],
        default=["mx", "base"],
        help="Run modes in this order. Use 'base' (or alias 'baseline'). Default: mx base",
    )
    parser.add_argument(
        "--target",
        default="vsim",
        help="Simulation target passed to make target=<target>. Default: vsim",
    )
    parser.add_argument(
        "--vsim-dir",
        default="target/sim/vsim",
        help="Directory containing simulation dumps. Default: target/sim/vsim",
    )
    parser.add_argument(
        "--window-seconds",
        type=float,
        default=180.0,
        help="Fresh-file window for rename_dump.py. Default: 180",
    )
    parser.add_argument(
        "--conflict",
        choices=["skip", "overwrite", "fail"],
        default="skip",
        help="rename_dump.py conflict behavior. Default: skip",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print commands but do not execute.",
    )
    return parser.parse_args()


def run_cmd(cmd, cwd, dry_run):
    cmd_str = " ".join(cmd)
    print("$", cmd_str)
    if dry_run:
        return
    subprocess.run(cmd, cwd=str(cwd), check=True)


def mode_to_mx_enable_and_suffix_tag(mode):
    if mode == "mx":
        return "1", "mx"
    return "0", "base"


def main():
    args = parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    rename_script = repo_root / "scripts" / "rename_dump.py"
    sw_inc = repo_root / "sw" / "inc"
    vsim_dir = repo_root / args.vsim_dir

    if not rename_script.exists():
        print("Error: rename script not found:", rename_script, file=sys.stderr)
        return 2

    if not sw_inc.exists():
        print("Error: SW include dir not found:", sw_inc, file=sys.stderr)
        return 2

    if not vsim_dir.exists():
        print("Error: VSIM directory not found:", vsim_dir, file=sys.stderr)
        return 2

    for dim in args.dims:
        for mode in args.modes:
            mx_enable, suffix_tag = mode_to_mx_enable_and_suffix_tag(mode)
            suffix = "{}{}".format(suffix_tag, dim)

            print(
                "\n=== mode={} dim={} (suffix={}) ===".format(
                    suffix_tag, dim, suffix
                )
            )

            run_cmd(
                [
                    "make",
                    "-C",
                    "golden-model",
                    "gemm",
                    "M={}".format(dim),
                    "N={}".format(dim),
                    "K={}".format(dim),
                    "SW={}".format(sw_inc),
                ],
                cwd=repo_root,
                dry_run=args.dry_run,
            )
            run_cmd(
                [
                    "make",
                    "golden",
                    "M={}".format(dim),
                    "N={}".format(dim),
                    "K={}".format(dim),
                ],
                cwd=repo_root,
                dry_run=args.dry_run,
            )
            run_cmd(
                [
                    "make",
                    "sw-build",
                    "MX_ENABLE={}".format(mx_enable),
                    "target={}".format(args.target),
                    "M={}".format(dim),
                    "N={}".format(dim),
                    "K={}".format(dim),
                ],
                cwd=repo_root,
                dry_run=args.dry_run,
            )
            run_cmd(
                ["make", "hw-build", "target={}".format(args.target)],
                cwd=repo_root,
                dry_run=args.dry_run,
            )
            run_cmd(
                ["make", "hw-run", "target={}".format(args.target)],
                cwd=repo_root,
                dry_run=args.dry_run,
            )
            run_cmd(
                [
                    "python3",
                    str(rename_script),
                    "--suffix",
                    suffix,
                    "--dir",
                    str(vsim_dir),
                    "--window-seconds",
                    str(args.window_seconds),
                    "--conflict",
                    args.conflict,
                ],
                cwd=repo_root,
                dry_run=args.dry_run,
            )

    print("\nSweep complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
