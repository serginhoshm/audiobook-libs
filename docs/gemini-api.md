## Gemini API in This Project

This project supports Google Gemini for:

1. General-purpose prompting via a utility script.

Gemini is not a pipeline translation backend.

## Key Source

Primary source:

- `config/pipeline.ini` in `[api_keys] gemini_api_key`

Emergency override:

- `GEMINI_API_KEY` environment variable

Legacy fallback file (still supported):

- `config/translation/gemini.env` (gitignored)

## Legacy Fallback File (Optional)

Versioned template:

- `config/translation/gemini.env.template`

Local runtime file (gitignored):

- `config/translation/gemini.env`

Steps:

1. Copy the template:

```bash
cp config/translation/gemini.env.template config/translation/gemini.env
```

2. Edit and provide your key:

```bash
GEMINI_API_KEY=your_key_here
GEMINI_MODEL=gemini-1.5-flash
```

Note: `config/translation/gemini.env` is ignored by git and is never committed. Prefer `config/pipeline.ini` for centralized runtime configuration.

## General Prompting

Utility script:

- `scripts/gemini_prompt.py`

Examples:

```bash
# Direct prompt
./.venv/bin/python scripts/gemini_prompt.py "Summarize this text in 5 bullets"

# Prompt from stdin
cat docs/project-order.md | ./.venv/bin/python scripts/gemini_prompt.py

# With system instruction
./.venv/bin/python scripts/gemini_prompt.py \
    --system "You are an objective technical reviewer" \
    "Review this paragraph"
```

Optional custom env file:

```bash
./.venv/bin/python scripts/gemini_prompt.py \
    --env-file /path/to/custom/gemini.env \
    "Your prompt"
```

## Dependency

Required package:

- `google-generativeai`

To refresh the environment:

```bash
bash setup/install_all.sh
```


