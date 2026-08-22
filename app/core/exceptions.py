import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.status import HTTP_500_INTERNAL_SERVER_ERROR

from app.schemas import ErrorResponse

logger = logging.getLogger(__name__)


def _request_id(request: Request) -> str | None:
    return getattr(request.state, "request_id", None)


def add_exception_handlers(app: FastAPI) -> None:
    @app.exception_handler(RequestValidationError)
    async def validation_exception_handler(
        request: Request,
        exc: RequestValidationError,
    ) -> JSONResponse:
        request_id = _request_id(request)
        logger.warning(
            "Request validation failed",
            extra={"request_id": request_id, "path": request.url.path, "errors": exc.errors()},
        )
        payload = ErrorResponse(detail="Request validation failed", request_id=request_id)
        return JSONResponse(status_code=422, content=payload.model_dump())

    @app.exception_handler(StarletteHTTPException)
    async def http_exception_handler(
        request: Request,
        exc: StarletteHTTPException,
    ) -> JSONResponse:
        request_id = _request_id(request)
        logger.info(
            "HTTP exception raised",
            extra={
                "request_id": request_id,
                "path": request.url.path,
                "status_code": exc.status_code,
                "detail": exc.detail,
            },
        )
        payload = ErrorResponse(detail=str(exc.detail), request_id=request_id)
        return JSONResponse(status_code=exc.status_code, content=payload.model_dump())

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(
        request: Request,
        exc: Exception,
    ) -> JSONResponse:
        request_id = _request_id(request)
        logger.exception(
            "Unhandled application exception",
            extra={"request_id": request_id, "path": request.url.path},
        )
        payload = ErrorResponse(detail="Internal server error", request_id=request_id)
        return JSONResponse(status_code=HTTP_500_INTERNAL_SERVER_ERROR, content=payload.model_dump())
