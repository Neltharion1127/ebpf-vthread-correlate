#!/usr/bin/env python3
"""Reconcile syscall-count truth with independently captured trace attribution."""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


COUNT_BASE = 1000
EXPECTED_TRACE_HI = 0xCAFEBABE00C0FFEE
CONTENT_CLASSES = ("CORRECT", "MISATTRIBUTED", "UNMAPPED", "NULLBUF", "INVALID", "LOST")
IDENTITY_CLASSES = (
    "IDENTITY_CORRECT",
    "IDENTITY_MISATTRIBUTED",
    "IDENTITY_UNMAPPED",
    "IDENTITY_LOST",
)
MARKER_RE = re.compile(
    r"^\[marker\] "
    r"ts=(?P<ts>\d+) "
    r"carrier=(?P<carrier>\d+) "
    r"count=(?P<count>\d+) "
    r"status=(?P<status>[A-Z]+) "
    r"vthread=(?P<vthread>\d+) "
    r"traceid_hi=(?P<traceid_hi>[0-9a-fA-F]+) "
    r"traceid_lo=(?P<traceid_lo>[0-9a-fA-F]+) "
    r"spanid=(?P<spanid>[0-9a-fA-F]+)$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="MarkerHarness manifest.csv")
    parser.add_argument("consumer_log", type=Path, help="bpftrace consumer log")
    parser.add_argument(
        "--expect-clean",
        action="store_true",
        help="fail on misattribution, loss, or a non-1:1 pairing",
    )
    return parser.parse_args()


def empty_content_counts() -> dict[str, int]:
    return {name: 0 for name in CONTENT_CLASSES}


def empty_identity_counts() -> dict[str, int]:
    return {name: 0 for name in IDENTITY_CLASSES}


def empty_bucket(include_surplus: bool = False) -> dict[str, Any]:
    bucket: dict[str, Any] = {
        "total": 0,
        "content_plane": empty_content_counts(),
        "identity_plane": empty_identity_counts(),
    }
    if include_surplus:
        bucket["surplus"] = 0
    return bucket


def read_manifest(path: Path) -> tuple[list[dict[str, Any]], dict[str, int]]:
    comments: list[str] = []
    csv_lines: list[str] = []
    with path.open(encoding="utf-8", newline="") as source:
        for line in source:
            if line.startswith("#"):
                comments.append(line.rstrip("\n"))
            elif line.strip():
                csv_lines.append(line)

    if not csv_lines:
        raise ValueError(f"manifest has no CSV header: {path}")

    header: dict[str, int] = {}
    for comment in comments:
        for key, value in re.findall(r"\b(pid|fd)=(\d+)\b", comment):
            header[key] = int(value)
    if set(header) != {"pid", "fd"}:
        raise ValueError("manifest header must contain pid=<n> and fd=<n>")

    required = {
        "k",
        "seq",
        "expected_traceId",
        "expected_spanId",
        "expected_vthread_id",
        "fd",
        "count",
    }
    entries: list[dict[str, Any]] = []
    seen: set[tuple[int, int]] = set()
    vthread_ids: dict[int, int] = {}
    reader = csv.DictReader(csv_lines)
    if reader.fieldnames is None or set(reader.fieldnames) != required:
        raise ValueError(f"manifest columns must be exactly {sorted(required)}")

    for row_number, row in enumerate(reader, start=3):
        try:
            k = int(row["k"])
            seq = int(row["seq"])
            fd = int(row["fd"])
            count = int(row["count"])
            expected_vthread_id = int(row["expected_vthread_id"])
            trace_id = row["expected_traceId"].lower()
            span_id = row["expected_spanId"].lower()
            int(trace_id, 16)
            int(span_id, 16)
        except (KeyError, TypeError, ValueError) as error:
            raise ValueError(f"invalid manifest row {row_number}: {row}") from error

        if len(trace_id) != 32 or len(span_id) != 16:
            raise ValueError(f"invalid ID width at manifest row {row_number}")
        if count != COUNT_BASE + k:
            raise ValueError(f"count does not encode k at manifest row {row_number}")
        if fd != header["fd"]:
            raise ValueError(f"fd differs from manifest header at row {row_number}")
        if expected_vthread_id <= 0:
            raise ValueError(f"invalid expected_vthread_id at row {row_number}")
        if k in vthread_ids and vthread_ids[k] != expected_vthread_id:
            raise ValueError(f"expected_vthread_id changed within k={k}")
        vthread_ids[k] = expected_vthread_id
        if (k, seq) in seen:
            raise ValueError(f"duplicate manifest key (k={k}, seq={seq})")
        seen.add((k, seq))

        entries.append(
            {
                "k": k,
                "seq": seq,
                "expected_trace_id": trace_id,
                "expected_span_id": span_id,
                "expected_span_value": int(span_id, 16),
                "expected_vthread_id": expected_vthread_id,
                "fd": fd,
                "count": count,
            }
        )
    return entries, header


def read_events(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    events: list[dict[str, Any]] = []
    malformed: list[str] = []
    with path.open(encoding="utf-8", errors="replace") as source:
        for line_number, raw_line in enumerate(source, start=1):
            line = raw_line.strip()
            if not line.startswith("[marker]"):
                continue
            match = MARKER_RE.fullmatch(line)
            if match is None:
                malformed.append(f"line {line_number}: {line}")
                continue
            fields = match.groupdict()
            status = fields["status"]
            if status not in {"OK", "UNMAPPED", "NULLBUF", "INVALID"}:
                malformed.append(f"line {line_number}: unsupported status {status}")
                continue
            count = int(fields["count"])
            events.append(
                {
                    "line": line_number,
                    "timestamp": int(fields["ts"]),
                    "carrier": int(fields["carrier"]),
                    "count": count,
                    "k_true": count - COUNT_BASE,
                    "status": status,
                    "vthread": int(fields["vthread"]),
                    "traceid_hi": int(fields["traceid_hi"], 16),
                    "traceid_lo": int(fields["traceid_lo"], 16),
                    "spanid": int(fields["spanid"], 16),
                }
            )
    return events, malformed


def classify_content(entry: dict[str, Any], event: dict[str, Any] | None) -> tuple[str, str]:
    if event is None:
        return "LOST", "NO_LOG_EVENT"
    if event["status"] != "OK":
        return event["status"], event["status"]
    if event["traceid_hi"] != EXPECTED_TRACE_HI:
        return "MISATTRIBUTED", "FOREIGN_CONTEXT"
    if event["traceid_lo"] != event["k_true"]:
        return "MISATTRIBUTED", "WRONG_K"
    if event["spanid"] != entry["expected_span_value"]:
        return "MISATTRIBUTED", "WRONG_SPAN"
    return "CORRECT", "MATCH"


def classify_identity(entry: dict[str, Any], event: dict[str, Any] | None) -> tuple[str, str]:
    if event is None:
        return "IDENTITY_LOST", "NO_LOG_EVENT"
    if event["status"] == "UNMAPPED" or event["vthread"] == 0:
        return "IDENTITY_UNMAPPED", "NO_IDENTITY_MAPPING"
    if event["vthread"] != entry["expected_vthread_id"]:
        return "IDENTITY_MISATTRIBUTED", "WRONG_VTHREAD"
    return "IDENTITY_CORRECT", "MATCH"


def compact_event(event: dict[str, Any]) -> dict[str, Any]:
    return {
        "line": event["line"],
        "timestamp": event["timestamp"],
        "carrier": event["carrier"],
        "count": event["count"],
        "k_true": event["k_true"],
        "status": event["status"],
        "vthread": event["vthread"],
        "traceid_hi": f"{event['traceid_hi']:016x}",
        "traceid_lo": f"{event['traceid_lo']:016x}",
        "spanid": f"{event['spanid']:016x}",
    }


def reconcile(
    entries: list[dict[str, Any]], events: list[dict[str, Any]], malformed: list[str]
) -> dict[str, Any]:
    events_by_k: dict[int, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        events_by_k[event["k_true"]].append(event)

    next_index: dict[int, int] = defaultdict(int)
    content_counts = empty_content_counts()
    identity_counts = empty_identity_counts()
    per_k: dict[str, dict[str, Any]] = {}
    per_seq: dict[str, dict[str, Any]] = {}
    content_reason_counts: dict[str, int] = defaultdict(int)
    identity_reason_counts: dict[str, int] = defaultdict(int)
    first_trace_misattributed: list[dict[str, Any]] = []
    first_identity_misattributed: list[dict[str, Any]] = []

    for entry in entries:
        k = entry["k"]
        index = next_index[k]
        same_k_events = events_by_k.get(k, [])
        event = same_k_events[index] if index < len(same_k_events) else None
        next_index[k] += 1

        content_class, content_reason = classify_content(entry, event)
        identity_class, identity_reason = classify_identity(entry, event)
        content_counts[content_class] += 1
        identity_counts[identity_class] += 1
        content_reason_counts[content_reason] += 1
        identity_reason_counts[identity_reason] += 1

        k_bucket = per_k.setdefault(str(k), empty_bucket(include_surplus=True))
        k_bucket["total"] += 1
        k_bucket["content_plane"][content_class] += 1
        k_bucket["identity_plane"][identity_class] += 1

        seq_bucket = per_seq.setdefault(str(entry["seq"]), empty_bucket())
        seq_bucket["total"] += 1
        seq_bucket["content_plane"][content_class] += 1
        seq_bucket["identity_plane"][identity_class] += 1

        if content_class == "MISATTRIBUTED" and len(first_trace_misattributed) < 10:
            assert event is not None
            item = compact_event(event)
            item.update(
                {
                    "manifest_k": k,
                    "seq": entry["seq"],
                    "k_attr": event["traceid_lo"] if event["traceid_hi"] == EXPECTED_TRACE_HI else None,
                    "reason": content_reason,
                    "expected_traceId": entry["expected_trace_id"],
                    "expected_spanId": entry["expected_span_id"],
                    "expected_vthread_id": entry["expected_vthread_id"],
                }
            )
            first_trace_misattributed.append(item)

        if identity_class == "IDENTITY_MISATTRIBUTED" and len(first_identity_misattributed) < 10:
            assert event is not None
            item = compact_event(event)
            item.update(
                {
                    "manifest_k": k,
                    "seq": entry["seq"],
                    "reason": identity_reason,
                    "expected_vthread_id": entry["expected_vthread_id"],
                }
            )
            first_identity_misattributed.append(item)

    surplus_events: list[dict[str, Any]] = []
    for k, same_k_events in sorted(events_by_k.items()):
        consumed = next_index.get(k, 0)
        extras = same_k_events[consumed:]
        if extras:
            bucket = per_k.setdefault(str(k), empty_bucket(include_surplus=True))
            bucket["surplus"] += len(extras)
            surplus_events.extend(compact_event(event) for event in extras)

    pairing_violations = len(surplus_events) + len(malformed)
    pairing_complete = content_counts["LOST"] == 0 and pairing_violations == 0
    return {
        "manifest_entries": len(entries),
        "log_events": len(events),
        "content_plane": {
            "counts": content_counts,
            "reason_counts": dict(sorted(content_reason_counts.items())),
            "foreign_context": content_reason_counts.get("FOREIGN_CONTEXT", 0),
        },
        "identity_plane": {
            "counts": identity_counts,
            "reason_counts": dict(sorted(identity_reason_counts.items())),
        },
        "pairing": {
            "complete": pairing_complete,
            "lost": content_counts["LOST"],
            "surplus": len(surplus_events),
            "malformed_marker_lines": len(malformed),
            "violations": pairing_violations,
            "surplus_events": surplus_events[:10],
            "malformed_examples": malformed[:10],
        },
        "per_k": dict(sorted(per_k.items(), key=lambda item: int(item[0]))),
        "per_seq": dict(sorted(per_seq.items(), key=lambda item: int(item[0]))),
        "first_10_trace_misattributed": first_trace_misattributed,
        "first_10_identity_misattributed": first_identity_misattributed,
    }


def print_bucket_table(title: str, buckets: dict[str, dict[str, Any]], include_surplus: bool) -> None:
    columns = [
        "key",
        "total",
        *CONTENT_CLASSES,
        "IDENTITY_MISATTRIBUTED",
        "IDENTITY_UNMAPPED",
        "IDENTITY_LOST",
    ]
    if include_surplus:
        columns.append("SURPLUS")
    widths = {column: max(len(column), 7) for column in columns}
    rows: list[dict[str, str]] = []
    for key, bucket in buckets.items():
        row = {"key": key, "total": str(bucket["total"])}
        row.update({name: str(bucket["content_plane"][name]) for name in CONTENT_CLASSES})
        row.update(
            {
                name: str(bucket["identity_plane"][name])
                for name in ("IDENTITY_MISATTRIBUTED", "IDENTITY_UNMAPPED", "IDENTITY_LOST")
            }
        )
        if include_surplus:
            row["SURPLUS"] = str(bucket.get("surplus", 0))
        for column, value in row.items():
            widths[column] = max(widths[column], len(value))
        rows.append(row)

    print(title)
    print(" ".join(column.rjust(widths[column]) for column in columns))
    print(" ".join("-" * widths[column] for column in columns))
    for row in rows:
        print(" ".join(row[column].rjust(widths[column]) for column in columns))


def print_report(summary: dict[str, Any], output_path: Path) -> None:
    print_bucket_table("Per-k results", summary["per_k"], include_surplus=True)
    print()
    print_bucket_table("Per-sequence results", summary["per_seq"], include_surplus=False)
    print()
    print("Content plane")
    for name in CONTENT_CLASSES:
        print(f"  {name:24s} {summary['content_plane']['counts'][name]}")
    print("Identity plane")
    for name in IDENTITY_CLASSES:
        print(f"  {name:24s} {summary['identity_plane']['counts'][name]}")
    pairing = summary["pairing"]
    print("Pairing")
    print(f"  {'SURPLUS':24s} {pairing['surplus']}")
    print(f"  {'MALFORMED':24s} {pairing['malformed_marker_lines']}")
    print(f"  {'PAIRING':24s} {'complete' if pairing['complete'] else 'VIOLATED'}")
    print(f"  {'summary.json':24s} {output_path}")


def main() -> int:
    args = parse_args()
    try:
        entries, header = read_manifest(args.manifest)
        events, malformed = read_events(args.consumer_log)
        summary = reconcile(entries, events, malformed)
    except (OSError, ValueError) as error:
        print(f"reconcile.py: error: {error}", file=sys.stderr)
        return 2

    summary["manifest_header"] = header
    summary["expect_clean"] = args.expect_clean
    output_path = args.manifest.parent / "summary.json"
    try:
        with output_path.open("w", encoding="utf-8") as output:
            json.dump(summary, output, indent=2, sort_keys=False)
            output.write("\n")
    except OSError as error:
        print(f"reconcile.py: error writing {output_path}: {error}", file=sys.stderr)
        return 2

    print_report(summary, output_path)
    if not args.expect_clean:
        return 0
    if summary["content_plane"]["counts"]["MISATTRIBUTED"] > 0:
        return 1
    if summary["identity_plane"]["counts"]["IDENTITY_MISATTRIBUTED"] > 0:
        return 1
    if summary["content_plane"]["counts"]["LOST"] > 0:
        return 1
    if summary["pairing"]["violations"] > 0:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
