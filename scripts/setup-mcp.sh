#!/bin/zsh
set -eu
MORA_PROJECT_DIR="${0:A:h:h}"
cd "$MORA_PROJECT_DIR"
python3 -m venv .venv
.venv/bin/python -m pip install -r mcp/requirements.txt
zsh scripts/build-app.sh
.venv/bin/python scripts/write-mcp-config.py
print "Mora MCP готов. Параметры подключения: $MORA_PROJECT_DIR/mcp/client-config.json"
