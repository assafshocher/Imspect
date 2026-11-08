#!/bin/bash
set -euo pipefail

research_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
environment_dir="${IMSPECT_RESEARCH_ENV:-$HOME/Library/Application Support/Imspect/research}"
python_command="${IMSPECT_PYTHON:-}"
if [[ -z "$python_command" ]]; then
  for candidate in python3.12 python3.11 python3.10 /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys; assert (3,10) <= sys.version_info[:2] < (3,13)' >/dev/null 2>&1; then
      python_command="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$python_command" ]]; then
  printf '%s\n' 'Install Python 3.10–3.12 from python.org, then run this installer again.'
  printf '%s\n' 'You can also set IMSPECT_PYTHON to the absolute path of a compatible Python.'
  exit 1
fi
"$python_command" -c 'import sys; assert (3,10) <= sys.version_info[:2] < (3,13), "Use Python 3.10–3.12 for the research environment"'
printf '%s\n' 'Installing the optional Imspect research tools.'
printf '%s\n' 'This downloads Python packages (including PyTorch) and can require several GB.'
printf '%s\n' 'Pretrained model weights download when you first run their metric. Images stay local.'
mkdir -p "$(dirname -- "$environment_dir")"
"$python_command" -m venv "$environment_dir"
"$environment_dir/bin/python3" -m pip install --upgrade pip
"$environment_dir/bin/python3" -m pip install -r "$research_dir/requirements.txt"
"$environment_dir/bin/python3" -m pip check
"$environment_dir/bin/python3" -m pip freeze > "$environment_dir/installed-versions.txt"
"$environment_dir/bin/python3" -m unittest discover -s "$research_dir" -p 'test_backend.py'
printf '\n%s\n' 'The Imspect research environment is ready.'
printf 'Python: %s\n' "$environment_dir/bin/python3"
