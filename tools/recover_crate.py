#!/usr/bin/env python3
"""Preserve a verified Cargo tar stream while changing only its gzip encoding.

Cargo 1.99 schema authority (5f94df4789f005f9a352888e8355ffc645b7ed0e):
  src/ops/registry/cargo_publish.rs: prepare_transmit
  crates/crates-io/lib.rs: NewCrate, NewCrateDependency, Registry::publish
Protocol: https://doc.rust-lang.org/cargo/reference/registry-web-api.html#publish

The CLI only prepares artifacts. Network publication requires an explicit call
to upload_verified(); it never reads a credential from disk or the environment.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import struct
import tarfile
import tomllib
import urllib.error
import urllib.request
import zlib
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

CRATE_QUOTA = 10_485_760
TAR_QUOTA = 128 << 20
JSON_QUOTA = 1 << 20
CARGO_COMMIT = "5f94df4789f005f9a352888e8355ffc645b7ed0e"
CRATES_INDEX = "https://github.com/rust-lang/crates.io-index"


class RecoveryError(ValueError):
    """An input or recovery invariant failed; nothing should be published."""


def sha256(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def gunzip(blob: bytes, *, limit: int = TAR_QUOTA) -> bytes:
    """Decode one complete gzip member, bounded before a tar parser sees it."""
    try:
        decoder = zlib.decompressobj(31)
        raw = decoder.decompress(blob, limit + 1)
        if len(raw) > limit or decoder.unconsumed_tail:
            raise RecoveryError("uncompressed tar exceeds its preparation limit")
        if not decoder.eof or decoder.unused_data:
            raise RecoveryError("gzip is truncated or has trailing/concatenated data")
        return raw
    except zlib.error as exc:
        raise RecoveryError("invalid gzip encoding or checksum") from exc


def safe_path(name: str) -> str:
    """Cargo uses relative POSIX archive paths, never links or traversal."""
    try:
        name.encode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise RecoveryError("tar path is not UTF-8") from exc
    path = PurePosixPath(name)
    if (
        not name
        or name.startswith("/")
        or "\\" in name
        or ":" in name
        or any(part in ("", ".", "..") for part in name.split("/"))
    ):
        raise RecoveryError("unsafe or ambiguous tar path")
    return path.as_posix()


def members_from_tar(raw: bytes, prefix: str) -> dict[str, bytes]:
    if len(raw) % 512 or not raw:
        raise RecoveryError("tar length is not a complete block stream")
    members: dict[str, bytes] = {}
    seen: set[str] = set()
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            for entry in archive:
                name = safe_path(entry.name)
                if name in seen:
                    raise RecoveryError("duplicate tar member")
                seen.add(name)
                if len(seen) > 10_000:
                    raise RecoveryError("too many tar members")
                if not name.startswith(prefix + "/"):
                    raise RecoveryError("tar member is outside the expected package")
                relative = name[len(prefix) + 1 :]
                if entry.isdir():
                    continue
                if not entry.isfile():
                    raise RecoveryError("tar links and special members are not permitted")
                stream = archive.extractfile(entry)
                if stream is None:
                    raise RecoveryError("tar file has no readable content")
                content = stream.read(TAR_QUOTA + 1)
                if len(content) != entry.size or len(content) > TAR_QUOTA:
                    raise RecoveryError("invalid tar file size")
                members[relative] = content
            tail = raw[archive.offset :]
            if len(tail) < 1024 or any(tail):
                raise RecoveryError("tar lacks its zero trailer or has trailing payload")
    except (tarfile.TarError, OSError, EOFError) as exc:
        raise RecoveryError("invalid tar stream") from exc
    return members


def string(value: object, context: str) -> str:
    if not isinstance(value, str):
        raise RecoveryError(f"{context} must be a string")
    return value


def string_list(value: object, context: str) -> list[str]:
    if not isinstance(value, list) or any(not isinstance(v, str) for v in value):
        raise RecoveryError(f"{context} must be a string list")
    return list(value)


def boolean(value: object, context: str) -> bool:
    if not isinstance(value, bool):
        raise RecoveryError(f"{context} must be a boolean")
    return value


def version_req(text: str) -> str:
    """Cargo/semver display for a conservative, explicit requirement subset.

    Covers this release's `1`/`3` and ordinary numeric comparators, conjunctions,
    prereleases and wildcards. Unsupported grammar fails closed, never gets
    silently changed. Build metadata is deliberately rejected.
    """
    comparator = re.compile(
        r"(>=|<=|>|<|=|\^|~)?\s*"
        r"([0-9]+|[xX*])(?:\.([0-9]+|[xX*]))?(?:\.([0-9]+|[xX*]))?"
        r"(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    )
    result = []
    for part in text.split(","):
        match = comparator.fullmatch(part.strip())
        if not match:
            raise RecoveryError("unsupported dependency version requirement")
        op, major, minor, patch, prerelease = match.groups()
        pieces = [v for v in (major, minor, patch) if v is not None]
        wildcard = any(v in ("x", "X", "*") for v in pieces)
        if any(len(v) > 1 and v.startswith("0") for v in pieces if v.isdigit()):
            raise RecoveryError("dependency version has leading zeros")
        if wildcard:
            first = next(i for i, v in enumerate(pieces) if v in ("x", "X", "*"))
            if op or prerelease or any(v not in ("x", "X", "*") for v in pieces[first:]):
                raise RecoveryError("unsupported wildcard requirement")
            body = ".".join(pieces[:first] + ["*"])
        else:
            if prerelease and patch is None:
                raise RecoveryError("prerelease requires a complete version")
            body = (op or "^") + ".".join(pieces) + (prerelease or "")
        result.append(body)
    return ", ".join(result)


def dependencies(manifest: dict) -> list[dict]:
    rows: list[dict] = []
    sections = (
        ("dependencies", "normal"),
        ("dev-dependencies", "dev"),
        ("build-dependencies", "build"),
    )

    def collect(table: dict, target: str | None) -> None:
        for section, kind in sections:
            declared = table.get(section, {})
            if not isinstance(declared, dict):
                raise RecoveryError("dependency section must be a table")
            for alias, spec in sorted(declared.items()):
                if isinstance(spec, str):
                    spec = {"version": spec}
                if not isinstance(spec, dict):
                    raise RecoveryError("dependency must have a version declaration")
                allowed = {
                    "version",
                    "package",
                    "features",
                    "optional",
                    "default-features",
                    "registry-index",
                }
                if spec.keys() - allowed:
                    raise RecoveryError("unsupported or unnormalized dependency fields")
                if spec.get("registry-index", CRATES_INDEX) != CRATES_INDEX:
                    raise RecoveryError("crates.io publication cannot use another registry")
                actual = string(spec.get("package", alias), "dependency package")
                row = {
                    "optional": boolean(spec.get("optional", False), "dependency optional"),
                    "default_features": boolean(
                        spec.get("default-features", True), "default-features"
                    ),
                    "name": actual,
                    "features": string_list(spec.get("features", []), "dependency features"),
                    "version_req": version_req(string(spec.get("version"), "dependency version")),
                    "target": target,
                    "kind": kind,
                }
                if alias != actual:
                    row["explicit_name_in_toml"] = alias
                rows.append(row)

    collect(manifest, None)
    targets = manifest.get("target", {})
    if not isinstance(targets, dict):
        raise RecoveryError("target dependencies must be a table")
    for target, table in sorted(targets.items()):
        if not isinstance(table, dict):
            raise RecoveryError("target dependency entry must be a table")
        collect(table, string(target, "dependency target"))
    return rows


def metadata_from_members(
    members: dict[str, bytes], *, name: str, version: str, vcs_sha: str, path_in_vcs: str
) -> dict:
    try:
        manifest = tomllib.loads(members["Cargo.toml"].decode("utf-8"))
        vcs = json.loads(members[".cargo_vcs_info.json"].decode("utf-8"))
    except (KeyError, UnicodeError, ValueError) as exc:
        raise RecoveryError("missing or invalid Cargo manifest/VCS metadata") from exc
    pkg = manifest.get("package")
    if not isinstance(pkg, dict) or pkg.get("name") != name or pkg.get("version") != version:
        raise RecoveryError("package name/version differs from expected tagged release")
    if (
        not re.fullmatch(r"[0-9a-f]{40}", vcs_sha)
        or not isinstance(vcs, dict)
        or not isinstance(vcs.get("git"), dict)
        or vcs["git"].get("sha1") != vcs_sha
        or vcs["git"].get("dirty", False) is not False
        or vcs.get("path_in_vcs") != path_in_vcs
    ):
        raise RecoveryError("package VCS identity does not match the clean tagged source")
    if "workspace" in manifest:
        raise RecoveryError("expected Cargo's normalized publish manifest")
    readme_file = pkg.get("readme")
    if readme_file is not None:
        readme_file = safe_path(string(readme_file, "readme"))
        try:
            readme = members[readme_file].decode("utf-8")
        except (KeyError, UnicodeError) as exc:
            raise RecoveryError("declared README missing or invalid UTF-8") from exc
    else:
        readme = None
    features = manifest.get("features", {})
    if not isinstance(features, dict):
        raise RecoveryError("features must be a table")
    out = {
        "name": name,
        "vers": version,
        "deps": dependencies(manifest),
        "features": {k: string_list(v, "feature values") for k, v in sorted(features.items())},
        "authors": string_list(pkg.get("authors", []), "authors"),
        "readme": readme,
        "readme_file": readme_file,
        "keywords": string_list(pkg.get("keywords", []), "keywords"),
        "categories": string_list(pkg.get("categories", []), "categories"),
    }
    for wire, toml in (
        ("description", "description"),
        ("documentation", "documentation"),
        ("homepage", "homepage"),
        ("license", "license"),
        ("license_file", "license-file"),
        ("repository", "repository"),
        ("links", "links"),
        ("rust_version", "rust-version"),
    ):
        value = pkg.get(toml)
        out[wire] = None if value is None else string(value, toml)
    if out["license_file"] is not None and safe_path(out["license_file"]) not in members:
        raise RecoveryError("declared license file is absent")
    badges = manifest.get("badges", {})
    if not isinstance(badges, dict) or any(
        not isinstance(v, dict) or any(not isinstance(s, str) for s in v.values())
        for v in badges.values()
    ):
        raise RecoveryError("badges must be nested string tables")
    out["badges"] = badges
    return out


def frame_upload(metadata: dict, crate: bytes) -> bytes:
    """Cargo's documented u32le JSON length + JSON + u32le crate length + crate."""
    encoded = json.dumps(metadata, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > JSON_QUOTA or len(crate) > 0xFFFFFFFF:
        raise RecoveryError("upload framing limits exceeded")
    return struct.pack("<I", len(encoded)) + encoded + struct.pack("<I", len(crate)) + crate


@dataclass(frozen=True)
class Prepared:
    metadata: dict
    original: bytes
    compressed: bytes
    raw_tar: bytes
    members: dict[str, bytes]
    vcs_sha: str

    def report(self) -> dict:
        return {
            "schema": 1,
            "name": self.metadata["name"],
            "version": self.metadata["vers"],
            "vcs_sha": self.vcs_sha,
            "cargo_schema_commit": CARGO_COMMIT,
            "original_bytes": len(self.original),
            "recompressed_bytes": len(self.compressed),
            "raw_tar_bytes": len(self.raw_tar),
            "member_count": len(self.members),
            "original_sha256": sha256(self.original),
            "recompressed_sha256": sha256(self.compressed),
            "raw_tar_sha256": sha256(self.raw_tar),
            "members_sha256": {k: sha256(v) for k, v in sorted(self.members.items())},
            "upload_body_sha256": sha256(frame_upload(self.metadata, self.compressed)),
        }


def zopfli_compress(raw: bytes) -> bytes:
    try:
        from importlib.metadata import version

        import zopfli.gzip
    except ImportError as exc:
        raise RecoveryError("preparation requires pinned zopfli==0.4.3") from exc
    if version("zopfli") != "0.4.3":
        raise RecoveryError("preparation requires pinned zopfli==0.4.3")
    return zopfli.gzip.compress(raw, numiterations=15)


def prepare(
    original: bytes,
    *,
    name: str,
    version: str,
    vcs_sha: str,
    path_in_vcs: str = "bindings/rust",
    quota: int = CRATE_QUOTA,
    recompressed: bytes | None = None,
    compressor: Callable[[bytes], bytes] = zopfli_compress,
) -> Prepared:
    raw = gunzip(original)
    members = members_from_tar(raw, f"{name}-{version}")
    metadata = metadata_from_members(
        members, name=name, version=version, vcs_sha=vcs_sha, path_in_vcs=path_in_vcs
    )
    packed = recompressed if recompressed is not None else compressor(raw)
    if gunzip(packed) != raw:
        raise RecoveryError("recompression changed the verified tar bytes")
    if len(packed) > quota:
        raise RecoveryError(f"recompressed crate exceeds the {quota}-byte registry quota")
    frame_upload(metadata, packed)
    return Prepared(metadata, original, packed, raw, members, vcs_sha)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never forward an upload credential or body to a redirect destination."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RecoveryError("registry redirected upload; inspect registry state before retry")


def open_upload(request: urllib.request.Request, timeout: float):
    return urllib.request.build_opener(NoRedirect()).open(request, timeout=timeout)


def upload_verified(prepared: Prepared, token: str, *, timeout: float = 120) -> dict:
    """Explicit publication boundary. Caller must separately authorize calling it.

    Uses the current release.yml crates-io environment's auth action token. The
    function never prints headers, tokens or request representations and does
    not automatically retry an ambiguous publication result.
    """
    if not token or "\n" in token or "\r" in token:
        raise RecoveryError("missing or invalid upload credential")
    # Revalidate public bytes immediately before the only network operation.
    checked = prepare(
        prepared.original,
        name=prepared.metadata["name"],
        version=prepared.metadata["vers"],
        vcs_sha=prepared.vcs_sha,
        recompressed=prepared.compressed,
    )
    if checked.metadata != prepared.metadata:
        raise RecoveryError("prepared upload metadata changed after validation")
    body = frame_upload(checked.metadata, checked.compressed)
    request = urllib.request.Request(
        "https://crates.io/api/v1/crates/new",
        data=body,
        method="PUT",
        headers={
            "Authorization": token,
            "Content-Type": "application/octet-stream",
            "Accept": "application/json",
            "User-Agent": "irregex-crate-recovery/1 (The-Billy-Company/irregex)",
        },
    )
    try:
        with open_upload(request, timeout) as response:
            answer = response.read(JSON_QUOTA + 1)
    except urllib.error.HTTPError as exc:
        # Never reflect server text that could echo request credentials.
        raise RecoveryError(
            f"registry rejected upload with HTTP {exc.code}; inspect registry state before retry"
        ) from None
    except (urllib.error.URLError, TimeoutError):
        raise RecoveryError(
            "upload result is uncertain; inspect registry state before retry"
        ) from None
    if len(answer) > JSON_QUOTA:
        raise RecoveryError("oversized registry response; inspect registry state")
    try:
        result = json.loads(answer)
    except ValueError:
        raise RecoveryError("invalid registry response; inspect registry state") from None
    if not isinstance(result, dict) or result.get("errors"):
        raise RecoveryError("registry reported upload errors; inspect registry state")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("crate", type=Path)
    parser.add_argument("--name", default="irgx")
    parser.add_argument("--version", required=True)
    parser.add_argument("--vcs-sha", required=True)
    parser.add_argument(
        "--recompressed",
        type=Path,
        help="validate an existing recompression instead of recompressing",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()
    prepared = prepare(
        args.crate.read_bytes(),
        name=args.name,
        version=args.version,
        vcs_sha=args.vcs_sha,
        recompressed=args.recompressed.read_bytes() if args.recompressed else None,
    )
    args.out_dir.mkdir(parents=True, exist_ok=False)
    (args.out_dir / f"{args.name}-{args.version}.crate").write_bytes(prepared.compressed)
    (args.out_dir / "metadata.json").write_text(json.dumps(prepared.metadata, indent=2) + "\n")
    (args.out_dir / "report.json").write_text(json.dumps(prepared.report(), indent=2) + "\n")
    (args.out_dir / "upload-body.bin").write_bytes(
        frame_upload(prepared.metadata, prepared.compressed)
    )
    print(json.dumps(prepared.report(), sort_keys=True))


if __name__ == "__main__":
    main()
