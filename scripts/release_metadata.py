#!/usr/bin/env python3
"""Validate that release tags, project metadata, and the Homebrew cask agree."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def single_match(text: str, pattern: str, label: str) -> str:
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise ValueError(f"expected exactly one {label}, found {len(matches)}")
    return matches[0]


def configured_version(xcconfig: Path) -> str:
    return single_match(
        xcconfig.read_text(),
        r"^MARKETING_VERSION\s*=\s*([^\s#]+)\s*$",
        "MARKETING_VERSION",
    )


def cask_metadata(cask: Path) -> tuple[str, str]:
    text = cask.read_text()
    version = single_match(text, r'^\s*version\s+"([^"]+)"\s*$', "cask version")
    checksum = single_match(text, r'^\s*sha256\s+"([^"]+)"\s*$', "cask sha256")
    return version, checksum


def validate(tag: str, xcconfig: Path, cask: Path) -> str:
    if not TAG.fullmatch(tag):
        raise ValueError("release tag must be a stable semantic version such as v1.2.3")
    version = tag[1:]
    if not SEMVER.fullmatch(version):
        raise ValueError(f"invalid semantic version: {version}")

    project_version = configured_version(xcconfig)
    if project_version != version:
        raise ValueError(
            f"tag version {version} does not match MARKETING_VERSION {project_version}"
        )

    cask_version, checksum = cask_metadata(cask)
    if not SEMVER.fullmatch(cask_version):
        raise ValueError(f"cask version is not a stable semantic version: {cask_version}")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("cask sha256 must contain exactly 64 lowercase hexadecimal characters")
    return version


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="release tag, for example v1.2.3")
    parser.add_argument(
        "--xcconfig", type=Path, default=Path("Hyperfocus/AppCore/Release.xcconfig")
    )
    parser.add_argument("--cask", type=Path, default=Path("Casks/hyperfocus.rb"))
    args = parser.parse_args()

    try:
        version = validate(args.tag, args.xcconfig, args.cask)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
