"""
Sample FastAPI application demonstrating secure coding practices.
"""
from fastapi import FastAPI, HTTPException, Depends, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.trustedhost import TrustedHostMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, validator
from typing import Optional
import logging
import os
import boto3
import json

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="DevSecOps Sample API",
    docs_url=None,       # disable swagger in prod
    redoc_url=None,
    openapi_url=None,
)

app.add_middleware(TrustedHostMiddleware, allowed_hosts=["*"])
app.add_middleware(
    CORSMiddleware,
    allow_origins=os.environ.get("ALLOWED_ORIGINS", "").split(","),
    allow_credentials=False,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "X-Request-ID"],
)

ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
AWS_REGION  = os.environ.get("AWS_REGION", "us-east-1")


class HealthResponse(BaseModel):
    status: str
    environment: str
    version: str


class ItemRequest(BaseModel):
    name: str
    description: Optional[str] = None

    @validator("name")
    def name_must_be_safe(cls, v):
        if len(v) > 100:
            raise ValueError("name too long")
        forbidden = ["<", ">", "&", "'", '"', ";", "--", "/*"]
        for char in forbidden:
            if char in v:
                raise ValueError(f"name contains forbidden character: {char}")
        return v.strip()


def get_secret(secret_name: str) -> dict:
    client = boto3.client("secretsmanager", region_name=AWS_REGION)
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])


@app.get("/health", response_model=HealthResponse)
async def health():
    return {
        "status": "healthy",
        "environment": ENVIRONMENT,
        "version": os.environ.get("APP_VERSION", "1.0.0"),
    }


@app.get("/ready")
async def ready():
    return {"status": "ready"}


@app.post("/items", status_code=status.HTTP_201_CREATED)
async def create_item(item: ItemRequest):
    logger.info(f"Creating item: {item.name}")
    return {"id": "generated-uuid", "name": item.name}


@app.get("/items/{item_id}")
async def get_item(item_id: str):
    if not item_id.isalnum():
        raise HTTPException(status_code=400, detail="Invalid item ID")
    return {"id": item_id, "name": "example"}


@app.exception_handler(Exception)
async def generic_exception_handler(request, exc):
    logger.error(f"Unhandled exception: {exc}", exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error"},
    )
