"""
Checkout associated repos
"""

load(
    "//@star/packages/star/gh.star",
    "gh_add",
)
load(
    "//@star/prelude/rules/asset.star",
    "asset_content",
)
load(
    "//@star/prelude/rules/checkout.star",
    "checkout_add_any_assets",
    "checkout_add_env_vars",
    "checkout_add_repo",
    "checkout_store_value",
)
load(
    "//@star/prelude/rules/env.star",
    "env_assign",
    "env_script",
)
load(
    "//@star/prelude/rules/ws.star",
    "workspace_get_absolute_path",
)

gh_add(
    "gh2",
    version = "v2.92.0",
)

checkout_add_env_vars(
    "spaces_install_env",
    vars = [
        env_script(
            "GH_TOKEN",
            script = "sysroot/bin/gh auth token",
            is_secret = True,
            is_required = True,
            help = "GitHub token for authentication",
        ),
    ],
    deps = [":gh2"],
)

checkout_store_value("SPACES_INSTALL_ROOT", workspace_get_absolute_path() + "/build/install")

checkout_add_repo(
    "install-spaces",
    url = "https://github.com/work-spaces/install-spaces",
    rev = "main",
)

checkout_add_repo(
    "spaces-checkout-run",
    url = "https://github.com/work-spaces/spaces-checkout-run",
    rev = "main",
)

checkout_add_any_assets(
    name = "workflows-toml",
    assets = [
        asset_content(destination = "docs/workflows.spaces.toml", content = ""),
        asset_content(destination = "testlab/workflows.spaces.toml", content = ""),
    ],
)

checkout_add_repo(
    "docs/work-spaces.github.io",
    url = "https://github.com/work-spaces/work-spaces.github.io",
    rev = "main",
    is_evaluate_spaces_modules = False,
)

checkout_add_repo(
    "testlab/spaces-e2e-testlab",
    url = "https://github.com/work-spaces/spaces-e2e-testlab",
    rev = "main",
    is_evaluate_spaces_modules = False,
)
