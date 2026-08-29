#!/usr/bin/env python3
"""Extract the macOS SwiftUI reference views embedded in the design PDF."""

from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfReader


REFERENCE_NAMES = (
    ("island-collapsed.png", "island-expanded.png", "settings-island.png"),
    ("settings-desk-pet.png", "desk-pet-companion.png"),
    ("merge-conflict.png", "merge-failed-toast.png"),
    ("pull-request-states.png",),
    ("worktree-manager.png", "worktree-commits.png"),
    (
        "machine-offline.png",
        "turn-failed.png",
        "session-expired.png",
        "merge-completed-toast.png",
    ),
    ("empty-states.png",),
    ("command-palette.png",),
    ("settings-overview.png",),
    ("card-comments.png", "card-subagents.png"),
    (
        "card-context-menu.png",
        "card-drag-indicator.png",
        "card-drag-preview.png",
        "keyboard-shortcuts.png",
    ),
    ("machine-popover.png",),
    ("new-chat-workspace.png",),
    ("changes-diff-viewer.png",),
    ("merge-into-main.png",),
    ("board-card-inspector.png",),
    ("chats-standalone-chat.png",),
    ("new-conversation.png", "board-labels.png"),
    ("connect-onboarding.png", "choose-git-repository.png"),
    ("settings-connection.png",),
    ("collapsed-navigation.png",),
    ("files-editor.png",),
    ("schedules-editor.png",),
    ("terminals.png",),
    ("menu-bar-item.png", "connection-popover.png", "review-notification.png"),
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

    extracted: list[tuple[str, bytes, int, int]] = []
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
            extracted.append(
                (name, image.data, image.image.width, image.image.height)
            )

    args.output.mkdir(parents=True, exist_ok=True)
    expected_names = {name for names in REFERENCE_NAMES for name in names}
    for name, data, width, height in extracted:
        target = args.output / name
        temporary = target.with_suffix(".png.tmp")
        temporary.write_bytes(data)
        temporary.replace(target)
        print(f"{target}: {width}x{height}")

    for stale in sorted(args.output.glob("*.png")):
        if stale.name not in expected_names:
            stale.unlink()
            print(f"removed stale reference: {stale}")


if __name__ == "__main__":
    main()
