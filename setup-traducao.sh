#!/usr/bin/env bash

set -e

echo "========================================="
echo " Configuração do ambiente de tradução"
echo "========================================="
echo

# Remove ambiente antigo
if [ -d ".venv" ]; then

    echo "Ambiente virtual existente encontrado."

    if ! rm -rf .venv 2>/dev/null; then
        echo
        echo "Não foi possível remover .venv."
        echo
        echo "Provavelmente existem arquivos pertencentes ao root."
        echo
        echo "Execute:"
        echo
        echo "sudo rm -rf .venv"
        echo
        echo "e rode este script novamente."
        exit 1
    fi
fi

echo "[1/5] Criando ambiente virtual..."

python3 -m venv .venv

echo
echo "[2/5] Ativando ambiente..."

source .venv/bin/activate

echo
echo "[3/5] Atualizando pip..."

python -m pip install --upgrade pip

echo
echo "[4/5] Instalando dependências..."

pip install \
    deep-translator \
    tqdm

echo
echo "[5/5] Testando instalação..."

python << 'PYTHON'
from deep_translator import GoogleTranslator

texto = "Tengo un supermercado espacial infinito."

resultado = GoogleTranslator(
    source="es",
    target="pt"
).translate(texto)

print()
print("Teste de tradução:")
print("ES :", texto)
print("PT :", resultado)
PYTHON

echo
echo "========================================="
echo " Ambiente configurado com sucesso"
echo "========================================="
echo
echo "Dependências instaladas:"
echo " - deep-translator"
echo " - tqdm"
echo
echo "Para ativar o ambiente:"
echo
echo "source .venv/bin/activate"
echo
