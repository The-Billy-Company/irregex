# Copyright (c) 2026 The Billy Company
# pyright: strict
"""Exercise header semantics and the real Git enumeration and write boundary."""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import pathlib
import subprocess
import tempfile
import unittest

import check


class Notices(unittest.TestCase):
    """Verify comment recognition and source-preserving insertion."""

    def rewrite(self, name: str, original: bytes) -> bytes:
        """Apply the source transformation with a fixed publication year."""
        style = check.source_style(pathlib.Path(name), original)
        self.assertIsNotNone(style)
        if style is None:
            self.fail("expected a supported source type")
        return check.add_notice(pathlib.Path(name), original, style, 2026)

    def test_preserves_original_notice_and_license_bytes(self) -> None:
        """Keep upstream ownership and license text byte for byte."""
        original = (
            b"/* Copyright 2007 Someone Else.\n * SPDX-License-Identifier: MIT\n */\nint x;\n"
        )
        updated = self.rewrite("main.c", original)
        self.assertEqual(updated, b"// Copyright (c) 2026 The Billy Company\n" + original)
        self.assertEqual(self.rewrite("main.c", updated), updated)

    def test_accepts_existing_years_and_spdx_in_initial_comments(self) -> None:
        """Accept existing legal notice forms without duplicate headers."""
        for notice in (
            b"// Copyright 2024-2025 The Billy Company. Apache-2.0.\n",
            b"/* SPDX-FileCopyrightText: 2024 The Billy Company */\n",
            b"/* SPDX-FileCopyrightText: The Billy Company */\n",
            b"// Copyright (C) 2024, 2025-2026 The Billy Company.\n",
            b"// \xc2\xa9 2026 The Billy Company\n",
        ):
            with self.subTest(notice=notice):
                original = notice + b"int x;\n"
                self.assertEqual(self.rewrite("main.c", original), original)

    def test_prose_about_copyright_is_not_an_ownership_record(self) -> None:
        """Reject prose mentioning copyright as an ownership claim."""
        original = b"// copyright rules The Billy Company\nconst x = 1;\n"
        self.assertNotEqual(self.rewrite("main.ts", original), original)
        self.assertFalse(check.COPYRIGHT.search(b"SPDX-FileCopyrightText rules The Billy Company"))

    def test_code_string_and_later_comments_are_not_notices(self) -> None:
        """Reject code literals and comments outside the initial header."""
        for original in (
            b'const message = "Copyright 2026 The Billy Company";\n',
            b"int x;\n// Copyright 2026 The Billy Company\n",
            b'"Copyright 2026 The Billy Company"\nx = 1\n',
        ):
            name = "test.py" if original.startswith(b'"') else "test.ts"
            with self.subTest(original=original):
                self.assertNotEqual(self.rewrite(name, original), original)

    def test_preserves_shebang_encoding_bom_crlf_and_legacy_bytes(self) -> None:
        """Preserve executable Python syntax across supported byte encodings."""
        for bom, encoding, character in (
            (check.BOM, b"utf-8", b"\xc3\xa9"),
            (b"", b"latin-1", b"\xe9"),
        ):
            prefix = bom + b"#!/usr/bin/python3\r\n# coding: " + encoding + b"\r\n"
            body = b"print('" + character + b"')\r\n"
            original = prefix + body
            expected = prefix + b"# Copyright (c) 2026 The Billy Company\r\n" + body
            with self.subTest(encoding=encoding):
                self.assertEqual(self.rewrite("run.py", original), expected)
                self.assertEqual(self.rewrite("run.py", expected), expected)
                _ = compile(original, "run.py", "exec")
                _ = compile(expected, "run.py", "exec")

    def test_swift_tools_version_remains_first(self) -> None:
        """Keep Swift package version metadata at its required position."""
        prefix = b"// swift-tools-version: 6.0\n"
        original = prefix + b"import PackageDescription\n"
        updated = self.rewrite("Package.swift", original)
        self.assertTrue(updated.startswith(prefix + b"// Copyright"))
        self.assertEqual(self.rewrite("Package.swift", updated), updated)

    def test_go_constraints_keep_blank_separation(self) -> None:
        """Keep Go build constraints and package comments separated."""
        original = b"//go:build linux\n// +build linux\n\npackage main\n"
        updated = self.rewrite("main.go", original)
        self.assertTrue(updated.startswith(b"//go:build linux\n// +build linux\n\n// Copyright"))
        self.assertIn(b"The Billy Company\n\npackage main\n", updated)
        self.assertEqual(self.rewrite("main.go", updated), updated)

    def test_comments_fit_languages_and_empty_files(self) -> None:
        """Render valid language comments even for an empty source."""
        for name, notice in (
            ("main.css", b"/* Copyright (c) 2026 The Billy Company */\n"),
            ("main.html", b"<!-- Copyright (c) 2026 The Billy Company -->\n"),
            ("main.vim", b'" Copyright (c) 2026 The Billy Company\n'),
            ("main.scm", b"; Copyright (c) 2026 The Billy Company\n"),
            ("main.lean", b"-- Copyright (c) 2026 The Billy Company\n"),
        ):
            with self.subTest(name=name):
                self.assertEqual(self.rewrite(name, b""), notice)

    def test_extensionless_scripts_and_final_shebang_without_newline(self) -> None:
        """Recognize executable script dialects and incomplete final lines."""
        original = b"#!/usr/bin/env node"
        self.assertEqual(
            self.rewrite("run", original),
            original + b"\n// Copyright (c) 2026 The Billy Company\n",
        )
        swift = b'#!/usr/bin/env swift\nprint("hello")\n'
        self.assertEqual(
            self.rewrite("run", swift),
            b'#!/usr/bin/env swift\n// Copyright (c) 2026 The Billy Company\nprint("hello")\n',
        )
        self.assertIsNone(check.source_style(pathlib.Path("LICENSE"), b"terms"))
        self.assertIsNone(check.source_style(pathlib.Path("package.json"), b"{}"))

    def test_php_opening_and_html_doctype_keep_their_position(self) -> None:
        """Retain required PHP, HTML and CSS opening declarations."""
        for name, original, prefix in (
            ("main.css", b'@charset "UTF-8";\np {color:red}\n', b'@charset "UTF-8";\n/* Copyright'),
            ("main.php", b"<?php echo 42;\n", b"<?php\n// Copyright"),
            ("main.html", b"<!DOCTYPE html>\n<html></html>\n", b"<!DOCTYPE html>\n<!-- Copyright"),
        ):
            with self.subTest(name=name):
                updated = self.rewrite(name, original)
                self.assertTrue(updated.startswith(prefix))
                self.assertEqual(self.rewrite(name, updated), updated)


class Repository(unittest.TestCase):
    """Exercise Git enumeration, ownership policy and writes in scratch repositories."""

    def setUp(self) -> None:
        """Create an isolated Git repository for each filesystem test."""
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        self.git("init", "-q")

    def git(self, *arguments: str) -> None:
        """Run a trusted test Git command in the scratch repository."""
        _ = subprocess.run(  # noqa: S603 -- tests supply fixed Git arguments without a shell
            [check.git_executable(), "-C", str(self.root), *arguments],
            check=True,
            capture_output=True,
            timeout=30,
        )

    def write(self, name: str, content: bytes) -> pathlib.Path:
        """Create a source fixture and return its location."""
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        _ = path.write_bytes(content)
        return path

    def config(self, entries: list[dict[str, str]]) -> None:
        """Write a repository ownership policy for the current test."""
        _ = self.write(".copyright.json", json.dumps({"exclude": entries}).encode())

    def run_check(self, fix: bool = False) -> tuple[int, int]:
        """Run the real repository gate without printing expected diagnostics."""
        with contextlib.redirect_stdout(io.StringIO()):
            return check.check(self.root, fix, 2026)

    def test_git_covers_tracked_and_new_sources_and_ignores_dependencies(self) -> None:
        """Cover new source files while respecting Git ownership boundaries."""
        tracked = self.write("tracked.py", b"x = 1\n")
        self.git("add", "tracked.py")
        new = self.write("new source.rs", b"fn main() {}\n")
        _ = self.write(".gitignore", b"dependency/\n")
        dependency = self.write("dependency/main.py", b"unowned\n")
        _ = self.write("deleted.py", b"x = 1\n")
        self.git("add", "deleted.py")
        (self.root / "deleted.py").unlink()
        original = tracked.read_bytes()
        self.assertEqual(self.run_check(), (2, 2))
        self.assertEqual(tracked.read_bytes(), original)
        self.assertEqual(self.run_check(True), (2, 2))
        self.assertEqual(self.run_check(), (2, 0))
        self.assertIn(b"Copyright", new.read_bytes())
        self.assertEqual(dependency.read_bytes(), b"unowned\n")

    def test_exclusion_glob_and_locked_upstream_are_preserved(self) -> None:
        """Require review when a hash-locked upstream exemption changes."""
        original = b"/* Copyright 1998 Upstream */\nint x;\n"
        upstream = self.write("upstream/main.c", original)
        self.config(
            [
                {"path": "upstream/**", "reason": "third-party source"},
                {
                    "path": "upstream/main.c",
                    "reason": "unmodified upstream",
                    "sha256": hashlib.sha256(original).hexdigest(),
                },
            ]
        )
        self.assertEqual(self.run_check(True), (0, 0))
        self.assertEqual(upstream.read_bytes(), original)
        _ = upstream.write_bytes(original + b"int y;\n")
        with self.assertRaisesRegex(ValueError, "excluded upstream source changed"):
            _ = self.run_check(True)
        self.assertNotIn(b"Billy", upstream.read_bytes())

    def test_symlink_target_is_never_modified(self) -> None:
        """Keep all writes inside the repository's regular source files."""
        with tempfile.TemporaryDirectory() as outside:
            target = pathlib.Path(outside) / "outside.py"
            _ = target.write_bytes(b"outside = True\n")
            (self.root / "linked.py").symlink_to(target)
            self.assertEqual(self.run_check(True), (0, 0))
            self.assertEqual(target.read_bytes(), b"outside = True\n")
            self.config(
                [
                    {
                        "path": "linked.py",
                        "reason": "upstream",
                        "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                    }
                ]
            )
            with self.assertRaisesRegex(ValueError, "became a symlink"):
                _ = self.run_check(True)

    def test_invalid_config_fails_before_mutation(self) -> None:
        """Reject ambiguous ownership policies before changing any source."""
        source = self.write("main.py", b"x = 1\n")
        for config in (
            b'{"exclude": [], "typo": true}',
            b'{"exclude": [], "exclude": []}',
            b'{"exclude": [{"path": "../outside", "reason": "no"}]}',
            b'{"exclude": [{"path": "vendor/**", "reason": "no", "sha256": "abc"}]}',
            b'{"exclude": [{"path": "vendor/**", "reason": "no", "sha256": "' + b"0" * 64 + b'"}]}',
        ):
            with self.subTest(config=config):
                _ = self.write(".copyright.json", config)
                with self.assertRaises(ValueError):
                    _ = self.run_check(True)
                self.assertEqual(source.read_bytes(), b"x = 1\n")

    def test_unknown_shebang_refuses_all_writes(self) -> None:
        """Require explicit syntax support before modifying an unknown script dialect."""
        source = self.write("first.py", b"x = 1\n")
        unknown = self.write("run", b"#!/usr/bin/env mystery\nsource syntax\n")
        with self.assertRaisesRegex(ValueError, "unsupported shebang interpreter"):
            _ = self.run_check(True)
        self.assertEqual(source.read_bytes(), b"x = 1\n")
        self.assertEqual(unknown.read_bytes(), b"#!/usr/bin/env mystery\nsource syntax\n")

    def test_changed_file_is_not_overwritten(self) -> None:
        """Refuse to overwrite a file edited after inspection."""
        source = self.write("main.py", b"changed\n")
        with self.assertRaisesRegex(ValueError, "file changed"):
            check.write_unchanged(source, b"original\n", b"replacement\n")
        self.assertEqual(source.read_bytes(), b"changed\n")


if __name__ == "__main__":
    _ = unittest.main()
