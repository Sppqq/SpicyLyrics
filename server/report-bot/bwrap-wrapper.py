#!/usr/bin/python3
"""Hide the parent Codex authentication mount from sandboxed tool commands."""
import os
import sys

args = sys.argv[1:]
real = "/usr/local/libexec/codex-bwrap-real"
if args == ["--help"]:
    os.execv(real, ["bwrap", *args])
try:
    separator = args.index("--")
except ValueError:
    raise SystemExit("bwrap command is missing --")
args[separator:separator] = [
    "--tmpfs", "/auth",
    "--ro-bind", "/dev/null", "/usr/local/libexec/codex-bwrap-real",
]
os.execv(real, ["bwrap", *args])
