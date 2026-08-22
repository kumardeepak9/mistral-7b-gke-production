from typing import Literal

from pydantic import BaseModel, Field

from app.config import settings


class ChatMessage(BaseModel):
    role: Literal["system", "user", "assistant"] = Field(
        description="OpenAI chat message role",
    )
    content: str = Field(min_length=1, description="Message text content")


class ChatCompletionRequest(BaseModel):
    model: str = Field(
        default_factory=lambda: settings.vllm_model_name,
        description="Model identifier. Defaults to configured vLLM model.",
    )
    messages: list[ChatMessage] = Field(
        ...,
        min_length=1,
        description="Conversation history",
    )
    max_tokens: int = Field(
        default_factory=lambda: settings.default_max_tokens,
        ge=1,
        description="Maximum tokens to generate",
    )
    temperature: float = Field(default=0.7, ge=0.0, le=2.0, description="Sampling temperature")
    stream: bool = Field(default=False, description="Streaming mode flag")


class ChatChoiceMessage(BaseModel):
    role: Literal["assistant"]
    content: str


class ChatChoice(BaseModel):
    index: int
    message: ChatChoiceMessage
    finish_reason: Literal["stop", "length", "content_filter", "tool_calls"] | None


class ChatUsage(BaseModel):
    prompt_tokens: int
    completion_tokens: int
    total_tokens: int


class ChatCompletionResponse(BaseModel):
    model_config = {"extra": "allow"}

    id: str
    object: Literal["chat.completion"]
    model: str
    choices: list[ChatChoice]
    usage: ChatUsage
    created: int | None = None
    system_fingerprint: str | None = None
