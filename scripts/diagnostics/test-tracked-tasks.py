"""Run the installed reporter and reader against one isolated local batch job."""
import argparse
import json
import pathlib
import subprocess
import tempfile
import uuid


def check(executable):
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        registry = root / "registry"
        source = root / "status.json"
        run = str(uuid.uuid4())
        thread = str(uuid.uuid4())
        options = ["--store", str(registry)]
        args = {"run_id": run, "title": "PDF batch", "status_file": str(source)}

        def rpc(method, params):
            request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}
            output = subprocess.run([executable, "--tracked-tasks-mcp", *options],
                                    input=json.dumps(request) + "\n", text=True, capture_output=True,
                                    check=True, timeout=10)
            return json.loads(output.stdout)["result"]

        def rows():
            return json.loads(subprocess.check_output([executable, "--tracked-tasks-snapshot", *options],
                                                      text=True, timeout=10))

        assert {t["name"] for t in rpc("tools/list", {})["tools"]} == {"track_task", "untrack_task"}
        assert rpc("initialize", {})["capabilities"] == {"tools": {}}
        metadata = {"threadId": thread, "x-codex-turn-metadata": {"thread_id": thread}}
        call = {"name": "track_task", "arguments": args, "_meta": metadata}
        assert not rpc("tools/call", call)["isError"]
        assert not rpc("tools/call", call)["isError"]
        assert rows()[0]["state"] == "pending"
        # The registrar has exited. The worker alone publishes the observations.
        for state, succeeded in [("running", 340), ("completed", 998)]:
            shadow = source.with_suffix(".tmp")
            shadow.write_text(json.dumps(dict(run_id=run, state=state, succeeded=succeeded,
                                              failed=2, total=1000)), encoding="utf-8")
            shadow.replace(source)
            row, = rows()
            assert (row["state"], row["succeeded"], row["failed"]) == (state, succeeded, 2)
            assert row["hasOrigin"]
            source.unlink()
            assert rows()[0]["succeeded"] == succeeded
        assert not rpc("tools/call", {"name": "untrack_task", "arguments": {"run_id": run}})["isError"]
        assert rows() == []


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable")
    check(parser.parse_args().executable)
    print("Tracked task MCP, worker updates, restart recovery and terminal counts passed.")

