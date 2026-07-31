"""Fetch model weights into the local cache.

Run by ``make fetch`` for local development, and by the Docker builder stage so
the weights end up baked into the image. Keeping it as a module rather than an
inline shell one-liner means the build and your laptop run identical code.

    uv run python -m app.fetch [--force]
"""

from __future__ import annotations

import argparse
import logging
import os
import sys

# Must be set before huggingface_hub is imported anywhere — it reads this into a
# module constant at import time.
#
# Xet is the Hub's newer content-addressed transfer backend. It currently 404s
# on `xet-read-token` for pinned-revision downloads of some repos, including our
# default model. Falling back to plain HTTPS is slower on cache hits and entirely
# reliable, which is the correct trade for a build step that must not flake.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

from app.config import load_config  # noqa: E402
from app.model import ensure_weights  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--force", action="store_true", help="re-download even if present")
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    config = load_config()
    dest = ensure_weights(config, force=args.force)

    size_mb = sum(f.stat().st_size for f in dest.rglob("*") if f.is_file()) / 1e6
    print(f"\n{config.model.version}\n  -> {dest}  ({size_mb:.0f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
