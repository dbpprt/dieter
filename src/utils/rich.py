"""Rich text utilities for terminal UI."""
from typing import Optional, TextIO

from rich.console import Console
from rich.prompt import Prompt
from rich.style import Style
from rich.text import Text


class CustomPrompt(Prompt):
    """Enhanced prompt with custom styling for better readability."""
    prompt_suffix = " ❯ "

    @classmethod
    def get_input(
        cls,
        console: Console,
        prompt: Text,
        password: bool = False,
        stream: Optional[TextIO] = None
    ) -> str:
        """Get user input with styled prompt.

        Args:
            console: Rich console instance
            prompt: Text to display as prompt
            password: Whether to hide input
            stream: Optional IO stream for input

        Returns:
            User input as string
        """
        styled_prompt = Text.assemble(
            ("╭─", "bright_black"),
            *prompt,
            ("\n╰", "bright_black"),
            (cls.prompt_suffix, Style(color="bright_blue", bold=True))
        )
        return console.input(styled_prompt, password=password)
