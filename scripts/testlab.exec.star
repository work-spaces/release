#!/usr/bin/env spaces
"""
Checkout the spaces-e2e-testlab repository into the workspace root using the
freshly built spaces binary, then run the rcache test script from the new
workspace.
"""

load("//@star/sdk/star/std/env.star", "env_get")
load("//@star/sdk/star/std/fs.star", "fs_exists")
load("//@star/sdk/star/std/process.star", "process_options", "process_run", "process_stderr_inherit", "process_stdout_inherit")
load("//@star/sdk/star/std/sh.star", "sh_run")

WORKSPACE = env_get("SPACES_WORKSPACE")
assert_on(WORKSPACE != None, "SPACES_WORKSPACE is not set")

SPACES = "spaces"
TESTLAB_NAME = "testlab"
TESTLAB_URL = "https://github.com/work-spaces/spaces-e2e-testlab"
TESTLAB_WORKSPACE = "{}/{}".format(WORKSPACE, TESTLAB_NAME)
TESTLAB_STORE = "{}/testlab-store".format(WORKSPACE)

print("Checking out {} into {}".format(TESTLAB_URL, TESTLAB_WORKSPACE))

sh_run("mkdir -p {}".format(TESTLAB_STORE))

if fs_exists(TESTLAB_WORKSPACE):
    sh_run("rm -rf {}".format(TESTLAB_WORKSPACE))

process_run(process_options(
    command = SPACES,
    args = [
        "checkout-repo",
        "--name={}".format(TESTLAB_NAME),
        "--url={}".format(TESTLAB_URL),
        "--rev=main",
    ],
    env = {
        "SPACES_ENV_HOME": TESTLAB_STORE,
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

RCACHE_SCRIPT = "./spaces-e2e-testlab/scripts/test_rcache.sh"

print("Running rcache script: {}".format(RCACHE_SCRIPT))

rcache_result = process_run(process_options(
    command = RCACHE_SCRIPT,
    cwd = "testlab",
    check = True,
))

print("rcache script exited with status {}".format(rcache_result["status"]))
