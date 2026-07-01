"""

"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_mkdir", "fs_read_text", "fs_write_text")
load("//@star/sdk/star/std/json.star", "json_decode")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_capture", "process_stdout_inherit")
load("//@star/sdk/star/std/string.star", "string_contains", "string_regex_find_all", "string_replace", "string_trim")

def utils_run(command: str, args: list[str] | None = None, cwd: str | None = None, check: bool = True, capture: bool = False) -> dict:
    """Run a process, optionally capturing stdout."""
    stdout = process_stdout_capture() if capture else process_stdout_inherit()
    result = process_run(process_options(
        command = command,
        args = args,
        cwd = cwd,
        stdout = stdout,
        stderr = process_stderr_inherit(),
        check = check,
    ))
    return result

def utils_git(args: list[str], cwd: str | None = None, check: bool = True, capture: bool = False) -> dict:
    return utils_run("git", args, cwd = cwd, check = check, capture = capture)

def utils_gh(args: list[str], cwd: str | None = None, check: bool = True, capture: bool = False) -> dict:
    return utils_run("gh", args, cwd = cwd, check = check, capture = capture)

def utils_create_pr(repo_slug: str, branch: str, title: str, body: str, cwd: str | None = None) -> str:
    print("Creating PR on {} from branch {}".format(repo_slug, branch))
    result = utils_gh(
        [
            "pr",
            "create",
            "--repo",
            repo_slug,
            "--base",
            "main",
            "--head",
            branch,
            "--title",
            title,
            "--body",
            body,
        ],
        cwd = cwd,
        capture = True,
    )
    return string_trim(result.get("stdout", ""))

def utils_refresh_main(clone_dir: str) -> None:
    """Fetch and hard-reset ``clone_dir`` to ``origin/main``.

    The directory must already be a git checkout. The script never clones;
    it is the caller's responsibility (typically the spaces checkout phase)
    to ensure the repo is present.
    """
    assert_on(
        fs_exists(clone_dir),
        "workdir does not exist: {} (the repo must be checked out before running this script)".format(clone_dir),
    )
    assert_on(
        fs_exists(clone_dir + "/.git"),
        "workdir is not a git checkout: {} (expected a .git directory)".format(clone_dir),
    )
    print("Refreshing checkout at {}".format(clone_dir))
    utils_git(["fetch", "origin", "main"], cwd = clone_dir)
    utils_git(["checkout", "main"], cwd = clone_dir)
    utils_git(["reset", "--hard", "origin/main"], cwd = clone_dir)

def utils_find_existing_pr(repo_slug: str, branch: str) -> str:
    """Return the URL of an open PR with the given head branch, or ``""``."""
    result = utils_gh(
        [
            "pr",
            "list",
            "--repo",
            repo_slug,
            "--head",
            branch,
            "--state",
            "open",
            "--json",
            "url",
        ],
        check = False,
        capture = True,
    )
    if result["status"] != 0:
        return ""
    stdout = result.get("stdout", "")
    if string_trim(stdout) == "":
        return ""
    decoded = json_decode(stdout)
    if type(decoded) != "list" or len(decoded) == 0:
        return ""
    return decoded[0].get("url", "")

def utils_release_exists(repo_slug: str, tag: str) -> bool:
    """Return True if a release for ``tag`` already exists on the remote."""
    result = process_run(process_options(
        command = "gh",
        args = ["release", "view", tag, "--repo", repo_slug],
        stdout = process_stdout_capture(),
        stderr = process_stdout_capture(),
        check = False,
    ))
    return result["status"] == 0

def utils_create_release(repo_slug: str, tag: str, is_latest: bool, is_draft: bool = False) -> None:
    """Create a GitHub release for ``tag`` with auto-generated notes.

    When ``is_draft`` is True, the release is created as a draft so that
    binaries can be attached before it is published. This is required for
    repositories with immutable releases enabled, where a release becomes
    immutable (and rejects new assets) as soon as it is published.
    """
    print("Creating {} {} on {}".format("draft release" if is_draft else "pre-release", tag, repo_slug))
    release_args = ["--latest"] if is_latest else ["--prerelease"]
    if is_draft:
        release_args = release_args + ["--draft"]
    utils_gh([
        "release",
        "create",
        tag,
        "--repo",
        repo_slug,
        "--title",
        tag,
        "--generate-notes",
    ] + release_args)

def utils_repo_slug(owner, repo):
    return "{}/{}".format(owner, repo)

# Expected (os, arch) pairs produced by build-and-publish.yaml. The asset
# names follow the pattern ``spaces-<os>-<arch>-<tag>.zip``. This is the single
# source of truth shared by the scripts that publish and that gate on the
# per-OS/arch release binaries.
_EXPECTED_BINARY_TARGETS = [
    ("linux", "x86_64"),
    ("linux", "aarch64"),
    ("macos", "x86_64"),
    ("macos", "aarch64"),
    ("windows", "x86_64"),
]

def utils_expected_binary_names(tag: str) -> list[str]:
    """Return the expected per-OS/arch binary asset names for ``tag``."""
    return [
        "spaces-{}-{}-{}.zip".format(os, arch, tag)
        for (os, arch) in _EXPECTED_BINARY_TARGETS
    ]

def utils_release_binaries_published(repo_slug: str, tag: str) -> bool:
    """Return True if every expected per-OS/arch binary is attached to ``tag``.

    Returns False when the release does not exist or is missing any expected
    asset, so callers can gate work on the binaries already being published.

    Args:
      repo_slug: The repository slug (e.g. "owner/repo").
      tag: The release tag to inspect.

    Returns:
      True if all expected binaries are attached, otherwise False.
    """
    result = process_run(process_options(
        command = "gh",
        args = ["release", "view", tag, "--repo", repo_slug, "--json", "assets"],
        stdout = process_stdout_capture(),
        stderr = process_stdout_capture(),
        check = False,
    ))
    if result["status"] != 0:
        return False
    info = json_decode(result["stdout"])
    attached = {}
    for asset in info.get("assets", []):
        name = asset.get("name", "")
        if name != "":
            attached[name] = True
    for name in utils_expected_binary_names(tag):
        if not attached.get(name, False):
            return False
    return True
