#!/usr/bin/env spaces
"""
Validate that ``--spaces-version`` matches the version declared by the spaces crates.

This script compares the provided version against:

- ``<spaces-repo-path>/crates/spaces/Cargo.toml``
- ``<spaces-repo-path>/crates/spaces-utils/Cargo.toml``

The argument may be passed either as ``0.20.1`` or ``v0.20.1``.
"""

load("//@star/sdk/star/semver.star", "semver_is_valid_version")
load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")
load("//@star/sdk/star/std/fs.star", "fs_exists", "fs_read_toml")

_SPACES_MANIFEST_REL = "crates/spaces/Cargo.toml"
_SPACES_UTILS_MANIFEST_REL = "crates/spaces-utils/Cargo.toml"

def _normalize_spaces_version(spaces_version: str) -> str:
    assert_on(spaces_version != "", "--spaces-version is required")
    normalized = spaces_version[1:] if spaces_version.startswith("v") else spaces_version
    assert_on(normalized != "", "--spaces-version has no version after the leading 'v'")
    assert_on(
        semver_is_valid_version(normalized),
        "--spaces-version must be a semantic version (for example: 0.20.1 or v0.20.1). Got '{}'".format(spaces_version),
    )
    return normalized

def _join_path(base: str, suffix: str) -> str:
    if base.endswith("/"):
        return base + suffix
    return base + "/" + suffix

def _read_package_version(manifest_path: str) -> str:
    assert_on(fs_exists(manifest_path), "Manifest not found: {}".format(manifest_path))

    manifest = fs_read_toml(manifest_path)
    package = manifest.get("package", {})
    assert_on(type(package) == "dict", "{} is missing a [package] table".format(manifest_path))

    version = package.get("version", None)
    assert_on(
        type(version) == "string" and version != "",
        "{} is missing package.version".format(manifest_path),
    )
    return version

def main():
    spec = args_parser(
        name = "check-spaces-version",
        description = "Validate --spaces-version against spaces crate Cargo.toml versions.",
        options = [
            args_opt("--spaces-version", help = "Version to validate (e.g. 0.20.1 or v0.20.1)"),
            args_opt("--spaces-repo-path", default = "spaces", help = "Path to the spaces repository root (default: spaces)"),
        ],
    )
    parsed = args_parse(spec)

    requested = parsed.get("spaces_version", "")
    spaces_repo_path = parsed.get("spaces_repo_path", "spaces")

    assert_on(spaces_repo_path != "", "--spaces-repo-path is required")

    normalized_requested = _normalize_spaces_version(requested)

    spaces_manifest = _join_path(spaces_repo_path, _SPACES_MANIFEST_REL)
    spaces_utils_manifest = _join_path(spaces_repo_path, _SPACES_UTILS_MANIFEST_REL)

    spaces_version = _read_package_version(spaces_manifest)
    spaces_utils_version = _read_package_version(spaces_utils_manifest)

    assert_on(
        spaces_version == spaces_utils_version,
        "Spaces crate versions do not match: {} has {}, but {} has {}".format(
            spaces_manifest,
            spaces_version,
            spaces_utils_manifest,
            spaces_utils_version,
        ),
    )
    assert_on(
        normalized_requested == spaces_version,
        "--spaces-version {} (normalized to {}) does not match Cargo.toml version {}".format(
            requested,
            normalized_requested,
            spaces_version,
        ),
    )

    print("Version check passed.")
    print("  requested:         {}".format(requested))
    print("  normalized:        {}".format(normalized_requested))
    print("  spaces repo path:  {}".format(spaces_repo_path))
    print("  spaces:            {} ({})".format(spaces_version, spaces_manifest))
    print("  spaces-utils:      {} ({})".format(spaces_utils_version, spaces_utils_manifest))

main()
