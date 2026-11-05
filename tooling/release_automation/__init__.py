"""Offline-testable release automation for Pinchflat-ngx.

The package intentionally depends only on the Python standard library so the
release logic can be exercised without compiling the Elixir application or
contacting GitHub.
"""

__all__ = ["__version__"]

__version__ = "1.0.0"
