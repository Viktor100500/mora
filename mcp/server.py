"""Mora MCP: standard stdio and authenticated loopback Streamable HTTP."""
from __future__ import annotations

import argparse
import hmac
import json
import os
import secrets
import subprocess
from pathlib import Path
from typing import Annotated, Any, Literal

import anyio
import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from pydantic import BaseModel, ConfigDict, Field

ROOT = Path(__file__).resolve().parent.parent
Money = Annotated[str, Field(pattern=r"^-?[0-9]+(?:\.[0-9]+)?$", max_length=80)]
ISODate = Annotated[str, Field(pattern=r"^\d{4}-\d{2}-\d{2}$")]
Name = Annotated[str, Field(min_length=1, max_length=256)]
RequestID = Annotated[str, Field(min_length=1, max_length=128)]
READ = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)
WRITE = ToolAnnotations(readOnlyHint=False, destructiveHint=False, idempotentHint=True, openWorldHint=False)


class Entry(BaseModel):
    model_config = ConfigDict(extra="forbid")
    date: ISODate
    merchant: Annotated[str, Field(min_length=1, max_length=400)]
    amount: Money
    currency: Annotated[str, Field(pattern=r"^[A-Z]{3}$", description="Original transaction currency. For expenses/income Mora automatically converts to the user-selected account currency using Visa on the transaction date. Do not preconvert.")]
    account: Annotated[Name, Field(description="Exact existing account explicitly selected or confirmed by the user for these operations. If unknown, ask even when only one account matches the currency. Never infer from currency or unconfirmed card digits.")]
    type: Literal["expense", "income", "transfer"]
    category: str = ""
    note: Annotated[str, Field(max_length=16_000)] = ""
    tags: Annotated[list[str], Field(max_length=30)] = Field(default_factory=list)
    id: str = ""
    to_account: Annotated[str, Field(description="For transfers, the destination account must also be explicitly selected or confirmed by the user.")] = ""
    to_amount: str = ""


def create_server(bridge_path: Path, data_dir: Path | None = None, port: int = 8765, read_only: bool = False) -> FastMCP:
    mcp = FastMCP(
        "Mora",
        instructions=(ROOT / "Prompts/mora-mcp.md").read_text(encoding="utf-8"),
        host="127.0.0.1", port=port, json_response=True, stateless_http=True,
        max_request_body_size=3_000_000,
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=[f"127.0.0.1:{port}", f"localhost:{port}"],
            allowed_origins=[f"http://127.0.0.1:{port}", f"http://localhost:{port}"],
        ),
    )

    def invoke(command: str, arguments: dict[str, Any]) -> dict[str, Any]:
        if read_only and command not in {"context", "preview_entries", "monthly_summary", "list_entries"}:
            if command not in {"import_csv", "reassign_entries"} or not arguments.get("dry_run", True):
                raise ToolError("Этот сервер запущен в режиме только чтения.")
        payload = json.dumps({"command": command, "arguments": arguments}, ensure_ascii=False)
        if len(payload.encode("utf-8")) > 3_000_000:
            raise ToolError("Запрос слишком большой. Разделите его на несколько пакетов.")
        argv = [str(bridge_path)]
        if data_dir is not None:
            argv += ["--data-dir", str(data_dir)]
        try:
            process = subprocess.run(argv, input=payload, capture_output=True, text=True, timeout=180, check=False)
            response = json.loads(process.stdout)
        except subprocess.TimeoutExpired as exc:
            raise ToolError("Время ожидания истекло. Повторите с тем же request_id, чтобы не создать дубликаты.") from exc
        except (OSError, ValueError) as exc:
            raise ToolError("Не удалось запустить компонент MoraBridge. Проверьте сборку и путь в конфигурации MCP.") from exc
        if not response.get("ok"):
            raise ToolError(response.get("error", "Не удалось выполнить действие в Mora."))
        return response["result"]

    async def call(command: str, arguments: dict[str, Any]) -> dict[str, Any]:
        return await anyio.to_thread.run_sync(invoke, command, arguments)

    @mcp.tool(annotations=READ)
    async def mora_context() -> dict[str, Any]:
        """Read today's local date, exact account names/currencies/conversion_fee_percent, categories, budgets, goals and recurring payments. Call before writes. Account availability is not user selection: ask for an unknown account even if only one matches the currency."""
        return await call("context", {})

    @mcp.tool(annotations=READ)
    async def mora_preview_entries(
        request_id: RequestID,
        entries: Annotated[list[Entry], Field(min_length=1, max_length=1000)],
        allow_new_categories: bool = False,
    ) -> dict[str, Any]:
        """Validate a batch without saving. Supply original amounts and currencies; Mora automatically fetches Visa rates for expenses/income in another account currency. First obtain the user's explicit account selection for these operations, including transfer destinations; ask even if only one account matches the currency. Silence or category/date answers do not confirm an account. Money must be strings, expense/transfer negative, income positive. Unknown accounts are rejected. Keep request_id and order identical when committing."""
        return await call("preview_entries", {"request_id": request_id, "entries": [e.model_dump() for e in entries], "allow_new_categories": allow_new_categories})

    @mcp.tool(annotations=WRITE)
    async def mora_add_entries(
        request_id: RequestID,
        entries: Annotated[list[Entry], Field(min_length=1, max_length=1000)],
        allow_new_categories: bool = False,
    ) -> dict[str, Any]:
        """Atomically record explicitly requested operations in Mora only after the user explicitly selects or confirms every account for these operations, including transfer destinations. Supply original amounts/currencies; Mora automatically converts expenses/income with Visa, adds the selected account conversion fee to foreign-currency expenses (do not add it yourself), and records the batch in import history. Ask for an unknown account even if only one matches the currency; silence or category/date answers do not confirm it. A failed row saves nothing. Reuse request_id for retries of the same batch; use a new request_id for a new purchase. Never performs bank payments."""
        return await call("add_entries", {"request_id": request_id, "entries": [e.model_dump() for e in entries], "allow_new_categories": allow_new_categories})

    @mcp.tool(annotations=WRITE)
    async def mora_reassign_entries(
        request_id: RequestID,
        transaction_ids: Annotated[list[str], Field(min_length=1, max_length=1000)],
        expected_account: Name,
        account: Name,
        dry_run: bool = True,
    ) -> dict[str, Any]:
        """Correct existing expense/income entries to an account explicitly selected by the user. Supply their internal UUIDs and expected current account. Mora automatically converts original amounts using Visa; preserves IDs, categories and notes, and attaches untracked entries to import history. First dry_run=true, then false. Atomic; stale or missing entries fail. Does not transfer bank funds."""
        return await call("reassign_entries", {"request_id": request_id, "transaction_ids": transaction_ids, "expected_account": expected_account, "account": account, "dry_run": dry_run})

    @mcp.tool(annotations=WRITE)
    async def mora_create_account(
        name: Name, currency: Annotated[str, Field(pattern=r"^[A-Z]{3}$")],
        opening_balance: Money,
        kind: Literal["checking", "savings", "cash", "investment", "credit"] = "checking",
    ) -> dict[str, Any]:
        """Create a bookkeeping account only when requested. Ask for unknown currency and opening balance. Exact retries return the same account; conflicting names fail. Does not open a bank account."""
        return await call("create_account", {"name": name, "currency": currency, "opening_balance": opening_balance, "kind": kind})

    @mcp.tool(annotations=WRITE)
    async def mora_import_csv(
        csv: Annotated[str, Field(min_length=1, max_length=2_000_000)],
        dry_run: bool = True, allow_new_categories: bool = False,
    ) -> dict[str, Any]:
        """Import standard 12-column Mora CSV. First obtain the user's explicit account selection for every row and transfer destination; ask for an unknown account even if only one matches the currency. Supply original currencies/amounts; Mora automatically converts expenses/income with Visa. Then use dry_run=true, followed by false to save. Accounts must already exist; unknown categories require explicit permission. Atomic and deduplicated."""
        return await call("import_csv", {"csv": csv, "dry_run": dry_run, "allow_new_categories": allow_new_categories})

    @mcp.tool(annotations=READ)
    async def mora_list_entries(
        from_date: str = "", to_date: str = "", account: str = "",
        limit: Annotated[int, Field(ge=1, le=200)] = 100,
    ) -> dict[str, Any]:
        """Read up to 200 transactions with optional inclusive ISO date range and account-name filter. Amounts are strings in account currencies; converted entries also include original purchase amounts/currencies and the Visa rate."""
        return await call("list_entries", {"from_date": from_date, "to_date": to_date, "account": account, "limit": limit})

    @mcp.tool(annotations=READ)
    async def mora_monthly_summary(month: Annotated[str, Field(pattern=r"^\d{4}-\d{2}$")]) -> dict[str, Any]:
        """Read income, spending and net for YYYY-MM in the base currency. Transfers are excluded; currencies with missing rates are reported."""
        return await call("monthly_summary", {"month": month})

    @mcp.tool(annotations=ToolAnnotations(readOnlyHint=False, destructiveHint=True, idempotentHint=True, openWorldHint=False))
    async def mora_set_budget(category: Name, limit: Money) -> dict[str, Any]:
        """Set the monthly spending limit for an existing expense category when requested. Amount is a positive string in the current base currency; updates an existing limit."""
        return await call("set_budget", {"category": category, "limit": limit})

    @mcp.tool(annotations=WRITE)
    async def mora_create_goal(request_id: RequestID, name: Name, target: Money, saved: Money, deadline: ISODate) -> dict[str, Any]:
        """Create a savings goal when requested. Target and saved are base-currency amounts, target positive and saved nonnegative. Reuse request_id on retries."""
        return await call("create_goal", {"request_id": request_id, "name": name, "target": target, "saved": saved, "deadline": deadline})

    @mcp.tool(annotations=WRITE)
    async def mora_create_recurring(
        request_id: RequestID, name: Name, amount: Money, account: Name,
        frequency: Literal["weekly", "monthly", "yearly"], next_date: ISODate, category: str = "",
    ) -> dict[str, Any]:
        """Create a recurring expense schedule when requested, only for an account explicitly selected or confirmed by the user. Ask for an unknown account even if only one matches the currency. Positive amount in the account currency; no immediate transaction or real payment is created. Reuse request_id on retries."""
        return await call("create_recurring", {"request_id": request_id, "name": name, "amount": amount, "account": account, "frequency": frequency, "next_date": next_date, "category": category})

    @mcp.resource("mora://context", mime_type="application/json")
    async def current_context() -> str:
        return json.dumps(await call("context", {}), ensure_ascii=False)

    @mcp.resource("mora://csv-format", mime_type="text/plain")
    def csv_format() -> str:
        return (ROOT / "Prompts/mora-csv.md").read_text(encoding="utf-8")

    @mcp.prompt()
    def mora_finance_assistant() -> str:
        """Instructions for translating natural-language finance requests into verified Mora tool calls."""
        return (ROOT / "Prompts/mora-mcp.md").read_text(encoding="utf-8")

    return mcp


class BearerMiddleware:
    def __init__(self, app: Any, token: str):
        self.app, self.token = app, token

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] == "http":
            headers = dict(scope.get("headers", []))
            supplied = headers.get(b"authorization", b"").decode("latin-1")
            if not hmac.compare_digest(supplied, "Bearer " + self.token):
                await send({"type": "http.response.start", "status": 401, "headers": [(b"www-authenticate", b'Bearer realm="Mora"'), (b"content-type", b"application/json")]})
                await send({"type": "http.response.body", "body": b'{"error":"unauthorized"}'})
                return
        await self.app(scope, receive, send)


def token_from_file(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise SystemExit("Файл токена должен иметь права 0600 и не быть символической ссылкой.")
    else:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(secrets.token_urlsafe(32))
    token = path.read_text(encoding="utf-8").strip()
    if len(token) < 32 or not token.isascii():
        raise SystemExit("Нужен непустой случайный токен не короче 32 ASCII-символов.")
    return token


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--transport", choices=["stdio", "streamable-http"], default="stdio")
    parser.add_argument("--bridge", type=Path)
    parser.add_argument("--data-dir", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--token-file", type=Path)
    parser.add_argument("--read-only", action="store_true")
    args = parser.parse_args()
    candidates = [ROOT / "build/Mora.app/Contents/MacOS/MoraBridge", ROOT.parent / "MacOS/MoraBridge", ROOT / ".build/debug/MoraBridge"]
    bridge = args.bridge or next((p for p in candidates if p.is_file()), candidates[0])
    if not bridge.is_file():
        parser.error("Сначала соберите Mora: zsh scripts/build-app.sh")
    if not 1 <= args.port <= 65535:
        parser.error("Некорректный порт.")
    server = create_server(bridge.resolve(), args.data_dir, args.port, args.read_only)
    if args.transport == "stdio":
        server.run(transport="stdio")
    else:
        token_file = args.token_file or (args.data_dir or Path.home() / "Library/Application Support/Mora") / "mcp-http-token"
        token = token_from_file(token_file)
        uvicorn.run(BearerMiddleware(server.streamable_http_app(), token), host="127.0.0.1", port=args.port, access_log=False)


if __name__ == "__main__":
    main()
