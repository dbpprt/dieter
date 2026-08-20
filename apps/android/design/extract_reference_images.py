#!/usr/bin/env python3
"""Extract the Android mockups embedded in the design PDF without recompression."""

from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfReader


REFERENCE_NAMES = (
    "phone-settings-connections.png",
    "phone-settings-display.png",
    "phone-board-server.png",
    "phone-notification-shade.png",
    "phone-chat-subagents.png",
    "phone-spaces.png",
    "phone-board-switcher.png",
    "phone-new-project.png",
    "phone-new-chat.png",
    "phone-new-schedule.png",
    "unfolded-board-card.png",
    "unfolded-chats-conversation.png",
    "phone-board.png",
    "phone-card-conversation.png",
    "phone-card-comments.png",
    "phone-chats.png",
    "phone-chat.png",
    "phone-files.png",
    "phone-schedules.png",
)


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
    if len(reader.pages) != len(REFERENCE_NAMES):
        raise SystemExit(
            f"expected {len(REFERENCE_NAMES)} PDF pages, found {len(reader.pages)}"
        )

    args.output.mkdir(parents=True, exist_ok=True)
    for page_number, (page, name) in enumerate(
        zip(reader.pages, REFERENCE_NAMES, strict=True), start=1
    ):
        images = list(page.images)
        if len(images) != 1:
            raise SystemExit(
                f"expected one embedded image on page {page_number}, found {len(images)}"
            )
        image = images[0]
        if image.image.mode != "RGBA":
            raise SystemExit(
                f"expected an RGBA reference on page {page_number}, found {image.image.mode}"
            )
        target = args.output / name
        target.write_bytes(image.data)
        print(f"{target}: {image.image.width}x{image.image.height}")


if __name__ == "__main__":
    main()
