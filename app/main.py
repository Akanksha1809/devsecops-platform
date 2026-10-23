import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.config import settings
from app.logging_config import configure_logging
from app.metrics import MetricsMiddleware
from app.routers import tasks, webhooks

configure_logging(settings.log_level)
logger = logging.getLogger("app")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("startup: %s v%s (sha=%s)", settings.name, settings.version, settings.git_sha)
    yield
    logger.info("shutdown: %s", settings.name)


app = FastAPI(title=settings.name, version=settings.version, lifespan=lifespan)
app.add_middleware(MetricsMiddleware)
app.include_router(tasks.router)
app.include_router(webhooks.router)


@app.get("/")
def root() -> dict:
    return {"name": settings.name, "version": settings.version, "git_sha": settings.git_sha}


@app.get("/health")
def health() -> dict:
    """Liveness: process is up and serving requests."""
    return {"status": "alive"}


@app.get("/ready")
def ready(response: Response) -> dict:
    """Readiness: process is able to serve real traffic.

    Honors APP_SIMULATE_UNHEALTHY so a deliberately broken release can be
    demonstrated for the rollout/rollback failure scenario.
    """
    if settings.simulate_unhealthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not ready", "reason": "simulated unhealthy release"}
    return {"status": "ready"}


@app.get("/metrics")
def metrics() -> Response:
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)
