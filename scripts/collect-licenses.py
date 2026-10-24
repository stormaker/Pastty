#!/usr/bin/env python3
"""Collect cached Cargo dependency notices without fetching or executing code."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def cargo_metadata(cargo, manifest, target):
    result = subprocess.run(
        [cargo, "metadata", "--locked", "--offline", "--format-version", "1",
         "--filter-platform", target, "--manifest-path", str(manifest)],
        check=False, capture_output=True, text=True,
    )
    if result.returncode:
        raise RuntimeError(
            "Cargo metadata failed. Build/fetch the locked target dependencies "
            "first; license collection never downloads packages."
        )
    return json.loads(result.stdout)


def selected_packages(metadata):
    """Include normal/build transitive dependencies, excluding dev-only edges."""
    resolve = metadata.get("resolve") or {}
    root_id = resolve.get("root")
    if not root_id:
        raise RuntimeError("Expected one application package, not a virtual workspace.")
    nodes = {node["id"]: node for node in resolve["nodes"]}
    packages = {package["id"]: package for package in metadata["packages"]}
    seen, pending = set(), [root_id]
    while pending:
        package_id = pending.pop()
        if package_id in seen:
            continue
        seen.add(package_id)
        for dependency in nodes[package_id]["deps"]:
            kinds = dependency.get("dep_kinds", [])
            if any(kind.get("kind") != "dev" for kind in kinds):
                pending.append(dependency["pkg"])
    return sorted(
        (packages[package_id] for package_id in seen if package_id != root_id),
        key=lambda package: (package["name"], package["version"]),
    )


def notice_documents(package):
    root = Path(package["manifest_path"]).resolve().parent
    candidates = set()
    prefixes = ("LICENSE", "LICENCE", "COPYING", "UNLICENSE", "NOTICE")
    for directory in [root, root / "licenses", root / "LICENSES"]:
        if directory.is_dir():
            candidates.update(
                path for path in directory.iterdir()
                if path.is_file() and path.name.upper().startswith(prefixes)
            )
    if package.get("license_file"):
        candidates.add(root / package["license_file"])
    documents, errors = [], []
    for path in sorted(candidates):
        resolved = path.resolve()
        if not resolved.is_relative_to(root):
            errors.append("declared notice is outside the package directory")
            continue
        label = str(resolved.relative_to(root))
        try:
            if not resolved.is_file() or resolved.stat().st_size > 1024 * 1024:
                raise ValueError("missing or oversized notice")
            text = resolved.read_text(encoding="utf-8")
            if not text.strip():
                raise ValueError("empty notice")
            documents.append((label, text))
        except (OSError, UnicodeError, ValueError):
            errors.append(f"cannot read notice {label}")
    if not documents:
        errors.append("no license text found in the cached package")
    if not package.get("license") and not package.get("license_file"):
        errors.append("no Cargo license declaration")

    # The Rust wrapper's MIT license is separate from the bundled SQLite C code.
    if package["name"] == "libsqlite3-sys":
        try:
            with (root / "sqlite3/sqlite3.c").open(encoding="utf-8") as source:
                header = source.read(65536)
            notice = next(
                match.group(0) for match in re.finditer(r"/\*.*?\*/", header, re.S)
                if "The author disclaims copyright" in match.group(0)
            )
            documents.append(("bundled SQLite public-domain notice (sqlite3.c)", notice))
        except (OSError, UnicodeError, StopIteration):
            errors.append("bundled SQLite copyright disclaimer not found")
    return documents, errors


def render(packages, target):
    summaries, texts, unresolved = [], {}, []
    for package in packages:
        name = f'{package["name"]} {package["version"]}'
        documents, errors = notice_documents(package)
        summaries.extend([name, f'Cargo license declaration: {package.get("license") or "UNKNOWN"}'])
        for label, text in documents:
            digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
            texts.setdefault(digest, {"text": text, "users": []})["users"].append(f"{name}: {label}")
            summaries.append(f"  {label} -> SHA-256 {digest}")
        for error in errors:
            unresolved.append(f"{name}: {error}")
            summaries.append(f"  UNKNOWN: {error}")
        summaries.append("")

    lines = [
        "Pastty dependency licenses and attribution",
        f"Cargo target: {target}",
        "Scope: locked target dependency graph, normal and build dependencies; dev-only dependencies excluded.",
        "Build/procedural-macro notices are included as a conservative superset of linked code.",
        "Original license documents are grouped by exact text hash; each package attribution is retained.",
        "Bundled SQLite carries its own public-domain copyright disclaimer below.",
        f"Dependency packages: {len(packages)}",
        f"Unresolved license texts: {len(unresolved)}",
        "",
        "PACKAGE INDEX",
        "=============",
        *summaries,
        "ORIGINAL NOTICE TEXTS",
        "=====================",
    ]
    for digest, document in sorted(texts.items()):
        lines.extend(["", f"SHA-256 {digest}", "Applies to:"])
        lines.extend(f"  {name}" for name in sorted(document["users"]))
        lines.extend(["", "----- BEGIN ORIGINAL NOTICE -----", document["text"],
                      "----- END ORIGINAL NOTICE -----"])
    return "\n".join(lines) + "\n", unresolved


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--strict", action="store_true", help="Fail on unresolved notices.")
    args = parser.parse_args()
    if args.target not in {"aarch64-apple-darwin", "x86_64-apple-darwin"}:
        parser.error("unsupported macOS target")
    root = Path(__file__).resolve().parent.parent
    cargo = os.environ.get("CARGO", "cargo")
    if cargo == "cargo" and not any(
        (Path(directory) / "cargo").is_file() for directory in os.get_exec_path()
    ):
        cargo = str(Path.home() / ".cargo/bin/cargo")
    try:
        metadata = cargo_metadata(cargo, root / "Cargo.toml", args.target)
        packages = selected_packages(metadata)
        result, unknown = render(packages, args.target)
        # Package/notice content should not disclose the build machine location.
        if str(root) in result or str(Path.home()) in result:
            raise RuntimeError("Notice output unexpectedly contains a local build path.")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(result, encoding="utf-8")
        print(f"Collected {len(packages)} dependency packages; {len(unknown)} unresolved notices.")
        if unknown:
            for entry in unknown:
                print(f"Warning: {entry}", file=sys.stderr)
            return 1 if args.strict else 0
        return 0
    except (OSError, ValueError, KeyError, RuntimeError) as error:
        # Avoid surfacing subprocess metadata or filesystem paths in distributed notices.
        print(f"License collection failed: {type(error).__name__}. Check the locked target dependency cache.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
