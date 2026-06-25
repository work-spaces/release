"""
Procedure for releasing a new version of spaces.

See the README for details.
"""

load("//@star/sdk/star/deps.star", "deps")
load("//@star/sdk/star/run.star", "run_add", "run_add_exec")
load("//@star/sdk/star/visibility.star", "visibility_private")
load("//@star/sdk/star/ws.star", "workspace_get_env_var", "workspace_load_value")

STARLARK_FILES = [
    "0.checkout.spaces.star",
    "1.checkout.spaces.star",
    "spaces.star",
    "scripts/create-release.exec.star",
    "scripts/gh-workflow-dispatch.exec.star",
    "scripts/publish-release-binaries.exec.star",
    "scripts/testlab.exec.star",
    "scripts/update-docs.exec.star",
    "scripts/update-packages.exec.star",
    "scripts/update-version.exec.star",
    "scripts/validate-tag.exec.star",
]

SPACES_INSTALL_ROOT = workspace_get_env_var("SPACES_INSTALL_ROOT")

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

run_add_exec(
    "format",
    command = "buildifier",
    args = STARLARK_FILES,
    deps = deps(files = STARLARK_FILES),
    visibility = visibility_private(),
    working_directory = ".",
)

# Depends on spaces install release to use the latest
# Runs the test labs
run_add_exec(
    "testlab",
    command = "release/scripts/testlab.exec.star",
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

spaces_tag = workspace_load_value("RELEASE_SPACES_TAG")
sdk_tag = workspace_load_value("RELEASE_SDK_TAG")
packages_tag = workspace_load_value("RELEASE_PACKAGES_TAG")

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
    ],
    help = "",
    deps = deps(
        rules = [
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

def _add_update_version_rule(
        name,
        repo,
        file_path,
        workdir,
        search,
        replace,
        help_text,
        rule_deps = []):
    """Register a ``run_add_exec`` that delegates to the update-version script."""
    pr_rule = name + "_pr"
    run_add_exec(
        pr_rule,
        command = "release/scripts/update-version.exec.star",
        args = [
            "--owner=work-spaces",
            "--repo={}".format(repo),
            "--file-path={}".format(file_path),
            "--workdir={}".format(workdir),
            "--search={}".format(search),
            "--replace={}".format(replace),
            "--new-version={}".format(spaces_tag),
        ],
        help = help_text,
        deps = deps(
            rules = rule_deps,
            files = ["scripts/update-version.exec.star"],
        ),
    )

    run_add_exec(
        name,
        command = "release/scripts/create-release.exec.star",
        args = [
            "--owner=work-spaces",
            "--repo={}".format(repo),
            "--tag={}".format(spaces_tag),
            "--latest-release",
        ],
        deps = deps(
            rules = [pr_rule],
            files = ["scripts/create-release.exec.star"],
        ),
    )

_add_update_version_rule(
    name = "update_install_spaces",
    repo = "install-spaces",
    file_path = "action.yml",
    workdir = "install-spaces",
    search = "version={}".format(_VERSION_REGEX),
    replace = "version={}".format(spaces_tag),
    help_text = "Open a PR bumping work-spaces/install-spaces to {}".format(spaces_tag),
    rule_deps = [":update_spaces_latest_release"],
)

_add_update_version_rule(
    name = "update_spaces_checkout_run",
    repo = "spaces-checkout-run",
    file_path = "action.yml",
    workdir = "spaces-checkout-run",
    search = "install-spaces@{}".format(_VERSION_REGEX),
    replace = "install-spaces@{}".format(spaces_tag),
    help_text = "Open a PR bumping work-spaces/spaces-checkout-run to {}".format(spaces_tag),
    rule_deps = [":update_install_spaces"],
)

run_add_exec(
    "update_package",
    command = "release/scripts/update-packages.exec.star",
    args = [
        "--owner=work-spaces",
        "--repo=packages",
        "--workdir=@star/packages",
        "--new-version={}".format(packages_tag),
    ],
    deps = deps(
        rules = [
            ":update_spaces_latest_release",
        ],
        files = [
            "scripts/update-packages.exec.star",
        ],
    ),
)

run_add_exec(
    "create_packages_release",
    command = "release/scripts/create-release.exec.star",
    args = [
        "--host=github.com",
        "--owner=work-spaces",
        "--repo=packages",
        "--tag={}".format(packages_tag),
        "--latest-release",
    ],
    help = "",
    deps = deps(
        rules = [
            ":update_package",
        ] + tag_deps,
        files = [
            "scripts/create-release.exec.star",
        ],
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
    help = "",
    deps = deps(
        rules = [
            ":update_package",
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
    ],
    help = "Update and publish docs for the current spaces release",
    deps = deps(
        rules = [
            ":update_spaces_latest_release",
            ":create_sdk_release",
            ":create_packages_release",
        ],
        files = [
            "scripts/update-docs.exec.star",
        ],
    ),
)

run_add(
    "publish",
    deps = [
        ":create_packages_release",
        ":create_sdk_release",
        ":update_spaces_latest_release",
        ":update_install_spaces",
        ":update_spaces_checkout_run",
        ":update_docs",
    ],
)
