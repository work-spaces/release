"""

"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
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

def main():
    """
    Open a PR that runs work-spaces/packages check-latest script.
    """
    spec = args_parser(
        name = "update-packages",
        description = "Open a PR that bumps a pinned version via literal find-and-replace.",
        options = [
            args_opt("--owner", help = "Repository owner (user or organization)"),
            args_opt("--repo", help = "Repository name"),
            args_opt("--workdir", help = "Directory of the packages repo"),
            args_opt("--new-version", help = "New version (e.g. v0.15.45); used for branch, PR title, and marker file naming"),
        ],
    )
    parsed = args_parse(spec)

    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    new_version = parsed.get("new_version", "")
    branch_prefix = parsed.get("branch_prefix", "update-spaces-")
    workdir = parsed.get("workdir", "")

    repo_slug = utils_repo_slug(owner, repo)
    branch = "{}{}".format(branch_prefix, new_version)

    # Case 1: Release already exists
    if utils_release_exists(repo_slug, new_version):
        print("Release {} already exists on {}; skipping creation.".format(new_version, repo_slug))
        return

    # Case 2: an open PR with our branch already exists. The bump is in
    # flight but not yet merged; fail so the caller knows to merge it.
    existing_pr = utils_find_existing_pr(repo_slug, branch)
    if existing_pr != "":
        assert_on(
            False,
            "\n".join([
                "",
                "A package update PR for {} is already open and has not been merged:".format(repo_slug),
                "  {}".format(existing_pr),
                "",
                "Merge the PR into main, then re-run this rule to continue the release.",
                "",
            ]),
        )

    # Case 3: branch already exists without an open PR. Fail loudly so we
    # do not accidentally overwrite prior work.
    utils_refresh_main(workdir)
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
        assert_on(
            False,
            "\n".join([
                "",
                "Branch `{}` already exists in {} for {}; refusing to create a new one.".format(branch, " and ".join(branch_locations), repo_slug),
                "",
                "Delete the existing branch (or merge/reset the existing change), then re-run this rule.",
                "",
            ]),
        )

    # Case 4: create a branch, run the update, and open a PR.
    utils_git(args = ["switch", "-c", branch], cwd = workdir)
    utils_run("script/check-latest.exec.star", args = [], cwd = workdir)

    title = "Check latest packages with spaces {}".format(new_version)
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

    assert_on(
        False,
        "\n".join([
            "",
            "Opened a packages update PR on {} that must be merged before continuing:".format(repo_slug),
            "  {}".format(pr_url) if pr_url != "" else "  (PR URL was not reported by `gh pr create`)",
            "",
            "Review and merge the PR into main, then re-run this script to continue the release.",
            "",
        ]),
    )

main()
