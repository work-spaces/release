#!/usr/bin/env spaces
"""
Collect JSON status files produced by release workflow steps and report whether
the release can proceed.

Each release step (for example ``update-version.exec.star`` and
``update-docs.exec.star``) writes a small JSON status file into the workspace
``build`` folder describing the state of that step, for example::

    {"status": "Complete"}
    {"status": "Need to merge PR at https://github.com/owner/repo/pull/123"}

This script gathers one or more such files (each passed with ``--status-file``,
which is repeatable) and aggregates their results:

- If every status is ``Complete``, the script prints a short confirmation and
  exits ``0``.
- If any status is not ``Complete`` (or a status file is missing or malformed),
  the script prints the outstanding actions to stdout and exits ``1`` so the
  release pipeline halts until a human performs those actions.

Example::

    collect-results.exec.star \\
        --status-file=build/update-version/spaces-v0.15.45.status.json \\
        --status-file=build/update-docs/work-spaces.github.io-v0.15.45.status.json
"""

load("//@star/sdk/star/std/args.star", "args_list", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_read_text")
load("//@star/sdk/star/std/json.star", "json_try_decode")
load("//@star/sdk/star/std/sys.star", "sys_exit")

_COMPLETE = "Complete"

def _status_for(status_file):
    """Return (is_complete, action) for a single status file.

    ``action`` is a human-readable description of what remains to be done, and
    is only meaningful when ``is_complete`` is ``False``.
    """
    if not fs_exists(status_file):
        return False, "status file is missing (step did not run or did not complete)"

    decoded = json_try_decode(fs_read_text(status_file), default = None)
    if type(decoded) != "dict":
        return False, "status file is missing or not valid JSON"

    status = decoded.get("status", "")
    if status == _COMPLETE:
        return True, ""
    if status == "":
        return False, "status file has no `status` field"
    return False, status

def main():
    """
    Aggregate release step status files and fail if any action is outstanding.
    """
    spec = args_parser(
        name = "collect-results",
        description = "Collect JSON status files and report whether the release can proceed.",
        options = [
            args_list("--status-file", help = "Path to a JSON status file (repeatable)"),
        ],
    )
    parsed = args_parse(spec)

    status_files = parsed.get("status_file", [])
    assert_on(len(status_files) > 0, "at least one --status-file is required")

    print("Collecting {} status file(s):".format(len(status_files)))

    pending = []
    for status_file in status_files:
        is_complete, action = _status_for(status_file)
        if is_complete:
            print("  [Complete] {}".format(status_file))
        else:
            print("  [Pending]  {}".format(status_file))
            pending.append((status_file, action))

    if len(pending) == 0:
        print("\nAll {} step(s) are complete.".format(len(status_files)))
        sys_exit(0)

    print("\nThe following action(s) are required before the release can continue:")
    for status_file, action in pending:
        print("- {}".format(action))
    print("")
    sys_exit(1)

main()
