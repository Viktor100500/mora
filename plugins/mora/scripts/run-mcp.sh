#!/bin/zsh
set -eu
MORA_PLUGIN_ROOT="${0:A:h:h}"
if [[ -f "$MORA_PLUGIN_ROOT/runtime.sh" ]]; then
  source "$MORA_PLUGIN_ROOT/runtime.sh"
fi
MORA_PLUGIN_PYTHON="${MORA_PYTHON:-${MORA_PLUGIN_PYTHON:-}}"
if [[ -z "$MORA_PLUGIN_PYTHON" || ! -x "$MORA_PLUGIN_PYTHON" ]]; then
  print -u2 'Mora: среда MCP не найдена. Выполните scripts/setup-mcp.sh в проекте Mora и пересоберите плагин либо задайте MORA_PYTHON.'
  exit 1
fi
if [[ ! -x "$MORA_PLUGIN_ROOT/bin/MoraBridge" ]]; then
  print -u2 'Mora: компонент MoraBridge отсутствует. Пересоберите архив плагина.'
  exit 1
fi
exec "$MORA_PLUGIN_PYTHON" "$MORA_PLUGIN_ROOT/MCP/server.py" --bridge "$MORA_PLUGIN_ROOT/bin/MoraBridge" "$@"
