import sys
import types

from flow.config import CommandCfg
from flow.models.command import CommandLLM


class FakeTokenizer:
    def apply_chat_template(self, messages, tokenize=False, add_generation_prompt=True):
        assert tokenize is False
        assert add_generation_prompt is True
        assert messages[-1]["content"].startswith("Instruction:")
        return "PROMPT"


def test_command_llm_uses_sampler_not_removed_temp_kwarg(monkeypatch) -> None:
    mlx_lm = types.ModuleType("mlx_lm")
    sample_utils = types.ModuleType("mlx_lm.sample_utils")
    calls = {}

    def fake_load(model_id):
        return "model", FakeTokenizer()

    def fake_make_sampler(temp=0.0):
        calls["sampler_temp"] = temp
        return "sampler"

    def fake_generate(model, tokenizer, *, prompt, max_tokens, sampler, verbose):
        calls.update(
            {
                "model": model,
                "tokenizer": tokenizer,
                "prompt": prompt,
                "max_tokens": max_tokens,
                "sampler": sampler,
                "verbose": verbose,
            }
        )
        return " Rewritten text. "

    mlx_lm.load = fake_load
    mlx_lm.generate = fake_generate
    sample_utils.make_sampler = fake_make_sampler
    monkeypatch.setitem(sys.modules, "mlx_lm", mlx_lm)
    monkeypatch.setitem(sys.modules, "mlx_lm.sample_utils", sample_utils)

    llm = CommandLLM(CommandCfg(enabled=True, model="stub", max_tokens=12))

    assert llm.run("rewrite", "hello") == "Rewritten text."
    assert calls == {
        "sampler_temp": 0.3,
        "model": "model",
        "tokenizer": llm._tokenizer,
        "prompt": "PROMPT",
        "max_tokens": 12,
        "sampler": "sampler",
        "verbose": False,
    }
