#!/usr/bin/env python3
"""Atomically update the version and checksum in the Hyperfocus cask."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path

SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CHECKSUM = re.compile(r"^[0-9a-f]{64}$")


def update(cask: Path, version: str, checksum: str) -> None:
    if not SEMVER.fullmatch(version):
        raise ValueError("version must be a stable semantic version such as 1.2.3")
    if not CHECKSUM.fullmatch(checksum):
        raise ValueError("checksum must contain exactly 64 lowercase hexadecimal characters")

    original = cask.read_text()
    changed, version_count = re.subn(
        r'(?m)^([ \t]*version[ \t]+)"[^"]+"[ \t]*$', rf'\g<1>"{version}"', original
    )
    changed, checksum_count = re.subn(
        r'(?m)^([ \t]*sha256[ \t]+)"[^"]+"[ \t]*$', rf'\g<1>"{checksum}"', changed
    )
    if version_count != 1 or checksum_count != 1:
        raise ValueError(
            "expected exactly one cask version and sha256 field "
            f"(found version={version_count}, sha256={checksum_count})"
        )

    mode = cask.stat().st_mode
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{cask.name}.", dir=cask.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w") as output:
            output.write(changed)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, cask)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cask", type=Path)
    parser.add_argument("version")
    parser.add_argument("sha256")
    args = parser.parse_args()
    try:
        update(args.cask, args.version, args.sha256)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
