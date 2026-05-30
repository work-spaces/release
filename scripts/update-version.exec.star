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
   the script fails with a message instructing the user to merge it. No
   marker file is written, so re-running after the merge will succeed.
5. Otherwise the script creates branch ``update-spaces-<new-version>``,
   applies the find-and-replace, commits, pushes, runs ``gh pr create``,
   and then fails with the new PR URL so the user knows it needs review
   and merging before the release can proceed.
"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_mkdir", "fs_read_text", "fs_write_text")
load("//@star/sdk/star/std/string.star", "string_contains", "string_regex_find_all", "string_replace")
load("star/utils.star", "utils_create_pr", "utils_find_existing_pr", "utils_git", "utils_refresh_main", "utils_repo_slug")

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
            args_opt("--workdir", help = "Directory of an existing checkout of the target repo (must already exist; the script does not clone)"),
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
    workdir = parsed.get("workdir", "")

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

    print("Repository:  {}".format(repo_slug))
    print("File:        {}".format(file_path))
    print("Search:      {}".format(search))
    print("Replace:     {}".format(replace))
    print("Branch:      {}".format(branch))
    print("Marker:      {}".format(marker_file))
    print("Workdir:     {}".format(workdir))

    # Idempotency: if we've already produced a marker for this bump, we're done.
    if fs_exists(marker_file):
        print("Marker file already exists; nothing to do.")
        return

    utils_refresh_main(workdir)

    target_path = "{}/{}".format(workdir, file_path)
    assert_on(fs_exists(target_path), "{} does not exist in {}".format(file_path, repo_slug))
    contents = fs_read_text(target_path)

    # ``--search`` is a regex; ``--replace`` is the literal post-substitution
    # marker we use to detect that the bump has already been merged.
    has_search = len(string_regex_find_all(search, contents)) > 0
    has_replace = string_contains(contents, replace)

    # Case 1: bump is already merged on main. Record and exit.
    if not has_search and has_replace:
        print("`{}` is already present on main; bump has already been merged.".format(replace))
        _write_marker(marker_file, repo_slug, new_version, "already merged on main", "")
        return

    assert_on(
        has_search,
        "Could not find search string in {}/{} on main:\n  {}".format(repo_slug, file_path, search),
    )

    # Case 2: an open PR with our branch already exists. The bump is in
    # flight but not yet merged; fail so the caller knows to merge it.
    existing_pr = utils_find_existing_pr(repo_slug, branch)
    if existing_pr != "":
        assert_on(
            False,
            "\n".join([
                "",
                "A version-bump PR for {} is already open and has not been merged:".format(repo_slug),
                "  {}".format(existing_pr),
                "",
                "Merge the PR into main, then re-run this rule to continue the release.",
                "",
            ]),
        )

    # Case 3: do the bump and open a PR.
    updated = string_replace(contents, search, replace, regex = True)
    assert_on(updated != contents, "Find-and-replace produced no change in {}".format(file_path))
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

    # The bump has been opened as a PR but not merged. Fail loudly so the
    # release pipeline halts and the user is told to merge it. We do *not*
    # write the marker file here: the next run must re-check ``main`` and
    # only succeed once the PR is merged.
    assert_on(
        False,
        "\n".join([
            "",
            "Opened a version-bump PR on {} that must be merged before continuing:".format(repo_slug),
            "  {}".format(pr_url) if pr_url != "" else "  (PR URL was not reported by `gh pr create`)",
            "",
            "Review and merge the PR into main, then re-run this script to continue the release.",
            "",
        ]),
    )

main()
