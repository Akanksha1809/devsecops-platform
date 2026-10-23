import pytest

from app.routers.webhooks import store

ALERTMANAGER_PAYLOAD = {
    "version": "4",
    "status": "firing",
    "receiver": "local-webhook",
    "groupLabels": {"alertname": "AppUnavailable"},
    "commonLabels": {"alertname": "AppUnavailable", "severity": "critical"},
    "commonAnnotations": {"summary": "The app has no healthy targets"},
    "externalURL": "http://alertmanager.monitoring.svc:9093",
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "AppUnavailable", "severity": "critical"},
            "annotations": {"summary": "The app has no healthy targets"},
            "startsAt": "2026-01-01T00:00:00Z",
            "endsAt": "0001-01-01T00:00:00Z",
            "fingerprint": "abc123",
        }
    ],
}


@pytest.fixture(autouse=True)
def _reset_store():
    store.reset()
    yield
    store.reset()


def test_receive_alert_accepts_valid_payload(client):
    resp = client.post("/webhooks/alerts", json=ALERTMANAGER_PAYLOAD)
    assert resp.status_code == 204


def test_received_alert_is_listed(client):
    client.post("/webhooks/alerts", json=ALERTMANAGER_PAYLOAD)
    resp = client.get("/webhooks/alerts")
    assert resp.status_code == 200
    body = resp.json()
    assert len(body) == 1
    assert body[0]["status"] == "firing"
    assert body[0]["alerts"][0]["labels"]["alertname"] == "AppUnavailable"


def test_most_recent_alert_listed_first(client):
    first = {**ALERTMANAGER_PAYLOAD, "receiver": "first"}
    second = {**ALERTMANAGER_PAYLOAD, "receiver": "second"}
    client.post("/webhooks/alerts", json=first)
    client.post("/webhooks/alerts", json=second)
    body = client.get("/webhooks/alerts").json()
    assert body[0]["receiver"] == "second"
    assert body[1]["receiver"] == "first"


def test_rejects_malformed_payload(client):
    resp = client.post("/webhooks/alerts", json={"not": "a valid alertmanager payload"})
    assert resp.status_code == 422


def test_empty_alert_list_initially(client):
    resp = client.get("/webhooks/alerts")
    assert resp.json() == []
