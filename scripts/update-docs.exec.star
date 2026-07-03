#!/usr/bin/env spaces
"""
Update and publish work-spaces.github.io docs for a released spaces tag.

This script orchestrates the docs publish flow:

1. Regenerates ``internal/version.star`` in the docs repo with versions from:

   - ``SPACES_VERSION`` from ``--spaces-tag`` (without the leading ``v``)
   - ``SDK_REV`` from ``--sdk-tag``
   - ``PACKAGE_REV`` from ``--packages-tag``

   If the generated file differs from ``main``, it commits the change on a
   branch and opens a PR. The script then writes a status file of the form
   ``Need to merge PR at <url>`` and exits successfully.
2. Refreshes the docs checkout to ``origin/main`` and verifies docs generation
   by running:

       spaces run //work-spaces.github.io:work-spaces.github.io_archive

   in ``docs/work-spaces.github.io`` (configurable via ``--workdir``).
3. Uses ``release/scripts/create-release.exec.star`` to create a release on the
   docs repo for the current spaces tag.
4. Uses ``release/scripts/gh-workflow-dispatch.exec.star`` to dispatch
   ``pages.yaml`` and follow it to completion.

Status file:

- A JSON status file is written into the workspace ``build`` folder describing
  the state of the workflow, for example ``{"status": "Complete"}`` once the
  whole flow finishes, or ``{"status": "Need to merge PR at <url>"}`` when a
  human still needs to merge the docs version-bump PR. Whenever the status file
  is written the script exits successfully.
"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_mkdir", "fs_read_text", "fs_write_text")
load("//@star/sdk/star/std/json.star", "json_write_file")
load(
    "internal/utils.star",
    "utils_create_pr",
    "utils_find_existing_pr",
    "utils_git",
    "utils_refresh_main",
    "utils_repo_slug",
    "utils_run",
)

_CREATE_RELEASE_SCRIPT = "release/scripts/create-release.exec.star"
_GH_DISPATCH_SCRIPT = "release/scripts/gh-workflow-dispatch.exec.star"

_VERSION_FILE_PATH = "internal/version.star"

def _arg(parsed: dict, key: str, fallback = ""):
    """Best-effort compatibility helper for dashed/underscored arg names."""
    underscored = key.replace("-", "_")
    return parsed.get(underscored, parsed.get(key, fallback))

def _write_status(status_file: str, status: str) -> None:
    """Write a JSON status file describing the state of the workflow."""
    parent = status_file.rsplit("/", 1)
    if len(parent) == 2:
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    json_write_file(status_file, {"status": status})
    print("Wrote status file: {} ({})".format(status_file, status))

def _spaces_version_from_tag(tag: str) -> str:
    assert_on(tag != "", "--spaces-tag is required")
    assert_on(tag.startswith("v"), "--spaces-tag must start with 'v' (for example: v0.15.45)")
    version = tag[1:]
    assert_on(version != "", "--spaces-tag has no version after the leading 'v'")
    return version

def _render_version_file(spaces_version: str, sdk_tag: str, packages_tag: str) -> str:
    return "\n".join([
        "\"\"\"",
        "Spaces version",
        "\"\"\"",
        "",
        "SPACES_VERSION = \"{}\"".format(spaces_version),
        "SDK_REV = \"{}\"".format(sdk_tag),
        "PACKAGE_REV = \"{}\"".format(packages_tag),
        "",
    ])

def _run_update_versions_file(owner: str, repo: str, workdir: str, spaces_version: str, sdk_tag: str, packages_tag: str, status_file: str) -> str:
    """Regenerate docs/internal/version.star and open a PR if needed."""
    repo_slug = utils_repo_slug(owner, repo)
    branch = "update-docs-versions-{}-{}-{}".format(spaces_version, sdk_tag, packages_tag)
    target_path = "{}/{}".format(workdir, _VERSION_FILE_PATH)

    expected = _render_version_file(spaces_version, sdk_tag, packages_tag)

    utils_refresh_main(workdir)
    assert_on(fs_exists(target_path), "{} does not exist in {}".format(_VERSION_FILE_PATH, repo_slug))

    current = fs_read_text(target_path)
    if current == expected:
        print("{} is already up to date on main.".format(_VERSION_FILE_PATH))
        _write_status(status_file, "Complete")
        return "Complete"

    existing_pr = utils_find_existing_pr(repo_slug, branch)
    if existing_pr != "":
        print("\n".join([
            "",
            "A docs version-file PR for {} is already open and has not been merged:".format(repo_slug),
            "  {}".format(existing_pr),
            "",
            "Merge the PR into main, then re-run this rule to continue the release.",
            "",
        ]))
        status = "Need to merge PR at {}".format(existing_pr)
        _write_status(status_file, status)
        return status

    fs_write_text(target_path, expected)

    utils_git(["checkout", "-B", branch], cwd = workdir)
    utils_git(["add", _VERSION_FILE_PATH], cwd = workdir)

    title = "Update docs versions: spaces {}, sdk {}, packages {}".format(spaces_version, sdk_tag, packages_tag)
    body = "Automated docs version update: regenerate `{}`.".format(_VERSION_FILE_PATH)

    utils_git(
        [
            "-c",
            "user.name=spaces-release-bot",
            "-c",
            "user.email=spaces-release-bot@users.noreply.github.com",
            "commit",
            "-m",
            title,
            "-m",
            body,
        ],
        cwd = workdir,
    )
    utils_git(["push", "--force", "origin", branch], cwd = workdir)

    pr_url = utils_create_pr(repo_slug, branch, title, body, workdir)

    print("\n".join([
        "",
        "Opened a docs version-bump PR on {} that must be merged before continuing:".format(repo_slug),
        "  {}".format(pr_url) if pr_url != "" else "  (PR URL was not reported by `gh pr create`)",
        "",
        "Review and merge the PR into main, then re-run this script to continue the release.",
        "",
    ]))

    status = "Need to merge PR at {}".format(pr_url) if pr_url != "" else "Need to merge PR (URL not reported by `gh pr create`)"
    _write_status(status_file, status)
    return status

def _dispatch_pages_workflow(host: str, owner: str, repo: str, workflow: str, ref: str, poll_interval: int, timeout_seconds: int) -> None:
    utils_run(
        _GH_DISPATCH_SCRIPT,
        args = [
            "--host={}".format(host),
            "--owner={}".format(owner),
            "--repo={}".format(repo),
            "--workflow={}".format(workflow),
            "--ref={}".format(ref),
            "--poll-interval={}".format(poll_interval),
            "--timeout={}".format(timeout_seconds),
        ],
        check = True,
    )

def main():
    """
    Update docs repo to the current spaces tag and publish docs.
    """
    spec = args_parser(
        name = "update-docs",
        description = "Update docs repo to the current spaces tag and publish docs.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (e.g. github.com)"),
            args_opt("--owner", default = "work-spaces", help = "Repository owner (user or organization)"),
            args_opt("--repo", default = "work-spaces.github.io", help = "Repository name"),
            args_opt("--spaces-tag", help = "Current spaces tag (e.g. v0.15.45)"),
            args_opt("--sdk-tag", help = "SDK release tag (e.g. v0.15.45)"),
            args_opt("--packages-tag", help = "Packages release tag (e.g. v0.15.45)"),
            args_opt("--workdir", default = "docs/work-spaces.github.io", help = "Directory of the docs repo checkout"),
            args_opt("--file-path", default = "docs/work-spaces.github.io", help = "Path to the docs repo checkout (informational; version generation targets internal/version.star)"),
            args_opt("--docs-target", default = "//work-spaces.github.io:work-spaces.github.io_archive", help = "Docs archive target to run for verification"),
            args_opt("--workflow", default = "pages.yaml", help = "Workflow filename to dispatch"),
            args_opt("--dispatch-ref", default = "", help = "Ref for workflow dispatch. Defaults to main."),
            args_opt("--poll-interval", type = "int", default = 10, help = "Seconds between workflow status polls"),
            args_opt("--timeout", type = "int", default = 1800, help = "Seconds to wait for workflow completion"),
            args_opt("--status-file", default = "", help = "Path to the JSON status file. Defaults to build/update-docs/<repo>-<spaces-tag>.status.json (relative to the workspace root)"),
        ],
    )
    parsed = args_parse(spec)

    host = _arg(parsed, "host", "github.com")
    owner = _arg(parsed, "owner", "")
    repo = _arg(parsed, "repo", "")
    spaces_tag = _arg(parsed, "spaces-tag", "")
    sdk_tag = _arg(parsed, "sdk-tag", "")
    packages_tag = _arg(parsed, "packages-tag", "")
    workdir = _arg(parsed, "workdir", "")
    file_path = _arg(parsed, "file-path", "")
    docs_target = _arg(parsed, "docs-target", "")
    workflow = _arg(parsed, "workflow", "")
    dispatch_ref = _arg(parsed, "dispatch-ref", "")
    poll_interval = _arg(parsed, "poll-interval", 10)
    timeout_seconds = _arg(parsed, "timeout", 1800)
    status_file = _arg(parsed, "status-file", "")

    assert_on(host != "", "--host is required")
    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(sdk_tag != "", "--sdk-tag is required")
    assert_on(packages_tag != "", "--packages-tag is required")
    assert_on(workdir != "", "--workdir is required")
    assert_on(file_path != "", "--file-path is required")
    assert_on(docs_target != "", "--docs-target is required")
    assert_on(workflow != "", "--workflow is required")
    assert_on(poll_interval > 0, "--poll-interval must be > 0")
    assert_on(timeout_seconds > 0, "--timeout must be > 0")

    spaces_version = _spaces_version_from_tag(spaces_tag)
    sdk_version = _spaces_version_from_tag(sdk_tag)
    packages_version = _spaces_version_from_tag(packages_tag)
    if dispatch_ref == "":
        dispatch_ref = "main"

    repo_slug = utils_repo_slug(owner, repo)

    # Status file lives in the workspace `build` folder.
    if status_file == "":
        status_file = "build/update-docs/{}-{}.status.json".format(repo, spaces_tag)
    status_dir = "build/update-docs"
    versions_status_file = "{}/{}-versions-{}-{}-{}.status.json".format(status_dir, repo, spaces_tag, sdk_tag, packages_tag)

    print("Repository:    {} (host: {})".format(repo_slug, host))
    print("spaces tag:    {}".format(spaces_tag))
    print("spaces ver:    {}".format(spaces_version))
    print("SDK tag:       {}".format(sdk_tag))
    print("SDK ver:       {}".format(sdk_version))
    print("packages tag:  {}".format(packages_tag))
    print("packages ver:  {}".format(packages_version))
    print("Workdir:       {}".format(workdir))
    print("File path:     {}".format(file_path))
    print("Docs target:   {}".format(docs_target))
    print("Workflow:      {}".format(workflow))
    print("Dispatch ref:  {}".format(dispatch_ref))
    print("Status file:   {}".format(status_file))

    # Step 1: regenerate internal/version.star (opens a PR if needed). If a
    # merge is required, record the required action and stop successfully.
    print("\nRegenerating {} for docs release...".format(_VERSION_FILE_PATH))
    status = _run_update_versions_file(owner, repo, workdir, spaces_version, sdk_tag, packages_tag, versions_status_file)
    if status != "Complete":
        print("Docs version-file update requires action: {}".format(status))
        _write_status(status_file, status)
        return

    # dispatch docs/pages workflow and wait until completion.
    _dispatch_pages_workflow(host, owner, repo, workflow, dispatch_ref, poll_interval, timeout_seconds)

    print("Docs update/publish flow completed successfully for {} on {}.".format(spaces_tag, repo_slug))
    _write_status(status_file, "Complete")

main()
