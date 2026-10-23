import gzip
import io
import json
import struct
import tarfile
import unittest
import urllib.error
from unittest.mock import patch

import recover_crate as recovery

SHA = "a" * 40
PREFIX = "irgx-2.6.1/"
MANIFEST = """
[package]
name = "irgx"
version = "2.6.1"
authors = ["Company"]
description = "Useful package"
readme = "README.md"
license-file = "LICENSE"
repository = "https://example.com/repo"
rust-version = "1.85"
links = "native"
keywords = ["regex"]
categories = ["text-processing"]
[features]
default = []
extra = ["dep:renamed", "renamed?/std"]
[dependencies.renamed]
package = "actual"
version = "1.2.3"
features = ["derive", "alloc"]
default-features = false
optional = true
[dev-dependencies]
testing = "3"
[build-dependencies]
builder = { version = ">=1.0, <3" }
[target.'cfg(windows)'.dependencies]
platform = { version = "2.*" }
[badges.maintenance]
status = "actively-developed"
"""


def raw_tar(overrides=None, *, extra=None):
    files = {
        "Cargo.toml": MANIFEST.encode(),
        "README.md": b"# Readme\nUnicode: \xc3\xa9\n",
        "LICENSE": b"license",
        "src/lib.rs": b"pub fn example() {}",
        ".cargo_vcs_info.json": json.dumps(
            {"git": {"sha1": SHA}, "path_in_vcs": "bindings/rust"}
        ).encode(),
    }
    files.update(overrides or {})
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w") as archive:
        for name, content in files.items():
            info = tarfile.TarInfo(PREFIX + name)
            info.size = len(content)
            info.mtime = 0
            archive.addfile(info, io.BytesIO(content))
        if extra is not None:
            archive.addfile(extra, io.BytesIO(b""))
    return stream.getvalue()


def package(**kwargs):
    return gzip.compress(raw_tar(**kwargs), mtime=42)


def prepare(blob=None, **kwargs):
    return recovery.prepare(
        blob or package(),
        name="irgx",
        version="2.6.1",
        vcs_sha=SHA,
        compressor=lambda raw: gzip.compress(raw, compresslevel=9, mtime=0),
        **kwargs,
    )


class RecoveryTests(unittest.TestCase):
    def test_metadata_preserves_all_kinds_renames_features_and_targets(self):
        metadata = prepare().metadata
        deps = {(d["name"], d["kind"], d["target"]): d for d in metadata["deps"]}
        alias = deps[("actual", "normal", None)]
        self.assertEqual(alias["explicit_name_in_toml"], "renamed")
        self.assertEqual(alias["features"], ["derive", "alloc"])
        self.assertTrue(alias["optional"])
        self.assertFalse(alias["default_features"])
        self.assertEqual(alias["version_req"], "^1.2.3")
        self.assertEqual(deps[("testing", "dev", None)]["version_req"], "^3")
        self.assertEqual(deps[("builder", "build", None)]["version_req"], ">=1.0, <3")
        self.assertEqual(deps[("platform", "normal", "cfg(windows)")]["version_req"], "2.*")
        self.assertEqual(metadata["features"]["extra"], ["dep:renamed", "renamed?/std"])
        self.assertEqual(metadata["readme"], "# Readme\nUnicode: é\n")
        self.assertEqual(metadata["readme_file"], "README.md")
        self.assertEqual(metadata["license_file"], "LICENSE")
        self.assertEqual(metadata["rust_version"], "1.85")
        self.assertEqual(metadata["links"], "native")
        self.assertEqual(metadata["badges"], {"maintenance": {"status": "actively-developed"}})
        self.assertIsNone(metadata["homepage"])

    def test_exact_tar_and_every_member_preserved(self):
        result = prepare()
        self.assertNotEqual(result.original, result.compressed)
        self.assertEqual(gzip.decompress(result.original), gzip.decompress(result.compressed))
        report = result.report()
        self.assertEqual(report["member_count"], 5)
        self.assertEqual(report["raw_tar_sha256"], recovery.sha256(raw_tar()))
        self.assertEqual(report["recompressed_sha256"], recovery.sha256(result.compressed))
        self.assertEqual(report["members_sha256"]["LICENSE"], recovery.sha256(b"license"))

    def test_bad_gzip_checksum_truncated_and_concatenated_fail(self):
        original = package()
        corrupt = bytearray(original)
        corrupt[-8] ^= 1
        for blob in (
            b"not gzip",
            original[:-2],
            bytes(corrupt),
            original + original,
            original + b"extra",
        ):
            with self.subTest(blob=blob[:12]), self.assertRaises(recovery.RecoveryError):
                prepare(blob)

    def test_gzip_expansion_is_bounded(self):
        with self.assertRaises(recovery.RecoveryError):
            recovery.gunzip(package(), limit=100)

    def test_non_tar_and_bad_trailer_fail(self):
        for raw in (b"bad tar", bytes(10240), raw_tar()[:-1024] + b"x" * 1024):
            with self.assertRaises(recovery.RecoveryError):
                prepare(gzip.compress(raw))

    def test_path_escape_duplicate_and_symlink_fail(self):
        entries = [
            tarfile.TarInfo("../escape"),
            tarfile.TarInfo(PREFIX + "Cargo.toml"),
            tarfile.TarInfo(PREFIX + "link"),
        ]
        entries[-1].type = tarfile.SYMTYPE
        entries[-1].linkname = "/etc/passwd"
        for entry in entries:
            with self.subTest(path=entry.name), self.assertRaises(recovery.RecoveryError):
                prepare(package(extra=entry))

    def test_identity_and_dirty_guard(self):
        for vcs in (
            {"git": {"sha1": "b" * 40}, "path_in_vcs": "bindings/rust"},
            {"git": {"sha1": SHA, "dirty": True}, "path_in_vcs": "bindings/rust"},
            {"git": {"sha1": SHA}, "path_in_vcs": "another"},
        ):
            with self.assertRaises(recovery.RecoveryError):
                prepare(package(overrides={".cargo_vcs_info.json": json.dumps(vcs).encode()}))
        with self.assertRaises(recovery.RecoveryError):
            prepare(
                package(
                    overrides={
                        "Cargo.toml": MANIFEST.replace(
                            'version = "2.6.1"', 'version = "2.6.2"'
                        ).encode()
                    }
                )
            )

    def test_manifest_and_readme_errors_fail_closed(self):
        for replacement in (
            b"bad {toml",
            MANIFEST.replace('readme = "README.md"', 'readme = "missing"').encode(),
            MANIFEST.replace('version = "1.2.3"', 'path = "../other"').encode(),
        ):
            with self.assertRaises(recovery.RecoveryError):
                prepare(package(overrides={"Cargo.toml": replacement}))

    def test_changed_tar_and_quota_rejected(self):
        with self.assertRaises(recovery.RecoveryError):
            prepare(recompressed=gzip.compress(raw_tar({"LICENSE": b"changed"})))
        with self.assertRaises(recovery.RecoveryError):
            prepare(quota=1)

    def test_upload_framing_is_cargo_protocol(self):
        result = prepare()
        framed = recovery.frame_upload(result.metadata, result.compressed)
        length = struct.unpack_from("<I", framed, 0)[0]
        self.assertEqual(json.loads(framed[4 : 4 + length]), result.metadata)
        crate_len = struct.unpack_from("<I", framed, 4 + length)[0]
        self.assertEqual(crate_len, len(result.compressed))
        self.assertEqual(framed[8 + length :], result.compressed)

    def test_unknown_version_grammar_and_registry_fail_closed(self):
        with self.assertRaises(recovery.RecoveryError):
            recovery.version_req("1 || 2")
        with self.assertRaises(recovery.RecoveryError):
            recovery.dependencies(
                {"dependencies": {"dep": {"version": "1", "registry-index": "https://elsewhere"}}}
            )

    def test_preparation_never_uses_network(self):
        with patch("urllib.request.urlopen", side_effect=AssertionError("network called")):
            prepare()

    def test_upload_revalidates_metadata_before_network(self):
        result = prepare()
        result.metadata["vers"] = "2.6.2"
        with (
            patch("recover_crate.open_upload", side_effect=AssertionError("network called")),
            self.assertRaises(recovery.RecoveryError),
        ):
            recovery.upload_verified(result, "secret")

    def test_bad_token_never_reaches_network(self):
        with (
            patch("recover_crate.open_upload", side_effect=AssertionError("network called")),
            self.assertRaises(recovery.RecoveryError),
        ):
            recovery.upload_verified(prepare(), "secret\nunsafe")

    def test_upload_transmits_validated_bytes_with_auth_without_compressor(self):
        result = prepare()
        answer = io.BytesIO(b'{"warnings":{"other":[]}}')
        with (
            patch("recover_crate.zopfli_compress", side_effect=AssertionError("compressor called")),
            patch("recover_crate.open_upload", return_value=answer) as transport,
        ):
            self.assertEqual(
                recovery.upload_verified(result, "secret"), {"warnings": {"other": []}}
            )
        request = transport.call_args.args[0]
        self.assertEqual(request.full_url, "https://crates.io/api/v1/crates/new")
        self.assertEqual(request.get_method(), "PUT")
        self.assertEqual(request.get_header("Authorization"), "secret")
        self.assertEqual(request.data, recovery.frame_upload(result.metadata, result.compressed))

    def test_http_errors_do_not_echo_server_or_token(self):
        error = urllib.error.HTTPError(
            "https://crates.io", 413, "secret", {}, io.BytesIO(b"secret")
        )
        with (
            patch("recover_crate.open_upload", side_effect=error),
            self.assertRaises(recovery.RecoveryError) as context,
        ):
            recovery.upload_verified(prepare(), "secret")
        self.assertIn("413", str(context.exception))
        self.assertNotIn("secret", str(context.exception))

    def test_redirects_refuse_forwarding_credentials(self):
        with self.assertRaises(recovery.RecoveryError):
            recovery.NoRedirect().redirect_request(
                None, None, 307, "redirect", {}, "https://other.test"
            )


if __name__ == "__main__":
    unittest.main()
