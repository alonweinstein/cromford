#!/bin/bash
# bin/classify.sh <file> — ask the model which category a file belongs to.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/lib/model.sh"
model=$(resolve_model classify)
bash "$root/bin/llm.sh" --model "$model" --prompt "Which category is this? $(cat "$1")"
