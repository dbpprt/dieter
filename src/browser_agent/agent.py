"""Browser agent that orchestrates LLM-guided browser automation."""
import logging
import signal
import sys
from dataclasses import dataclass
from typing import List, Optional, Tuple

from langchain_core.messages import AIMessage, HumanMessage
from langchain_openai import ChatOpenAI
from rich.box import ROUNDED
from rich.console import Console
from rich.live import Live
from rich.markdown import Markdown
from rich.panel import Panel
from rich.status import Status
from rich.text import Text

from src.prompts.browser import CONVERSATION_TEMPLATE
from src.prompts.browser import PROMPT_TEMPLATE as BROWSER_PROMPT_TEMPLATE
from src.utils.rich import CustomPrompt

from .analysis import PageAnalyzer, PageState
from .browser import BrowserManager
from .commands import Command, CommandParser
from .config import load_config
from .interaction import BrowserInteraction


@dataclass
class ModelState:
    is_thinking: bool = False
    is_first_turn: bool = True
    continue_automatically: bool = False


class BrowserAgent:
    def __init__(self, config_path: str = "src/config.yaml"):
        self.logger = logging.getLogger(__name__)
        self.console = Console()
        self.config = load_config(config_path)
        self.chat = ChatOpenAI(
            openai_api_key=self.config.api_key,
            openai_api_base=self.config.base_url,
            model_name=self.config.model_name,
            temperature=0.7
        )
        self.browser_manager = BrowserManager(self.config)
        self.status = Status("", console=self.console)
        self.conversation_history: List = []

        signal.signal(signal.SIGINT, lambda s, f: self._handle_shutdown())
        signal.signal(signal.SIGTERM, lambda s, f: self._handle_shutdown())

    def _handle_shutdown(self) -> None:
        self.logger.warning("Received shutdown signal, cleaning up...")
        self.cleanup()
        sys.exit(0)

    def cleanup(self) -> None:
        if self.browser_manager:
            self.browser_manager.cleanup()

    def _build_message_content(self, user_input: str, model_state: ModelState) -> List[dict]:
        if model_state.is_thinking:
            return [{"type": "text", "text": "<next />"}]

        page_state = self.analyzer.capture_state()
        context = self._create_context(page_state, model_state.is_first_turn)
        content = [
            {"type": "text", "text": context},
            {"type": "image_url", "image_url": f"data:image/png;base64,{page_state.encoded_image}"}
        ]

        if user_input:
            content.append({"type": "text", "text": user_input})

        return content

    def _create_context(self, page_state: PageState, is_first_turn: bool) -> str:
        template = BROWSER_PROMPT_TEMPLATE if is_first_turn else CONVERSATION_TEMPLATE
        parsed_content = "\n".join(f"id: {i} {content}" for i, content in enumerate(page_state.parsed_content))

        return template.format(
            additional_context=parsed_content,
            history=page_state.history_text,
            current_url=self.browser_manager.current_url,
            scroll_y=page_state.viewport_info.scroll_y,
            scroll_height=page_state.viewport_info.scroll_height,
            viewport_height=page_state.viewport_info.viewport_height,
            can_scroll_down=page_state.viewport_info.can_scroll_down,
            can_go_back=page_state.navigation_state.can_go_back,
            can_go_forward=page_state.navigation_state.can_go_forward
        )

    def _get_llm_response(self, message_content: List[dict]) -> str:
        self.conversation_history.append(HumanMessage(content=message_content))

        messages_for_call = self.conversation_history
        if self.config.max_history_size is not None:
            if len(self.conversation_history) > self.config.max_history_size:
                first_message = self.conversation_history[0]
                last_messages = self.conversation_history[-self.config.max_history_size:]
                truncation_message = HumanMessage(content=[{"type": "text", "text": "<truncated />"}])
                messages_for_call = [first_message, truncation_message] + last_messages

        with Live(self.status, refresh_per_second=10, transient=True):
            self.status.update("Thinking...")
            try:
                response = self.chat.invoke(messages_for_call)
                self.conversation_history.append(AIMessage(content=response.content))
                return response.content
            finally:
                self.status.update("")

    def _execute_browser_command(self, command: Command, page_state: Optional[PageState]) -> bool:
        if command.type == 'thinking':
            if command.message:
                self.console.print(Panel(Text(command.message, style="blue"), box=ROUNDED, border_style="blue"))
            return command.has_next

        command_info = f"{command.type} {command.element_id or ''} {command.text or ''} {command.url or ''} {command.message or ''}".strip()
        self.logger.debug("Executing command: %s", command_info)
        self.console.print(Panel(Text(f"Executing command: {command_info}", style="yellow"), box=ROUNDED, border_style="yellow"))

        try:
            match command.type:
                case 'back':
                    self.interaction.navigate_back()
                case 'click':
                    self.interaction.click(command.element_id, page_state.label_coordinates, page_state.screenshot)
                case 'scroll_down':
                    if page_state.viewport_info.can_scroll_down:
                        self.interaction.scroll('down')
                case 'scroll_up':
                    self.interaction.scroll('up')
                case 'type':
                    self.interaction.type_text(command.text, command.element_id, page_state.label_coordinates, page_state.screenshot, command.enter)
                case 'navigate':
                    self.browser_manager.navigate(command.url)
                case _:
                    raise ValueError(f"Unknown command type: {command.type}")

            return command.has_next
        except Exception as e:
            self.logger.error("Error executing command: %s", str(e), exc_info=True)
            return False

    def _process_model_response(self, response: str, model_state: ModelState) -> Tuple[bool, bool]:
        # Only show raw LLM response when verbose logging is enabled
        if self.logger.getEffectiveLevel() == logging.DEBUG:
            self.console.print(Panel(Text(f"LLM: {response}", style="magenta"), box=ROUNDED, border_style="magenta"))

        try:
            command = CommandParser.parse(response)
            page_state = None if command.type == 'thinking' else self.analyzer.capture_state()
            continue_automatically = self._execute_browser_command(command, page_state)
            is_thinking = command.type == 'thinking'
            return continue_automatically, is_thinking
        except ValueError:
            self.logger.debug("No command found in response, displaying as markdown")
            self.console.print(Panel(Markdown(response), box=ROUNDED, border_style="blue"))
            return False, True

    def run(self) -> None:
        try:
            self.browser_manager.setup()
            self.interaction = BrowserInteraction(self.browser_manager.page, self.status)
            self.analyzer = PageAnalyzer(self.browser_manager.page, self.status)

            self.logger.debug("Browser session started")
            self.console.print(Panel(Text("Browser session started. Type 'q' to quit.", style="bold green"), box=ROUNDED, border_style="green"))

            model_state = ModelState()

            while True:
                user_input = ""
                if not model_state.continue_automatically:
                    user_input = CustomPrompt.ask(Text("Enter your instruction", style="bright_white bold"), console=self.console)
                    if user_input.lower() == 'q':
                        break

                message_content = self._build_message_content(user_input, model_state)
                response = self._get_llm_response(message_content)

                model_state.continue_automatically, model_state.is_thinking = self._process_model_response(response, model_state)
                model_state.is_first_turn = False

        except KeyboardInterrupt:
            self.logger.warning("Received keyboard interrupt")
        except Exception:
            self.logger.exception("Unexpected error occurred")
        finally:
            self.cleanup()
