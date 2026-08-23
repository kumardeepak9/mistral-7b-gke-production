import logging
import sys

from pythonjsonlogger import jsonlogger

from app.config import settings


class _GoogleCloudFormatter(jsonlogger.JsonFormatter):
    """
    Extends the standard JSON formatter to match Google Cloud Logging's
    expected field names.

    Cloud Logging maps:
      "severity"  → log level  (replaces "levelname")
      "message"   → log text   (standard)
      "time"      → timestamp  (standard asctime)

    Reference:
      https://cloud.google.com/logging/docs/structured-logging
    """

    def add_fields(
        self,
        log_record: dict,
        record: logging.LogRecord,
        message_dict: dict,
    ) -> None:
        super().add_fields(log_record, record, message_dict)

        # Rename levelname → severity so GCP severity filter works
        log_record["severity"] = log_record.pop("levelname", record.levelname)

        # Rename asctime → time for GCP timestamp parsing
        if "asctime" in log_record:
            log_record["time"] = log_record.pop("asctime")

        # Static context — injected into every log line
        log_record["app_env"] = settings.app_env
        log_record["app_version"] = settings.app_version
        log_record["service"] = "fastapi-gateway"


def setup_logging() -> None:
    """
    Configure the root logger to emit structured JSON to stdout.

    Call this exactly once, at application startup, before any other
    logging calls are made.  After this runs, every `logging.getLogger()`
    instance in the process inherits the JSON format.
    """
    log_level = getattr(logging, settings.log_level, logging.INFO)

    # JSON formatter with ISO-8601 timestamps
    formatter = _GoogleCloudFormatter(
        fmt="%(asctime)s %(levelname)s %(name)s %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%S",
    )

    # Stream handler — always stdout so Docker / Kubernetes log collectors
    # can capture it without any file-path configuration.
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(formatter)

    # Root logger configuration
    root_logger = logging.getLogger()
    root_logger.setLevel(log_level)

    # Remove default handlers to avoid duplicate lines
    root_logger.handlers.clear()
    root_logger.addHandler(handler)

    # Silence noisy third-party loggers in production
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("uvicorn.access").setLevel(
        logging.DEBUG if not settings.is_production else logging.WARNING
    )

    logging.getLogger(__name__).info(
        "Logging initialised",
        extra={"log_level": settings.log_level},
    )
