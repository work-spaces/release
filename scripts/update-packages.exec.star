"""

"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load(
    "star/utils.star",
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
    Open a PR that bumps a pinned version via literal find-and-replace.
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

    # Create a new branch to update the packages for the new tag
    branch_name = branch_prefix + new_version
    utils_refresh_main(workdir)
    utils_git(args = ["switch", "-c", branch_name], cwd = workdir)
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
