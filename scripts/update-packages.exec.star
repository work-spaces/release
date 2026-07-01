#!/usr/bin/env spaces
"""
Update the work-spaces/packages repo and publish its release.

This script consolidates what used to be two separate rules
(``update_package`` + ``create_packages_release``) into a single flow that:

1. Refreshes the packages checkout and runs its ``check-latest`` script to
   make the changes (the "make the changes" step).
2. Commits, pushes, and opens a PR on work-spaces/packages (the "create the
   PR" step).
3. Once that PR has been merged into ``main``, creates the GitHub release
   for the given tag (the "do the release" step).

A human must review and merge the PR between phases 2 and 3, so the script
records whenever user input is required: a PR was just opened, an open PR is
still outstanding, or a stale branch already exists. In every terminal case
the script writes a JSON status file under ``build/`` describing the state of
the workflow, for example ``{"status": "Complete"}`` once the release has been
created, or ``{"status": "Need to merge PR at <url>"}`` when a human still has
to merge the PR. A human-readable explanation is also written alongside it so
the reason the release paused is easy to find. Whenever the status file is
written the script exits successfully; re-run the rule after merging the PR to
continue, and the release is created automatically once ``main`` contains the
new version.
"""

load(
    "//@star/sdk/star/std/args.star",
    "args_flag",
    "args_opt",
    "args_parse",
    "args_parser",
)
load("//@star/sdk/star/std/fs.star", "fs_mkdir", "fs_write_text")
load("//@star/sdk/star/std/json.star", "json_write_file")
load(
    "//@star/sdk/star/std/process.star",
    "process_options",
    "process_run",
    "process_stderr_inherit",
    "process_stdout_inherit",
)
load(
    "internal/utils.star",
    "utils_create_pr",
    "utils_find_existing_pr",
    "utils_git",
    "utils_refresh_main",
    "utils_release_exists",
    "utils_repo_slug",
    "utils_run",
)

def _write_status(status_file, status):
    """Write a JSON status file describing the state of the workflow."""
    parent = status_file.rsplit("/", 1)
    if len(parent) == 2:
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    json_write_file(status_file, {"status": status})
    print("Wrote status file: {} ({})".format(status_file, status))

def _record_action(build_file, status_file, status, lines):
    """Record a required human action and pause the release successfully.

    Writes the detailed message under ``build/`` (for humans) and a concise
    JSON status file describing the outstanding action, then returns. The
    caller returns so the script exits successfully; re-running after the
    action re-checks ``main`` and continues the release.
    """
    message = "\n".join(lines)
    parent = build_file.rsplit("/", 1)
    if len(parent) == 2:
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    fs_write_text(build_file, message + "\n")
    print(message)
    print("Wrote halt message to: {}".format(build_file))
    _write_status(status_file, status)

def _create_release(repo_slug, tag, is_latest):
    """Create the GitHub release for ``tag`` using the ``gh`` CLI."""
    print("Creating {} {} on {}".format("release" if is_latest else "pre-release", tag, repo_slug))
    release_args = ["--latest"] if is_latest else ["--prerelease"]
    process_run(process_options(
        command = "gh",
        args = [
            "release",
            "create",
            tag,
            "--repo",
            repo_slug,
            "--title",
            tag,
            "--generate-notes",
        ] + release_args,
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

def main():
    """
    Bump the packages repo, open a PR, and create the release once merged.
    """
    spec = args_parser(
        name = "update-packages",
        description = "Bump work-spaces/packages to the latest packages and publish the release.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (e.g. github.com)"),
            args_opt("--owner", help = "Repository owner (user or organization)"),
            args_opt("--repo", help = "Repository name"),
            args_opt("--workdir", help = "Directory of an existing checkout of the packages repo"),
            args_opt("--tag", help = "Release tag / new version (e.g. v0.2.57); used for the release, branch, and PR title"),
            args_opt("--spaces-version", default = "", help = "Version of spaces the packages are checked against (e.g. v0.15.45)"),
            args_opt("--branch-prefix", default = "update-spaces-", help = "Prefix for the update branch name (default 'update-spaces-')"),
            args_opt("--build-dir", default = "build/update-packages", help = "Directory (under the workspace) for the halt-message file"),
            args_opt("--status-file", default = "", help = "Path to the JSON status file. Defaults to <build-dir>/<repo>-<tag>.status.json (relative to the workspace root)"),
            args_flag("--latest-release", help = "Mark the created release as latest (otherwise a prerelease)"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    workdir = parsed.get("workdir", "")
    tag = parsed.get("tag", "")
    spaces_version = parsed.get("spaces_version", "")
    branch_prefix = parsed.get("branch_prefix", "update-spaces-")
    build_dir = parsed.get("build_dir", "build/update-packages")
    status_file = parsed.get("status_file", "")
    is_latest = parsed.get("latest_release", False)

    assert_on(host != "", "--host is required")
    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(workdir != "", "--workdir is required")
    assert_on(tag != "", "--tag is required")

    repo_slug = utils_repo_slug(owner, repo)
    branch = "{}{}".format(branch_prefix, tag)
    halt_file = "{}/{}-{}.md".format(build_dir, repo, tag)
    if status_file == "":
        status_file = "{}/{}-{}.status.json".format(build_dir, repo, tag)

    print("Repository: {} (host: {})".format(repo_slug, host))
    print("Tag:        {}".format(tag))
    print("Branch:     {}".format(branch))
    print("Workdir:    {}".format(workdir))
    print("Status:     {}".format(status_file))

    # If the release already exists, the whole flow is complete.
    if utils_release_exists(repo_slug, tag):
        print("Release {} already exists on {}; nothing to do.".format(tag, repo_slug))
        _write_status(status_file, "Complete")
        return

    # If main already contains the bump (the PR was merged), skip straight to
    # publishing the release.
    utils_refresh_main(workdir)
    latest_main_commit_message = utils_git(
        ["log", "-1", "--pretty=%B", "origin/main"],
        cwd = workdir,
        capture = True,
    )["stdout"].strip()
    if tag in latest_main_commit_message:
        print("origin/main already contains {}; creating the release.".format(tag))
        _create_release(repo_slug, tag, is_latest)
        print("Release {} created on {}.".format(tag, repo_slug))
        _write_status(status_file, "Complete")
        return

    # An open PR with our branch is still outstanding: the user must merge it
    # before the release can be created.
    existing_pr = utils_find_existing_pr(repo_slug, branch)
    if existing_pr != "":
        _record_action(halt_file, status_file, "Need to merge PR at {}".format(existing_pr), [
            "",
            "A packages update PR for {} is already open and has not been merged:".format(repo_slug),
            "  {}".format(existing_pr),
            "",
            "Merge the PR into main, then re-run this rule to create the release.",
            "",
        ])
        return

    # A branch already exists without an open PR. Fail loudly so we do not
    # accidentally overwrite prior work.
    local_branch_exists = utils_git(
        ["show-ref", "--verify", "--quiet", "refs/heads/{}".format(branch)],
        cwd = workdir,
        check = False,
    )["status"] == 0
    remote_branch_exists = utils_git(
        ["ls-remote", "--exit-code", "--heads", "origin", branch],
        cwd = workdir,
        check = False,
    )["status"] == 0
    if local_branch_exists or remote_branch_exists:
        branch_locations = []
        if local_branch_exists:
            branch_locations.append("local checkout")
        if remote_branch_exists:
            branch_locations.append("origin")
        locations = " and ".join(branch_locations)
        _record_action(halt_file, status_file, "Delete stale branch `{}` in {} for {}, then re-run".format(branch, locations, repo_slug), [
            "",
            "Branch `{}` already exists in {} for {}; refusing to create a new one.".format(branch, locations, repo_slug),
            "",
            "Delete the existing branch (or merge/reset the existing change), then re-run this rule.",
            "",
        ])
        return

    # Make the changes, commit, push, and open a PR.
    utils_git(["switch", "-c", branch], cwd = workdir)
    utils_run("script/check-latest.exec.star", args = [], cwd = workdir)
    utils_git(["add", "-A"], cwd = workdir)

    title = "Check latest packages with spaces {}".format(spaces_version)
    body = "Automated update to latest packages."

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

    # The PR is open but not merged. Record the required action so the pipeline
    # pauses and the user is told to merge it. We do not create the release
    # here; the next run re-checks main and creates the release once the PR has
    # landed.
    status = "Need to merge PR at {}".format(pr_url) if pr_url != "" else "Need to merge PR (URL not reported by `gh pr create`)"
    _record_action(halt_file, status_file, status, [
        "",
        "Opened a packages update PR on {} that must be merged before the release can be created:".format(repo_slug),
        "  {}".format(pr_url) if pr_url != "" else "  (PR URL was not reported by `gh pr create`)",
        "",
        "Review and merge the PR into main, then re-run this rule to create the release.",
        "",
    ])

main()
