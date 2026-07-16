from pathlib import Path
import os

BASE_DIR = Path(__file__).resolve().parent.parent
ROOT_DIR = BASE_DIR.parent

SECRET_KEY = os.environ.get("DJANGO_SECRET_KEY", "dev-only-secret-key-change-me")
DEBUG = os.environ.get("DJANGO_DEBUG", "1") == "1"


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

WEBAPP = {
    "ROOT_DIR": ROOT_DIR,
    "PIPELINE_CONFIG": ROOT_DIR / "config" / "pipeline.ini",
    "WORKER_POLL_SECONDS": int(os.environ.get("WEBAPP_WORKER_POLL_SECONDS", "2")),
    "WORKER_GRACE_SECONDS": int(os.environ.get("WEBAPP_WORKER_GRACE_SECONDS", "8")),
    "WORKER_IDLE_EXIT_SECONDS": int(os.environ.get("WEBAPP_WORKER_IDLE_EXIT_SECONDS", "180")),
    "WORKER_MANAGE_LIBRETRANSLATE": os.environ.get("WEBAPP_WORKER_MANAGE_LIBRETRANSLATE", "0"),
    "SQLITE_LOCK_RETRY_ATTEMPTS": int(os.environ.get("WEBAPP_SQLITE_LOCK_RETRY_ATTEMPTS", "5")),
    "SQLITE_LOCK_RETRY_WAIT_SECONDS": float(os.environ.get("WEBAPP_SQLITE_LOCK_RETRY_WAIT_SECONDS", "0.25")),
    "WEBAPP_LOG_DIR": ROOT_DIR / "logs" / "webapp",
    # Legacy LibreTranslate settings kept commented for possible future reactivation.
    # "LIBRETRANSLATE_URL": os.environ.get("LIBRETRANSLATE_URL", "http://127.0.0.1:5000"),
    # "LIBRETRANSLATE_HOST": os.environ.get("LIBRETRANSLATE_HOST", "127.0.0.1"),
    # "LIBRETRANSLATE_PORT": os.environ.get("LIBRETRANSLATE_PORT", "5000"),
    # "LIBRETRANSLATE_EXECUTABLE": os.environ.get(
    #     "LIBRETRANSLATE_EXECUTABLE",
    #     str(ROOT_DIR / "external" / "LibreTranslate" / ".venv" / "bin" / "libretranslate"),
    # ),
    # "LIBRETRANSLATE_LOAD_ONLY_LANG_CODES": os.environ.get("LIBRETRANSLATE_LOAD_ONLY_LANG_CODES", "en,es,zh,pt"),
    # "LIBRETRANSLATE_START_TIMEOUT_SECONDS": int(os.environ.get("LIBRETRANSLATE_START_TIMEOUT_SECONDS", "60")),
}
