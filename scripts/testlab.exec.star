#!/usr/bin/env spaces
"""
Checkout the spaces-e2e-testlab repository into the workspace root using the
freshly built spaces binary, then run the rcache test script from the new
workspace.

If the per-OS/arch release binaries for ``--tag`` are already attached to the
GitHub release (i.e. ``publish-release-binaries.exec.star`` has already run and
published them), this script exits without doing anything, since the testlab
only needs to run before the binaries are published.
"""

load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/env.star", "env_get")
load("//@star/sdk/star/std/fs.star", "fs_exists")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_inherit")
load("//@star/sdk/star/std/sh.star", "sh_run")
load("internal/utils.star", "utils_release_binaries_published", "utils_repo_slug")

SPACES = "spaces"
TESTLAB_NAME = "testlab"
TESTLAB_URL = "https://github.com/work-spaces/spaces-e2e-testlab"

def _run_testlab(workspace):
    testlab_workspace = "{}/{}".format(workspace, TESTLAB_NAME)
    testlab_store = "{}/testlab-store".format(workspace)

    print("Checking out {} into {}".format(TESTLAB_URL, testlab_workspace))

    sh_run("mkdir -p {}".format(testlab_store))

    if fs_exists(testlab_workspace):
        sh_run("rm -rf {}".format(testlab_workspace))

    process_run(process_options(
        command = SPACES,
        args = [
            "checkout-repo",
            "--name={}".format(TESTLAB_NAME),
            "--url={}".format(TESTLAB_URL),
            "--rev=main",
        ],
        env = {
            "SPACES_ENV_HOME": testlab_store,
        },
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

    print("Running: spaces run //:all")

    process_run(process_options(
        command = SPACES,
        args = [
            "run",
            "//:all",
        ],
        cwd = "testlab",
        stdout = process_stdout_inherit(),
        stderr = process_stderr_inherit(),
        check = True,
    ))

    rcache_script = "./spaces-e2e-testlab/scripts/test_rcache.sh"

    print("Running rcache script: {}".format(rcache_script))

    rcache_result = process_run(process_options(
        command = rcache_script,
        cwd = "testlab",
        check = True,
    ))

    print("rcache script exited with status {}".format(rcache_result["status"]))

def main():
    """Entry point: skip when binaries are published, otherwise run the testlab."""
    spec = args_parser(
        name = "testlab",
        description = "Run the spaces-e2e-testlab unless the release binaries are already published.",
        options = [
            args_opt("--owner", default = "work-spaces", help = "Repository owner (user or organization)"),
            args_opt("--repo", default = "spaces", help = "Repository name"),
            args_opt("--tag", default = "", help = "Release tag to check for already-published binaries"),
        ],
    )
    parsed = args_parse(spec)

    owner = parsed.get("owner", "work-spaces")
    repo = parsed.get("repo", "spaces")
    tag = parsed.get("tag", "")

    workspace = env_get("SPACES_WORKSPACE")
    assert_on(workspace != None, "SPACES_WORKSPACE is not set")

    if tag != "":
        repo_slug = utils_repo_slug(owner, repo)
        if utils_release_binaries_published(repo_slug, tag):
            print(
                ("Release binaries for {} are already published on {}; " +
                 "skipping the testlab.").format(tag, repo_slug),
            )
            return

    _run_testlab(workspace)

main()
