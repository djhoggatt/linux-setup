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


def parse_dimensions(text: str) -> dict[str, tuple[int, int]]:
    dimensions: dict[str, tuple[int, int]] = {}
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
            dimensions[current] = (int(match.group(1)), int(match.group(2)))
            current = None
    return dimensions


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


def prompt_y_offsets(order: list[str]) -> dict[str, int]:
    print()
    print("Enter the Y offset for each monitor.")
    print("Use 0 for no vertical offset. Positive values move the monitor down.")

    offsets: dict[str, int] = {}
    for output in order:
        while True:
            raw = input(f"Y offset for {output}: ").strip()
            try:
                offsets[output] = int(raw)
            except ValueError:
                print("Use an integer, for example 0, 540, or 1080.")
                continue
            break

    return offsets


def build_script(
    order: list[str],
    dimensions: dict[str, tuple[int, int]],
    y_offsets: dict[str, int],
) -> str:

    lines = [
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "",
    ]

    x = 0
    for output in order:
        width, _ = dimensions.get(output, (1920, 1080))
        y = y_offsets.get(output, 0)
        lines.append(f"wlr-randr --output {output} --on --pos {x},{y}")
        x += width

    lines.append("")
    return "\n".join(lines)


def main() -> None:
    output = run_wlr_randr()
    print(output.rstrip())
    print()

    outputs = parse_outputs(output)
    if len(outputs) < 2:
        raise SystemExit("Need at least two detected outputs.")

    dimensions = parse_dimensions(output)
    order = prompt_order(outputs)
    y_offsets = prompt_y_offsets(order)

    STARTUP_SCRIPT.parent.mkdir(parents=True, exist_ok=True)
    STARTUP_SCRIPT.write_text(build_script(order, dimensions, y_offsets), encoding="utf-8")
    STARTUP_SCRIPT.chmod(0o755)

    print()
    print(f"Wrote startup script: {STARTUP_SCRIPT}")
    print("Run it once now to test:")
    print(f"  {STARTUP_SCRIPT}")


if __name__ == "__main__":
    main()
