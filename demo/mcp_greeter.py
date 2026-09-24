"""Minimal local MCP stdio demo; Python standard library only."""
import json
import sys

for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:  # Notifications have no response.
        continue
    method = request.get("method")
    error = None
    if method == "initialize":
        result = {
            "protocolVersion": request["params"]["protocolVersion"],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "demo-greeter", "version": "1.0.0"},
        }
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [{
            "name": "greet",
            "description": "Return a friendly greeting from a local MCP server.",
            "inputSchema": {
                "type": "object",
                "properties": {"name": {"type": "string"}},
                "required": ["name"],
                "additionalProperties": False,
            },
        }]}
    elif method == "tools/call":
        params = request.get("params", {})
        name = params.get("arguments", {}).get("name")
        if params.get("name") != "greet" or not isinstance(name, str):
            error = {"code": -32602, "message": "Expected greet with a string name"}
        else:
            result = {"content": [{"type": "text", "text": f"Hello, {name}! This reply came from a separate MCP server process."}]}
    else:
        error = {"code": -32601, "message": "Method not found"}
    response = {"jsonrpc": "2.0", "id": request["id"]}
    response.update({"error": error} if error else {"result": result})
    print(json.dumps(response), flush=True)
