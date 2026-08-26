#!/usr/bin/env spaces
"""
Ensure that per-OS/arch binaries are attached to a GitHub pre-release.

Given a host, owner, repo, and tag, this script:

1. Uses ``gh release view --json isPrerelease,assets`` to inspect the
   release for ``tag`` on ``owner/repo``.
2. Computes the set of expected binary asset names for the tag based on the
   selected platforms passed via repeatable ``--platform`` inputs. Asset names
   follow ``spaces-<tag>-<os>-<arch>.zip``.
3. If every expected asset is already attached, exits successfully without
   doing any work.
4. Otherwise, the release must still be a pre-release. The pipeline attaches
   binaries while the release is a pre-release and only afterwards promotes it
   to the latest release, so a non-pre-release with missing assets means the
   steps ran out of order and the script aborts.
5. If the release is a pre-release with missing assets, dispatches the
   ``spaces-build-and-publish.yaml`` workflow via
   ``release/scripts/gh-workflow-dispatch.exec.star`` with ``--field=tag=<tag>``
   and explicit boolean build inputs for each supported platform, enabling
   only the platforms whose binaries are currently missing.
6. If ``--dry-run`` is set, never dispatches; it only reports which
   platforms would be published.

Example::

    publish-release-binaries.exec.star \\
        --host=github.com \\
        --owner=work-spaces \\
        --repo=spaces \\
        --tag=v0.15.45 \\
        --platform=linux-x86_64 \\
        --platform=linux-aarch64 \\
        --platform=macos-x86_64 \\
        --platform=macos-aarch64
"""

load("//@star/sdk/star/std/args.star", "args_flag", "args_list", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/json.star", "json_decode")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_capture", "process_stdout_inherit")
load("internal/utils.star", "utils_repo_slug")

# Path (relative to the workspace) of the helper that dispatches a workflow
# and follows it to completion. Invoked as a subprocess so it inherits the
# same gh authentication/environment as this script.
_GH_DISPATCH_SCRIPT = "release/scripts/gh-workflow-dispatch.exec.star"

# Workflow that builds and uploads the per-OS/arch binaries for a tag.
_BUILD_AND_PUBLISH_WORKFLOW = "spaces-build-and-publish.yaml"

# Supported platform values for ``--platform`` and their corresponding workflow
# inputs (``build-<platform>``) in spaces/.github/workflows/spaces-build-and-publish.yaml.
_SUPPORTED_PLATFORMS = [
    "linux-x86_64",
    "linux-aarch64",
    "macos-x86_64",
    "macos-aarch64",
    "windows-x86_64",
]

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
            "isPrerelease,assets",
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

def _normalize_platforms(platform_args):
    """Validate and de-duplicate requested platforms.

    Requires at least one ``--platform`` value.
    """
    assert_on(
        len(platform_args) > 0,
        "At least one --platform is required (repeatable). Supported values: {}".format(_SUPPORTED_PLATFORMS),
    )

    selected = []
    seen = {}
    for platform in platform_args:
        assert_on(platform != "", "--platform must not be empty")
        assert_on(
            platform in _SUPPORTED_PLATFORMS,
            "Unsupported --platform value: {} (supported: {})".format(platform, _SUPPORTED_PLATFORMS),
        )
        if not seen.get(platform, False):
            selected.append(platform)
            seen[platform] = True
    return selected

def _expected_binary_name(tag, platform):
    parts = platform.split("-")
    assert_on(
        len(parts) == 2,
        "Invalid platform value: {} (expected <os>-<arch>)".format(platform),
    )

    # release workflow uploads assets as spaces-<tag>-<os>-<arch>.zip
    return "spaces-{}-{}-{}.zip".format(tag, parts[0], parts[1])

def _expected_binary_names(tag, platforms):
    return [_expected_binary_name(tag, platform) for platform in platforms]

def _dispatch_build_and_publish(host, owner, repo, tag, platforms):
    """Invoke gh-workflow-dispatch.exec.star for ``tag`` and selected platforms."""
    print(
        "Dispatching {} for tag {} (platforms: {})...".format(
            _BUILD_AND_PUBLISH_WORKFLOW,
            tag,
            ", ".join(platforms),
        ),
    )

    selected_set = {platform: True for platform in platforms}
    dispatch_args = [
        "--host={}".format(host),
        "--owner={}".format(owner),
        "--repo={}".format(repo),
        "--workflow={}".format(_BUILD_AND_PUBLISH_WORKFLOW),
        "--ref={}".format(tag),
        "--field=tag={}".format(tag),
    ]

    # Explicitly set all platform inputs because the workflow defaults to true
    # for every target; omitted fields would still build those targets.
    for platform in _SUPPORTED_PLATFORMS:
        build_value = "true" if selected_set.get(platform, False) else "false"
        dispatch_args.append("--field=build-{}={}".format(platform, build_value))

    process_run(process_options(
        command = _GH_DISPATCH_SCRIPT,
        args = dispatch_args,
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

def main():
    """Entry point: check assets and, if needed, dispatch the build."""
    spec = args_parser(
        name = "publish-release-binaries",
        description = "Ensure per-OS/arch binaries are attached to a release.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (e.g. github.com)"),
            args_opt("--owner", default = "work-spaces", help = "Repository owner (user or organization)"),
            args_opt("--repo", default = "spaces", help = "Repository name"),
            args_opt("--tag", help = "Release tag to check and publish binaries for"),
            args_list("--platform", help = "Platform to build (repeatable, required at least once): linux-x86_64, linux-aarch64, macos-x86_64, macos-aarch64, windows-x86_64"),
            args_flag("--dry-run", help = "Only report missing platforms; never dispatch the build workflow"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "github.com")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    tag = parsed.get("tag", "")
    platform_args = parsed.get("platform", [])
    dry_run = parsed.get("dry_run", False)

    assert_on(host != "", "--host is required")
    assert_on(owner != "", "--owner is required")
    assert_on(repo != "", "--repo is required")
    assert_on(tag != "", "--tag is required")

    platforms = _normalize_platforms(platform_args)

    repo_slug = utils_repo_slug(owner, repo)
    expected_by_platform = {
        platform: _expected_binary_name(tag, platform)
        for platform in platforms
    }
    expected = [expected_by_platform[platform] for platform in platforms]

    print("Repository: {} (host: {})".format(repo_slug, host))
    print("Tag:        {}".format(tag))
    print("Platforms:")
    for platform in platforms:
        print("  - {}".format(platform))
    print("Expected binaries:")
    for name in expected:
        print("  - {}".format(name))
    if dry_run:
        print("Mode: dry-run (no workflow dispatch)")

    info = _view_release(repo_slug, tag)
    attached = _attached_asset_names(info)
    missing = _missing_assets(expected, attached)

    if len(missing) == 0:
        print("All {} expected binaries are already attached to {}.".format(
            len(expected),
            tag,
        ))
        return

    print("Missing binaries ({}):".format(len(missing)))
    for name in missing:
        print("  - {}".format(name))

    missing_set = {name: True for name in missing}
    missing_platforms = [
        platform
        for platform in platforms
        if missing_set.get(expected_by_platform[platform], False)
    ]

    print("Platforms requiring publish ({}):".format(len(missing_platforms)))
    for platform in missing_platforms:
        print("  - {}".format(platform))

    if dry_run:
        print(
            "Dry run: would publish {} platform(s) for {}: {}".format(
                len(missing_platforms),
                tag,
                missing_platforms,
            ),
        )
        return

    # Binaries are attached while the release is still a pre-release, before the
    # pipeline promotes it to the latest release. A non-pre-release with missing
    # assets means the release steps ran out of order.
    assert_on(
        info.get("isPrerelease", False),
        ("Release {} on {} is not a pre-release but is missing binaries: {}. " +
         "The pipeline attaches binaries while the release is still a " +
         "pre-release.").format(
            tag,
            repo_slug,
            missing,
        ),
    )

    # The workflow dispatches against ``--ref=<tag>`` and checks source out at
    # that same tag, so it can run directly after the pre-release is created.
    _dispatch_build_and_publish(host, owner, repo, tag, missing_platforms)

    # Confirm every expected binary is now attached.
    info = _view_release(repo_slug, tag)
    still_missing = _missing_assets(expected, _attached_asset_names(info))
    assert_on(
        len(still_missing) == 0,
        "Build-and-publish completed but binaries are still missing from {}: {}".format(
            tag,
            still_missing,
        ),
    )

    print("Build-and-publish workflow completed and binaries attached to {}.".format(tag))

main()
