## Gemini API no projeto

Este projeto agora suporta Google Gemini para:

1. Traducao de SRT no pipeline (backend `gemini`)
2. Prompt geral para outras tarefas (script utilitario)

## Arquivo local de chave (nao versionado)

Template versionado:

- `config/translation/gemini.env.template`

Arquivo real local (ignorado pelo Git):

- `config/translation/gemini.env`

Passos:

1. Copie o template:

```bash
cp config/translation/gemini.env.template config/translation/gemini.env
```

2. Edite e preencha sua chave:

```bash
GEMINI_API_KEY=sua_chave_aqui
GEMINI_MODEL=gemini-1.5-flash
```

Observacao: `config/translation/gemini.env` esta no `.gitignore` e nao sera enviado ao repositório.

## Traducao SRT com backend Gemini

No fluxo principal (`workflows/exec.sh`), escolha backend `gemini` no prompt interativo
ou passe via CLI:

```bash
bash workflows/exec.sh --backend gemini
```

Tambem funciona direto no script Python:

```bash
./.venv/bin/python scripts/traduzir.py \
    entrada.srt saida.srtpt es \
    --backend gemini \
    --gemini-model gemini-1.5-flash
```

## Prompt geral (outras tarefas)

Script utilitario:

- `scripts/gemini_prompt.py`

Exemplos:

```bash
# Prompt direto
./.venv/bin/python scripts/gemini_prompt.py "Resuma este texto em 5 bullets"

# Prompt via stdin
cat docs/project-order.md | ./.venv/bin/python scripts/gemini_prompt.py

# Com instrucao de sistema
./.venv/bin/python scripts/gemini_prompt.py \
    --system "Voce e um revisor tecnico objetivo" \
    "Revise este paragrafo"
```

Opcionalmente, pode apontar outro arquivo de ambiente:

```bash
./.venv/bin/python scripts/gemini_prompt.py \
    --env-file /caminho/custom/gemini.env \
    "Seu prompt"
```

## Dependencia

O setup ja instala o pacote necessario:

- `google-generativeai`

Para atualizar o ambiente:

```bash
bash setup/install_all.sh
```


