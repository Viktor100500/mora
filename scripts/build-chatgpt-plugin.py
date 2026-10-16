"""Build a private Mora plugin without bundling financial data or credentials."""
from __future__ import annotations

import argparse
import json
import shlex
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def build(output: Path, python: Path, bridge: Path) -> Path:
    if not python.is_file() or not bridge.is_file():
        raise SystemExit("Сначала выполните scripts/setup-mcp.sh: нужны Python MCP и собранный MoraBridge.")
    output.mkdir(parents=True, exist_ok=True)
    package = output / "mora"
    package.mkdir(exist_ok=True)
    source = ROOT / "plugins/mora"
    # Explicit inputs only: no database, downloads, env files or runtime tokens.
    for relative in ["plugin.json", "mcp.json", "scripts/run-mcp.sh", "skills/mora-finance/SKILL.md", "skills/mora-setup/SKILL.md"]:
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target)
    copies = {
        "MCP/server.py": ROOT / "mcp/server.py",
        "MCP/requirements.txt": ROOT / "mcp/requirements.txt",
        "Prompts/mora-mcp.md": ROOT / "Prompts/mora-mcp.md",
        "Prompts/mora-csv.md": ROOT / "Prompts/mora-csv.md",
        "skills/mora-finance/references/workflow.md": ROOT / "Prompts/mora-mcp.md",
        "bin/MoraBridge": bridge,
        "assets/icon.png": ROOT / "build/Mora.iconset/icon_128x128@2x.png",
        "README.md": ROOT / "plugins/mora/README.md",
    }
    for relative, origin in copies.items():
        target = package / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)
    (package / "runtime.sh").write_text("MORA_PLUGIN_PYTHON=" + shlex.quote(str(python.absolute())) + "\n", encoding="utf-8")
    for relative in ["bin/MoraBridge", "scripts/run-mcp.sh"]:
        (package / relative).chmod(0o755)
    # One contained plugin directory, suitable for local installation/export.
    archive = output / "Mora-ChatGPT.zip"
    allowed = [*copies, "plugin.json", "mcp.json", "scripts/run-mcp.sh", "skills/mora-finance/SKILL.md", "skills/mora-setup/SKILL.md", "runtime.sh"]
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as bundle:
        for relative in sorted(allowed):
            path = package / relative
            if path.is_symlink():
                raise SystemExit("Символические ссылки не входят в архив плагина.")
            bundle.write(path, "mora/" + relative)
    marketplace_path = output / ".agents/plugins/marketplace.json"
    marketplace_path.parent.mkdir(parents=True, exist_ok=True)
    marketplace = {
        "name": "mora-local",
        "interface": {"displayName": "Mora на этом Mac"},
        "plugins": [{"name": "mora", "source": {"source": "local", "path": "./mora"},
                     "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"}, "category": "Finance"}],
    }
    if marketplace_path.exists():
        existing = json.loads(marketplace_path.read_text(encoding="utf-8"))
        if existing.get("name") != marketplace["name"]:
            raise SystemExit("В выходном каталоге уже существует другой marketplace; выберите --output.")
        other = [p for p in existing.get("plugins", []) if p.get("name") != "mora"]
        marketplace["plugins"] = other + marketplace["plugins"]
    marketplace_path.write_text(json.dumps(marketplace, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"package": str(package), "archive": str(archive), "bytes": archive.stat().st_size}, ensure_ascii=False))
    return package


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/ChatGPTPlugin")
    parser.add_argument("--python", type=Path, default=ROOT / ".venv/bin/python")
    parser.add_argument("--bridge", type=Path, default=ROOT / "build/Mora.app/Contents/MacOS/MoraBridge")
    arguments = parser.parse_args()
    build(arguments.output.absolute(), arguments.python, arguments.bridge)
