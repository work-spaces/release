"""
Procedure for releasing a new version of spaces.

See the README for details.
"""

load("//@star/prelude/rules/deps.star", "deps")
load("//@star/prelude/rules/run.star", "run_add_exec", "run_load_env")
load("//@star/prelude/rules/visibility.star", "visibility_private")
load("//@star/prelude/rules/ws.star", "workspace_get_env_var", "workspace_load_value")

STARLARK_FILES = [
    "0.checkout.spaces.star",
    "1.checkout.spaces.star",
    "spaces.star",
    "scripts/create-release.exec.star",
    "scripts/gh-workflow-dispatch.exec.star",
    "scripts/publish-release-binaries.exec.star",
    "scripts/testlab.exec.star",
    "scripts/collect-results.exec.star",
    "scripts/update-docs.exec.star",
    "scripts/update-packages.exec.star",
    "scripts/update-version.exec.star",
    "scripts/validate-tag.exec.star",
]

SPACES_INSTALL_ROOT = workspace_get_env_var("SPACES_INSTALL_ROOT")

spaces_tag = workspace_load_value("RELEASE_SPACES_TAG")
previous_spaces_tag = workspace_load_value("RELEASE_PREVIOUS_SPACES_TAG") or "unknown"
sdk_tag = workspace_load_value("RELEASE_SDK_TAG")
packages_tag = workspace_load_value("RELEASE_PACKAGES_TAG")

run_add_exec(
    "check_starlark",
    command = "buildifier",
    args = [
        "-lint=warn",
        "-mode=check",
    ] + STARLARK_FILES,
    deps = deps(files = STARLARK_FILES),
    visibility = visibility_private(),
    working_directory = ".",
)

release_notes_file = "build/release-notes.md"

run_add_exec(
    "generate_release_notes",
    command = "release/scripts/generate-release-notes.exec.star",
    args = [
        "--owner=work-spaces",
        "--repo=spaces",
        "--tag=" + previous_spaces_tag,
        "--workdir=spaces",
        "--notes-file=" + release_notes_file,
        "--new-tag=" + spaces_tag,
    ],
    deps = deps(files = ["//spaces/**"]),
    target_files = ["//{}".format(release_notes_file)],
    env = {
        "GH_TOKEN": workspace_get_env_var("GH_TOKEN"),
    },
)

run_add_exec(
    "format",
    command = "buildifier",
    args = STARLARK_FILES,
    deps = deps(files = STARLARK_FILES),
    visibility = visibility_private(),
    working_directory = ".",
)

# Depends on spaces install release to use the latest
# Runs the test labs. Skips itself when the release binaries for spaces_tag are
# already published (see release/scripts/testlab.exec.star).
run_add_exec(
    "testlab",
    command = "release/scripts/testlab.exec.star",
    args = [
        "--owner=work-spaces",
        "--repo=spaces",
        "--tag={}".format(spaces_tag),
    ],
    help = "Checkout and run the testlab including the rcache test",
    deps = deps(
        rules = ["//spaces:install_release"],
        files = [
            "scripts/testlab.exec.star",
            "//{}/bin/spaces".format(SPACES_INSTALL_ROOT),
        ],
    ),
    env = {
        "PATH": "{}/bin:{}".format(
            SPACES_INSTALL_ROOT,
            workspace_get_env_var("PATH"),
        ),
    },
)

# JSON status files written by the release steps below. Each version-bump step
# exits successfully but records whether a human action (such as merging a PR)
# is still required. The ``publish`` rule collects these and fails if any
# outstanding action remains.
_INSTALL_SPACES_STATUS = "build/update-version/install-spaces-{}.status.json".format(spaces_tag)
_SPACES_CHECKOUT_RUN_STATUS = "build/update-version/spaces-checkout-run-{}.status.json".format(spaces_tag)
_UPDATE_DOCS_STATUS = "build/update-docs/work-spaces.github.io-{}.status.json".format(spaces_tag)
_PACKAGES_STATUS = "build/update-packages/packages-{}.status.json".format(packages_tag)
_STATUS_FILES = [
    _INSTALL_SPACES_STATUS,
    _SPACES_CHECKOUT_RUN_STATUS,
    _UPDATE_DOCS_STATUS,
    _PACKAGES_STATUS,
]

tags = {"spaces": spaces_tag, "sdk": sdk_tag, "packages": packages_tag}
tag_deps = []
for tag, tag_value in tags.items():
    rule = "check_tag_{}".format(tag)
    tag_deps.append(":" + rule)
    run_add_exec(
        rule,
        command = "release/scripts/validate-tag.exec.star",
        help = "Ensures the {} tag is a valid semantic version with a leading 'v'.",
        args = [
            "--tag={}".format(tag_value),
        ],
    )

run_add_exec(
    "create_spaces_release",
    command = "release/scripts/create-release.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=spaces",
        "--tag={}".format(spaces_tag),
        "--release-notes={}".format(release_notes_file),
    ],
    help = "",
    deps = deps(
        rules = [
            ":generate_release_notes",
            ":testlab",
        ] + tag_deps,
        files = [
            "scripts/create-release.exec.star",
        ],
    ),
)

run_add_exec(
    "publish_binaries",
    command = "release/scripts/publish-release-binaries.exec.star",
    args = [
        "--tag={}".format(spaces_tag),
    ],
    help = "",
    deps = deps(
        rules = [
            ":create_spaces_release",
        ],
        files = [
            "scripts/publish-release-binaries.exec.star",
        ],
    ),
)

run_add_exec(
    "clear_spaces_prerelease",
    command = "gh",
    args = [
        "release",
        "edit",
        spaces_tag,
        "--repo=github.com/work-spaces/spaces",
        "--prerelease=false",
    ],
    help = "",
    deps = [":publish_binaries"],
)

run_add_exec(
    "update_spaces_latest_release",
    command = "gh",
    args = [
        "release",
        "edit",
        spaces_tag,
        "--repo=github.com/work-spaces/spaces",
        "--latest",
    ],
    help = "",
    deps = [":clear_spaces_prerelease"],
)

run_add_exec(
    "gh_musl_build",
    command = "release/scripts/gh-workflow-dispatch.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=spaces",
        "--workflow=build.yaml",
        "--ref={}".format(spaces_tag),
    ],
    help = "Run the gh musl build on Github",
    deps = deps(),
)

# ---------------------------------------------------------------------------
# Downstream version bumps
#
# After a new spaces release is published, two downstream repos pin the
# released version in their composite-action YAML and need to be bumped:
#
#   - work-spaces/install-spaces/action.yml
#       echo version=<TAG> >> $GITHUB_OUTPUT
#   - work-spaces/spaces-checkout-run/action.yml
#       uses: work-spaces/install-spaces@<TAG>
#
# Both repos are already cloned as workspace members by 1.checkout.spaces.star,
# so we reuse those checkouts as the --workdir for the update-version script
# (relative paths from the workspace root, which is the default working
# directory for run_add_exec rules). ``--search`` is a regex matching whatever
# version is currently pinned on main; ``--replace`` is the literal new line.
# ---------------------------------------------------------------------------

# Matches semver-ish tags like ``v0.15.44``, ``v0.15.45-alpha2``, ``v1.2.3+build``.
_VERSION_REGEX = r"v\d+\.\d+\.\d+[\w.+-]*"

# NOTE: The status-producing rules below (update_install_spaces,
# update_spaces_checkout_run, create_packages_release, update_docs) exit
# successfully even when they only recorded "Need to merge PR" in their status
# file -- a required human action is an expected outcome, not a failure. Their
# real completion condition (the PR being merged into main) lives in remote
# GitHub state that spaces cannot observe. If these rules declared their script
# as a glob/file input, spaces would hash that unchanged input, treat the prior
# successful run as up to date, and SKIP them on re-run -- so they would never
# re-check the remote and flip their status to "Complete" after a merge. We
# therefore give them rule-only dependencies (no glob inputs) so they re-run on
# every invocation and re-evaluate the merge state. The scripts are idempotent
# and short-circuit cheaply once the bump has landed.

run_add_exec(
    "update_install_spaces",
    command = "release/scripts/update-version.exec.star",
    args = [
        "--owner=work-spaces",
        "--repo=install-spaces",
        "--file-path=action.yml",
        "--workdir=install-spaces",
        "--search=version={}".format(_VERSION_REGEX),
        "--replace=version={}".format(spaces_tag),
        "--new-version={}".format(spaces_tag),
        "--status-file={}".format(_INSTALL_SPACES_STATUS),
        "--latest-release",
    ],
    help = "Open a PR bumping work-spaces/install-spaces to {} and then create a release".format(spaces_tag),
    # Rule-only deps (no glob input) so this always re-runs; see note above.
    deps = deps(
        rules = [":update_spaces_latest_release"],
    ),
)

run_add_exec(
    "update_spaces_checkout_run",
    command = "release/scripts/update-version.exec.star",
    args = [
        "--owner=work-spaces",
        "--repo=spaces-checkout-run",
        "--file-path=action.yml",
        "--workdir=spaces-checkout-run",
        "--search=install-spaces@{}".format(_VERSION_REGEX),
        "--replace=install-spaces@{}".format(spaces_tag),
        "--new-version={}".format(spaces_tag),
        "--status-file={}".format(_SPACES_CHECKOUT_RUN_STATUS),
        "--latest-release",
    ],
    help = "Open a PR bumping work-spaces/spaces-checkout-run to {} and then create a release".format(spaces_tag),
    # Rule-only deps (no glob input) so this always re-runs; see note above.
    deps = deps(
        rules = [":update_install_spaces"],
    ),
)

# Bumps work-spaces/packages to the latest packages, opens a PR, and creates
# the packages release once that PR has been merged. The script halts (with a
# message written under build/) whenever a PR needs to be reviewed and merged
# by a human; re-run this rule after merging to create the release.
run_add_exec(
    "create_packages_release",
    command = "release/scripts/update-packages.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=packages",
        "--workdir=@star/packages",
        "--tag={}".format(packages_tag),
        "--spaces-version={}".format(spaces_tag),
        "--status-file={}".format(_PACKAGES_STATUS),
        "--latest-release",
    ],
    help = "",
    # Rule-only deps (no glob input) so this always re-runs; see note above.
    deps = deps(
        rules = [
            ":update_spaces_latest_release",
        ] + tag_deps,
    ),
)

run_add_exec(
    "create_sdk_release",
    command = "release/scripts/create-release.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=sdk",
        "--tag={}".format(sdk_tag),
        "--latest-release",
    ],
    help = "Creates a release for work-spaces/sdk using what is currently in the main branch",
    deps = deps(
        rules = [
            ":create_packages_release",
        ] + tag_deps,
        files = [
            "scripts/create-release.exec.star",
        ],
    ),
)

run_add_exec(
    "update_docs",
    command = "release/scripts/update-docs.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=work-spaces.github.io",
        "--spaces-tag={}".format(spaces_tag),
        "--sdk-tag={}".format(sdk_tag),
        "--packages-tag={}".format(packages_tag),
        "--workdir=docs/work-spaces.github.io",
        "--status-file={}".format(_UPDATE_DOCS_STATUS),
    ],
    help = "Update and publish docs for the current spaces release",
    # Rule-only deps (no glob input) so this always re-runs; see note above.
    deps = deps(
        rules = [
            ":update_spaces_latest_release",
            ":create_sdk_release",
            ":create_packages_release",
        ],
    ),
)

run_add_exec(
    "publish",
    command = "release/scripts/collect-results.exec.star",
    args = ["--status-file={}".format(status_file) for status_file in _STATUS_FILES],
    help = "Collect release step status files; fail if any human action (such as merging a PR) is still required",
    deps = deps(
        rules = [
            ":create_packages_release",
            ":create_sdk_release",
            ":update_spaces_latest_release",
            ":update_install_spaces",
            ":update_spaces_checkout_run",
            ":update_docs",
        ],
        files = [
            "scripts/collect-results.exec.star",
        ],
    ),
)
