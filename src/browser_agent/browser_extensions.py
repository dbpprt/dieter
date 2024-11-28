"""Browser extension management."""
import logging
import shutil
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional
import zipfile


@dataclass
class ExtensionConfig:
    """Browser extension configuration."""
    url: str
    extract_dir: Optional[str] = None
    enabled: bool = True


class ExtensionManager:
    """Manages browser extensions."""

    def __init__(self, data_dir: Path, extensions_config: Dict):
        self.logger = logging.getLogger(__name__)
        self.extensions_dir = data_dir / "extensions"
        self.extensions_dir.mkdir(parents=True, exist_ok=True)
        self.extensions_config = {
            name: ExtensionConfig(**config)
            for name, config in extensions_config.items()
        }

    def setup_extensions(self) -> Dict[str, str]:
        """Set up enabled extensions.

        Returns:
            Dict mapping extension names to their installed paths
        """
        extension_paths = {}

        for ext_name, config in self.extensions_config.items():
            if not config.enabled:
                continue

            try:
                ext_path = self._setup_extension(ext_name, config)
                if ext_path:
                    extension_paths[ext_name] = ext_path
                    self.logger.debug(f"Successfully set up extension {ext_name} at {ext_path}")
            except Exception as e:
                self.logger.error(
                    f"Failed to setup extension {ext_name}: {str(e)}")

        return extension_paths

    def _setup_extension(self, name: str, config: ExtensionConfig) -> Optional[str]:
        """Download and setup a browser extension.

        Args:
            name: Extension name/ID
            config: Extension configuration

        Returns:
            Path to the installed extension directory
        """
        ext_dir = self.extensions_dir / name
        ext_path = ext_dir
        if config.extract_dir:
            ext_path = ext_dir / config.extract_dir

        # If extension is already installed, return its path
        if ext_path.exists() and any(ext_path.iterdir()):
            self.logger.debug(f"Using existing extension at {ext_path}")
            return str(ext_path.absolute())

        # Clean up any partial installations
        if ext_dir.exists():
            shutil.rmtree(ext_dir)
        ext_dir.mkdir(exist_ok=True)

        # Download and extract the extension
        zip_path = ext_dir / f"{name}.zip"
        try:
            self.logger.debug(f"Downloading extension {name} from {config.url}")
            urllib.request.urlretrieve(config.url, zip_path)

            # Extract the ZIP file
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(ext_dir)

            # Clean up the zip file
            zip_path.unlink()

            if not ext_path.exists():
                raise Exception("Extension directory not found after extraction")

            self.logger.debug(f"Successfully extracted extension to {ext_path}")
            return str(ext_path.absolute())

        except Exception as e:
            if zip_path.exists():
                zip_path.unlink()
            if ext_dir.exists():
                shutil.rmtree(ext_dir)
            raise Exception(f"Failed to setup extension: {str(e)}")
