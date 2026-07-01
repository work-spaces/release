#!/usr/bin/env spaces
"""
Update a pinned ``spaces`` version in a downstream repository by performing a
regex find-and-replace, then opening a pull request against ``main``.

This script is generic over (repo, file, search, replace) so the same logic
can drive multiple version bumps. ``--search`` is a Rust-regex pattern, and
``--replace`` is the replacement string (capture references like ``$1`` are
supported). For example, to bump the version pinned in
``work-spaces/install-spaces/action.yml``::

    update-version.exec.star \\
        --owner=work-spaces \\
        --repo=install-spaces \\
        --file-path=action.yml \\
        --search='version=v\\d+\\.\\d+\\.\\d+[\\w.-]*' \\
        --replace='version=v0.15.45' \\
        --new-version=v0.15.45

And to bump the ``install-spaces`` ref pinned in
``work-spaces/spaces-checkout-run/action.yml``::

    update-version.exec.star \\
        --owner=work-spaces \\
        --repo=spaces-checkout-run \\
        --file-path=action.yml \\
        --search='install-spaces@v\\d+\\.\\d+\\.\\d+[\\w.-]*' \\
        --replace='install-spaces@v0.15.45' \\
        --new-version=v0.15.45

Behavior:

1. A marker file is computed in the current spaces workspace (under
   ``build/update-version/<repo>-<new-version>.md`` by default, or
   ``--marker-file=<path>``). The marker is written only once the bump has
   landed on ``main``; if it already exists, the script is a no-op.
2. The repo at ``--workdir`` (which must already be a git checkout; the
   script does not clone) is fetched and hard-reset to ``origin/main``.
3. The contents of ``--file-path`` on ``main`` are inspected:

   - If ``--search`` no longer matches and ``--replace`` is present as a
     literal substring, the bump has already been merged. The marker file
     is written and the script exits successfully.
   - If ``--search`` does not match and ``--replace`` is also missing, the
     script aborts; the caller's parameters do not match the repo state.

4. If a PR already exists with head branch ``update-spaces-<new-version>``,
   the script records that the PR must be merged and exits successfully.
   No marker file is written, so re-running after the merge will re-check
   ``main`` and continue the release.
5. Otherwise the script creates branch ``update-spaces-<new-version>``,
   applies the find-and-replace, commits, pushes, runs ``gh pr create``,
   and then records the new PR URL so the user knows it needs review and
   merging before the release can proceed, exiting successfully.
6. Once the bump has landed on ``main`` (cases 1a/1b above), the script
   also creates the GitHub release for ``--new-version`` on the target
   repo (if it does not already exist) before writing the marker file and
   exiting successfully. Pass ``--latest-release`` to mark it as the latest
   release rather than a pre-release.

In every terminal case the script writes a JSON status file into the
workspace ``build`` folder describing the state of the workflow, for
example ``{"status": "Complete"}`` once the bump has landed, or
``{"status": "Need to merge PR at <url>"}`` when a human still needs to
merge the PR. Whenever the status file is written the script exits
successfully; a human action being required is a normal, expected outcome
rather than a failure.
"""

load("//@star/sdk/star/std/args.star", "args_flag", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_mkdir", "fs_read_text", "fs_write_text")
load("//@star/sdk/star/std/json.star", "json_write_file")
load("//@star/sdk/star/std/string.star", "string_contains", "string_regex_find_all", "string_replace")
load("internal/utils.star", "utils_create_pr", "utils_create_release", "utils_find_existing_pr", "utils_git", "utils_refresh_main", "utils_release_exists", "utils_repo_slug")

def _write_marker(marker_file, repo_slug, new_version, status, pr_url):
    """Write a small markdown note recording the outcome."""
    parent = marker_file.rsplit("/", 1)
    if len(parent) == 2:
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    lines = [
        "# {} version bump to {}".format(repo_slug, new_version),
        "",
        "- Status: {}".format(status),
    ]
    if pr_url != "":
        lines.append("- PR: {}".format(pr_url))
    lines.append("")
    fs_write_text(marker_file, "\n".join(lines))
    print("Wrote marker file: {}".format(marker_file))

def _write_status(status_file, status):
    """Write a JSON status file describing the state of the workflow."""
    parent = status_file.rsplit("/", 1)
    if len(parent) == 2:
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    json_write_file(status_file, {"status": status})
    print("Wrote status file: {} ({})".format(status_file, status))

def _ensure_release(repo_slug, tag, is_latest):
    """Create the release for ``tag`` on ``repo_slug`` unless it already exists."""
    if utils_release_exists(repo_slug, tag):
        print("Release {} already exists on {}; skipping creation.".format(tag, repo_slug))
        return
    utils_create_release(repo_slug, tag, is_latest)
    print("Release {} created on {}.".format(tag, repo_slug))

def main():
    """
    Open a PR that bumps a pinned version via literal find-and-replace.
    """
    spec = args_parser(
        name = "update-version",
        description = "Open a PR that bumps a pinned version via literal find-and-replace.",
        options = [
            args_opt("--owner", help = "Repository owner (user or organization)"),
            args_opt("--repo", help = "Repository name"),
            args_opt("--file-path", help = "Path within the repo of the file to update"),
            args_opt("--search", help = "Regex pattern to find in the target file (Rust regex syntax)"),
            args_opt("--replace", help = "Replacement string. May reference regex captures via $1, $2, ${name}, etc."),
            args_opt("--new-version", help = "New version (e.g. v0.15.45); used for branch, PR title, and marker file naming"),
            args_opt("--branch-prefix", default = "update-spaces-", help = "Prefix for the update branch name (default 'update-spaces-')"),
            args_opt("--marker-file", default = "", help = "Path to the marker file. Defaults to build/update-version/<repo>-<new-version>.md (relative to the workspace root)"),
            args_opt("--status-file", default = "", help = "Path to the JSON status file. Defaults to build/update-version/<repo>-<new-version>.status.json (relative to the workspace root)"),
            args_opt("--workdir", help = "Directory of an existing checkout of the target repo (must already exist; the script does not clone)"),
            args_flag("--latest-release", help = "Mark the created release as the latest release (otherwise it is created as a pre-release)"),
        ],
    )
    parsed = args_parse(spec)

    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    file_path = parsed.get("file_path", "")
    search = parsed.get("search", "")
    replace = parsed.get("replace", "")
    new_version = parsed.get("new_version", "")
    branch_prefix = parsed.get("branch_prefix", "update-spaces-")
    marker_file = parsed.get("marker_file", "")
    status_file = parsed.get("status_file", "")
    workdir = parsed.get("workdir", "")
    is_latest = parsed.get("latest_release", False)

    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(file_path != "", "--file-path is required")
    assert_on(search != "", "--search is required")
    assert_on(replace != "", "--replace is required")
    assert_on(new_version != "", "--new-version is required")
    assert_on(workdir != "", "--workdir is required")
    assert_on(search != replace, "--search and --replace must differ")

    repo_slug = utils_repo_slug(owner, repo)
    branch = "{}{}".format(branch_prefix, new_version)

    # Marker default is relative to the script's working directory, which is
    # the workspace root when launched via run_add_exec.
    if marker_file == "":
        marker_file = "build/update-version/{}-{}.md".format(repo, new_version)
    if status_file == "":
        status_file = "build/update-version/{}-{}.status.json".format(repo, new_version)

    print("Repository:  {}".format(repo_slug))
    print("File:        {}".format(file_path))
    print("Search:      {}".format(search))
    print("Replace:     {}".format(replace))
    print("Branch:      {}".format(branch))
    print("Marker:      {}".format(marker_file))
    print("Status:      {}".format(status_file))
    print("Workdir:     {}".format(workdir))

    # Idempotency: if we've already produced a marker for this bump, we're done.
    if fs_exists(marker_file):
        print("Marker file already exists; nothing to do.")
        _write_status(status_file, "Complete")
        return

    utils_refresh_main(workdir)

    target_path = "{}/{}".format(workdir, file_path)
    assert_on(fs_exists(target_path), "{} does not exist in {}".format(file_path, repo_slug))
    contents = fs_read_text(target_path)

    # ``--search`` is a regex. ``--replace`` is usually a literal
    # post-substitution marker, but may also include capture references.
    has_search = len(string_regex_find_all(search, contents)) > 0
    has_replace = string_contains(contents, replace)
    updated = string_replace(contents, search, replace, regex = True)
    has_change = updated != contents

    # Case 1a: bump is already merged on main and --replace is a literal marker.
    if not has_search and has_replace:
        print("`{}` is already present on main; bump has already been merged.".format(replace))
        _ensure_release(repo_slug, new_version, is_latest)
        _write_marker(marker_file, repo_slug, new_version, "already merged on main", "")
        _write_status(status_file, "Complete")
        return

    # Case 1b: regex replacement is already effectively applied (for example,
    # capture-based replacements where --replace itself is not a literal file
    # substring). Record and exit.
    if has_search and not has_change:
        print("Regex replacement produced no change; bump has already been merged on main.")
        _ensure_release(repo_slug, new_version, is_latest)
        _write_marker(marker_file, repo_slug, new_version, "already merged on main", "")
        _write_status(status_file, "Complete")
        return

    assert_on(
        has_search,
        "Could not find search string in {}/{} on main:\n  {}".format(repo_slug, file_path, search),
    )

    # Case 2: an open PR with our branch already exists. The bump is in
    # flight but not yet merged; record that a human must merge it and exit
    # successfully. We do *not* write the marker file, so the next run will
    # re-check ``main`` and only complete once the PR is merged.
    existing_pr = utils_find_existing_pr(repo_slug, branch)
    if existing_pr != "":
        print("\n".join([
            "",
            "A version-bump PR for {} is already open and has not been merged:".format(repo_slug),
            "  {}".format(existing_pr),
            "",
            "Merge the PR into main, then re-run this rule to continue the release.",
            "",
        ]))
        _write_status(status_file, "Need to merge PR at {}".format(existing_pr))
        return

    # Case 3: do the bump and open a PR.
    assert_on(has_change, "Find-and-replace produced no change in {}".format(file_path))
    fs_write_text(target_path, updated)

    utils_git(["checkout", "-B", branch], cwd = workdir)
    utils_git(["add", file_path], cwd = workdir)

    title = "Bump version to {}".format(new_version)
    body = "Automated version bump: replace `{}` with `{}` in `{}`.".format(search, replace, file_path)

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

    # The bump has been opened as a PR but not merged. Record that a human
    # must merge it and exit successfully so the caller can inspect the
    # status file. We do *not* write the marker file here: the next run must
    # re-check ``main`` and only complete once the PR is merged.
    print("\n".join([
        "",
        "Opened a version-bump PR on {} that must be merged before continuing:".format(repo_slug),
        "  {}".format(pr_url) if pr_url != "" else "  (PR URL was not reported by `gh pr create`)",
        "",
        "Review and merge the PR into main, then re-run this script to continue the release.",
        "",
    ]))
    status = "Need to merge PR at {}".format(pr_url) if pr_url != "" else "Need to merge PR (URL not reported by `gh pr create`)"
    _write_status(status_file, status)

main()
