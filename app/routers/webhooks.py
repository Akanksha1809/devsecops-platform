import logging
from collections import deque
from datetime import UTC, datetime

from fastapi import APIRouter
from pydantic import BaseModel

logger = logging.getLogger("app.webhooks")

router = APIRouter(prefix="/webhooks", tags=["webhooks"])

_MAX_STORED_ALERTS = 50


class Alert(BaseModel):
    status: str
    labels: dict[str, str] = {}
    annotations: dict[str, str] = {}
    startsAt: str | None = None
    endsAt: str | None = None
    fingerprint: str | None = None


class AlertmanagerWebhook(BaseModel):
    """Matches Alertmanager's webhook_config payload schema."""

    version: str
    status: str
    receiver: str
    groupLabels: dict[str, str] = {}
    commonLabels: dict[str, str] = {}
    commonAnnotations: dict[str, str] = {}
    externalURL: str
    alerts: list[Alert]


class StoredAlert(BaseModel):
    received_at: str
    status: str
    receiver: str
    alerts: list[Alert]


class AlertStore:
    """In-memory sink for alert notifications. A free local alternative to
    a real notification service (console output + this project's own
    FastAPI app standing in as a webhook receiver — see
    docs/IMPLEMENTATION_PLAN.md §4e). Not persisted; lost on pod restart.
    """

    def __init__(self, maxlen: int = _MAX_STORED_ALERTS) -> None:
        self._alerts: deque[StoredAlert] = deque(maxlen=maxlen)

    def add(self, payload: AlertmanagerWebhook) -> StoredAlert:
        stored = StoredAlert(
            received_at=datetime.now(UTC).isoformat(),
            status=payload.status,
            receiver=payload.receiver,
            alerts=payload.alerts,
        )
        self._alerts.appendleft(stored)
        return stored

    def list(self) -> list[StoredAlert]:
        return list(self._alerts)

    def reset(self) -> None:
        self._alerts.clear()


store = AlertStore()


@router.post("/alerts", status_code=204)
def receive_alert(payload: AlertmanagerWebhook) -> None:
    stored = store.add(payload)
    logger.warning(
        "alert received",
        extra={
            "extra_fields": {
                "alert_status": stored.status,
                "receiver": stored.receiver,
                "alert_count": len(stored.alerts),
                "alert_names": [a.labels.get("alertname", "unknown") for a in stored.alerts],
            }
        },
    )


@router.get("/alerts", response_model=list[StoredAlert])
def list_alerts() -> list[StoredAlert]:
    return store.list()
