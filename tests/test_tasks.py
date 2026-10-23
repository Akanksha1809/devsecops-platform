def test_list_tasks_empty(client):
    resp = client.get("/api/v1/tasks")
    assert resp.status_code == 200
    assert resp.json() == []


def test_create_and_get_task(client):
    created = client.post("/api/v1/tasks", json={"title": "write pipeline"})
    assert created.status_code == 201
    body = created.json()
    assert body["title"] == "write pipeline"
    assert body["done"] is False

    fetched = client.get(f"/api/v1/tasks/{body['id']}")
    assert fetched.status_code == 200
    assert fetched.json() == body


def test_create_task_rejects_empty_title(client):
    resp = client.post("/api/v1/tasks", json={"title": ""})
    assert resp.status_code == 422


def test_create_task_rejects_missing_title(client):
    resp = client.post("/api/v1/tasks", json={})
    assert resp.status_code == 422


def test_get_missing_task_returns_404(client):
    resp = client.get("/api/v1/tasks/999")
    assert resp.status_code == 404


def test_update_task(client):
    created = client.post("/api/v1/tasks", json={"title": "task"}).json()
    resp = client.patch(f"/api/v1/tasks/{created['id']}", json={"done": True})
    assert resp.status_code == 200
    assert resp.json()["done"] is True
    assert resp.json()["title"] == "task"


def test_update_missing_task_returns_404(client):
    resp = client.patch("/api/v1/tasks/999", json={"done": True})
    assert resp.status_code == 404


def test_delete_task(client):
    created = client.post("/api/v1/tasks", json={"title": "task"}).json()
    resp = client.delete(f"/api/v1/tasks/{created['id']}")
    assert resp.status_code == 204
    assert client.get(f"/api/v1/tasks/{created['id']}").status_code == 404


def test_delete_missing_task_returns_404(client):
    resp = client.delete("/api/v1/tasks/999")
    assert resp.status_code == 404


def test_list_tasks_returns_created_tasks(client):
    client.post("/api/v1/tasks", json={"title": "a"})
    client.post("/api/v1/tasks", json={"title": "b"})
    resp = client.get("/api/v1/tasks")
    assert len(resp.json()) == 2
