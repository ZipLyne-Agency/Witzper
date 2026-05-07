from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_run_command_closes_stream_server_on_shutdown() -> None:
    source = (ROOT / "flow" / "__main__.py").read_text()
    run_body = source.split("def run(", maxsplit=1)[1]
    run_body = run_body.split('@app.command("dict")', maxsplit=1)[0]

    assert "stream._server.close()" in run_body
    assert "stream._server = None" in run_body
