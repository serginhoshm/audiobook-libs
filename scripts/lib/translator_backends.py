from __future__ import annotations

from dataclasses import dataclass, field
import json
import random
import time
from typing import Dict, List
from urllib import parse as urlparse
from urllib import request as urlrequest

from deep_translator import GoogleTranslator


@dataclass
class TranslationResult:
    text: str
    backend: str
    latency_ms: int
    retries: int
    warnings: List[str] = field(default_factory=list)
    raw_meta: Dict[str, object] = field(default_factory=dict)


class BackendError(RuntimeError):
    pass


class DeepTranslatorBackend:
    name = "deep_translator"

    def translate(self, text: str, src: str, tgt: str, context: Dict[str, object]) -> str:
        source = src if src and src != "auto" else "auto"
        translator = GoogleTranslator(source=source, target=tgt)
        return translator.translate(text)


class GoogleSimpleBackend:
    name = "google_simple"

    def __init__(self, timeout_seconds: int = 20):
        self.timeout_seconds = timeout_seconds

    def translate(self, text: str, src: str, tgt: str, context: Dict[str, object]) -> str:
        source = src if src and src != "auto" else "auto"
        query = {
            "client": "gtx",
            "sl": source,
            "tl": tgt,
            "dt": "t",
            "q": text,
        }
        url = "https://translate.googleapis.com/translate_a/single?" + urlparse.urlencode(query)
        req = urlrequest.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urlrequest.urlopen(req, timeout=self.timeout_seconds) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))

        if not payload or not isinstance(payload, list) or not payload[0]:
            raise BackendError("google_simple returned empty payload")

        translated_parts = []
        for part in payload[0]:
            if isinstance(part, list) and part:
                translated_parts.append(str(part[0]))
        return "".join(translated_parts).strip()


class OllamaBackend:
    name = "ollama_local"

    def __init__(self, host: str, model: str, timeout_seconds: int = 45):
        self.host = host.rstrip("/")
        self.model = model
        self.timeout_seconds = timeout_seconds

    def translate(self, text: str, src: str, tgt: str, context: Dict[str, object]) -> str:
        prompt = (
            "Translate the following subtitle text. Preserve meaning and punctuation. "
            "Return only the translated text, no explanations.\n\n"
            f"Source language: {src}. Target language: {tgt}.\n"
            "Text:\n"
            f"{text}"
        )
        body = {
            "model": self.model,
            "prompt": prompt,
            "stream": False,
            "options": {"temperature": 0.1},
        }
        req = urlrequest.Request(
            f"{self.host}/api/generate",
            data=json.dumps(body).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlrequest.urlopen(req, timeout=self.timeout_seconds) as resp:
            payload = json.loads(resp.read().decode("utf-8", errors="replace"))

        response = str(payload.get("response", "")).strip()
        if not response:
            raise BackendError("ollama returned empty response")
        return response


@dataclass
class OrchestratorConfig:
    retries_per_backend: int = 3
    backoff_base_seconds: float = 1.0
    jitter: float = 0.2
    online_circuit_failures: int = 4


class TranslationOrchestrator:
    def __init__(self, config: OrchestratorConfig, backends: List[object]):
        self.config = config
        self.backends = backends
        self.fail_streak: Dict[str, int] = {backend.name: 0 for backend in backends}

    def _sleep_backoff(self, attempt_index: int) -> None:
        delay = self.config.backoff_base_seconds * (2 ** attempt_index)
        jitter = random.uniform(0.0, self.config.jitter)
        time.sleep(delay + jitter)

    def _is_online_backend(self, backend_name: str) -> bool:
        return backend_name in {"deep_translator", "google_simple"}

    def _skip_by_circuit(self, backend_name: str) -> bool:
        if not self._is_online_backend(backend_name):
            return False
        return self.fail_streak.get(backend_name, 0) >= self.config.online_circuit_failures

    def translate(self, text: str, src: str, tgt: str, context: Dict[str, object]) -> TranslationResult:
        errors: List[str] = []
        for backend in self.backends:
            if self._skip_by_circuit(backend.name):
                errors.append(f"{backend.name}:circuit-open")
                continue

            for attempt in range(self.config.retries_per_backend):
                started = time.perf_counter()
                try:
                    translated = backend.translate(text=text, src=src, tgt=tgt, context=context)
                    latency_ms = int((time.perf_counter() - started) * 1000)
                    self.fail_streak[backend.name] = 0
                    return TranslationResult(
                        text=translated,
                        backend=backend.name,
                        latency_ms=latency_ms,
                        retries=attempt,
                        raw_meta={"attempt": attempt + 1},
                    )
                except Exception as exc:
                    self.fail_streak[backend.name] = self.fail_streak.get(backend.name, 0) + 1
                    errors.append(f"{backend.name}:attempt{attempt + 1}:{exc}")
                    if attempt + 1 < self.config.retries_per_backend:
                        self._sleep_backoff(attempt)

        raise BackendError("All backends failed: " + " | ".join(errors))
