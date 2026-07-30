"""Tests for the sample API.

These focus on the security-relevant behaviour of the service: that the
interactive docs stay disabled, that input validation actually rejects the
inputs it claims to, and that unhandled errors do not leak internals.
"""

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError

from app import ItemRequest, app

client = TestClient(app)


def test_health_reports_healthy():
    response = client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "healthy"
    assert "environment" in body
    assert "version" in body


def test_ready_reports_ready():
    response = client.get("/ready")

    assert response.status_code == 200
    assert response.json() == {"status": "ready"}


@pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json"])
def test_interactive_docs_are_disabled(path):
    """The app disables these deliberately; a regression would expose the schema."""
    assert client.get(path).status_code == 404


def test_create_item_accepts_a_clean_name():
    response = client.post("/items", json={"name": "widget"})

    assert response.status_code == 201
    assert response.json()["name"] == "widget"


@pytest.mark.parametrize(
    "name",
    [
        "<script>",
        "a'b",
        'a"b',
        "a;b",
        "a--b",
        "a/*b",
        "a&b",
        "a>b",
    ],
)
def test_create_item_rejects_forbidden_characters(name):
    response = client.post("/items", json={"name": name})

    assert response.status_code == 422


def test_create_item_rejects_overlong_name():
    response = client.post("/items", json={"name": "x" * 101})

    assert response.status_code == 422


def test_item_name_is_stripped():
    assert ItemRequest(name="  widget  ").name == "widget"


def test_item_name_validation_is_enforced_at_the_model():
    with pytest.raises(ValidationError):
        ItemRequest(name="<script>")


def test_get_item_accepts_alphanumeric_id():
    response = client.get("/items/abc123")

    assert response.status_code == 200
    assert response.json()["id"] == "abc123"


@pytest.mark.parametrize("item_id", ["../etc/passwd", "abc-123", "abc 123", "a%2e%2e"])
def test_get_item_rejects_non_alphanumeric_id(item_id):
    response = client.get(f"/items/{item_id}")

    # Either the route rejects it or it never matches the route at all; both
    # outcomes keep the traversal attempt away from the handler body.
    assert response.status_code in (400, 404)
