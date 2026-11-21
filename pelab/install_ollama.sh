#!/usr/bin/env bash
set -euo pipefail
# install_ollama.sh – install Ollama on the master and print login/run instructions.
# Usage: install_ollama.sh [cloud-model]
MODEL="${1:-minimax-m2.5:cloud}"

if command -v ollama >/dev/null 2>&1; then
    echo "Ollama already installed: $(ollama --version 2>/dev/null || echo present)"
else
    echo "Installing Ollama (https://ollama.com/download/linux)..."
    # The Ollama installer needs zstd for extraction.
    if ! command -v zstd >/dev/null 2>&1; then
        echo "Installing zstd (required by the Ollama installer)..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y zstd 2>/dev/null || {
                echo "zstd not in current repos; adding base Ubuntu repo..."
                echo 'deb http://archive.ubuntu.com/ubuntu/ noble main universe' > /etc/apt/sources.list.d/base.list
                echo 'deb http://archive.ubuntu.com/ubuntu/ noble-updates main universe' >> /etc/apt/sources.list.d/base.list
                echo 'deb http://security.ubuntu.com/ubuntu/ noble-security main universe' >> /etc/apt/sources.list.d/base.list
                apt-get update -y && apt-get install -y zstd
            }
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y zstd
        elif command -v yum >/dev/null 2>&1; then
            yum install -y zstd
        fi
    fi
    curl -fsSL https://ollama.com/install.sh | sh
    echo "Ollama installed."
fi

echo
echo "=============================================================="
echo "  OLLAMA READY – authenticate + pull a CLOUD model"
echo "=============================================================="
echo "  A local model is not powerful enough, so use a cloud model."
echo "  1. ollama login                 # authenticate with your Ollama account"
echo "  2. ollama run ${MODEL}          # pull + run the chosen cloud model"
echo "----------------------------------------------------------------"
echo "  The openainano bridge targets http://127.0.0.1:11434."
echo "  Verify: ollama list"
echo "=============================================================="
