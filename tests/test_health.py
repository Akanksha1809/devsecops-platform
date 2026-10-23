from app.config import settings


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "alive"}


def test_ready(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ready"


def test_ready_simulated_unhealthy(client, monkeypatch):
    monkeypatch.setattr(settings, "simulate_unhealthy", True)
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.json()["status"] == "not ready"


def test_root(client):
    resp = client.get("/")
    body = resp.json()
    assert body["name"]
    assert body["version"]


def test_metrics_exposes_prometheus_format(client):
    client.get("/health")
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert b"http_requests_total" in resp.content
