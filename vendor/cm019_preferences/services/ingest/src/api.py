"""FastAPI routes for the ingest service."""

import logging
import os
from pathlib import Path
from typing import Optional, List
from datetime import datetime
import uuid
import tempfile

from fastapi import Depends, FastAPI, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Shared JWT verification (CM019 clean-house PR 1). Importing this
# package triggers the import-time JWT_SECRET validation in
# auth.jwt -- starting the ingest service without a real secret
# raises RuntimeError at boot rather than silently accepting tokens
# signed with a placeholder.
from auth import require_auth

from .config import settings
from .pipeline import pipeline

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="PWG Ingest Service",
    description="Data ingestion pipeline for Personal World Graph",
    version="0.1.0"
)

# CORS allowlist (CM019 clean-house PR 6). Previous wildcard
# allow_origins=["*"] combined with allow_credentials=True is a
# known footgun. Ingest is bound to 127.0.0.1 and reached only by
# the local assistant, so the legitimate browser origins are
# localhost-based. Comma-separated list via INGEST_CORS_ORIGINS
# overrides the default for environments that need additional
# origins (e.g. the Doctor's tailnet origin for a future browser
# surface).
_DEFAULT_CORS_ORIGINS = [
    "http://localhost",
    "http://127.0.0.1",
]
_cors_env = os.environ.get("INGEST_CORS_ORIGINS", "").strip()
_cors_origins = (
    [o.strip() for o in _cors_env.split(",") if o.strip()]
    if _cors_env
    else _DEFAULT_CORS_ORIGINS
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_origin_regex=r"^http://(localhost|127\.0\.0\.1)(:\d+)?$",
    allow_credentials=True,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
)


# Request/Response models
class IngestResponse(BaseModel):
    """Response from ingestion."""
    request_id: str
    status: str
    preferences_created: int
    triples_inserted: int
    vectors_inserted: int
    duration_seconds: float
    errors: List[str]


class SearchRequest(BaseModel):
    """Vector similarity search request."""
    query: str
    user_id: str
    compartment_level: int = 4
    limit: int = 10


class SearchResult(BaseModel):
    """Single search result."""
    preference_id: str
    subject: str
    score: float
    preference_type: str
    category: Optional[str]
    compartment_level: int


class StatsResponse(BaseModel):
    """Pipeline statistics."""
    files_processed: int
    preferences_created: int
    triples_inserted: int
    vectors_inserted: int
    errors: int
    vectorizer_dimension: int
    embedding_model: str


# Startup/shutdown events
@app.on_event("startup")
async def startup():
    """Initialize pipeline on startup."""
    await pipeline.initialize()
    logger.info("Ingest service started")


# Health endpoints
@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "service": "ingest",
        "timestamp": datetime.utcnow().isoformat()
    }


@app.get("/ready")
async def ready():
    """Readiness check - verifies dependencies."""
    oxigraph_ok = await pipeline.oxigraph.health_check()
    qdrant_ok = await pipeline.qdrant.health_check()

    if not oxigraph_ok or not qdrant_ok:
        raise HTTPException(
            status_code=503,
            detail={
                "oxigraph": "healthy" if oxigraph_ok else "unhealthy",
                "qdrant": "healthy" if qdrant_ok else "unhealthy"
            }
        )

    return {
        "status": "ready",
        "dependencies": {
            "oxigraph": "healthy",
            "qdrant": "healthy"
        }
    }


# Ingest endpoints
#
# POST /ingest/file and POST /ingest/directory removed in CM019
# clean-house PR 6: read-anywhere primitives whose legitimate caller
# (the assistant binary) routes through /ingest/upload with the file
# body in the request. Removal is the clean fix per the design doc
# Section 5.
@app.post("/ingest/upload", response_model=IngestResponse)
async def ingest_upload(
    file: UploadFile = File(...),
    user_id: str = Form(...),
    compartment_level: Optional[int] = Form(None),
    category: Optional[str] = Form(None),
    _auth=Depends(require_auth),
):
    """Ingest an uploaded file. Service-token only."""
    request_id = str(uuid.uuid4())

    # Validate file size
    max_size = settings.max_file_size_mb * 1024 * 1024
    content = await file.read()
    if len(content) > max_size:
        raise HTTPException(
            status_code=413,
            detail=f"File too large. Maximum size: {settings.max_file_size_mb}MB"
        )

    # Save to temp file
    suffix = Path(file.filename).suffix if file.filename else ".tmp"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(content)
        tmp_path = Path(tmp.name)

    try:
        result = await pipeline.ingest_file(
            tmp_path,
            user_id,
            compartment_level=compartment_level,
            category=category
        )

        return IngestResponse(
            request_id=request_id,
            status="success" if not result["errors"] else "partial",
            preferences_created=result["preferences_created"],
            triples_inserted=result["triples_inserted"],
            vectors_inserted=result["vectors_inserted"],
            duration_seconds=result["duration_seconds"],
            errors=result["errors"]
        )

    finally:
        # Cleanup temp file
        tmp_path.unlink(missing_ok=True)


# Search endpoints
@app.post("/search", response_model=List[SearchResult])
async def search_similar(
    request: SearchRequest,
    _auth=Depends(require_auth),
):
    """Search for similar preferences using vector similarity.
    Service-token only."""
    results = await pipeline.search_similar(
        query=request.query,
        user_id=request.user_id,
        compartment_level=request.compartment_level,
        limit=request.limit
    )

    return [
        SearchResult(
            preference_id=r.get("payload", {}).get("preference_id", ""),
            subject=r.get("payload", {}).get("subject", ""),
            score=r.get("score", 0),
            preference_type=r.get("payload", {}).get("preference_type", ""),
            category=r.get("payload", {}).get("category"),
            compartment_level=r.get("payload", {}).get("compartment_level", 4)
        )
        for r in results
    ]


# GET /search/embed removed in CM019 clean-house PR 6: debug-only
# surface that reveals the first 10 dims of any embedding. No
# legitimate caller.


# Stats endpoints
@app.get("/stats", response_model=StatsResponse)
async def get_stats(_auth=Depends(require_auth)):
    """Get pipeline statistics. Service-token only."""
    stats = pipeline.get_stats()
    return StatsResponse(**stats)


@app.get("/stats/counts")
async def get_counts(
    user_id: Optional[str] = None,
    _auth=Depends(require_auth),
):
    """Get vector and triple counts. Service-token only."""
    vector_count = await pipeline.qdrant.count(user_id)
    triple_count = await pipeline.oxigraph.count_triples()

    return {
        "vectors": vector_count,
        "triples": triple_count,
        "user_id": user_id
    }


# Run with: uvicorn src.api:app --host 127.0.0.1 --port 8001
#
# Bind defaults to 127.0.0.1 (CM019 clean-house PR 6, design doc
# Section 4): ingest is reached by the local assistant only and
# iOS does not call this service. INGEST_HOST overrides for envs
# that need to bind elsewhere (e.g. a Tailscale interface IP for a
# multi-machine future) -- the customer install runs on a single
# machine.
if __name__ == "__main__":
    import uvicorn
    host = os.environ.get("INGEST_HOST", "127.0.0.1")
    uvicorn.run(app, host=host, port=8001)
