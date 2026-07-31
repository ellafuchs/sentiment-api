"""The gate: metrics in, verdict out.

    uv run python -m eval.gate                       # judge eval_report.json
    uv run python -m eval.gate --baseline live.json  # also check for regression

Deliberately a pure function of numbers. No network, no model, no cloud — it
reads a JSON file and some thresholds and returns pass or fail. That is what
makes it trustworthy: you can test every branch of it in milliseconds, and
nothing about the environment can change its answer.

Exit code 0 means the candidate may ship. Exit code 1 means it may not. That is
the entire interface CI needs.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

from app.config import GateConfig, load_config

DEFAULT_REPORT = Path(__file__).resolve().parent.parent / "eval_report.json"


@dataclass(frozen=True)
class Check:
    """One threshold, and whether the candidate cleared it."""

    name: str
    actual: float
    threshold: float
    higher_is_better: bool

    @property
    def passed(self) -> bool:
        if self.higher_is_better:
            return self.actual >= self.threshold
        return self.actual <= self.threshold

    @property
    def margin(self) -> float:
        """How far past the line, positive when passing."""
        return (
            self.actual - self.threshold if self.higher_is_better else self.threshold - self.actual
        )


@dataclass(frozen=True)
class Verdict:
    checks: list[Check]

    @property
    def passed(self) -> bool:
        return all(c.passed for c in self.checks)

    @property
    def failures(self) -> list[Check]:
        return [c for c in self.checks if not c.passed]

    def to_markdown(self) -> str:
        """A table a human reviewer can read in the PR without opening CI logs.

        A red X alone is not enough — the reviewer needs to see *which* metric
        failed and by how much, or they cannot judge whether to override.
        """
        header = "✅ **Gate passed**" if self.passed else "❌ **Gate failed**"
        lines = [
            header,
            "",
            "| check | value | threshold | margin | |",
            "|---|---:|---:|---:|:-:|",
        ]
        for c in self.checks:
            direction = "min" if c.higher_is_better else "max"
            lines.append(
                f"| {c.name} | {c.actual:.4g} | {direction} {c.threshold:.4g} "
                f"| {c.margin:+.4g} | {'✅' if c.passed else '❌'} |"
            )
        if not self.passed:
            names = ", ".join(c.name for c in self.failures)
            lines += ["", f"Blocked by: **{names}**."]
        return "\n".join(lines)


def run_gate(report: dict, gate: GateConfig, baseline: dict | None = None) -> Verdict:
    """Judge a candidate's metrics against absolute floors, then against production.

    ``baseline`` is the currently-deployed model's report, or None when nothing
    is deployed yet.
    """
    checks = [
        Check("accuracy", report["accuracy"], gate.min_accuracy, higher_is_better=True),
        Check("macro_f1", report["macro_f1"], gate.min_macro_f1, higher_is_better=True),
        Check(
            "p95_latency_ms",
            report["p95_latency_ms"],
            gate.max_p95_latency_ms,
            higher_is_better=False,
        ),
    ]

    # The regression check, and the reason absolute floors alone are not enough.
    # A model at 0.885 clears min_accuracy: 0.88 while being meaningfully worse
    # than the 0.90 already serving traffic. Without this, quality erodes one
    # individually-acceptable PR at a time.
    if baseline is not None and "accuracy" in baseline:
        floor = baseline["accuracy"] - gate.max_accuracy_regression
        checks.append(Check("accuracy vs live", report["accuracy"], floor, higher_is_better=True))

    return Verdict(checks)


def load_report(path: Path) -> dict:
    if not path.is_file():
        raise SystemExit(f"no report at {path} — run `make eval` first")
    report = json.loads(path.read_text())

    required = {"accuracy", "macro_f1", "p95_latency_ms"}
    if missing := required - set(report):
        raise SystemExit(f"{path} is missing {sorted(missing)} — is it a real eval report?")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--baseline",
        type=Path,
        default=None,
        help="the live model's report, for the regression check",
    )
    parser.add_argument("--markdown", type=Path, default=None, help="also write the table here")
    args = parser.parse_args(argv)

    report = load_report(args.report)
    baseline = json.loads(args.baseline.read_text()) if args.baseline else None
    if baseline is None:
        print("note: no baseline given — skipping the regression check\n", file=sys.stderr)

    verdict = run_gate(report, load_config().gate, baseline)
    table = verdict.to_markdown()

    print(table)
    if args.markdown:
        args.markdown.write_text(table + "\n")

    return 0 if verdict.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
