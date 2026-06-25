#!/usr/bin/env spaces
"""
Update and publish work-spaces.github.io docs for a released spaces tag.

This script orchestrates the docs publish flow by composing existing release
helpers:

1. Uses ``release/scripts/update-version.exec.star`` to bump versions in the docs repo using regex search:

   - ``SPACES_VERSION`` in ``spaces.star`` from ``--spaces-tag``
   - ``@star/sdk`` ``rev`` in ``0.checkout.spaces.star`` from ``--sdk-tag``
   - ``@star/packages`` ``rev`` in ``0.checkout.spaces.star`` from ``--packages-tag``
2. Refreshes the docs checkout to ``origin/main`` and verifies docs generation
   by running:

       spaces run //work-spaces.github.io:work-spaces.github.io_archive

   in ``docs/work-spaces.github.io`` (configurable via ``--workdir``).
3. Uses ``release/scripts/create-release.exec.star`` to create a release on the
   docs repo for the current spaces tag.
4. Uses ``release/scripts/gh-workflow-dispatch.exec.star`` to dispatch
   ``pages.yaml`` and follow it to completion.

Important behavior inherited from ``update-version.exec.star``:

- On first run, if the version bump is not yet merged, it opens a PR and exits
  with a failure message (to force manual review/merge).
- Re-run this script after that PR is merged to continue with verification,
  release creation, and workflow dispatch.
"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/string.star", "string_regex_find_all")
load("internal/utils.star", "utils_refresh_main", "utils_repo_slug", "utils_run")

_UPDATE_VERSION_SCRIPT = "release/scripts/update-version.exec.star"
_CREATE_RELEASE_SCRIPT = "release/scripts/create-release.exec.star"
_GH_DISPATCH_SCRIPT = "release/scripts/gh-workflow-dispatch.exec.star"

# Matches lines like:
#   SPACES_VERSION = "0.15.45"
#   SPACES_VERSION="0.15.45.docs"
#   SPACES_VERSION = "0.15.45-alpha.1"
# Capture groups:
#   1) `SPACES_VERSION = "` prefix (including optional spaces)
#   2) optional version context and closing quote (for example: `.docs"`)
_SPACES_VERSION_LINE_REGEX = r'(SPACES_VERSION\s*=\s*")\d+\.\d+\.\d+([\w.+-]*")'

# In docs/work-spaces.github.io/0.checkout.spaces.star, match the sdk repo block
# and replace only the `rev` value.
_SDK_REV_LINE_REGEX = r'("url"\s*:\s*"https://github.com/work-spaces/sdk",\s*"rev"\s*:\s*")v\d+\.\d+\.\d+([\w.+-]*")'

# In docs/work-spaces.github.io/0.checkout.spaces.star, match the packages repo
# block and replace only the `rev` value.
_PACKAGES_REV_LINE_REGEX = r'("url"\s*:\s*"https://github.com/work-spaces/packages",\s*"rev"\s*:\s*")v\d+\.\d+\.\d+([\w.+-]*")'

_CHECKOUT_FILE_PATH = "0.checkout.spaces.star"
_SPACES_FILE_PATH = "spaces.star"

def _arg(parsed: dict, key: str, fallback = ""):
    """Best-effort compatibility helper for dashed/underscored arg names."""
    underscored = key.replace("-", "_")
    return parsed.get(underscored, parsed.get(key, fallback))

def _spaces_version_from_tag(tag: str) -> str:
    assert_on(tag != "", "--spaces-tag is required")
    assert_on(tag.startswith("v"), "--spaces-tag must start with 'v' (for example: v0.15.45)")
    version = tag[1:]
    assert_on(version != "", "--spaces-tag has no version after the leading 'v'")
    return version

def _spaces_core_version_from_tag(tag: str) -> str:
    version = _spaces_version_from_tag(tag)
    matches = string_regex_find_all(r"^\d+\.\d+\.\d+", version)
    for match in matches:
        return match.get("match", "")
    assert_on(False, "--spaces-tag must contain a semver core x.y.z")
    return ""

def _run_update_version(owner: str, repo: str, file_path: str, workdir: str, search: str, replace: str, new_version: str, branch_prefix: str) -> None:
    utils_run(
        _UPDATE_VERSION_SCRIPT,
        args = [
            "--owner={}".format(owner),
            "--repo={}".format(repo),
            "--file-path={}".format(file_path),
            "--workdir={}".format(workdir),
            "--search={}".format(search),
            "--replace={}".format(replace),
            "--new-version={}".format(new_version),
            "--branch-prefix={}".format(branch_prefix),
        ],
        check = True,
    )

def _run_update_spaces_version(owner: str, repo: str, workdir: str, spaces_tag: str) -> None:
    # Keep any existing context after x.y.z (for example `.docs`) while
    # replacing only the semver core from `--spaces-tag`.
    replace = "$1{}$2".format(_spaces_core_version_from_tag(spaces_tag))
    _run_update_version(
        owner,
        repo,
        _SPACES_FILE_PATH,
        workdir,
        _SPACES_VERSION_LINE_REGEX,
        replace,
        spaces_tag,
        "update-docs-spaces-",
    )

def _run_update_sdk_version(owner: str, repo: str, workdir: str, sdk_tag: str) -> None:
    replace = "$1{}$2".format(sdk_tag)
    _run_update_version(
        owner,
        repo,
        _CHECKOUT_FILE_PATH,
        workdir,
        _SDK_REV_LINE_REGEX,
        replace,
        sdk_tag,
        "update-docs-sdk-",
    )

def _run_update_packages_version(owner: str, repo: str, workdir: str, packages_tag: str) -> None:
    replace = "$1{}$2".format(packages_tag)
    _run_update_version(
        owner,
        repo,
        _CHECKOUT_FILE_PATH,
        workdir,
        _PACKAGES_REV_LINE_REGEX,
        replace,
        packages_tag,
        "update-docs-packages-",
    )

def _verify_docs_build(workdir: str, docs_target: str) -> None:
    print("Verifying docs archive target {} in {}".format(docs_target, workdir))
    utils_run(
        "spaces",
        args = ["run", docs_target],
        cwd = workdir,
        check = True,
    )

def _create_docs_release(host: str, owner: str, repo: str, tag: str) -> None:
    utils_run(
        _CREATE_RELEASE_SCRIPT,
        args = [
            "--host={}".format(host),
            "--owner={}".format(owner),
            "--repo={}".format(repo),
            "--tag={}".format(tag),
        ],
        check = True,
    )

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
            args_opt("--file-path", default = "docs/work-spaces.github.io", help = "Path to the docs repo checkout (informational; version updates target 0.checkout.spaces.star and spaces.star)"),
            args_opt("--docs-target", default = "//work-spaces.github.io:work-spaces.github.io_archive", help = "Docs archive target to run for verification"),
            args_opt("--workflow", default = "pages.yaml", help = "Workflow filename to dispatch"),
            args_opt("--dispatch-ref", default = "", help = "Ref for workflow dispatch. Defaults to --spaces-tag."),
            args_opt("--poll-interval", type = "int", default = 10, help = "Seconds between workflow status polls"),
            args_opt("--timeout", type = "int", default = 1800, help = "Seconds to wait for workflow completion"),
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
        dispatch_ref = spaces_tag

    repo_slug = utils_repo_slug(owner, repo)

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

    # Step 1: bump versions in docs repo (opens PRs if needed).
    print("\nUpdating SPACES_VERSION in {} for spaces release...".format(_SPACES_FILE_PATH))
    _run_update_spaces_version(owner, repo, workdir, spaces_tag)

    print("\nUpdating SDK rev in {} for SDK release...".format(_CHECKOUT_FILE_PATH))
    _run_update_sdk_version(owner, repo, workdir, sdk_tag)

    print("\nUpdating packages rev in {} for packages release...".format(_CHECKOUT_FILE_PATH))
    _run_update_packages_version(owner, repo, workdir, packages_tag)

    # Ensure local checkout is synchronized with main before verification,
    # including the case where update-version was a no-op due to marker reuse.
    utils_refresh_main(workdir)

    # Step 2: ensure docs archive builds after the version update.
    _verify_docs_build(workdir, docs_target)

    # Step 3: create a docs release that matches the current spaces tag.
    _create_docs_release(host, owner, repo, spaces_tag)

    # Step 4: dispatch docs/pages workflow and wait until completion.
    _dispatch_pages_workflow(host, owner, repo, workflow, dispatch_ref, poll_interval, timeout_seconds)

    print("Docs update/publish flow completed successfully for {} on {}.".format(spaces_tag, repo_slug))

main()
