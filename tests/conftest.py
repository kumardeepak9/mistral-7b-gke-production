from collections.abc import Iterator

import pytest
from fastapi.testclient import TestClient

from app.main import create_application


@pytest.fixture
def client() -> Iterator[TestClient]:
    app = create_application()
    with TestClient(app) as test_client:
        yield test_client
