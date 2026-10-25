#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


metadata = load("release_metadata", ROOT / "scripts/release_metadata.py")
updater = load("update_cask", ROOT / "scripts/update_cask.py")


class ReleaseMetadataTests(unittest.TestCase):
    def fixture(self, version: str = "1.2.3") -> tuple[Path, Path, tempfile.TemporaryDirectory]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        xcconfig = root / "Release.xcconfig"
        cask = root / "hyperfocus.rb"
        xcconfig.write_text(f"MACOSX_DEPLOYMENT_TARGET = 12.3\nMARKETING_VERSION = {version}\n")
        cask.write_text(
            f'cask "hyperfocus" do\n  version "{version}"\n'
            f'  sha256 "{"a" * 64}"\nend\n'
        )
        return xcconfig, cask, temporary

    def test_accepts_matching_stable_release(self) -> None:
        xcconfig, cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        self.assertEqual(metadata.validate("v1.2.3", xcconfig, cask), "1.2.3")

    def test_rejects_unstable_or_noncanonical_tags(self) -> None:
        xcconfig, cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        for tag in ("1.2.3", "v1.2", "v01.2.3", "v1.2.3-beta.1"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "stable semantic"):
                metadata.validate(tag, xcconfig, cask)

    def test_rejects_project_version_mismatch(self) -> None:
        xcconfig, cask, temporary = self.fixture("1.2.4")
        self.addCleanup(temporary.cleanup)
        with self.assertRaisesRegex(ValueError, "MARKETING_VERSION"):
            metadata.validate("v1.2.3", xcconfig, cask)

    def test_allows_previous_valid_cask_version(self) -> None:
        xcconfig, cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        cask.write_text('version "1.2.2"\nsha256 "' + "a" * 64 + '"\n')
        self.assertEqual(metadata.validate("v1.2.3", xcconfig, cask), "1.2.3")

    def test_rejects_duplicate_fields_and_invalid_checksum(self) -> None:
        xcconfig, cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        cask.write_text('version "1.2.3"\nversion "1.2.3"\nsha256 "nope"\n')
        with self.assertRaisesRegex(ValueError, "exactly one cask version"):
            metadata.validate("v1.2.3", xcconfig, cask)


class CaskUpdaterTests(unittest.TestCase):
    def fixture(self, text: str | None = None) -> tuple[Path, tempfile.TemporaryDirectory]:
        temporary = tempfile.TemporaryDirectory()
        cask = Path(temporary.name) / "hyperfocus.rb"
        cask.write_text(
            text
            or 'cask "hyperfocus" do\n  version "1.0.0"\n  sha256 "'
            + "a" * 64
            + '"\nend\n'
        )
        return cask, temporary

    def test_updates_only_release_fields(self) -> None:
        cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        updater.update(cask, "2.3.4", "b" * 64)
        self.assertEqual(
            cask.read_text(),
            'cask "hyperfocus" do\n  version "2.3.4"\n  sha256 "'
            + "b" * 64
            + '"\nend\n',
        )

    def test_rejects_bad_inputs_without_writing(self) -> None:
        cask, temporary = self.fixture()
        self.addCleanup(temporary.cleanup)
        original = cask.read_bytes()
        for version, checksum in (("v2.0.0", "b" * 64), ("2.0.0", "BAD")):
            with self.subTest(version=version), self.assertRaises(ValueError):
                updater.update(cask, version, checksum)
            self.assertEqual(cask.read_bytes(), original)

    def test_rejects_unexpected_shape_without_partial_write(self) -> None:
        for text in (
            'cask "hyperfocus" do\n  version "1.0.0"\nend\n',
            'version "1.0.0"\nversion "1.0.1"\nsha256 "' + "a" * 64 + '"\n',
        ):
            cask, temporary = self.fixture(text)
            self.addCleanup(temporary.cleanup)
            original = cask.read_bytes()
            with self.assertRaisesRegex(ValueError, "exactly one"):
                updater.update(cask, "2.0.0", "b" * 64)
            self.assertEqual(cask.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
