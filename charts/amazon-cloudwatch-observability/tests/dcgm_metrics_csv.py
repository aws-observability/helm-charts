#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""Check the rendered DcgmExporter metricsConfig the way dcgm-exporter reads it.

    python3 dcgm_metrics_csv.py [--name NAME ...] [--sha-env VAR] < rendered.yaml
"""

import argparse
import hashlib
import re
import sys

# Where the operator mounts the ConfigMap it renders from metricsConfig.
CSV_PATH = "/etc/dcgm-exporter/dcp-metrics-included.csv"

# The metric types dcgm-exporter accepts.
PROM_TYPES = ("counter", "gauge", "untyped", "label")


def type_error(fields):
    """The exporter's error for an unsupported metric type in a 3-field record, or None."""
    kind = fields[1].strip(" ")
    if kind in PROM_TYPES:
        return None
    return (f'unsupported Prometheus metric type "{kind}"; '
            "supported types are counter, gauge, untyped, and label")


def extract_metrics_config(rendered):
    """Lines of spec.metricsConfig in the DcgmExporter document, or None."""
    for doc in re.split(r"(?m)^---\s*$", rendered):
        if not re.search(r"(?m)^kind:\s*DcgmExporter\s*$", doc):
            continue
        lines = doc.splitlines()
        for i, line in enumerate(lines):
            if re.match(r"^  metricsConfig: \|[-+]?\s*$", line):
                body = []
                for nxt in lines[i + 1:]:
                    if nxt.strip() and not nxt.startswith("    "):
                        break
                    body.append(nxt[4:])
                while body and not body[-1].strip():
                    body.pop()
                return body
    return None


def extract_env_value(rendered, name):
    """The value of env entry NAME in the DcgmExporter document, or None."""
    for doc in re.split(r"(?m)^---\s*$", rendered):
        if not re.search(r"(?m)^kind:\s*DcgmExporter\s*$", doc):
            continue
        m = re.search(r'(?m)^  - name: "?' + re.escape(name) + r'"?\s*\n    value: "?([^"\n]*)"?\s*$', doc)
        return m.group(1) if m else None
    return None


def split_record(line, lineno):
    """(fields, None) for one physical line as Go's encoding/csv splits it, or (None, error)."""
    fields, pos = [], 0
    while True:
        if line.startswith('"', pos):
            value, i = [], pos + 1
            while True:
                q = line.find('"', i)
                if q < 0:
                    return None, f"record on line {lineno}: quoted field not closed on this line"
                value.append(line[i:q])
                if line.startswith('"', q + 1):
                    value.append('"')
                    i = q + 2
                    continue
                if q + 1 == len(line):
                    fields.append("".join(value))
                    return fields, None
                if line[q + 1] == ",":
                    fields.append("".join(value))
                    pos = q + 2
                    break
                return None, (f"parse error on line {lineno}, column {q + 1}: "
                              'extraneous or missing " in quoted-field')
            continue
        end = line.find(",", pos)
        field = line[pos:] if end < 0 else line[pos:end]
        quote = field.find('"')
        if quote >= 0:
            return None, (f"parse error on line {lineno}, column {pos + quote + 1}: "
                          'bare " in non-quoted-field')
        fields.append(field)
        if end < 0:
            return fields, None
        pos = end + 1


def records(lines):
    """[(lineno, fields, error)] for every line the CSV reader does not skip."""
    out = []
    for lineno, line in enumerate(lines, 1):
        if line == "" or line.startswith("#"):
            continue
        fields, error = split_record(line, lineno)
        out.append((lineno, fields, error))
    return out


def exporter_error(lines):
    """The error dcgm-exporter reports for this CSV body, or None if it loads."""
    want, loaded = None, []
    for lineno, fields, error in records(lines):
        if error is None and want is not None and len(fields) != want:
            error = f"record on line {lineno}: wrong number of fields"
        if error is not None:
            return f"Could not read metrics file '{CSV_PATH}'; err: {error}"
        if want is None:
            want = len(fields)
        loaded.append(fields)
    for i, fields in enumerate(loaded):
        if len(fields) != 3:
            shown = " ".join(f.strip(" ") for f in fields)
            return (f"malformed CSV record; err: failed to parse line {i} (`[{shown}]`), "
                    "expected 3 fields")
        error = type_error(fields)
        if error is not None:
            return error
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--name", action="append", default=[], metavar="NAME")
    parser.add_argument("--sha-env", metavar="VAR")
    args = parser.parse_args()

    rendered = sys.stdin.read()
    lines = extract_metrics_config(rendered)
    if not lines:
        print("no DcgmExporter spec.metricsConfig in the rendered output")
        return 2

    parsed = records(lines)
    bad = {lineno for lineno, fields, error in parsed
           if error or len(fields) != 3 or type_error(fields)}
    failed = False
    for lineno, fields, error in parsed:
        if lineno not in bad:
            continue
        failed = True
        if error:
            what = "does not parse"
        elif len(fields) != 3:
            what = f"has {len(fields)} fields, want 3 (name, type, help)"
        else:
            what = f'has type "{fields[1].strip(" ")}", want one of {", ".join(PROM_TYPES)}'
        # The error this line causes on its own: blank the other bad lines, keep numbering.
        alone = [l if (n == lineno or n not in bad) else "" for n, l in enumerate(lines, 1)]
        print(f"metricsConfig line {lineno} {what}:")
        print(f"    {lines[lineno - 1]}")
        print(f"    dcgm-exporter: {exporter_error(alone)}")

    if failed:
        print(f"dcgm-exporter would exit with: {exporter_error(lines)}")

    if args.name:
        names = [fields[0].strip(" ") for _, fields, error in parsed if not error and fields]
        missing = sorted(set(args.name) - set(names))
        extra = sorted(set(names) - set(args.name))
        doubled = sorted({n for n in names if names.count(n) > 1})
        for what, items in (("missing", missing), ("not expected", extra), ("listed twice", doubled)):
            if items:
                failed = True
                print(f"field names {what}: {', '.join(items)}")

    if args.sha_env:
        want = hashlib.sha256("\n".join(lines).encode()).hexdigest()[:16]
        got = extract_env_value(rendered, args.sha_env)
        if got != want:
            failed = True
            print(f"env {args.sha_env} is {got!r}, want {want!r} (checksum of the rendered metricsConfig)")

    if failed:
        return 1
    report = f"{len(parsed)} records, each with 3 fields and a valid type"
    if args.name:
        report += f", the {len(args.name)} expected names"
    if args.sha_env:
        report += f", {args.sha_env} matches the list"
    print(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
