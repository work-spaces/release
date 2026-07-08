#!/usr/bin/env spaces
"""
Create a GitHub release using the ``gh`` CLI if it does not already exist.

Given a host, owner, repo, and tag (plus optional release-notes file), this script:

1. Uses ``gh release view`` to check whether a release for the given tag
   already exists on the remote. If so, creation is skipped.
2. Otherwise, runs ``gh release create`` to create a new pre-release. The
   release tag is created from the command line arg and the title is set to
   the tag. If ``--release-notes`` is provided, the markdown in that file is
   used as release notes; otherwise GitHub auto-generated notes are used.

Example::

    create-release.exec.star \\
        --host=github.com \\
        --owner=work-spaces \\
        --repo=spaces \\
        --tag=v0.15.45 \\
        --release-notes=build/release-notes.md
"""

load(
    "//@star/sdk/star/std/args.star",
    "args_flag",
    "args_opt",
    "args_parse",
    "args_parser",
)
load("internal/utils.star", "utils_create_release", "utils_release_exists", "utils_repo_slug")

def main():
    """
    Execute the create-release script.
    """
    spec = args_parser(
        name = "create-release",
        description = "Create a GitHub pre-release for a tag if it does not already exist.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (e.g. github.com)"),
            args_opt("--owner", help = "Repository owner (user or organization)"),
            args_opt("--repo", help = "Repository name"),
            args_opt("--tag", help = "Tag to create the release for (will be created on the remote)"),
            args_opt("--release-notes", default = "", help = "Optional path to markdown release notes used for the release body"),
            args_flag("--latest-release", help = "Update the latest release on the repository (otherwise, use prerelease)"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    tag = parsed.get("tag", "")
    release_notes = parsed.get("release_notes", "")
    is_latest = parsed.get("latest_release", False)

    assert_on(host != "", "--host is required")
    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(tag != "", "--tag is required")

    repo_slug = utils_repo_slug(owner, repo)

    print("Repository: {} (host: {})".format(repo_slug, host))
    print("Tag:        {}".format(tag))
    if release_notes != "":
        print("Notes file: {}".format(release_notes))

    if utils_release_exists(repo_slug, tag):
        print("Release {} already exists on {}; skipping creation.".format(tag, repo_slug))
        return

    utils_create_release(repo_slug, tag, is_latest, release_notes)
    print("Pre-release {} created on {}.".format(tag, repo_slug))

main()
