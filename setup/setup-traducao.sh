#!/usr/bin/env bash

set -e

echo "========================================="
echo " Configuração do ambiente de tradução"
echo "========================================="
echo

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

if command -v dnf >/dev/null 2>&1; then
    echo "Detectado Fedora/RHEL com dnf."
    sudo dnf install -y \
        python3 \
        python3-pip \
        python3-virtualenv
elif command -v apt-get >/dev/null 2>&1; then
    echo "Detectado Debian/Ubuntu com apt-get."
    sudo apt-get update
    sudo apt-get install -y \
        python3 \
        python3-pip \
        python3-venv
else
    echo "Gerenciador de pacotes não suportado neste sistema."
    echo "Instale manualmente python3, python3-pip e python3-venv antes de continuar."
    exit 1
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
