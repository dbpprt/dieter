# CLI App

A Python command-line application with modern development setup.

## Prerequisites

Install the required tools on macOS using Homebrew:

```bash
# Install pyenv and poetry
brew install pyenv poetry
```

## Setup Development Environment

1. Configure pyenv and add it to your shell (add to ~/.zshrc or ~/.bash_profile):

```bash
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.zshrc
echo 'command -v pyenv >/dev/null || export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.zshrc
echo 'eval "$(pyenv init -)"' >> ~/.zshrc
```

2. Restart your shell or reload the configuration:

```bash
source ~/.zshrc
```

3. Install Python 3.11 with pyenv:

```bash
pyenv install 3.11
```

4. Configure Poetry to create virtual environments in the project directory:

```bash
poetry config virtualenvs.in-project true
```

## Project Setup

1. Clone the repository:

```bash
git clone <repository-url>
cd cli-app
```

2. Set local Python version:

```bash
pyenv local 3.11
```

3. Install dependencies:

```bash
poetry install
```

## Development

- Run the CLI:

```bash
poetry run python -m src --example "test"
```

- Open in VSCode with debugging support:

```bash
code .
```

Then use F5 to start debugging (breakpoints are supported)

## Model Conversion

To convert safetensor models to PyTorch format:

```bash
poetry run python weights/omniparser/convert_safetensor_to_pt.py
```

## Code Quality

The project is set up with:

- Black for code formatting
- Pylint for code analysis
- Flake8 for style guide enforcement

These tools are automatically configured in VSCode settings.
