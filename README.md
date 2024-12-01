# `dieter`

<div align="center">
  <img src="assets/logo.png" alt="dieter Logo" width="200"/>
  <p><strong>Vision-Guided Browser Automation Agent</strong></p>
</div>

<div align="center">
  <video src="assets/demo.mov" width="600"/>
</div>

## Overview

`dieter` is a sophisticated browser automation agent that combines Large Language Models (LLM) with computer vision to interact with web interfaces. Unlike traditional automation tools that rely on selectors or XPath, `dieter` understands web pages visually - similar to how humans do.

## Key Features

- **Vision-Based Interaction**: Uses OmniParser's pretrained YOLO model to identify clickable elements and interactive components
- **Intelligent Text Recognition**: Leverages Apple's Vision framework for accurate OCR
- **LLM-Guided Decision Making**: Uses language models to understand context and determine actions
- **Memory System**: Maintains context and previous interactions for more intelligent automation
- **Robust Navigation**: Tracks viewport state and navigation history
- **Interactive & Non-Interactive Modes**: Supports both guided and automated execution

## Technical Architecture

- **Browser Control**: Playwright for reliable browser automation
- **Computer Vision**:
  - OmniParser's YOLO model for element detection
  - Apple Vision framework for OCR
  - Custom OmniParser integration for combining visual inputs
- **LLM Integration**: OpenAI API for decision making
- **State Management**: Comprehensive tracking of page state, viewport info, and navigation history

## Model Compatibility

| Model                                    | Status | Notes                   |
| ---------------------------------------- | ------ | ----------------------- |
| google/gemini-flash-1.5                  | 🟢     | Recommended             |
| anthropic/claude-3.5-sonnet:beta         | 🟢     | Recommended             |
| mistralai/pixtral-large-2411             | 🟢     | Recommended             |
| openai/gpt-4o-mini                       | 🟡     | Prompt adherence issues |
| anthropic/claude-3.5-haiku:beta          | 🔴     | No vision support       |
| anthropic/claude-3-haiku                 | 🔴     | Doesn't work            |
| meta-llama/llama-3.2-90b-vision-instruct | 🔴     | Doesn't work            |
| meta-llama/llama-3.2-11b-vision-instruct | 🔴     | Doesn't work            |
| qwen/qwen-2-vl-72b-instruct              | 🔴     | Doesn't work            |
| mistralai/pixtral-12b                    | 🔴     | Doesn't work            |

## Prerequisites

- macOS 10.15 or later (required for Vision framework)
- Python 3.11
- Poetry for dependency management
- OmniParser YOLO weights for element detection

## Installation

1. Clone the repository:

```bash
git clone https://github.com/dbpprt/dieter
cd dieter
```

2. Set up Python environment:

```bash
pyenv install 3.11
pyenv local 3.11
```

3. Install dependencies:

```bash
poetry config virtualenvs.in-project true
poetry install
```

4. Download OmniParser weights:

   - Get weights from [HuggingFace](https://huggingface.co/microsoft/OmniParser)
   - Place in `weights/omniparser/icon_detect/best.pt`

5. Configure:

```bash
cp config.yaml.template config.yaml
# Add your API keys and settings
```

## Configuration

The `config.yaml` file controls `dieter`'s behavior. Here's the template with explanations:

```yaml
# OpenRouter Configuration
api_key: ${OPENROUTER_API_KEY} # Set via environment variable OPENROUTER_API_KEY
base_url: "https://openrouter.ai/api/v1"
model_name: "google/gemini-flash-1.5" # OpenRouter model format

# Conversation History Control
max_history_size: 4 # Number of message pairs to keep (null for unlimited)

# Browser Configuration
browser:
  width: 1024
  height: 768
  browser_type: "chromium" # chromium, firefox, or webkit
  data_dir: ".data/browser"
  device_scale_factor: 2
  is_mobile: true
  has_touch: true
  extensions:
    ublock_origin:
      url: "https://github.com/gorhill/uBlock/releases/download/1.61.2/uBlock0_1.61.2.chromium.zip"
      extract_dir: "uBlock0.chromium"
      enabled: true

# OmniParser Configuration
omniparser:
  weights_path: "weights/omniparser/icon_detect/best.pt" # Path to YOLO weights
```

### Configuration Options

- **OpenRouter Settings**:

  - `api_key`: Your OpenRouter API key
  - `base_url`: API endpoint
  - `model_name`: LLM model to use (see Model Compatibility table)

- **History Control**:

  - `max_history_size`: Limits conversation memory (null = unlimited)

- **Browser Settings**:

  - `width/height`: Browser window dimensions
  - `browser_type`: Browser engine selection
  - `device_scale_factor`: Screen resolution scaling
  - `is_mobile/has_touch`: Mobile device simulation
  - `extensions`: Browser extension configuration

- **OmniParser**:
  - `weights_path`: Path to YOLO model weights

## CLI Commands

`dieter` provides several command-line options:

```bash
poetry run python -m src [options]
```

### Available Options

| Option            | Description                                    | Default     |
| ----------------- | ---------------------------------------------- | ----------- |
| `--config`        | Path to configuration file                     | config.yaml |
| `--verbose`, `-v` | Enable detailed logging                        | False       |
| `--instruction`   | Run single instruction in non-interactive mode | None        |
| `--model-name`    | Override model from config                     | None        |

### Usage Examples

1. Interactive Mode:

```bash
poetry run python -m src
```

2. Non-Interactive Mode:

```bash
poetry run python -m src --instruction "navigate to example.com"
```

3. Debug Mode:

```bash
poetry run python -m src -v
```

4. Custom Model:

```bash
poetry run python -m src --model-name "anthropic/claude-3.5-sonnet:beta"
```

## How It Works

1. **Page Analysis**:

   - Captures screenshot of current page
   - Detects interactive elements using OmniParser's YOLO model
   - Performs OCR on text content
   - Tracks viewport and navigation state

2. **Decision Making**:

   - LLM analyzes page state and current task
   - Determines next action based on visual context
   - Maintains memory of previous interactions

3. **Execution**:
   - Precise interaction with detected elements
   - Viewport management for scrolling
   - Navigation handling
   - State verification after actions

## FAQ

### Why macOS Only?

`dieter` relies on Apple's Vision framework for OCR capabilities, which provides superior text recognition compared to alternatives.

### How Does Visual Detection Work?

`dieter` uses OmniParser's pretrained YOLO model to detect interactive elements like buttons, links, and input fields, combined with OCR for text recognition. This approach makes it more robust to UI changes compared to selector-based automation.

### Can It Handle Dynamic Content?

Yes, since `dieter` operates based on visual information rather than DOM structure, it can handle dynamically loaded content and modern web applications effectively.

### What Types of Automation Can It Handle?

- Web navigation and interaction
- Form filling
- Content extraction
- Visual verification
- Complex multi-step workflows

### How Does the Context Work?

The context system in `dieter` is implemented through a sophisticated combination of prompts and agent behavior:

1. **Prompt Templates** (`prompts/browser.py`):

   - Maintains structured context through sections like `<additional_context>`, `<browser_state>`, `<history>`, and `<memory>`
   - Provides the model with current page state, navigation capabilities, and interaction history

2. **Memory System** (`agent.py`):

   - Implements a `<memorize>` command allowing the model to store important information
   - Persists memories across conversation turns
   - Useful for maintaining context when scrolling or navigating between pages

3. **Context Truncation**:
   - Configurable through `max_history_size` in config.yaml
   - When history exceeds the limit, older messages are removed while preserving the first message
   - A `<truncated />` marker is inserted to indicate removed context
   - Ensures the model maintains focus on recent interactions while staying within context limits

This system allows `dieter` to maintain relevant context while preventing context overflow, enabling more coherent and effective automation across complex tasks.

## License

This project is under the MIT License - see LICENSE file for details.

Note about OmniParser licensing:
- OmniParser's icon_detect model is under AGPL license
- OmniParser's icon_caption_blip2 and icon_caption_florence models are under MIT license

## Disclaimer

This README is AI-generated based on analysis of the `dieter` source code.

---

Built with ❤️ using Python, OmniParser, and Apple Vision Framework
