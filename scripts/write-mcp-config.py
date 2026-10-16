"""Write portable MCP launch parameters using this checkout's actual paths."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
packaged = root / "build/Mora.app/Contents/MacOS/MoraBridge"
bridge = packaged if packaged.is_file() else root / ".build/release/MoraBridge"
config = {"mcpServers": {"mora": {
    "command": str(root / ".venv/bin/python"),
    "args": [str(root / "mcp/server.py"), "--bridge", str(bridge)],
}}}
(root / "mcp/client-config.json").write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("Конфигурация MCP сохранена")
