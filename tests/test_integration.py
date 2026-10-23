import pytest


@pytest.mark.integration
def test_full_task_lifecycle_and_metrics_track_it(client):
    before = client.get("/metrics").text
    before_count = before.count('path="/api/v1/tasks"')

    created = client.post("/api/v1/tasks", json={"title": "ship the pipeline"}).json()
    task_id = created["id"]

    assert client.get(f"/api/v1/tasks/{task_id}").json()["done"] is False
    assert client.patch(f"/api/v1/tasks/{task_id}", json={"done": True}).json()["done"] is True
    assert client.get("/api/v1/tasks").json() == [
        {"id": task_id, "title": "ship the pipeline", "done": True}
    ]
    client.delete(f"/api/v1/tasks/{task_id}")
    assert client.get(f"/api/v1/tasks/{task_id}").status_code == 404

    after = client.get("/metrics").text
    after_count = after.count('path="/api/v1/tasks"')
    assert after_count > before_count


@pytest.mark.integration
def test_readiness_toggle_reflected_end_to_end(client, monkeypatch):
    from app.config import settings

    assert client.get("/ready").status_code == 200
    monkeypatch.setattr(settings, "simulate_unhealthy", True)
    assert client.get("/ready").status_code == 503
    monkeypatch.setattr(settings, "simulate_unhealthy", False)
    assert client.get("/ready").status_code == 200


@pytest.mark.integration
def test_invalid_task_update_type_is_rejected(client):
    created = client.post("/api/v1/tasks", json={"title": "task"}).json()
    resp = client.patch(f"/api/v1/tasks/{created['id']}", json={"done": "not-a-bool"})
    assert resp.status_code == 422
