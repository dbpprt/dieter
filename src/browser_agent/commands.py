"""Command handling for browser interactions."""

import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Pattern


@dataclass
class Command:
    """Represents a parsed browser command."""

    type: str
    element_id: Optional[str] = None
    text: Optional[str] = None
    message: Optional[str] = None
    url: Optional[str] = None
    enter: bool = False
    has_next: bool = False
    memories: List[str] = None
    result: Optional[str] = None

    def __post_init__(self):
        if self.memories is None:
            self.memories = []


class CommandParser:
    """Parses and validates browser commands."""

    PATTERNS: Dict[str, Pattern] = {
        "back": re.compile(r"<back\s*/>"),
        "click": re.compile(r'<click\s+id="(\d+)"\s*/>'),
        "scroll_down": re.compile(r"<scroll_down\s*/>"),
        "scroll_up": re.compile(r"<scroll_up\s*/>"),
        "type": re.compile(r'<type\s+text="([^"]*)"\s+id="(\d+)"(?:\s+enter="(true|false)")?\s*/>'),
        "thinking": re.compile(r'<thinking\s+message="([^"]*)"\s*/>'),
        "next": re.compile(r"<next\s*/>"),
        "navigate": re.compile(r'<navigate\s+url="([^"]*)"\s*/>'),
        "memorize": re.compile(r'<memorize\s+text="([^"]*)"\s*/>'),
        "done": re.compile(r'<done\s+result="([^"]*)"\s*/>'),
    }

    COMMAND_EXTRACTOR = re.compile(r"<[^>]+>")

    @classmethod
    def parse(cls, response: str) -> Command:
        """Parse a command string into a Command object."""
        # Extract only the content between < and >
        if matches := cls.COMMAND_EXTRACTOR.findall(response):
            command_str = " ".join(matches)
        else:
            raise ValueError("No valid command found in response")

        # Check for next tag
        has_next = bool(cls.PATTERNS["next"].search(command_str))
        # Remove next tag if present
        command_str = cls.PATTERNS["next"].sub("", command_str).strip()

        # Handle thinking commands
        thinking_matches = list(cls.PATTERNS["thinking"].finditer(command_str))
        thinking_message = thinking_matches[-1].group(1) if thinking_matches else None

        # Handle memorize commands
        memories = [m.group(1) for m in cls.PATTERNS["memorize"].finditer(command_str)]
        # Remove memorize commands for further processing
        command_str = cls.PATTERNS["memorize"].sub("", command_str).strip()

        # Handle done command
        done_match = cls.PATTERNS["done"].search(command_str)
        if done_match:
            return Command(type="done", result=done_match.group(1), message=thinking_message, memories=memories)

        # Remove thinking commands and process the actual action command
        command_str = cls.PATTERNS["thinking"].sub("", command_str).strip()

        if not command_str and thinking_message:
            return Command(type="thinking", message=thinking_message, has_next=has_next, memories=memories)

        # Match action commands
        for cmd_type, pattern in cls.PATTERNS.items():
            if cmd_type in ("thinking", "next", "memorize", "done"):
                continue

            if match := pattern.match(command_str):
                if cmd_type == "type":
                    enter = match.group(3) == "true" if match.group(3) else False
                    return Command(
                        type=cmd_type,
                        text=match.group(1),
                        element_id=match.group(2),
                        enter=enter,
                        message=thinking_message,
                        has_next=has_next,
                        memories=memories,
                    )
                elif cmd_type == "click":
                    return Command(
                        type=cmd_type,
                        element_id=match.group(1),
                        message=thinking_message,
                        has_next=has_next,
                        memories=memories,
                    )
                elif cmd_type == "navigate":
                    return Command(
                        type=cmd_type,
                        url=match.group(1),
                        message=thinking_message,
                        has_next=has_next,
                        memories=memories,
                    )
                else:
                    return Command(type=cmd_type, message=thinking_message, has_next=has_next, memories=memories)

        raise ValueError(f"Invalid command format: {command_str}")
