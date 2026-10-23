from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="APP_")

    name: str = "devsecops-platform-app"
    version: str = "0.1.0"
    git_sha: str = "unknown"
    log_level: str = "INFO"
    simulate_unhealthy: bool = False


settings = Settings()
