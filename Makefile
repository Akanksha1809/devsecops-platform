.PHONY: venv install test lint fmt run build run-image clean bootstrap validate teardown

VENV := .venv
PY := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

venv:
	python3.12 -m venv $(VENV)

install: venv
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements-dev.txt

test:
	$(VENV)/bin/pytest --cov=app --cov-report=term-missing

lint:
	$(VENV)/bin/ruff check app tests
	$(VENV)/bin/ruff format --check app tests

fmt:
	$(VENV)/bin/ruff format app tests

run:
	$(VENV)/bin/uvicorn app.main:app --reload --port 8000

build:
	docker build -t devsecops-platform-app:dev .

run-image: build
	docker run --rm -p 8000:8000 devsecops-platform-app:dev

clean:
	rm -rf $(VENV) .pytest_cache .ruff_cache htmlcov .coverage

bootstrap:
	./scripts/bootstrap.sh

validate:
	./scripts/validate.sh

teardown:
	./scripts/teardown.sh
