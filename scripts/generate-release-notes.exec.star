#!/usr/bin/env spaces
"""
Generate markdown release notes for all commits between a tag and the current
commit (HEAD).

The script uses:

1. ``git`` to resolve ``HEAD`` and list commits in ``<tag>..HEAD``.
2. ``gh`` to discover repository metadata (slug + web URL) for commit links.

By default, notes are printed to stdout. Optionally write them to a file via
``--notes-file``.

Pass ``--new-tag`` to overwrite the tip commit reference in the generated
markdown with an upcoming tag name (for example ``v0.17.3``) before that tag
exists.

Example::

    generate-release-notes.exec.star \
        --tag=v0.17.2 \
        --workdir=. \
        --notes-file=build/release-notes.md
"""

load("//@star/prelude/exec/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/prelude/exec/fs.star", "fs_mkdir", "fs_write_text")
load("//@star/prelude/exec/json.star", "json_decode")
load(
    "//@star/prelude/exec/process.star",
    "process_options",
    "process_run",
    "process_stderr_inherit",
    "process_stdout_capture",
)
load("//@star/prelude/exec/string.star", "string_split_lines", "string_trim")

def _run_capture(command: str, args: list[str], cwd: str, check: bool = True) -> dict:
    return process_run(process_options(
        command = command,
        args = args,
        cwd = cwd,
        stdout = process_stdout_capture(),
        stderr = process_stderr_inherit(),
        check = check,
    ))

def _git_capture(args: list[str], cwd: str, check: bool = True) -> dict:
    return _run_capture("git", args, cwd, check = check)

def _gh_capture(args: list[str], cwd: str, check: bool = True) -> dict:
    return _run_capture("gh", args, cwd, check = check)

def _discover_repo_info(host: str, owner: str, repo: str, workdir: str) -> dict:
    """Return ``{"slug": "owner/repo", "url": "https://..."}`` from ``gh``."""
    gh_args = ["repo", "view"]

    if owner != "" or repo != "":
        assert_on(owner != "" and repo != "", "--owner and --repo must be provided together")
        repo_slug = "{}/{}".format(owner, repo)
        repo_ref = repo_slug if host == "github.com" else "{}/{}".format(host, repo_slug)
        gh_args.append(repo_ref)

    gh_args.extend(["--json", "nameWithOwner,url"])

    info = json_decode(_gh_capture(gh_args, workdir)["stdout"])
    slug = info.get("nameWithOwner", "")
    url = info.get("url", "")

    assert_on(slug != "", "Could not resolve repository slug via `gh repo view`")
    assert_on(url != "", "Could not resolve repository URL via `gh repo view`")
    return {"slug": slug, "url": url}

def _verify_tag_exists(tag: str, workdir: str) -> None:
    result = _git_capture(["rev-parse", "--verify", "{}^{{commit}}".format(tag)], workdir, check = False)
    assert_on(result["status"] == 0, "Tag '{}' was not found in {}. Ensure the tag exists locally (or fetch tags first).".format(tag, workdir))

def _head_sha(workdir: str) -> str:
    return string_trim(_git_capture(["rev-parse", "HEAD"], workdir)["stdout"])

def _list_commits(tag: str, head_sha: str, workdir: str) -> list[dict]:
    """List commits in ``<tag>..HEAD`` as ``[{"sha": ..., "subject": ...}, ...]``."""
    commit_range = "{}..{}".format(tag, head_sha)
    output = string_trim(_git_capture(
        [
            "log",
            "--reverse",
            "--pretty=format:%H%x1f%s",
            commit_range,
        ],
        workdir,
    )["stdout"])

    if output == "":
        return []

    commits = []
    for line in string_split_lines(output):
        if line == "":
            continue
        parts = line.split("\x1f", 1)
        sha = parts[0] if len(parts) > 0 else ""
        subject = parts[1] if len(parts) > 1 else ""
        if sha == "":
            continue
        commits.append({
            "sha": sha,
            "subject": subject if subject != "" else "(no commit subject)",
        })

    return commits

def _build_notes(tag: str, head_sha: str, repo_url: str, commits: list[dict], new_tag: str) -> str:
    range_end_label = new_tag if new_tag != "" else head_sha[:7]
    compare_end = new_tag if new_tag != "" else head_sha

    lines = [
        "# Release Notes",
        "",
        "Changes between `{}` and `{}`.".format(tag, range_end_label),
        "",
    ]

    if len(commits) == 0:
        lines.append("- No commits found in this range.")
    else:
        for commit in commits:
            sha = commit["sha"]
            ref_label = sha[:7]
            if new_tag != "" and sha == head_sha:
                ref_label = new_tag
            subject = commit["subject"]
            lines.append("- {} ([`{}`]({}/commit/{}))".format(subject, ref_label, repo_url, sha))

    lines.extend([
        "",
        "**Full Changelog**: {}/compare/{}...{}".format(repo_url, tag, compare_end),
        "",
    ])

    return "\n".join(lines)

def _write_notes(path: str, notes: str) -> None:
    parent = path.rsplit("/", 1)
    if len(parent) == 2 and parent[0] != "":
        fs_mkdir(parent[0], parents = True, exist_ok = True)
    fs_write_text(path, notes)

def main():
    spec = args_parser(
        name = "generate-release-notes",
        description = "Generate release notes for commits between a tag and the current commit.",
        options = [
            args_opt("--host", default = "github.com", help = "Git host (used when --owner/--repo are provided)"),
            args_opt("--owner", default = "", help = "Repository owner; optional when running in a checkout gh can resolve"),
            args_opt("--repo", default = "", help = "Repository name; optional when running in a checkout gh can resolve"),
            args_opt("--tag", help = "Start tag for release notes (commits are taken from <tag>..HEAD)"),
            args_opt("--workdir", default = ".", help = "Path to the local git checkout"),
            args_opt("--notes-file", default = "", help = "Optional output markdown file. If empty, only stdout is used."),
            args_opt("--new-tag", default = "", help = "Optional upcoming tag name used to overwrite the tip commit reference in the markdown"),
        ],
    )
    parsed = args_parse(spec)

    host = parsed.get("host", "github.com")
    owner = parsed.get("owner", "")
    repo = parsed.get("repo", "")
    tag = parsed.get("tag", "")
    workdir = parsed.get("workdir", ".")
    notes_file = parsed.get("notes_file", "")
    new_tag = parsed.get("new_tag", "")

    assert_on(tag != "", "--tag is required")

    print("Tag:      {}".format(tag))
    print("Workdir:  {}".format(workdir))

    _verify_tag_exists(tag, workdir)
    head_sha = _head_sha(workdir)
    repo_info = _discover_repo_info(host, owner, repo, workdir)

    print("Repo:     {}".format(repo_info["slug"]))
    print("HEAD:     {}".format(head_sha))

    commits = _list_commits(tag, head_sha, workdir)
    notes = _build_notes(tag, head_sha, repo_info["url"], commits, new_tag)

    if notes_file != "":
        _write_notes(notes_file, notes)
        print("Wrote release notes to {}".format(notes_file))

    print("")
    print(notes)

main()
