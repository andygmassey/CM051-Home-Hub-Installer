from __future__ import annotations

from typing import TYPE_CHECKING

# Lazy re-exports (PEP 562).
#
# Importing a stdlib-only submodule such as ``identity_resolver.compartment``
# must NOT eagerly pull ``.resolver`` (which imports ``httpx``) or
# ``.normalise`` (which imports ``phonenumbers``). Those heavy third-party
# deps are not installed in every service venv that only needs the compartment
# helpers -- e.g. the Assistant API (ical-server) imports
# ``identity_resolver.compartment.normalise_user_id`` at module load to derive
# USER_URI, and would otherwise crash-loop on a ModuleNotFoundError for httpx
# or phonenumbers even when compartment itself is dependency-free.
#
# The public names below therefore resolve on first attribute access via
# ``__getattr__`` instead of at package-import time. ``from identity_resolver
# import IdentityResolver`` (and friends) keep working unchanged.

__all__ = [
    "IdentityResolver",
    "MatchResult",
    "PersonIdentity",
    "normalise_email",
    "normalise_phone",
]

if TYPE_CHECKING:
    from .models import MatchResult, PersonIdentity
    from .normalise import normalise_email, normalise_phone
    from .resolver import IdentityResolver


def __getattr__(name: str):
    if name in ("MatchResult", "PersonIdentity"):
        from . import models

        return getattr(models, name)
    if name in ("normalise_email", "normalise_phone"):
        from . import normalise

        return getattr(normalise, name)
    if name == "IdentityResolver":
        from .resolver import IdentityResolver

        return IdentityResolver
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


def __dir__():
    return sorted(__all__)
