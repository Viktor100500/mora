"""Exercise Mora through the official MCP client, using disposable data only."""
from __future__ import annotations
import asyncio
import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import httpx
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from mcp.client.streamable_http import streamable_http_client

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / ".build/debug/MoraBridge"


async def successful(session: ClientSession, name: str, args: dict) -> dict:
    result = await session.call_tool(name, args)
    assert not result.isError, (name, result.content)
    return result.structuredContent


async def exercise_stdio(directory: Path) -> None:
    parameters = StdioServerParameters(command=sys.executable, args=[str(ROOT / "mcp/server.py"), "--bridge", str(BRIDGE), "--data-dir", str(directory)])
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            initialized = await session.initialize()
            assert initialized.serverInfo.name == "Mora"
            listing = await session.list_tools()
            assert len(listing.tools) == 11
            assert all(t.inputSchema.get("type") == "object" for t in listing.tools)
            resources = await session.list_resources()
            assert {str(r.uri) for r in resources.resources} == {"mora://context", "mora://csv-format"}
            assert (await session.get_prompt("mora_finance_assistant")).messages
            context = await successful(session, "mora_context", {})
            assert context["accounts"] == []
            account = {"name": "Test bank, Test", "currency": "RSD", "opening_balance": "1000"}
            await successful(session, "mora_create_account", account)
            repeated = await successful(session, "mora_create_account", account)
            assert repeated["status"] == "already_exists"
            await successful(session, "mora_create_account", {"name": "Test EUR", "currency": "EUR", "opening_balance": "20"})
            entry = {"date": context["today"], "merchant": 'Кофе, "утро"', "amount": "-125.50", "currency": "RSD", "account": "Test bank, Test", "type": "expense", "category": "Кафе и рестораны"}
            args = {"request_id": "stdio-batch", "entries": [entry, entry]}
            preview = await successful(session, "mora_preview_entries", args)
            assert not preview["saved"] and preview["imported"] == 2
            before = await successful(session, "mora_list_entries", {})
            assert before["total"] == 0
            written = await successful(session, "mora_add_entries", args)
            assert written["saved"] and written["imported"] == 2
            repeated = await successful(session, "mora_add_entries", args)
            assert repeated["imported"] == 0 and repeated["duplicates"] == 2
            changed = dict(entry, amount="-99")
            failed = await session.call_tool("mora_add_entries", {"request_id": "stdio-batch", "entries": [changed]})
            assert failed.isError
            invalid = dict(entry, currency="ZZZ")
            failed = await session.call_tool("mora_add_entries", {"request_id": "bad-batch", "entries": [entry, invalid]})
            assert failed.isError
            listed = await successful(session, "mora_list_entries", {})
            assert listed["total"] == 2 and listed["entries"][0]["amount"] == "-125.5"
            await successful(session, "mora_set_budget", {"category": "Продукты", "limit": "12000"})
            await successful(session, "mora_create_goal", {"request_id": "goal-1", "name": "Отпуск", "target": "100000", "saved": "0", "deadline": "2027-05-01"})
            await successful(session, "mora_create_recurring", {"request_id": "rent-1", "name": "Аренда", "amount": "400", "account": "Test EUR", "frequency": "monthly", "next_date": "2026-10-31", "category": "Дом"})
            resource = await session.read_resource("mora://context")
            assert "Test bank, Test" in resource.contents[0].text
            assert (await successful(session, "mora_monthly_summary", {"month": context["today"][:7]}))["rates_missing"] == ["EUR", "RSD"]
            numeric = dict(entry, amount=42)
            assert (await session.call_tool("mora_add_entries", {"request_id": "not-string", "entries": [numeric]})).isError
    # A read-only server rejects writes even when a client calls them directly.
    parameters.args += ["--read-only"]
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            assert (await successful(session, "mora_list_entries", {}))["total"] == 2
            assert (await session.call_tool("mora_create_account", {"name": "Forbidden", "currency": "USD", "opening_balance": "0"})).isError


async def exercise_http(directory: Path) -> None:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    token = "test-only-" + "x" * 48
    token_file = directory / "http-token"
    token_file.write_text(token)
    token_file.chmod(0o600)
    argv = [sys.executable, str(ROOT / "mcp/server.py"), "--transport", "streamable-http", "--bridge", str(BRIDGE), "--data-dir", str(directory), "--port", str(port), "--token-file", str(token_file)]
    with tempfile.TemporaryFile() as logs:
        process = subprocess.Popen(argv, stdout=logs, stderr=logs)
        try:
            url = f"http://127.0.0.1:{port}/mcp"
            async with httpx.AsyncClient(timeout=2) as client:
                for _ in range(60):
                    try:
                        response = await client.post(url, json={})
                        if response.status_code == 401:
                            break
                    except httpx.ConnectError:
                        pass
                    if process.poll() is not None:
                        raise AssertionError("HTTP server exited")
                    await asyncio.sleep(0.1)
                else:
                    raise AssertionError("HTTP server did not start")
                assert (await client.post(url, json={}, headers={"Authorization": "Bearer incorrect"})).status_code == 401
                malicious = {"Authorization": "Bearer " + token, "Origin": "https://untrusted.example"}
                assert (await client.post(url, json={}, headers=malicious)).status_code == 403
                assert (await client.post(url, json={}, headers={"Authorization": "Bearer " + token, "Host": "untrusted.example"})).status_code == 421
            async with httpx.AsyncClient(headers={"Authorization": "Bearer " + token}) as client:
                async with streamable_http_client(url, http_client=client) as streams:
                    async with ClientSession(streams[0], streams[1]) as session:
                        await session.initialize()
                        assert len((await session.list_tools()).tools) == 11
                        context = await successful(session, "mora_context", {})
                        assert len(context["accounts"]) == 2
                        account = await successful(session, "mora_create_account", {"name": "HTTP USD", "currency": "USD", "opening_balance": "10"})
                        assert account["status"] == "created"
        finally:
            process.terminate()
            process.wait(timeout=10)


async def main() -> None:
    with tempfile.TemporaryDirectory(prefix="MoraMCPTests-") as folder:
        directory = Path(folder)
        await exercise_stdio(directory)
        print("stdio: tools, schemas, prompts, resources, money precision, writes, retries, atomic errors and read-only mode passed")
        await exercise_http(directory)
        print("Streamable HTTP: authenticated handshake, tools, writes and unauthorized/origin/host rejection passed")


if __name__ == "__main__":
    asyncio.run(main())
