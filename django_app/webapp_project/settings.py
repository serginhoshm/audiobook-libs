from pathlib import Path
import configparser
import logging
import os

BASE_DIR = Path(__file__).resolve().parent.parent
ROOT_DIR = BASE_DIR.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-only-secret-key-change-me")
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"
logger = logging.getLogger(__name__)


def _parse_allowed_hosts() -> list[str]:
    raw_hosts = os.environ.get("DJANGO_ALLOWED_HOSTS", "127.0.0.1,localhost")
    hosts = [item.strip() for item in raw_hosts.split(",") if item.strip()]
    return hosts or ["127.0.0.1", "localhost"]


ALLOWED_HOSTS = _parse_allowed_hosts()

INSTALLED_APPS = [
    "django.contrib.admin",
    "django.contrib.auth",
    "django.contrib.contenttypes",
    "django.contrib.sessions",
    "django.contrib.messages",
    "django.contrib.staticfiles",
    "pipeline_ui",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
]

ROOT_URLCONF = "webapp_project.urls"

TEMPLATES = [
    {
        "BACKEND": "django.template.backends.django.DjangoTemplates",
        "DIRS": [BASE_DIR / "templates"],
        "APP_DIRS": True,
        "OPTIONS": {
            "context_processors": [
                "django.template.context_processors.request",
                "django.contrib.auth.context_processors.auth",
                "django.contrib.messages.context_processors.messages",
            ],
        },
    },
]

WSGI_APPLICATION = "webapp_project.wsgi.application"
ASGI_APPLICATION = "webapp_project.asgi.application"

DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.sqlite3",
        "NAME": BASE_DIR / "db.sqlite3",
        "OPTIONS": {
            "timeout": int(os.environ.get("SQLITE_TIMEOUT_SECONDS", "30")),
        },
    }
}

AUTH_PASSWORD_VALIDATORS = []

LANGUAGE_CODE = "pt-br"
TIME_ZONE = "America/Sao_Paulo"
USE_I18N = True
USE_TZ = True

STATIC_URL = "/static/"
STATIC_ROOT = BASE_DIR / "staticfiles"

DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"


def _read_pipeline_ini() -> configparser.ConfigParser:
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(ROOT_DIR / "config" / "pipeline.ini", encoding="utf-8")
    return cfg


def _resolve_data_root() -> Path:
    raw = _PIPELINE_INI.get("paths", "workdir", fallback="").strip()
    if not raw:
        raw = _PIPELINE_INI.get("paths", "data_root_relative", fallback="data").strip()
        logger.warning("[config] [paths] data_root_relative is deprecated; use [paths] workdir")
    if raw.startswith("/"):
        return Path(raw)
    return ROOT_DIR / raw


_PIPELINE_INI = _read_pipeline_ini()


def _pipeline_ini_value(section: str, option: str, fallback: str = "") -> str:
    try:
        return _PIPELINE_INI.get(section, option, fallback=fallback).strip()
    except Exception:
        return fallback


def _pipeline_ini_first_nonempty(candidates: list[tuple[str, str]], fallback: str = "") -> str:
    for section, option in candidates:
        value = _pipeline_ini_value(section, option, "")
        if value:
            return value
    return fallback

WEBAPP = {
    "ROOT_DIR": ROOT_DIR,
    "PIPELINE_CONFIG": ROOT_DIR / "config" / "pipeline.ini",
    "WORKER_POLL_SECONDS": int(os.environ.get("WEBAPP_WORKER_POLL_SECONDS", "2")),
    "WORKER_MAX_SLOTS_PER_SCOPE": int(os.environ.get("WEBAPP_WORKER_MAX_SLOTS_PER_SCOPE", "1")),
    "WORKER_STATUS_COLLECTOR_POLL_SECONDS": int(os.environ.get("WEBAPP_WORKER_STATUS_COLLECTOR_POLL_SECONDS", "3")),
    "WORKER_STATUS_SNAPSHOT_STALE_SECONDS": int(os.environ.get("WEBAPP_WORKER_STATUS_SNAPSHOT_STALE_SECONDS", "15")),
    "WORKER_GRACE_SECONDS": int(os.environ.get("WEBAPP_WORKER_GRACE_SECONDS", "8")),
    "WORKER_IDLE_EXIT_SECONDS": int(os.environ.get("WEBAPP_WORKER_IDLE_EXIT_SECONDS", "180")),
    "SQLITE_LOCK_RETRY_ATTEMPTS": int(os.environ.get("WEBAPP_SQLITE_LOCK_RETRY_ATTEMPTS", "5")),
    "SQLITE_LOCK_RETRY_WAIT_SECONDS": float(os.environ.get("WEBAPP_SQLITE_LOCK_RETRY_WAIT_SECONDS", "0.25")),
    "YOUTUBE_DATA_API_KEY": os.environ.get(
        "YOUTUBE_DATA_API_KEY",
        _pipeline_ini_first_nonempty(
            [
                ("api_keys", "youtube_data_api_key"),
            ],
            "",
        ),
    ),
    "GEMINI_API_KEY": os.environ.get(
        "GEMINI_API_KEY",
        _pipeline_ini_first_nonempty(
            [
                ("api_keys", "gemini_api_key"),
            ],
            "",
        ),
    ),
    "GEMINI_MODEL": os.environ.get(
        "GEMINI_MODEL",
        _pipeline_ini_first_nonempty(
            [
                ("models", "gemini_model"),
            ],
            "gemini-1.5-flash",
        ),
    ),
    "WEBAPP_LOG_DIR": _resolve_data_root() / "logs" / "webapp",
}
