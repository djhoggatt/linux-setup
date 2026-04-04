#!/usr/bin/env python3
from __future__ import annotations

import re
import subprocess
from pathlib import Path


STARTUP_SCRIPT = Path.home() / ".local" / "bin" / "monitor-layout"


def run_wlr_randr() -> str:
    result = subprocess.run(
        ["wlr-randr"],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout


def parse_outputs(text: str) -> list[str]:
    outputs: list[str] = []
    for line in text.splitlines():
        if not line or line.startswith(" "):
            continue
        name = line.split()[0]
        if name not in outputs:
            outputs.append(name)
    return outputs


def parse_widths(text: str) -> dict[str, int]:
    widths: dict[str, int] = {}
    current: str | None = None
    pattern = re.compile(r"^\s+(\d+)x(\d+)")

    for line in text.splitlines():
        if not line:
            continue
        if not line.startswith(" "):
            current = line.split()[0]
            continue
        if current is None:
            continue
        match = pattern.match(line)
        if match:
            widths[current] = int(match.group(1))
            current = None
    return widths


def prompt_order(outputs: list[str]) -> list[str]:
    print("Detected monitors:")
    for index, output in enumerate(outputs, start=1):
        print(f"  {index}. {output}")

    print()
    print("Enter monitor order from left to right using the numbers above.")
    print("Example: 2 1")

    while True:
        raw = input("Left-to-right order: ").strip()
        try:
            indexes = [int(part) for part in raw.split()]
        except ValueError:
            print("Use space-separated numbers.")
            continue

        if len(indexes) != len(outputs):
            print(f"Enter exactly {len(outputs)} numbers.")
            continue
        if sorted(indexes) != list(range(1, len(outputs) + 1)):
            print("Each monitor number must be used exactly once.")
            continue

        return [outputs[index - 1] for index in indexes]


def build_script(order: list[str], widths: dict[str, int]) -> str:
    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
    ]

    x = 0
    for output in order:
        lines.append(f"wlr-randr --output {output} --on --pos {x},0")
        x += widths.get(output, 1920)

    lines.append("")
    return "\n".join(lines)


def main() -> None:
    output = run_wlr_randr()
    print(output.rstrip())
    print()

    outputs = parse_outputs(output)
    if len(outputs) < 2:
        raise SystemExit("Need at least two detected outputs.")

    widths = parse_widths(output)
    order = prompt_order(outputs)

    STARTUP_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    STARTUP_SCRIPT.write_text(build_script(order, widths), encoding="utf-8")
    STARTUP_SCRIPT.chmod(0o755)

    print()
    print(f"Wrote startup script: {STARTUP_SCRIPT}")
    print("Run it once now to test:")
    print(f"  {STARTUP_SCRIPT}")


if __name__ == "__main__":
    main()
