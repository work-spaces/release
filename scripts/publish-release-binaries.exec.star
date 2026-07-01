#!/usr/bin/env spaces
"""
Ensure that all per-OS/arch binaries are attached to a GitHub release.

Given a host, owner, repo, and tag, this script:

1. Uses ``gh release view --json isPrerelease,assets`` to inspect the
   release for ``tag`` on ``owner/repo``.
2. Computes the set of expected binary asset names for the tag (one per
   OS/arch produced by ``.github/workflows/build-and-publish.yaml`` in the
   ``work-spaces/spaces`` repository).
3. If every expected asset is already attached, exits successfully without
   doing any work.
4. Otherwise, the release must be in pre-release state (assets can only be
   attached to a pre-release). If it is not, the script aborts.
5. If the release is a pre-release with missing assets, dispatches the
   ``build-and-publish.yaml`` workflow via
   ``release/scripts/gh.exec.star`` with ``--field=tag=<tag>`` so the
   workflow can build and upload the missing binaries.

Example::

    publish-release-binaries.exec.star \\
        --host=github.com \\
        --owner=work-spaces \\
        --repo=spaces \\
        --tag=v0.15.45
"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/json.star", "json_decode")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_capture", "process_stdout_inherit")
load("internal/utils.star", "utils_expected_binary_names", "utils_repo_slug")

# Path (relative to the workspace) of the helper that dispatches a workflow
# and follows it to completion. Invoked as a subprocess so it inherits the
# same gh authentication/environment as this script.
_GH_DISPATCH_SCRIPT = "release/scripts/gh-workflow-dispatch.exec.star"

# Workflow that builds and uploads the per-OS/arch binaries for a tag.
_BUILD_AND_PUBLISH_WORKFLOW = "build-and-publish.yaml"

def _view_release(repo_slug, tag):
    """Return the parsed ``gh release view`` JSON for ``tag``.

    Aborts if the release does not exist.
    """
    result = process_run(process_options(
        command = "gh",
        args = [
            "release",
            "view",
            tag,
            "--repo",
            repo_slug,
            "--json",
            "isPrerelease,assets,tagName",
        ],
        stdout = process_stdout_capture(),
        stderr = process_stdout_capture(),
        check = False,
    ))
    assert_on(
        result["status"] == 0,
        ("Release {} does not exist on {} (gh exit status {}). " +
         "Create the release before publishing binaries.").format(
            tag,
            repo_slug,
            result["status"],
        ),
    )
    return json_decode(result["stdout"])

def _attached_asset_names(release_info):
    names = []
    for asset in release_info.get("assets", []):
        name = asset.get("name", "")
        if name != "":
            names.append(name)
    return names

def _missing_assets(expected, attached):
    attached_set = {name: True for name in attached}
    return [name for name in expected if not attached_set.get(name, False)]

def _dispatch_build_and_publish(host, owner, repo, tag):
    """Invoke gh-workflow-dispatch.exec.star to dispatch build-and-publish.yaml for ``tag``."""
    print("Dispatching {} for tag {}...".format(_BUILD_AND_PUBLISH_WORKFLOW, tag))
    process_run(process_options(
        command = _GH_DISPATCH_SCRIPT,
        args = [
            "--host={}".format(host),
            "--owner={}".format(owner),
            "--repo={}".format(repo),
            "--workflow={}".format(_BUILD_AND_PUBLISH_WORKFLOW),
            "--ref={}".format(tag),
            "--field=tag={}".format(tag),
        ],
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

def main():
    """Entry point: check assets and, if needed, dispatch the build."""
    spec = args_parser(
        name = "publish-release-binaries",
        description = "Ensure all per-OS/arch binaries are attached to a release.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (e.g. github.com)"),
            args_opt("--owner", default = "work-spaces", help = "Repository owner (user or organization)"),
            args_opt("--repo", default = "spaces", help = "Repository name"),
            args_opt("--tag", help = "Release tag to check and publish binaries for"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "github.com")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    tag = parsed.get("tag", "")

    assert_on(host != "", "--host is required")
    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(tag != "", "--tag is required")

    repo_slug = utils_repo_slug(owner, repo)
    expected = utils_expected_binary_names(tag)

    print("Repository: {} (host: {})".format(repo_slug, host))
    print("Tag:        {}".format(tag))
    print("Expected binaries:")
    for name in expected:
        print("  - {}".format(name))

    info = _view_release(repo_slug, tag)
    attached = _attached_asset_names(info)
    missing = _missing_assets(expected, attached)

    if len(missing) == 0:
        print("All {} expected binaries are already attached to {}; nothing to do.".format(
            len(expected),
            tag,
        ))
        return

    print("Missing binaries ({}):".format(len(missing)))
    for name in missing:
        print("  - {}".format(name))

    is_prerelease = info.get("isPrerelease", False)
    assert_on(
        is_prerelease,
        ("Release {} on {} is not a pre-release but is missing binaries: {}. " +
         "Binaries can only be attached to a pre-release.").format(
            tag,
            repo_slug,
            missing,
        ),
    )

    _dispatch_build_and_publish(host, owner, repo, tag)
    print("Build-and-publish workflow completed for {}.".format(tag))

main()
