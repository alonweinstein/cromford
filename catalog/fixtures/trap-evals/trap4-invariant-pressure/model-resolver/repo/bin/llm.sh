#!/bin/bash
# bin/llm.sh --model <id> --prompt <text> — send a prompt to the model.
# Offline stand-in for local development: it prints the model it was asked for
# and nothing else.
model=
while [ $# -gt 0 ]; do
  case $1 in
    --model) model=$2; shift 2 ;;
    --prompt) shift 2 ;;
    *) shift ;;
  esac
done
echo "MODEL=$model"
