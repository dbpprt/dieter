#!/usr/bin/env python3
"""Extract the macOS SwiftUI mockups embedded in the design PDF losslessly."""

from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfReader


REFERENCE_NAMES = (
    ("desktop-board-conversation.png",),
    ("desktop-chats-conversation.png",),
    ("desktop-chat-idle.png",),
    ("conversation-subagent-timeline.png",),
    ("conversation-subagents.png", "app-settings-connection.png"),
    ("command-palette.png",),
    (
        "new-chat.png",
        "menu-bar-item.png",
        "connection-popover.png",
        "review-notification.png",
    ),
    ("new-board-card.png", "project-context.png"),
    (
        "done-retention.png",
        "create-board.png",
        "board-labels.png",
        "card-context-menu.png",
    ),
    ("archived-chats.png", "app-settings-agents.png"),
    ("add-git-project.png",),
    ("schedules.png",),
    ("files.png",),
)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pdf", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "reference",
    )
    args = parser.parse_args()

    reader = PdfReader(args.pdf)
    if len(reader.pages) != len(REFERENCE_NAMES):
        raise SystemExit(
            f"expected {len(REFERENCE_NAMES)} PDF pages, found {len(reader.pages)}"
        )

    args.output.mkdir(parents=True, exist_ok=True)
    for page_number, (page, names) in enumerate(
        zip(reader.pages, REFERENCE_NAMES, strict=True), start=1
    ):
        images = list(page.images)
        if len(images) != len(names):
            raise SystemExit(
                f"expected {len(names)} image(s) on page {page_number}, "
                f"found {len(images)}"
            )
        for image, name in zip(images, names, strict=True):
            if image.image.mode != "RGBA":
                raise SystemExit(
                    f"expected an RGBA reference on page {page_number}, "
                    f"found {image.image.mode}"
                )
            target = args.output / name
            target.write_bytes(image.data)
            print(f"{target}: {image.image.width}x{image.image.height}")


if __name__ == "__main__":
    main()
