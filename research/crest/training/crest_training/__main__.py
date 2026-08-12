"""Create non-promotable CREST training and held-out validation evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .package import (
    DataPackage,
    InputSafetyError,
    SchemaError,
    TrainingError,
    sha256_bytes,
)
from .proposal import build_proposal, build_validation_report, canonical_json_bytes

DEFAULT_SETTINGS = Path(__file__).resolve().parent.parent / "validation-settings.json"


def _read_json(path: str | Path, label: str) -> tuple[dict[str, object], str]:
    source = Path(path)
    if source.is_dir() or not source.is_file() or source.is_symlink():
        raise InputSafetyError(f"{label} must be an explicit regular JSON file")
    raw = source.read_bytes()
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SchemaError(f"invalid {label} JSON: {error}") from error
    if not isinstance(value, dict):
        raise SchemaError(f"{label} must contain a JSON object")
    return value, sha256_bytes(raw)


def _write_json(
    path: str | Path, artifact: dict[str, object], package_source: str | Path
) -> None:
    destination = Path(path)
    if not destination.parent.is_dir() or destination.is_symlink():
        raise InputSafetyError(
            "output parent must exist and output must not be a symlink"
        )
    package = Path(package_source)
    resolved = destination.resolve()
    if package.is_dir():
        try:
            resolved.relative_to(package.resolve())
        except ValueError:
            pass
        else:
            raise InputSafetyError(
                "refusing to write generated output into the data package"
            )
    elif package.is_file() and resolved == package.resolve():
        raise InputSafetyError("refusing to overwrite the data package")
    destination.write_bytes(canonical_json_bytes(artifact))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    propose = commands.add_parser(
        "propose", help="rank research candidates from training only"
    )
    propose.add_argument("--package", required=True)
    propose.add_argument("--k", required=True, type=int)
    propose.add_argument("--output", required=True)
    validate = commands.add_parser(
        "validate", help="score frozen prefixes on held-out validation"
    )
    validate.add_argument("--package", required=True)
    validate.add_argument("--proposal", required=True)
    validate.add_argument("--settings", default=str(DEFAULT_SETTINGS))
    validate.add_argument("--output", required=True)
    inspect = commands.add_parser(
        "fingerprint", help="print the immutable dataset fingerprint"
    )
    inspect.add_argument("--package", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        package = DataPackage(args.package)
        if args.command == "propose":
            artifact = build_proposal(package, args.k)
            _write_json(args.output, artifact, args.package)
        elif args.command == "validate":
            proposal, _ = _read_json(args.proposal, "proposal")
            settings, _ = _read_json(args.settings, "settings")
            artifact = build_validation_report(package, proposal, settings)
            _write_json(args.output, artifact, args.package)
        else:
            from .predicates import load_manifest

            manifest = load_manifest(package)
            sys.stdout.write(f"{manifest.dataset_fingerprint}\n")
        return 0
    except TrainingError as error:
        print(f"ERROR[{error.category}]: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
