#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT
"""Golden-manifest comparator for helm template tests.

Compares a rendered `helm template` stream against per-document expected
YAML files ("goldens"), structurally:

  - document order in the stream is irrelevant (docs are keyed by
    kind/namespace/name)
  - map key order is irrelevant; comparison is strict (missing OR
    unexpected keys fail)
  - list order is preserved and enforced (Kubernetes list order can be
    semantic: env, args, volumeMounts, ...)
  - scalar values must be equal, unless the expected value is a
    placeholder

Placeholders (only valid in expected files, as string scalars):

  ((ANY))       matches any scalar
  ((BASE64))    matches base64/PEM-ish content
  ((SEMVER))    matches version-ish strings (1.2.3, v1.2.3-rc1, 1.300070.0b1586)
  ((RE:...))    matches the given regular expression (fully anchored)

Update mode regenerates the expected directory from a render and
auto-substitutes placeholders at known-volatile paths (cert material,
caBundle, chart version labels, image tags) so goldens do not churn on
releases or cert regeneration.

Usage:
  golden.py compare --expected DIR --render FILE
  golden.py update  --expected DIR --render FILE
"""

import argparse
import os
import re
import sys

import yaml

PLACEHOLDER_RE = re.compile(r"^\(\((ANY|BASE64|SEMVER|RE:.*)\)\)$", re.DOTALL)

PLACEHOLDER_PATTERNS = {
    "ANY": re.compile(r"(?s).*"),
    "BASE64": re.compile(r"^[A-Za-z0-9+/=\s-]+$"),
    "SEMVER": re.compile(r"^v?\d+\.\d+[\w.+-]*$"),
}

# Values at these locations are volatile across renders/releases and are
# auto-replaced with placeholders in update mode. Extend here, not in
# individual goldens.
VOLATILE_LABELS = {
    "app.kubernetes.io/version": "((ANY))",
    "helm.sh/chart": "((ANY))",
}
VOLATILE_SECRET_DATA = "((BASE64))"  # every data value in a Secret
VOLATILE_CA_BUNDLE = "((BASE64))"    # webhook clientConfig.caBundle
IMAGE_RE = re.compile(r"^(?P<repo>[\w.\-/]+):(?P<tag>[\w.\-]+)$")


def doc_key(doc):
    meta = doc.get("metadata", {}) or {}
    return (
        doc.get("kind", "Unknown"),
        meta.get("namespace", ""),
        meta.get("name", "unnamed"),
    )


def doc_filename(doc):
    kind, ns, name = doc_key(doc)
    base = f"{kind}.{name}" if not ns else f"{kind}.{ns}.{name}"
    return base + ".yaml"


def load_render(path):
    with open(path) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    return {doc_key(d): d for d in docs}


def load_expected(directory):
    expected = {}
    for fname in sorted(os.listdir(directory)):
        if not fname.endswith(".yaml"):
            continue
        with open(os.path.join(directory, fname)) as f:
            doc = yaml.safe_load(f)
        if doc:
            expected[doc_key(doc)] = doc
    return expected


def match_scalar(expected, actual):
    """True if actual satisfies expected (placeholder-aware)."""
    if isinstance(expected, str):
        m = PLACEHOLDER_RE.match(expected)
        if m:
            token = m.group(1)
            if token.startswith("RE:"):
                return re.fullmatch(token[3:], str(actual) if actual is not None else "", re.DOTALL) is not None
            return PLACEHOLDER_PATTERNS[token].match(
                str(actual) if actual is not None else ""
            ) is not None
    return expected == actual


def compare_node(expected, actual, path, errors):
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            errors.append(f"{path}: expected mapping, got {type(actual).__name__}")
            return
        for key in expected:
            if key not in actual:
                errors.append(f"{path}.{key}: expected key missing from render")
            else:
                compare_node(expected[key], actual[key], f"{path}.{key}", errors)
        for key in actual:
            if key not in expected:
                errors.append(f"{path}.{key}: unexpected key in render")
    elif isinstance(expected, list):
        if not isinstance(actual, list):
            errors.append(f"{path}: expected list, got {type(actual).__name__}")
            return
        if len(expected) != len(actual):
            errors.append(
                f"{path}: list length mismatch (expected {len(expected)}, got {len(actual)})"
            )
            return
        for i, (e, a) in enumerate(zip(expected, actual)):
            compare_node(e, a, f"{path}[{i}]", errors)
    else:
        if not match_scalar(expected, actual):
            errors.append(f"{path}: expected {expected!r}, got {actual!r}")


def compare(expected_dir, render_path):
    actual_docs = load_render(render_path)
    expected_docs = load_expected(expected_dir)
    errors = []

    for key in sorted(expected_docs):
        if key not in actual_docs:
            errors.append(f"{'/'.join(filter(None, key))}: expected document not rendered")
    for key in sorted(actual_docs):
        if key not in expected_docs:
            errors.append(f"{'/'.join(filter(None, key))}: rendered document has no golden")

    for key in sorted(set(expected_docs) & set(actual_docs)):
        doc_errors = []
        compare_node(expected_docs[key], actual_docs[key], "", doc_errors)
        label = "/".join(filter(None, key))
        errors.extend(f"{label}{e}" for e in doc_errors)

    return errors


def substitute_volatile(node, path=""):
    """Recursively replace known-volatile values with placeholders."""
    if isinstance(node, dict):
        for key, value in list(node.items()):
            child_path = f"{path}.{key}"
            if key == "labels" and isinstance(value, dict):
                for lbl, repl in VOLATILE_LABELS.items():
                    if lbl in value:
                        value[lbl] = repl
                substitute_volatile(value, child_path)
            elif key == "caBundle" and isinstance(value, str):
                node[key] = VOLATILE_CA_BUNDLE
            elif key == "image" and isinstance(value, str):
                m = IMAGE_RE.match(value)
                if m:
                    node[key] = f"((RE:{re.escape(m.group('repo'))}:.+))"
            else:
                substitute_volatile(value, child_path)
    elif isinstance(node, list):
        for item in node:
            substitute_volatile(item, path)


def update(expected_dir, render_path):
    actual_docs = load_render(render_path)
    os.makedirs(expected_dir, exist_ok=True)

    # Remove stale goldens so deletions show up in git.
    for fname in os.listdir(expected_dir):
        if fname.endswith(".yaml"):
            os.remove(os.path.join(expected_dir, fname))

    for key, doc in sorted(actual_docs.items()):
        if doc.get("kind") == "Secret" and isinstance(doc.get("data"), dict):
            for k in doc["data"]:
                doc["data"][k] = VOLATILE_SECRET_DATA
        substitute_volatile(doc)
        fname = doc_filename(doc)
        with open(os.path.join(expected_dir, fname), "w") as f:
            yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=True, width=4096)
    print(f"wrote {len(actual_docs)} golden(s) to {expected_dir}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["compare", "update"])
    parser.add_argument("--expected", required=True)
    parser.add_argument("--render", required=True)
    args = parser.parse_args()

    if args.mode == "update":
        update(args.expected, args.render)
        return 0

    errors = compare(args.expected, args.render)
    for e in errors:
        print(f"  {e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
