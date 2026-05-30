#!/usr/bin/env spaces
"""
Validate that a tag is a semantic version with a leading ``v``.

The tag must:

1. Start with the literal character ``v``.
2. Have a remainder (after stripping the leading ``v``) that is a well-formed
   semantic version, per ``@star/sdk/star/semver.star``.

On success, the parsed components are printed. On failure, the script aborts
via ``assert_on``.

Example::

    validate-tag.exec.star --tag=v0.15.45
"""

load("//@star/sdk/star/semver.star", "semver_is_valid_version", "semver_parse")
load("//@star/sdk/star/std/args.star", "args_opt", "args_parse", "args_parser")

def _validate(tag):
    assert_on(
        tag.startswith("v"),
        "tag {} must start with a leading 'v' (e.g. v1.2.3)".format(tag),
    )

    version = tag[1:]
    assert_on(
        version != "",
        "tag {} has no version after the leading 'v'".format(tag),
    )
    assert_on(
        semver_is_valid_version(version),
        "tag {} is not a valid semantic version (got '{}')".format(tag, version),
    )

    return semver_parse(version)

def main():
    """
    Ensure a tag is a semver version with a leading 'v'.
    """
    spec = args_parser(
        name = "validate-tag",
        description = "Ensure a tag is a semver version with a leading 'v'.",
        options = [
            args_opt("--tag", help = "Tag to validate (e.g. v1.2.3)"),
        ],
    )
    parsed = args_parse(spec)

    tag = parsed.get("tag", "v0.0.0")
    components = _validate(tag)

    print("Tag {} is a valid semver tag.".format(tag))
    print("  major: {}".format(components["major"]))
    print("  minor: {}".format(components["minor"]))
    print("  patch: {}".format(components["patch"]))
    if components.get("pre", "") != "":
        print("  pre:   {}".format(components["pre"]))
    if components.get("build", "") != "":
        print("  build: {}".format(components["build"]))

main()
