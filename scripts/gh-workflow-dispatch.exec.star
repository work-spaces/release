#!/usr/bin/env spaces
"""
Trigger a GitHub Actions workflow via ``gh workflow run`` (a workflow_dispatch
event) and follow the resulting run to completion.

Requires ``gh`` >= 2.87.0, which introduced the ``return_run_details`` API
behavior so that ``gh workflow run`` immediately prints the created run URL.
The run id is recovered by parsing that URL, removing the need to poll
``gh run list`` to discover the dispatched run.

The script:

1. Runs ``gh workflow run <workflow> --repo <owner/repo> --ref <ref>``,
   forwarding any ``--field key=value`` (-> ``-f``) and
   ``--raw-field key=value`` (-> ``-F``) inputs, and captures stdout.
2. Extracts the run id from the printed
   ``https://<host>/<owner>/<repo>/actions/runs/<id>`` URL.
3. Polls ``gh run view <id> --json status,conclusion,url`` every
   ``--poll-interval`` seconds until ``status == "completed"`` (or
   ``--timeout`` seconds elapse).
4. On a non-success conclusion, prints failed logs via
   ``gh run view <id> --log-failed`` and aborts.

Example::

    gh.exec.star \\
        --owner=work-spaces \\
        --repo=spaces \\
        --workflow=release.yml \\
        --ref=v0.15.45 \\
        --field=tag=v0.15.45
"""

load("//@star/sdk/star/std/args.star", "args_list", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/json.star", "json_decode")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_capture", "process_stdout_inherit")
load("//@star/sdk/star/std/string.star", "string_regex_captures")
load("//@star/sdk/star/std/time.star", "time_sleep_seconds")

# Statuses reported by ``gh run view --json status``. Anything other than
# "completed" means the run is still in flight.
_TERMINAL_STATUS = "completed"

# Conclusion values that indicate a successful run.
_SUCCESS_CONCLUSION = "success"
_FAIL_CONCLUSION = "failure"

# Matches the run id in URLs like ``https://github.com/owner/repo/actions/runs/12345678``
# (or ``/attempts/N`` suffix). gh 2.87+ prints this URL on stdout after a
# successful workflow_dispatch when the host supports ``return_run_details``.
_RUN_URL_PATTERN = r"/actions/runs/(?P<id>\d+)"

def _repo_slug(owner, repo):
    return "{}/{}".format(owner, repo)

def _gh_capture(args):
    """Run ``gh`` capturing stdout; raise on non-zero exit."""
    return process_run(process_options(
        command = "gh",
        args = args,
        stdout = process_stdout_capture(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

def _build_dispatch_args(repo_slug, workflow, ref, fields, raw_fields):
    args = [
        "workflow",
        "run",
        workflow,
        "--repo",
        repo_slug,
        "--ref",
        ref,
    ]
    for field in fields:
        args.append("-f")
        args.append(field)
    for field in raw_fields:
        args.append("-F")
        args.append(field)
    return args

def _dispatch_and_get_run_id(repo_slug: str, workflow: str, ref: str, fields: list[str], raw_fields: list[str]) -> int:
    """
    Dispatch the workflow and return the new run id from gh's stdout.

    Args:
        repo_slug: The repository slug (e.g. "owner/repo").
        workflow: The workflow file name (e.g. "workflow.yml").
        ref: The git ref to dispatch the workflow on (e.g. "main").
        fields: A list of field-value pairs to pass to `gh workflow run`.
        raw_fields: A list of raw field-value pairs to pass to `gh workflow run`.

    Returns:
        The new run id as an integer.
    """
    print("Dispatching workflow {} on {}@{}".format(workflow, repo_slug, ref))
    result = _gh_capture(_build_dispatch_args(repo_slug, workflow, ref, fields, raw_fields))
    stdout = result.get("stdout", "")

    # Echo gh's output so the user sees the standard "Created workflow_dispatch
    # event ..." message and the run URL.
    if stdout != "":
        print(stdout)

    captures = string_regex_captures(_RUN_URL_PATTERN, stdout)
    if captures == None:
        assert_on(
            False,
            "Could not extract a run id from `gh workflow run` output. " +
            "This requires `gh` >= 2.87.0 against a host that supports " +
            "`return_run_details` (github.com or GHES >= 3.21). gh stdout was:\n{}".format(stdout),
        )
        return int(0)
    else:
        return int(captures["id"])

def _view_run(repo_slug: str, run_id: int) -> dict:
    """
    View the details of a GitHub workflow run.

    Args:
        repo_slug: The repository slug (e.g. "owner/repo").
        run_id: The run id to view.

    Returns:
        A dictionary containing the run details.
    """
    result = _gh_capture([
        "run",
        "view",
        "{}".format(run_id),
        "--repo",
        repo_slug,
        "--json",
        "status,conclusion,url,name,displayTitle",
    ])
    return json_decode(result["stdout"])

def _wait_for_completion(repo_slug: str, run_id: int, poll_interval: int, timeout_seconds: int) -> dict:
    """
    Poll a run until it reaches the terminal ``completed`` status.

    Args:
        repo_slug: The repository slug (e.g. "owner/repo").
        run_id: The run id to wait for.
        poll_interval: The number of seconds to wait between polls.
        timeout_seconds: The maximum number of seconds to wait for completion.

    Returns:
        A dictionary containing the run details when it reaches the terminal status.
    """

    # Starlark forbids ``while``; iterate a bounded range sized by the timeout.
    max_attempts = (timeout_seconds // poll_interval) + 1
    last_status = ""
    last_info = {}
    for _ in range(max_attempts):
        info = _view_run(repo_slug, run_id)
        last_info = info
        status = info.get("status", "")
        if status != last_status:
            print("Run {} status: {}".format(run_id, status))
            last_status = status
        if status == _TERMINAL_STATUS:
            return info
        time_sleep_seconds(poll_interval)

    assert_on(False, "Timed out waiting for run {} to complete (last status: {}, conclusion: {})".format(
        run_id,
        last_info.get("status", ""),
        last_info.get("conclusion", ""),
    ))
    return {}

def _print_failed_logs(repo_slug: str, run_id: int) -> None:
    """
    Best-effort dump of failed-step logs to help debug a bad run.

    Args:
        repo_slug: The repository slug (e.g. "owner/repo").
        run_id: The run id to fetch logs for.
    """
    print("Fetching failed logs for run {}...".format(run_id))
    process_run(process_options(
        command = "gh",
        args = [
            "run",
            "view",
            "{}".format(run_id),
            "--repo",
            repo_slug,
            "--log-failed",
        ],
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = False,
    ))

def main():
    """Entry point: parse args, dispatch the workflow, and follow it."""
    spec = args_parser(
        name = "gh-exec",
        description = "Dispatch a GitHub Actions workflow and follow it to completion.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (informational; gh auth is used as-is)"),
            args_opt("--owner", help = "Repository owner (user or organization)"),
            args_opt("--repo", help = "Repository name"),
            args_opt("--workflow", help = "Workflow file name (e.g. release.yml) or numeric workflow id"),
            args_opt("--ref", default = "main", help = "Git ref (branch or tag) to run the workflow against"),
            args_list("--field", short = "-f", help = "Workflow input as key=value (repeatable; passed to gh as -f)"),
            args_list("--raw-field", short = "-F", help = "Workflow input as key=value, no template expansion (repeatable; passed to gh as -F)"),
            args_opt("--poll-interval", type = "int", default = 10, help = "Seconds between status polls (default 10)"),
            args_opt("--timeout", type = "int", default = 1800, help = "Total seconds to wait for the run to finish (default 1800)"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "github.com")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    workflow = parsed.get("workflow", "")
    ref = parsed.get("ref", "main")
    fields = parsed.get("field", [])
    raw_fields = parsed.get("raw-field", [])
    poll_interval = parsed.get("poll-interval", 10)
    timeout_seconds = parsed.get("timeout", 1800)

    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(workflow != "", "--workflow is required")
    assert_on(ref != "", "--ref is required")
    assert_on(poll_interval > 0, "--poll-interval must be > 0")
    assert_on(timeout_seconds > 0, "--timeout must be > 0")

    repo_slug = _repo_slug(owner, repo)

    print("Repository: {} (host: {})".format(repo_slug, host))
    print("Workflow:   {}".format(workflow))
    print("Ref:        {}".format(ref))
    if len(fields) > 0:
        print("Fields:     {}".format(fields))
    if len(raw_fields) > 0:
        print("Raw fields: {}".format(raw_fields))

    run_id = _dispatch_and_get_run_id(repo_slug, workflow, ref, fields, raw_fields)
    print("Dispatched run id: {}".format(run_id))

    info = _wait_for_completion(repo_slug, run_id, poll_interval, timeout_seconds)
    conclusion = _FAIL_CONCLUSION
    if info:
        conclusion = info.get("conclusion", "")
        print("Run {} completed with conclusion: {}".format(run_id, conclusion))
        run_url = info.get("url", "")
        if run_url != "":
            print("Run URL: {}".format(run_url))

    if conclusion != _SUCCESS_CONCLUSION:
        _print_failed_logs(repo_slug, run_id)
        assert_on(False, "Workflow run {} did not succeed (conclusion: {})".format(run_id, conclusion))

main()
