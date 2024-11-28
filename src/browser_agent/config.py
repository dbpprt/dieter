from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

import yaml
from rich.console import Console


@dataclass
class BrowserConfig:
    width: int = 1024
    height: int = 768
    browser_type: str = "chromium"
    data_dir: str = ".data/browser"
    device_scale_factor: int = 2
    is_mobile: bool = True
    has_touch: bool = True
    extensions: Optional[Dict[str, Any]] = None


@dataclass
class Config:
    api_key: str = ""
    base_url: str = "https://openrouter.ai/api/v1"
    model_name: str = ""
    max_history_size: Optional[int] = 4
    browser: BrowserConfig = field(default_factory=BrowserConfig)


def load_config(config_path: str = "src/config.yaml") -> Config:
    """Load configuration from YAML file."""
    console = Console()
    path = Path(config_path)
    if not path.exists():
        console.print(f"[yellow]Warning: Config file not found at {path}, using defaults[/yellow]")
        return Config()

    try:
        with open(path) as f:
            config_data = yaml.safe_load(f)
            browser_config = config_data.get('browser', {})
            return Config(
                api_key=config_data.get('api_key', ''),
                base_url=config_data.get('base_url', 'https://openrouter.ai/api/v1'),
                model_name=config_data.get('model_name', ''),
                max_history_size=config_data.get('max_history_size', 4),
                browser=BrowserConfig(
                    width=browser_config.get('width', 1024),
                    height=browser_config.get('height', 768),
                    browser_type=browser_config.get('browser_type', 'chromium'),
                    data_dir=browser_config.get('data_dir', '.data/browser'),
                    device_scale_factor=browser_config.get('device_scale_factor', 2),
                    is_mobile=browser_config.get('is_mobile', True),
                    has_touch=browser_config.get('has_touch', True),
                    extensions=browser_config.get('extensions')
                )
            )
    except Exception as e:
        console.print(f"[red]Error loading config: {str(e)}[/red]")
        return Config()
