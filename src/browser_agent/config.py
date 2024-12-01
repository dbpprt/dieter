import os
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
class OmniParserConfig:
    weights_path: str = "weights/omniparser/icon_detect/best.pt"


@dataclass
class Config:
    api_key: str = ""
    base_url: str = "https://openrouter.ai/api/v1"
    model_name: str = ""
    max_history_size: Optional[int] = 4
    browser: BrowserConfig = field(default_factory=BrowserConfig)
    omniparser: OmniParserConfig = field(default_factory=OmniParserConfig)


def substitute_env_vars(value: str) -> str:
    """Replace ${VAR} or $VAR in string with environment variable."""
    if not isinstance(value, str):
        return value

    if value.startswith("${") and value.endswith("}"):
        env_var = value[2:-1]
        return os.environ.get(env_var, "")
    elif value.startswith("$"):
        env_var = value[1:]
        return os.environ.get(env_var, "")
    return value


def process_config_values(config: Dict[str, Any]) -> Dict[str, Any]:
    """Recursively process config values, substituting environment variables."""
    processed_config = {}
    for key, value in config.items():
        if isinstance(value, dict):
            processed_config[key] = process_config_values(value)
        else:
            processed_config[key] = substitute_env_vars(value)
    return processed_config


def load_config(config_path: str = "config.yaml") -> Config:
    """Load configuration from YAML file with environment variable support."""
    console = Console()
    path = Path(config_path)
    if not path.exists():
        console.print(f"[yellow]Warning: Config file not found at {path}, using defaults[/yellow]")
        return Config()

    try:
        with open(path) as f:
            config_data = yaml.safe_load(f)
            # Process environment variables
            config_data = process_config_values(config_data)

            browser_config = config_data.get("browser", {})
            omniparser_config = config_data.get("omniparser", {})
            return Config(
                api_key=config_data.get("api_key", ""),
                base_url=config_data.get("base_url", "https://openrouter.ai/api/v1"),
                model_name=config_data.get("model_name", ""),
                max_history_size=config_data.get("max_history_size", 4),
                browser=BrowserConfig(
                    width=browser_config.get("width", 1024),
                    height=browser_config.get("height", 768),
                    browser_type=browser_config.get("browser_type", "chromium"),
                    data_dir=browser_config.get("data_dir", ".data/browser"),
                    device_scale_factor=browser_config.get("device_scale_factor", 2),
                    is_mobile=browser_config.get("is_mobile", True),
                    has_touch=browser_config.get("has_touch", True),
                    extensions=browser_config.get("extensions"),
                ),
                omniparser=OmniParserConfig(
                    weights_path=omniparser_config.get("weights_path", "weights/omniparser/icon_detect/best.pt"),
                ),
            )
    except Exception as e:
        console.print(f"[red]Error loading config: {str(e)}[/red]")
        return Config()
