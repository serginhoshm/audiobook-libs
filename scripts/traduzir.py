#!/usr/bin/env python3

import argparse
import configparser
from datetime import datetime, timezone
import json
import os
import re
import signal
import subprocess
import sys
import time
from pathlib import Path
from urllib import error as urlerror
from urllib import parse as urlparse
from urllib import request as urlrequest

from deep_translator import GoogleTranslator
import pysrt
from tqdm import tqdm


DEFAULT_BLOCK_MAX_LINES = 20
DEFAULT_BLOCK_MAX_CHARS = 3500
TRANSLATION_MEMORY_SUFFIX = ".translation-memory.json"
MARKER_TEMPLATE = "[[SRT-{index:04d}]]"
DEFAULT_BACKEND = "libretranslate"
DEFAULT_GEMINI_MODEL = "gemini-1.5-flash"
DEFAULT_NLLB_MODEL_DIR = "models/nllb/facebook-nllb-200-distilled-600M"
DEFAULT_ZH_CALIBRATION_DIR = "config/translation/zh"
DEFAULT_ZH_GLOSSARY_LIMIT = 500
DEFAULT_DEEPL_KEYS_INI = "config/translation/deepl_keys.ini"
DEFAULT_DEEPL_KEYS_STATE_INI = "config/translation/deepl_keys_state.ini"
DEFAULT_DEEPL_ENDPOINT = "free"
DEFAULT_DEEPL_USAGE_TIMEOUT_SECONDS = 12
DEEPL_FREE_BASE_URL = "https://api-free.deepl.com/v2"
DEEPL_PRO_BASE_URL = "https://api.deepl.com/v2"
DEFAULT_NLLB_MAX_INPUT_LENGTH = 768
DEFAULT_NLLB_MAX_NEW_TOKENS = 192
DEFAULT_NLLB_LEGACY_GENERATION = os.getenv("NLLB_LEGACY_GENERATION", "0") == "1"
DEFAULT_LIBRETRANSLATE_URL = "http://127.0.0.1:5000"
DEFAULT_LIBRETRANSLATE_TARGET_LANG = "pt"
DEFAULT_LIBRETRANSLATE_TIMEOUT_SECONDS = 30
DEFAULT_LIBRETRANSLATE_START_TIMEOUT_SECONDS = 60
DEFAULT_LIBRETRANSLATE_LOAD_ONLY_LANG_CODES = "en,es,zh,pt"
DEFAULT_MAX_UNTRANSLATED_RATIO = 0.10
DEFAULT_MAX_UNTRANSLATED_LINES = 6
DEFAULT_ZH_MAX_UNTRANSLATED_RATIO = 0.05
DEFAULT_ZH_MAX_UNTRANSLATED_LINES = 3
CALIBRATION_PROFILE_FILE = "calibration_profile.json"
CALIBRATION_STATE_FILE = "calibration_state.json"
GLOSSARY_FILE = "glossary.json"
LOCAL_KNOWLEDGE_FILE = "local_knowledge.json"
DETECTION_SAMPLE_MAX_CHARS = 100
DETECTION_TIMEOUT_SECONDS = 8

SOURCE_LANG_ALIASES = {
    "auto": "auto",
    "unknown": "auto",
    "desconhecido": "auto",
    "ar": "ar",
    "arb_arab": "ar",
    "de": "de",
    "deu_latn": "de",
    "en": "en",
    "eng_latn": "en",
    "es": "es",
    "es-es": "es",
    "spa_latn": "es",
    "fr": "fr",
    "fra_latn": "fr",
    "hi": "hi",
    "hin_deva": "hi",
    "it": "it",
    "ita_latn": "it",
    "ja": "ja",
    "jpn_jpan": "ja",
    "ko": "ko",
    "kor_hang": "ko",
    "nl": "nl",
    "nld_latn": "nl",
    "pl": "pl",
    "pol_latn": "pl",
    "pt": "pt",
    "por_latn": "pt",
    "ru": "ru",
    "rus_cyrl": "ru",
    "tr": "tr",
    "tur_latn": "tr",
    "uk": "uk",
    "ukr_cyrl": "uk",
    "zh": "zh-cn",
    "zh-cn": "zh-cn",
    "zh_hans": "zh-cn",
    "zho_hans": "zh-cn",
}

SOURCE_LANG_NORMALIZED_MAP = {
    "auto": "auto",
    "ar": "ar",
    "de": "de",
    "en": "en",
    "es": "es",
    "fr": "fr",
    "hi": "hi",
    "it": "it",
    "ja": "ja",
    "ko": "ko",
    "nl": "nl",
    "pl": "pl",
    "pt": "pt",
    "ru": "ru",
    "tr": "tr",
    "uk": "uk",
    "zh-cn": "zh-CN",
}

NLLB_SOURCE_LANG_MAP = {
    "ar": "arb_Arab",
    "de": "deu_Latn",
    "en": "eng_Latn",
    "es": "spa_Latn",
    "fr": "fra_Latn",
    "hi": "hin_Deva",
    "it": "ita_Latn",
    "ja": "jpn_Jpan",
    "ko": "kor_Hang",
    "nl": "nld_Latn",
    "pl": "pol_Latn",
    "pt": "por_Latn",
    "ru": "rus_Cyrl",
    "tr": "tur_Latn",
    "uk": "ukr_Cyrl",
    "zh-cn": "zho_Hans",
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Translate an SRT file to Brazilian Portuguese."
    )
    parser.add_argument("input_srt", type=Path, help="Input SRT file.")
    parser.add_argument("output_srt", type=Path, help="Translated output SRT file.")
    parser.add_argument(
        "source_lang",
        nargs="?",
        default="auto",
        help="Source language (for example: es, zh-CN, auto).",
    )
    parser.add_argument(
        "--block-max-lines",
        type=int,
        default=DEFAULT_BLOCK_MAX_LINES,
        help="Maximum number of subtitles per context block.",
    )
    parser.add_argument(
        "--block-max-chars",
        type=int,
        default=DEFAULT_BLOCK_MAX_CHARS,
        help="Approximate maximum number of characters per context block.",
    )
    parser.add_argument(
        "--backend",
        choices=["libretranslate", "google", "nllb_local", "gemini", "deepl_doc"],
        default=os.getenv("TRANSLATION_BACKEND", DEFAULT_BACKEND),
        help="Translation backend: libretranslate (default), google, nllb_local (offline), gemini (Google API), or deepl_doc.",
    )
    parser.add_argument(
        "--deepl-endpoint",
        default=os.getenv("DEEPL_ENDPOINT", DEFAULT_DEEPL_ENDPOINT),
        help="DeepL endpoint profile: free, pro, or a custom base URL.",
    )
    parser.add_argument(
        "--deepl-keys-ini",
        type=Path,
        default=Path(os.getenv("DEEPL_KEYS_INI", DEFAULT_DEEPL_KEYS_INI)),
        help="INI file with DeepL API keys.",
    )
    parser.add_argument(
        "--deepl-keys-state-ini",
        type=Path,
        default=Path(os.getenv("DEEPL_KEYS_STATE_INI", DEFAULT_DEEPL_KEYS_STATE_INI)),
        help="INI file with blocked/exhausted DeepL key state.",
    )
    parser.add_argument(
        "--deepl-reset-keys-state",
        action="store_true",
        help="Reset blocked DeepL key state before starting translation.",
    )
    parser.add_argument(
        "--deepl-usage-timeout-seconds",
        type=int,
        default=int(os.getenv("DEEPL_USAGE_TIMEOUT_SECONDS", str(DEFAULT_DEEPL_USAGE_TIMEOUT_SECONDS))),
        help="Timeout in seconds for DeepL /usage precheck.",
    )
    parser.add_argument(
        "--gemini-model",
        default=os.getenv("GEMINI_MODEL", DEFAULT_GEMINI_MODEL),
        help="Gemini model name used by the gemini backend.",
    )
    parser.add_argument(
        "--nllb-model-dir",
        type=Path,
        default=Path(os.getenv("NLLB_MODEL_DIR", DEFAULT_NLLB_MODEL_DIR)),
        help="Local directory for the offline NLLB model.",
    )
    parser.add_argument(
        "--nllb-max-input-length",
        type=int,
        default=int(os.getenv("NLLB_MAX_INPUT_LENGTH", str(DEFAULT_NLLB_MAX_INPUT_LENGTH))),
        help="Maximum input length for local NLLB.",
    )
    parser.add_argument(
        "--nllb-max-new-tokens",
        type=int,
        default=int(os.getenv("NLLB_MAX_NEW_TOKENS", str(DEFAULT_NLLB_MAX_NEW_TOKENS))),
        help="Maximum new tokens per generation for local NLLB.",
    )
    parser.add_argument(
        "--nllb-legacy-generation",
        action="store_true",
        default=DEFAULT_NLLB_LEGACY_GENERATION,
        help="Use legacy NLLB generation mode (fallback).",
    )
    parser.add_argument(
        "--zh-calibration-dir",
        type=Path,
        default=Path(os.getenv("ZH_CALIBRATION_DIR", DEFAULT_ZH_CALIBRATION_DIR)),
        help="Directory with Chinese calibration profile/glossary.",
    )
    parser.add_argument(
        "--zh-glossary-limit",
        type=int,
        default=int(os.getenv("ZH_GLOSSARY_LIMIT", str(DEFAULT_ZH_GLOSSARY_LIMIT))),
        help="Limit for Chinese adaptive glossary/context entries.",
    )
    parser.add_argument(
        "--libretranslate-url",
        default=os.getenv("LIBRETRANSLATE_URL", DEFAULT_LIBRETRANSLATE_URL),
        help="Base URL for LibreTranslate API.",
    )
    parser.add_argument(
        "--libretranslate-target-lang",
        default=os.getenv("LIBRETRANSLATE_TARGET_LANG", DEFAULT_LIBRETRANSLATE_TARGET_LANG),
        help="Target language code for LibreTranslate.",
    )
    parser.add_argument(
        "--libretranslate-timeout-seconds",
        type=int,
        default=int(os.getenv("LIBRETRANSLATE_TIMEOUT_SECONDS", str(DEFAULT_LIBRETRANSLATE_TIMEOUT_SECONDS))),
        help="HTTP timeout in seconds for LibreTranslate requests.",
    )
    parser.add_argument(
        "--libretranslate-auto-server",
        action=argparse.BooleanOptionalAction,
        default=os.getenv("LIBRETRANSLATE_AUTO_SERVER", "1") == "1",
        help="Automatically start a local LibreTranslate server if the configured URL is offline.",
    )
    parser.add_argument(
        "--libretranslate-start-timeout-seconds",
        type=int,
        default=int(
            os.getenv(
                "LIBRETRANSLATE_START_TIMEOUT_SECONDS",
                str(DEFAULT_LIBRETRANSLATE_START_TIMEOUT_SECONDS),
            )
        ),
        help="Timeout in seconds waiting for local LibreTranslate server startup.",
    )
    parser.add_argument(
        "--libretranslate-load-only-lang-codes",
        default=os.getenv("LIBRETRANSLATE_LOAD_ONLY_LANG_CODES", DEFAULT_LIBRETRANSLATE_LOAD_ONLY_LANG_CODES),
        help="Comma-separated language codes passed to libretranslate --load-only when auto-starting.",
    )
    parser.add_argument(
        "--fail-on-untranslated",
        action=argparse.BooleanOptionalAction,
        default=os.getenv("TRANSLATION_FAIL_ON_UNTRANSLATED", "1") == "1",
        help="Fail the run when too many lines look untranslated in the output SRT.",
    )
    parser.add_argument(
        "--max-untranslated-ratio",
        type=float,
        default=float(os.getenv("TRANSLATION_MAX_UNTRANSLATED_RATIO", str(DEFAULT_MAX_UNTRANSLATED_RATIO))),
        help="Maximum allowed ratio of suspicious untranslated lines before failing.",
    )
    parser.add_argument(
        "--max-untranslated-lines",
        type=int,
        default=int(os.getenv("TRANSLATION_MAX_UNTRANSLATED_LINES", str(DEFAULT_MAX_UNTRANSLATED_LINES))),
        help="Minimum number of suspicious untranslated lines required to fail.",
    )
    parser.add_argument(
        "--zh-max-untranslated-ratio",
        type=float,
        default=float(os.getenv("TRANSLATION_ZH_MAX_UNTRANSLATED_RATIO", str(DEFAULT_ZH_MAX_UNTRANSLATED_RATIO))),
        help="zh-CN specific maximum allowed ratio of suspicious untranslated lines before failing.",
    )
    parser.add_argument(
        "--zh-max-untranslated-lines",
        type=int,
        default=int(os.getenv("TRANSLATION_ZH_MAX_UNTRANSLATED_LINES", str(DEFAULT_ZH_MAX_UNTRANSLATED_LINES))),
        help="zh-CN specific minimum number of suspicious untranslated lines required to fail.",
    )
    return parser.parse_args()


def normalize_text(text):
    return re.sub(r"\s+", " ", (text or "").replace("\r", " ").replace("\n", " ")).strip()


def normalize_source_language(source_lang):
    raw = normalize_text(source_lang).lower().replace("_", "-")
    if not raw:
        raw = "auto"
    key = SOURCE_LANG_ALIASES.get(raw)
    if not key:
        return None, None
    normalized = SOURCE_LANG_NORMALIZED_MAP.get(key, "auto")
    return key, normalized


def build_detection_sample(texts, max_chars=DETECTION_SAMPLE_MAX_CHARS):
    remaining = max(1, int(max_chars))
    parts = []

    for raw_text in texts:
        text = normalize_text(raw_text)
        if not text:
            continue
        chunk = text[:remaining]
        parts.append(chunk)
        remaining -= len(chunk)
        if remaining <= 0:
            break

    return " ".join(parts).strip()[: max(1, int(max_chars))]


def detect_language_with_google(sample_text):
    if not normalize_text(sample_text):
        return None

    query = urlparse.urlencode(
        {
            "client": "gtx",
            "sl": "auto",
            "tl": "pt",
            "dt": "t",
            "q": sample_text,
        }
    )
    endpoint = f"https://translate.googleapis.com/translate_a/single?{query}"
    req = urlrequest.Request(endpoint, headers={"User-Agent": "Mozilla/5.0"}, method="GET")

    try:
        with urlrequest.urlopen(req, timeout=DETECTION_TIMEOUT_SECONDS) as resp:
            payload = resp.read().decode("utf-8", errors="replace")
        data = json.loads(payload)
    except (urlerror.URLError, TimeoutError, json.JSONDecodeError, ValueError):
        return None
    except Exception:
        return None

    if isinstance(data, list) and len(data) >= 3 and isinstance(data[2], str):
        detected = data[2].strip().lower().replace("_", "-")
        return detected or None
    return None


def resolve_source_language_for_translation(source_lang_key, source_lang_normalized, source_texts):
    if source_lang_key != "auto":
        return source_lang_key, source_lang_normalized

    sample_text = build_detection_sample(source_texts)
    if not sample_text:
        print("[translation] detect_language: sample unavailable", flush=True)
        return "auto", "auto"

    detected = detect_language_with_google(sample_text)
    if not detected:
        print("[translation] detect_language: unresolved", flush=True)
        return "auto", "auto"

    detected_key, detected_normalized = normalize_source_language(detected)
    if detected_key in {None, "auto"}:
        primary = detected.split("-")[0]
        detected_key, detected_normalized = normalize_source_language(primary)

    if detected_key in {None, "auto"}:
        print(f"[translation] detect_language: detected={detected} not mapped", flush=True)
        return "auto", "auto"

    print(
        f"[translation] detect_language: detected={detected} resolved_source={detected_key}",
        flush=True,
    )
    return detected_key, detected_normalized


def memory_path_for(output_path, backend, source_lang_key):
    safe_backend = normalize_text(backend).replace(" ", "_") or "backend"
    safe_lang = normalize_text(source_lang_key).replace(" ", "_") or "lang"
    return output_path.parent / f".{output_path.stem}.{safe_backend}.{safe_lang}{TRANSLATION_MEMORY_SUFFIX}"


class BaseTranslator:
    def translate(self, text):
        raise NotImplementedError()


class GoogleBackendTranslator(BaseTranslator):
    def __init__(self, source_lang):
        self.translator = GoogleTranslator(source=source_lang, target="pt")

    def translate(self, text):
        return self.translator.translate(text)


class LocalLibreTranslateServerManager:
    def __init__(self, base_url, start_timeout_seconds=DEFAULT_LIBRETRANSLATE_START_TIMEOUT_SECONDS, load_only_lang_codes=""):
        self.base_url = normalize_text(base_url).rstrip("/")
        self.start_timeout_seconds = max(5, int(start_timeout_seconds))
        self.load_only_lang_codes = normalize_text(load_only_lang_codes)
        self.process = None
        self.started_here = False

    def _project_root(self):
        return Path(__file__).resolve().parents[1]

    def _libretranslate_executable(self):
        root = self._project_root()
        configured = normalize_text(os.getenv("LIBRETRANSLATE_EXECUTABLE", ""))
        if configured:
            return Path(configured)
        return root / "external" / "LibreTranslate" / ".venv" / "bin" / "libretranslate"

    def _is_ready(self):
        try:
            with urlrequest.urlopen(f"{self.base_url}/languages", timeout=2) as resp:
                return int(getattr(resp, "status", 200)) < 400
        except Exception:
            return False

    def ensure_started(self):
        if self._is_ready():
            return

        executable = self._libretranslate_executable()
        if not executable.exists():
            raise RuntimeError(
                f"LibreTranslate executable not found: {executable}. "
                "Run setup/libretranslate/setup_libretranslate.sh first."
            )

        parsed = urlparse.urlparse(self.base_url)
        host = parsed.hostname or "127.0.0.1"
        port = str(parsed.port or 5000)

        cmd = [str(executable), "--host", host, "--port", port]
        if self.load_only_lang_codes:
            cmd.extend(["--load-only", self.load_only_lang_codes])

        self.process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        self.started_here = True

        for _ in range(self.start_timeout_seconds):
            if self._is_ready():
                return
            time.sleep(1)

        self.close()
        raise RuntimeError("LibreTranslate local server did not become ready in time")

    def close(self):
        if not self.process:
            return

        try:
            os.killpg(self.process.pid, signal.SIGTERM)
        except Exception:
            pass

        for _ in range(8):
            if self.process.poll() is not None:
                self.process = None
                return
            time.sleep(0.5)

        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except Exception:
            pass
        self.process = None


class LibreTranslateBackendTranslator(BaseTranslator):
    SOURCE_LANG_MAP = {
        "zh-cn": "zh",
        "es": "es",
        "auto": "auto",
    }

    def __init__(self, source_lang, base_url, target_lang="pt", timeout_seconds=DEFAULT_LIBRETRANSLATE_TIMEOUT_SECONDS):
        self.base_url = normalize_text(base_url).rstrip("/")
        self.target_lang = normalize_text(target_lang).lower() or DEFAULT_LIBRETRANSLATE_TARGET_LANG
        self.timeout_seconds = max(3, int(timeout_seconds))
        source_key = normalize_text(source_lang).lower() or "auto"
        self.source_lang = self.SOURCE_LANG_MAP.get(source_key, "auto")
        self.server_manager = None

    def attach_server_manager(self, server_manager):
        self.server_manager = server_manager

    def _post_json(self, path, payload):
        data = json.dumps(payload).encode("utf-8")
        req = urlrequest.Request(
            f"{self.base_url}{path}",
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urlrequest.urlopen(req, timeout=self.timeout_seconds) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return json.loads(body)

    def translate(self, text):
        normalized = normalize_text(text)
        if not normalized:
            return ""

        payload = {
            "q": normalized,
            "source": self.source_lang,
            "target": self.target_lang,
            "format": "text",
        }

        try:
            response = self._post_json("/translate", payload)
        except urlerror.HTTPError as exc:
            if self.source_lang != "auto":
                payload["source"] = "auto"
                response = self._post_json("/translate", payload)
            else:
                raise RuntimeError(f"LibreTranslate request failed with HTTP {exc.code}") from exc
        except urlerror.URLError as exc:
            raise RuntimeError(f"LibreTranslate request failed: {exc}") from exc

        translated = normalize_text(str(response.get("translatedText", "")))
        if not translated:
            raise RuntimeError("LibreTranslate returned an empty translation")
        return translated

    def close(self):
        if self.server_manager is not None:
            self.server_manager.close()
            self.server_manager = None


class DeepLKeyExhaustedError(RuntimeError):
    pass


class DeepLKeyInvalidError(RuntimeError):
    pass


def deepl_base_url(endpoint_raw):
    endpoint = normalize_text(endpoint_raw).lower()
    if endpoint in {"", "free"}:
        return DEEPL_FREE_BASE_URL
    if endpoint == "pro":
        return DEEPL_PRO_BASE_URL

    custom = normalize_text(endpoint_raw).rstrip("/")
    if custom.startswith("http://") or custom.startswith("https://"):
        if custom.endswith("/v2"):
            return custom
        return f"{custom}/v2"

    return DEEPL_FREE_BASE_URL


def key_prefix8(api_key):
    return normalize_text(api_key).lower()[:8]


def load_deepl_keys_from_ini(path):
    if not path.exists():
        raise FileNotFoundError(f"DeepL keys file not found: {path}")

    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str
    loaded = cfg.read(path, encoding="utf-8")
    if not loaded:
        raise RuntimeError(f"Could not read DeepL keys file: {path}")

    keys = []

    def add_key(raw):
        value = normalize_text(raw).strip('"').strip("'")
        if value and value not in keys:
            keys.append(value)

    for section in ("deepl_keys", "keys"):
        if cfg.has_section(section):
            for _, raw_value in cfg.items(section):
                add_key(raw_value)

    if cfg.has_section("deepl"):
        for raw_name, raw_value in cfg.items("deepl"):
            key_name = normalize_text(raw_name).lower()
            if key_name in {"api_key", "deepl_api_key", "key"}:
                add_key(raw_value)
            elif key_name == "api_keys":
                for part in re.split(r"[,\n;]+", raw_value or ""):
                    add_key(part)

    if not keys:
        raise RuntimeError(f"No valid DeepL API key found in: {path}")

    return keys


def load_blocked_key_prefixes(state_path):
    if not state_path.exists():
        return set()

    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str
    cfg.read(state_path, encoding="utf-8")

    blocked = set()
    if cfg.has_section("blocked_keys"):
        for raw_prefix in cfg.options("blocked_keys"):
            prefix = normalize_text(raw_prefix).lower()
            if re.fullmatch(r"[0-9a-f]{8}", prefix):
                blocked.add(prefix)
    return blocked


def persist_blocked_key_prefix(state_path, prefix, reason):
    state_path.parent.mkdir(parents=True, exist_ok=True)

    cfg = configparser.ConfigParser(interpolation=None)
    cfg.optionxform = str
    cfg.read(state_path, encoding="utf-8")
    if not cfg.has_section("blocked_keys"):
        cfg.add_section("blocked_keys")

    timestamp = datetime.now(timezone.utc).isoformat()
    cfg.set("blocked_keys", prefix.lower(), f"{timestamp}|{reason}")

    with state_path.open("w", encoding="utf-8") as fh:
        cfg.write(fh)


class DeepLRotatingTranslator(BaseTranslator):
    def __init__(
        self,
        source_lang,
        endpoint,
        keys_ini,
        keys_state_ini,
        usage_timeout_seconds,
        reset_keys_state=False,
    ):
        source_lang_map = {
            "es": "ES",
            "zh-cn": "ZH",
            "auto": None,
        }
        self.source_lang = source_lang_map.get((source_lang or "auto").lower(), None)
        self.base_url = deepl_base_url(endpoint)
        self.keys_ini = Path(keys_ini)
        self.state_path = Path(keys_state_ini)
        self.usage_timeout_seconds = max(3, int(usage_timeout_seconds))
        self.google_fallback = GoogleBackendTranslator(source_lang)

        if reset_keys_state and self.state_path.exists():
            self.state_path.unlink()

        self._all_keys = load_deepl_keys_from_ini(self.keys_ini)
        self._blocked_prefixes = load_blocked_key_prefixes(self.state_path)
        self._available_keys = []
        self._next_key_index = 0
        self._build_available_key_pool()
        print(
            "[DEEPL_ROTATION_MODE] backend=deepl_doc endpoint=%s total_keys=%s available_keys=%s"
            % (self.base_url, len(self._all_keys), len(self._available_keys)),
            flush=True,
        )

    def _headers(self, api_key):
        return {
            "Authorization": f"DeepL-Auth-Key {api_key}",
            "Content-Type": "application/x-www-form-urlencoded",
        }

    def _mark_key_blocked(self, api_key, reason):
        prefix = key_prefix8(api_key)
        if not prefix or prefix in self._blocked_prefixes:
            return
        self._blocked_prefixes.add(prefix)
        persist_blocked_key_prefix(self.state_path, prefix, reason)
        print(f"[deepl_doc] key blocked ({prefix}...): {reason}", flush=True)

    def _post_form(self, path, form_data, api_key, timeout):
        encoded = urlparse.urlencode(form_data, doseq=True).encode("utf-8")
        req = urlrequest.Request(
            f"{self.base_url}{path}",
            data=encoded,
            headers=self._headers(api_key),
            method="POST",
        )
        with urlrequest.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, body

    def _get_usage(self, api_key):
        req = urlrequest.Request(
            f"{self.base_url}/usage",
            headers={"Authorization": f"DeepL-Auth-Key {api_key}"},
            method="GET",
        )

        try:
            with urlrequest.urlopen(req, timeout=self.usage_timeout_seconds) as resp:
                body = resp.read().decode("utf-8", errors="replace")
                payload = json.loads(body)
                count = int(payload.get("character_count", -1))
                limit = int(payload.get("character_limit", -1))
                if limit > 0 and count >= limit:
                    return "exhausted", f"usage_exhausted:{count}/{limit}"
                return "available", f"usage:{count}/{limit}"
        except urlerror.HTTPError as exc:
            if exc.code == 456:
                return "exhausted", "http_456"
            if exc.code in {401, 403}:
                return "invalid", f"http_{exc.code}"
            return "unknown", f"http_{exc.code}"
        except Exception:
            # Keep the key if usage endpoint is temporarily unavailable.
            return "unknown", "usage_unknown"

    def _build_available_key_pool(self):
        self._available_keys = []
        for index, api_key in enumerate(self._all_keys, start=1):
            prefix = key_prefix8(api_key)
            if not prefix:
                continue
            if prefix in self._blocked_prefixes:
                print(f"[deepl_doc] skipping blocked key ({index}): {prefix}...", flush=True)
                continue

            status, detail = self._get_usage(api_key)
            if status in {"exhausted", "invalid"}:
                self._mark_key_blocked(api_key, detail)
                continue

            print(f"[deepl_doc] key ready ({index}): {prefix}... [{detail}]", flush=True)
            self._available_keys.append(api_key)

    def _translate_with_key(self, text, api_key):
        form_data = {
            "text": text,
            "target_lang": "PT-BR",
            "preserve_formatting": "1",
            "split_sentences": "nonewlines",
        }
        if self.source_lang and self.source_lang != "AUTO":
            form_data["source_lang"] = self.source_lang

        try:
            _, body = self._post_form("/translate", form_data, api_key, timeout=45)
        except urlerror.HTTPError as exc:
            if exc.code == 456:
                raise DeepLKeyExhaustedError("http_456") from exc
            if exc.code in {401, 403}:
                raise DeepLKeyInvalidError(f"http_{exc.code}") from exc
            raise RuntimeError(f"DeepL translate request failed with HTTP {exc.code}") from exc

        payload = json.loads(body)
        translations = payload.get("translations") or []
        if not translations:
            raise RuntimeError("DeepL returned no translations")

        translated = normalize_text(translations[0].get("text", ""))
        if not translated:
            raise RuntimeError("DeepL returned an empty translation")
        return translated

    def _google_fallback_translate(self, text, reason):
        print(f"[DEEPL_FALLBACK_EXHAUSTED_KEYS] fallback=google reason={reason}", flush=True)
        return self.google_fallback.translate(text)

    def translate(self, text):
        normalized = normalize_text(text)
        if not normalized:
            return ""

        while self._available_keys:
            if self._next_key_index >= len(self._available_keys):
                self._next_key_index = 0

            api_key = self._available_keys[self._next_key_index]
            prefix = key_prefix8(api_key)

            try:
                translated = self._translate_with_key(normalized, api_key)
                self._next_key_index = (self._next_key_index + 1) % max(1, len(self._available_keys))
                return translated
            except DeepLKeyExhaustedError as exc:
                self._mark_key_blocked(api_key, str(exc))
            except DeepLKeyInvalidError as exc:
                self._mark_key_blocked(api_key, str(exc))
            except Exception:
                # Non-quota transient errors should not permanently block the key.
                self._next_key_index = (self._next_key_index + 1) % max(1, len(self._available_keys))
                raise

            # Remove blocked key from active pool and continue rotating.
            self._available_keys.pop(self._next_key_index)

        return self._google_fallback_translate(normalized, "all DeepL keys exhausted or blocked")


class GeminiBackendTranslator(BaseTranslator):
    def __init__(self, api_key, model_name, source_lang):
        if not normalize_text(api_key):
            raise ValueError("GEMINI_API_KEY is not set for gemini backend.")

        try:
            import google.generativeai as genai
        except Exception as exc:
            raise RuntimeError(
                "Missing dependency for gemini. Run setup/install_all.sh"
            ) from exc

        self._genai = genai
        self.source_lang = source_lang or "auto"
        self.model_name = normalize_text(model_name) or DEFAULT_GEMINI_MODEL
        genai.configure(api_key=api_key)
        self.model = genai.GenerativeModel(
            self.model_name,
            generation_config={"temperature": 0.0, "top_p": 1, "top_k": 1},
        )

    def translate(self, text):
        normalized = (text or "").strip()
        if not normalized:
            return ""

        prompt = (
            "Translate from the source language to Brazilian Portuguese. "
            "Return only the translation, with no explanations. "
            "Preserve markers in the format [[SRT-0001]] exactly as provided, "
            "without changing index, brackets, or order. "
            f"Expected source language: {self.source_lang}.\n\n"
            f"Text:\n{normalized}"
        )
        response = self.model.generate_content(prompt)
        translated = normalize_text(getattr(response, "text", ""))
        if not translated:
            raise RuntimeError("Empty response from Gemini backend.")
        return translated


class NLLBLocalTranslator(BaseTranslator):
    def __init__(
        self,
        model_dir,
        source_lang_nllb,
        max_input_length=DEFAULT_NLLB_MAX_INPUT_LENGTH,
        max_new_tokens=DEFAULT_NLLB_MAX_NEW_TOKENS,
        legacy_generation=DEFAULT_NLLB_LEGACY_GENERATION,
    ):
        if not normalize_text(source_lang_nllb):
            raise ValueError(
                "nllb_local requires an explicit source language."
            )
        if not model_dir.exists():
            raise FileNotFoundError(
                f"NLLB model directory not found: {model_dir}"
            )

        try:
            import torch
            from transformers import AutoModelForSeq2SeqLM, AutoTokenizer
        except Exception as exc:
            raise RuntimeError(
                "Missing dependencies for nllb_local. Run setup/setup-nllb-local.sh"
            ) from exc

        self._torch = torch
        self.max_input_length = max(256, int(max_input_length))
        self.max_new_tokens = max(64, int(max_new_tokens))
        self.legacy_generation = bool(legacy_generation)
        self.device = "cpu"

        torch_dtype = torch.float32
        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir), use_fast=False)
        self.model = AutoModelForSeq2SeqLM.from_pretrained(
            str(model_dir),
            torch_dtype=torch_dtype,
            low_cpu_mem_usage=True,
        )
        self.model.to(self.device)
        self.model.eval()

        if not self.legacy_generation:
            self.model.generation_config.max_length = None

        self.source_lang = source_lang_nllb
        self.target_lang = "por_Latn"
        try:
            self.tokenizer.src_lang = self.source_lang
        except Exception as exc:
            raise ValueError(f"Unsupported NLLB source language: {self.source_lang}") from exc
        self.forced_bos_token_id = self.tokenizer.convert_tokens_to_ids(self.target_lang)
        if self.forced_bos_token_id is None or self.forced_bos_token_id < 0:
            raise RuntimeError("Could not resolve target token por_Latn")

        mode = "legacy" if self.legacy_generation else "fast"
        print(
            "[nllb_local] modo=%s device=%s max_input=%s max_new=%s"
            % (mode, self.device, self.max_input_length, self.max_new_tokens),
            flush=True,
        )

    def _prepare_inputs(self, normalized):
        inputs = self.tokenizer(
            normalized,
            return_tensors="pt",
            truncation=True,
            max_length=self.max_input_length,
        )
        if self.device != "cpu":
            inputs = {key: value.to(self.device) for key, value in inputs.items()}
        return inputs

    def _translate_legacy(self, inputs):
        input_len = int(inputs["input_ids"].shape[1])
        generation_max_length = min(2048, input_len + 512)
        output_tokens = self.model.generate(
            **inputs,
            forced_bos_token_id=self.forced_bos_token_id,
            max_length=generation_max_length,
        )
        return self.tokenizer.batch_decode(output_tokens, skip_special_tokens=True)[0]

    def _translate_fast(self, inputs):
        output_tokens = self.model.generate(
            **inputs,
            forced_bos_token_id=self.forced_bos_token_id,
            max_new_tokens=self.max_new_tokens,
            num_beams=1,
            do_sample=False,
        )
        return self.tokenizer.batch_decode(output_tokens, skip_special_tokens=True)[0]

    def translate(self, text):
        normalized = normalize_text(text)
        if not normalized:
            return normalized

        inputs = self._prepare_inputs(normalized)

        with self._torch.no_grad():
            if self.legacy_generation:
                translated = self._translate_legacy(inputs)
            else:
                translated = self._translate_fast(inputs)
        return translated


def build_translator(args, source_lang_key, source_lang_normalized):
    backend = args.backend

    if backend == "libretranslate":
        server_manager = None
        if args.libretranslate_auto_server:
            server_manager = LocalLibreTranslateServerManager(
                base_url=args.libretranslate_url,
                start_timeout_seconds=args.libretranslate_start_timeout_seconds,
                load_only_lang_codes=args.libretranslate_load_only_lang_codes,
            )
            server_manager.ensure_started()

        translator = LibreTranslateBackendTranslator(
            source_lang=source_lang_normalized,
            base_url=args.libretranslate_url,
            target_lang=args.libretranslate_target_lang,
            timeout_seconds=args.libretranslate_timeout_seconds,
        )
        translator.attach_server_manager(server_manager)
        return translator, "libretranslate"

    if backend == "deepl_doc":
        translator = DeepLRotatingTranslator(
            source_lang=source_lang_normalized,
            endpoint=args.deepl_endpoint,
            keys_ini=args.deepl_keys_ini,
            keys_state_ini=args.deepl_keys_state_ini,
            usage_timeout_seconds=args.deepl_usage_timeout_seconds,
            reset_keys_state=args.deepl_reset_keys_state,
        )
        return translator, "deepl_doc"

    if backend == "nllb_local":
        if source_lang_key == "auto":
            print("Warning: source_lang=auto is not supported in nllb_local. Falling back to google backend.")
            return GoogleBackendTranslator(source_lang_normalized), "google"

        source_lang_nllb = NLLB_SOURCE_LANG_MAP.get(source_lang_key)
        if not source_lang_nllb:
            print(
                "Warning: source_lang=%s is not mapped for nllb_local. Falling back to google backend."
                % source_lang_key
            )
            return GoogleBackendTranslator(source_lang_normalized), "google"

        translator = NLLBLocalTranslator(
            args.nllb_model_dir,
            source_lang_nllb,
            max_input_length=args.nllb_max_input_length,
            max_new_tokens=args.nllb_max_new_tokens,
            legacy_generation=args.nllb_legacy_generation,
        )
        return translator, "nllb_local"

    if backend == "gemini":
        api_key = os.getenv("GEMINI_API_KEY", "")
        translator = GeminiBackendTranslator(
            api_key=api_key,
            model_name=args.gemini_model,
            source_lang=source_lang_normalized,
        )
        return translator, "gemini"

    return GoogleBackendTranslator(source_lang_normalized), "google"


def contains_cjk(text):
    return bool(re.search(r"[\u3400-\u9fff\uf900-\ufaff]", text or ""))


def _is_suspicious_untranslated(source_text, translated_text, source_lang_key):
    src = normalize_text(source_text)
    tgt = normalize_text(translated_text)
    if not src or not tgt:
        return False

    if src == tgt:
        return True

    # For Chinese source, translated lines that still contain CJK are often untranslated.
    if source_lang_key == "zh-cn" and contains_cjk(tgt):
        return True

    return False


def collect_translation_quality_stats(source_texts, subtitles, source_lang_key):
    suspicious = []
    checked = 0

    for idx, subtitle in enumerate(subtitles, start=1):
        src = source_texts[idx - 1] if idx - 1 < len(source_texts) else ""
        tgt = normalize_text(subtitle.text)
        if not src or not tgt:
            continue
        checked += 1
        if _is_suspicious_untranslated(src, tgt, source_lang_key):
            suspicious.append(
                {
                    "index": idx,
                    "source": src,
                    "translated": tgt,
                }
            )

    ratio = (len(suspicious) / checked) if checked else 0.0
    return {
        "checked": checked,
        "suspicious": suspicious,
        "ratio": ratio,
    }


def load_json_file(path, default_value):
    if not path.exists():
        return default_value
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data
    except Exception:
        return default_value


def save_json_file(path, payload):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=2, sort_keys=True)


def enforce_dict_limit(mapping, limit):
    if limit <= 0:
        mapping.clear()
        return
    while len(mapping) > limit:
        first_key = next(iter(mapping))
        mapping.pop(first_key, None)


def merge_unique_glossary_entries(base_entries, extra_entries):
    merged = list(base_entries)
    seen = {
        (
            normalize_text(entry.get("source_regex", "")),
            normalize_text(entry.get("target", "")),
        )
        for entry in merged
        if isinstance(entry, dict)
    }

    for entry in extra_entries:
        if not isinstance(entry, dict):
            continue
        key = (
            normalize_text(entry.get("source_regex", "")),
            normalize_text(entry.get("target", "")),
        )
        if not all(key) or key in seen:
            continue
        merged.append(entry)
        seen.add(key)

    return merged


def merge_local_knowledge(profile, glossary, local_knowledge):
    local_global_replacements = local_knowledge.get("global_replacements", {})
    if isinstance(local_global_replacements, dict):
        profile_global = profile.setdefault("global_replacements", {})
        for wrong, correct in local_global_replacements.items():
            if wrong and correct:
                profile_global[wrong] = correct

    local_glossary_entries = local_knowledge.get("glossary_entries", [])
    if isinstance(local_glossary_entries, list):
        glossary_entries = glossary.setdefault("entries", [])
        glossary["entries"] = merge_unique_glossary_entries(glossary_entries, local_glossary_entries)


def scan_watch_patterns(text, watch_patterns):
    hits = []
    for pattern in watch_patterns:
        if not isinstance(pattern, dict):
            continue
        pattern_id = normalize_text(pattern.get("id", ""))
        regex = pattern.get("regex")
        if not pattern_id or not regex:
            continue
        try:
            if re.search(regex, text, flags=re.IGNORECASE):
                hits.append(pattern_id)
        except re.error:
            continue
    return hits


def load_zh_calibration_bundle(calibration_dir):
    profile_path = calibration_dir / CALIBRATION_PROFILE_FILE
    glossary_path = calibration_dir / GLOSSARY_FILE
    state_path = calibration_dir / CALIBRATION_STATE_FILE
    local_knowledge_path = calibration_dir / LOCAL_KNOWLEDGE_FILE

    profile_default = {"cases": [], "global_replacements": {}}
    glossary_default = {"entries": []}
    local_knowledge_default = {
        "global_replacements": {},
        "glossary_entries": [],
        "watch_patterns": [],
        "domain_terms_pt": [],
    }
    state_default = {
        "last_run": None,
        "backend": None,
        "active_replacements": {},
        "case_results": [],
        "auto_glossary": {},
        "watch_hits": {},
        "watch_samples": [],
    }

    profile = load_json_file(profile_path, profile_default)
    glossary = load_json_file(glossary_path, glossary_default)
    local_knowledge = load_json_file(local_knowledge_path, local_knowledge_default)
    state = load_json_file(state_path, state_default)

    merge_local_knowledge(profile, glossary, local_knowledge)

    return {
        "profile_path": profile_path,
        "glossary_path": glossary_path,
        "state_path": state_path,
        "local_knowledge_path": local_knowledge_path,
        "profile": profile,
        "glossary": glossary,
        "local_knowledge": local_knowledge,
        "state": state,
    }


def run_zh_precalibration(tradutor, profile):
    active_replacements = dict(profile.get("global_replacements", {}))
    case_results = []

    for case in profile.get("cases", []):
        source = normalize_text(case.get("source", ""))
        if not source:
            continue

        translated = normalize_text(translate_single_line(tradutor, source))
        translated_lower = translated.lower()

        forbid_hits = [term for term in case.get("forbid", []) if term.lower() in translated_lower]
        must_include = [term for term in case.get("must_include", []) if term.strip()]
        missing_terms = [term for term in must_include if term.lower() not in translated_lower]

        triggered = bool(forbid_hits or missing_terms)
        if triggered:
            for wrong, correct in case.get("preferred_replacements", {}).items():
                if wrong and correct:
                    active_replacements[wrong] = correct

        case_results.append(
            {
                "id": case.get("id", "case"),
                "source": source,
                "translated": translated,
                "triggered": triggered,
                "forbid_hits": forbid_hits,
                "missing_terms": missing_terms,
            }
        )

    return active_replacements, case_results


def apply_case_replacements(text, replacements):
    updated = text
    for wrong, correct in replacements.items():
        if wrong and correct:
            updated = updated.replace(wrong, correct)
    return updated


def apply_glossary_for_source(source_text, translated_text, glossary_entries):
    updated = translated_text
    for entry in glossary_entries:
        source_regex = entry.get("source_regex")
        target = normalize_text(entry.get("target", ""))
        forbidden_targets = [normalize_text(term) for term in entry.get("forbidden_targets", [])]
        if not source_regex or not re.search(source_regex, source_text):
            continue

        for forbidden in forbidden_targets:
            if forbidden:
                updated = re.sub(re.escape(forbidden), target, updated, flags=re.IGNORECASE)
    return updated


def update_auto_glossary(state, source_text, translated_text, limit):
    auto_glossary = state.setdefault("auto_glossary", {})
    src = normalize_text(source_text)
    tgt = normalize_text(translated_text)
    if not src or not tgt or not contains_cjk(src):
        return

    current = auto_glossary.get(src)
    if isinstance(current, dict):
        count = int(current.get("count", 0)) + 1
    else:
        count = 1

    auto_glossary[src] = {"target": tgt, "count": count}

    if len(auto_glossary) > limit:
        ranked = sorted(auto_glossary.items(), key=lambda item: int(item[1].get("count", 0)), reverse=True)
        trimmed = dict(ranked[:limit])
        auto_glossary.clear()
        auto_glossary.update(trimmed)


def get_auto_glossary_target(state, source_text):
    auto_glossary = state.get("auto_glossary", {})
    entry = auto_glossary.get(source_text)
    if isinstance(entry, dict):
        return normalize_text(entry.get("target", ""))
    if isinstance(entry, str):
        return normalize_text(entry)
    return ""


def load_translation_memory(memory_path):
    if not memory_path.exists():
        return {}

    try:
        with open(memory_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return {}

    if not isinstance(data, dict):
        return {}

    memory = {}
    for key, value in data.items():
        if isinstance(key, str) and isinstance(value, str):
            memory[key] = value
    return memory


def save_translation_memory(memory_path, memory):
    memory_path.parent.mkdir(parents=True, exist_ok=True)
    with open(memory_path, "w", encoding="utf-8") as f:
        json.dump(memory, f, ensure_ascii=False, indent=2, sort_keys=True)


def split_into_blocks(subtitles, max_lines, max_chars):
    blocks = []
    current_block = []
    current_chars = 0

    for subtitle in subtitles:
        text = normalize_text(subtitle.text)
        if not text:
            current_block.append(subtitle)
            continue

        would_exceed_lines = len(current_block) >= max_lines
        would_exceed_chars = current_block and (current_chars + len(text) > max_chars)
        if current_block and (would_exceed_lines or would_exceed_chars):
            blocks.append(current_block)
            current_block = []
            current_chars = 0

        current_block.append(subtitle)
        current_chars += len(text)

    if current_block:
        blocks.append(current_block)

    return blocks


def translate_single_line(tradutor, text):
    try:
        return normalize_text(tradutor.translate(text))
    except Exception:
        return text


def translate_block_text(tradutor, subtitles, source_memory, max_chars):
    payload_parts = []
    source_texts = []

    for index, subtitle in enumerate(subtitles, start=1):
        source_text = normalize_text(subtitle.text)
        source_texts.append(source_text)
        payload_parts.append(f"{MARKER_TEMPLATE.format(index=index)} {source_text}")

    payload = "\n".join(payload_parts)
    if len(subtitles) > 1 and len(payload) > max_chars:
        return None

    try:
        translated_payload = tradutor.translate(payload)
    except Exception:
        return None

    marker_regex = re.compile(r"\[\[SRT-(\d{4})\]\]")
    matches = list(marker_regex.finditer(translated_payload))
    if len(matches) != len(subtitles):
        return None

    translated_lines = []
    for position, match in enumerate(matches):
        start = match.end()
        end = matches[position + 1].start() if position + 1 < len(matches) else len(translated_payload)
        translated_text = normalize_text(translated_payload[start:end])
        if not translated_text:
            return None
        translated_lines.append(translated_text)

    for source_text, translated_text in zip(source_texts, translated_lines):
        if source_text and translated_text:
            source_memory[source_text] = translated_text

    return translated_lines


def translate_chinese_srt(
    subtitles,
    tradutor,
    memory_path,
    block_max_lines,
    block_max_chars,
    source_memory,
    calibration_bundle,
    glossary_limit,
):
    profile = calibration_bundle["profile"]
    glossary_entries = calibration_bundle["glossary"].get("entries", [])
    local_knowledge = calibration_bundle.get("local_knowledge", {})
    watch_patterns = local_knowledge.get("watch_patterns", [])
    state = calibration_bundle["state"]

    watch_hits = state.setdefault("watch_hits", {})
    watch_samples = state.setdefault("watch_samples", [])

    active_replacements, case_results = run_zh_precalibration(tradutor, profile)
    state["last_run"] = datetime.now(timezone.utc).isoformat()
    state["active_replacements"] = active_replacements
    state["case_results"] = case_results

    blocks = split_into_blocks(subtitles, block_max_lines, block_max_chars)
    total_blocks = len(blocks)

    for block_index, block in enumerate(
        tqdm(blocks, desc="[translation]", unit="block", leave=False, disable=not sys.stderr.isatty()),
        start=1,
    ):
        block_texts = [normalize_text(subtitle.text) for subtitle in block]
        if all((text in source_memory) or get_auto_glossary_target(state, text) for text in block_texts if text):
            translated_lines = []
            for text in block_texts:
                cached = source_memory.get(text)
                if not cached:
                    cached = get_auto_glossary_target(state, text) or text
                translated_lines.append(cached)
        else:
            translated_lines = translate_block_text(tradutor, block, source_memory, block_max_chars)
            if translated_lines is None or len(translated_lines) != len(block):
                translated_lines = [translate_single_line(tradutor, text) for text in block_texts]

        for subtitle, source_text, translated_text in zip(block, block_texts, translated_lines):
            if translated_text:
                calibrated = apply_case_replacements(translated_text, active_replacements)
                calibrated = apply_glossary_for_source(source_text, calibrated, glossary_entries)
                for pattern_id in scan_watch_patterns(calibrated, watch_patterns):
                    watch_hits[pattern_id] = int(watch_hits.get(pattern_id, 0)) + 1
                    if len(watch_samples) < 200:
                        watch_samples.append(
                            {
                                "pattern": pattern_id,
                                "source": source_text,
                                "translated": calibrated,
                            }
                        )
                subtitle.text = calibrated
                source_memory[source_text] = calibrated
                update_auto_glossary(state, source_text, calibrated, glossary_limit)

        enforce_dict_limit(source_memory, glossary_limit)
        save_json_file(calibration_bundle["state_path"], state)

        save_translation_memory(memory_path, source_memory)

def translate_simple_srt(subtitles, tradutor):
    for subtitle in tqdm(subtitles, desc="[translation]", unit="item", leave=False, disable=not sys.stderr.isatty()):
        texto = normalize_text(subtitle.text)
        if not texto:
            continue

        try:
            subtitle.text = tradutor.translate(texto)
        except Exception:
            continue


def main():
    args = parse_args()
    input_path = args.input_srt
    output_path = args.output_srt

    source_lang = (args.source_lang or "").strip()
    source_lang_key, source_lang_normalized = normalize_source_language(source_lang)
    if source_lang_key is None:
        print("Error: invalid source language. Use ISO code (ex: en, es, zh-CN), NLLB code (ex: eng_Latn), or auto.")
        sys.exit(1)

    if not input_path.exists():
        print(f"Error: input file not found: {input_path}")
        sys.exit(1)

    output_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        subtitles = pysrt.open(str(input_path), encoding="utf-8")
    except Exception:
        subtitles = pysrt.open(str(input_path), encoding="iso-8859-1")

    source_texts = [normalize_text(subtitle.text) for subtitle in subtitles]

    if len(subtitles) == 0:
        print(f"Error: input file has no subtitles: {input_path}")
        sys.exit(1)

    source_lang_key, source_lang_normalized = resolve_source_language_for_translation(
        source_lang_key,
        source_lang_normalized,
        source_texts,
    )
    if source_lang_key == "auto":
        print("[translation] error: source language unresolved (Desconhecido).", flush=True)
        sys.exit(2)

    tradutor = None
    try:
        tradutor, selected_backend = build_translator(args, source_lang_key, source_lang_normalized)

        if source_lang_key == "zh-cn":
            memory_path = memory_path_for(output_path, selected_backend, source_lang_key)
            translation_memory = load_translation_memory(memory_path)
            calibration_bundle = load_zh_calibration_bundle(args.zh_calibration_dir)
            calibration_bundle["state"]["backend"] = selected_backend

            translate_chinese_srt(
                subtitles,
                tradutor,
                memory_path,
                max(1, args.block_max_lines),
                max(1, args.block_max_chars),
                translation_memory,
                calibration_bundle,
                max(1, args.zh_glossary_limit),
            )
            save_translation_memory(memory_path, translation_memory)
            save_json_file(calibration_bundle["state_path"], calibration_bundle["state"])
        else:
            translate_simple_srt(subtitles, tradutor)

        quality_stats = collect_translation_quality_stats(source_texts, subtitles, source_lang_key)
        suspicious_count = len(quality_stats["suspicious"])
        checked_count = quality_stats["checked"]
        suspicious_ratio = quality_stats["ratio"]

        if source_lang_key == "zh-cn":
            effective_max_untranslated_ratio = max(0.0, args.zh_max_untranslated_ratio)
            effective_max_untranslated_lines = max(1, args.zh_max_untranslated_lines)
        else:
            effective_max_untranslated_ratio = max(0.0, args.max_untranslated_ratio)
            effective_max_untranslated_lines = max(1, args.max_untranslated_lines)

        print(
            "[translation_quality] checked=%s suspicious=%s ratio=%.3f threshold_lines=%s threshold_ratio=%.3f"
            % (
                checked_count,
                suspicious_count,
                suspicious_ratio,
                effective_max_untranslated_lines,
                effective_max_untranslated_ratio,
            ),
            flush=True,
        )

        should_fail_quality = (
            args.fail_on_untranslated
            and checked_count > 0
            and suspicious_count >= effective_max_untranslated_lines
            and suspicious_ratio >= effective_max_untranslated_ratio
        )

        if should_fail_quality:
            print(
                "[translation_quality] FAIL: suspicious untranslated lines exceed threshold "
                "(min_lines=%s min_ratio=%.3f)"
                % (effective_max_untranslated_lines, effective_max_untranslated_ratio),
                flush=True,
            )
            for item in quality_stats["suspicious"][:8]:
                print(
                    "[translation_quality] suspicious line %s src='%s' out='%s'"
                    % (item["index"], item["source"][:120], item["translated"][:120]),
                    flush=True,
                )
            sys.exit(2)

        subtitles.save(str(output_path), encoding="utf-8")

        print(f"Completed. Output file generated at: {output_path}")
    finally:
        if tradutor and hasattr(tradutor, "close"):
            try:
                tradutor.close()
            except Exception:
                pass


if __name__ == "__main__":
    main()
