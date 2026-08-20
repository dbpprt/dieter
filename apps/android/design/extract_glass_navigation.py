#!/usr/bin/env python3
"""Extract the glass-navigation mockups embedded in the design PDF losslessly."""

from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfReader


REFERENCE_PAGES = {
    0: "phone-glass-lens-dock.png",
    1: "phone-glass-command-center.png",
    2: "phone-glass-board.png",
    3: "phone-glass-chat.png",
}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent / "reference",
    )
    args = parser.parse_args()

    reader = PdfReader(args.pdf)
    if len(reader.pages) != 18:
        raise SystemExit(f"expected 18 PDF pages, found {len(reader.pages)}")

    args.output.mkdir(parents=True, exist_ok=True)
    for page_index, name in REFERENCE_PAGES.items():
        images = list(reader.pages[page_index].images)
        if len(images) != 1:
            raise SystemExit(
                f"expected one embedded image on page {page_index + 1}, found {len(images)}"
            )
        image = images[0]
        if image.image.mode != "RGBA":
            raise SystemExit(
                f"expected an RGBA reference on page {page_index + 1}, found {image.image.mode}"
            )
        target = args.output / name
        target.write_bytes(image.data)
        print(f"{target}: {image.image.width}x{image.image.height}")


if __name__ == "__main__":
    main()
