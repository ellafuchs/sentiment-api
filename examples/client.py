"""Call the sentiment service from Python.

Start the service in one terminal:

    make run

Then in another:

    uv run python examples/client.py
    uv run python examples/client.py "your own sentence here"

The same code works against Cloud Run later — only BASE_URL changes.
"""

from __future__ import annotations

import sys

import httpx

BASE_URL = "http://localhost:8080"


def classify(texts: list[str], base_url: str = BASE_URL) -> list[dict]:
    """POST a batch of texts, get back a label and score for each.

    Send the whole list in one request rather than looping. The service runs a
    single forward pass over the batch, so 20 texts in one call costs far less
    than 20 separate calls.
    """
    response = httpx.post(
        f"{base_url}/predict",
        json={"texts": texts},
        timeout=30.0,
    )
    response.raise_for_status()
    return response.json()["predictions"]


def main() -> int:
    texts = sys.argv[1:] or [
        "I love this movie, it was fantastic!",
        "Absolutely terrible, a total waste of time.",
        "The food was great",
        "The food was not great",
    ]

    try:
        predictions = classify(texts)
    except httpx.ConnectError:
        print(f"Could not reach {BASE_URL} — is `make run` going in another terminal?")
        return 1
    except httpx.HTTPStatusError as exc:
        # 422 means the request violated the contract (empty batch, too many
        # items, text too long). The body says which.
        print(f"HTTP {exc.response.status_code}: {exc.response.text}")
        return 1

    for text, pred in zip(texts, predictions, strict=True):
        print(f"  {pred['label']:<8} {pred['score']:.4f}  {text}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
