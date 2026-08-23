import httpx
from fastapi.testclient import TestClient

from app.config import settings


def test_root_endpoint_returns_service_metadata(client: TestClient) -> None:
    response = client.get("/")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")

    body = response.json()
    assert body == {
        "service": "mistral-inference-gateway",
        "version": settings.app_version,
        "environment": settings.app_env,
        "status": "running",
        "docs": "/docs",
    }


def test_health_endpoint_returns_liveness_payload(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")

    body = response.json()
    assert body["status"] == "ok"
    assert body["version"] == settings.app_version
    assert body["environment"] == settings.app_env
    assert isinstance(body["uptime_seconds"], float)
    assert body["uptime_seconds"] >= 0.0


def test_readiness_endpoint_returns_ready_checks(client: TestClient) -> None:
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("application/json")

    body = response.json()
    assert body == {
        "status": "ok",
        "version": settings.app_version,
        "checks": {"config_loaded": "ok"},
    }


def test_chat_completions_proxies_non_stream_response(
    client: TestClient,
    monkeypatch,
) -> None:
    async def fake_post(*args, **kwargs) -> httpx.Response:
        return httpx.Response(
            status_code=200,
            json={
                "id": "chatcmpl-test",
                "object": "chat.completion",
                "model": settings.vllm_model_name,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "hello"},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 5,
                    "completion_tokens": 2,
                    "total_tokens": 7,
                },
            },
        )

    monkeypatch.setattr(client.app.state.http_client, "post", fake_post)

    response = client.post(
        "/v1/chat/completions",
        json={
            "messages": [{"role": "user", "content": "Say hello"}],
            "max_tokens": 16,
            "stream": False,
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["object"] == "chat.completion"
    assert body["choices"][0]["message"]["content"] == "hello"


def test_chat_completions_rejects_max_tokens_above_limit(client: TestClient) -> None:
    response = client.post(
        "/v1/chat/completions",
        json={
            "messages": [{"role": "user", "content": "Say hello"}],
            "max_tokens": settings.max_tokens_limit + 1,
        },
    )

    assert response.status_code == 422
    assert "exceeds the server limit" in response.json()["detail"]


def test_chat_completions_maps_upstream_timeout_to_gateway_timeout(
    client: TestClient,
    monkeypatch,
) -> None:
    async def fake_post(*args, **kwargs) -> httpx.Response:
        raise httpx.TimeoutException("timeout")

    monkeypatch.setattr(client.app.state.http_client, "post", fake_post)

    response = client.post(
        "/v1/chat/completions",
        json={
            "messages": [{"role": "user", "content": "Say hello"}],
            "max_tokens": 16,
            "stream": False,
        },
    )

    assert response.status_code == 504
    assert response.json()["detail"] == "vLLM upstream request timed out"
