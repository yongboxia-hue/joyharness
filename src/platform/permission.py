"""Accessibility permission, which macOS requires before pynput can send keys."""

from __future__ import annotations

import logging
import subprocess

logger = logging.getLogger(__name__)


def has_required_permissions() -> bool:
    """Check if the process has the permissions needed for keyboard simulation."""
    return _check_macos_accessibility()


def get_permission_warning() -> str:
    """Return a user-facing warning message for missing permissions."""
    return (
        "WARNING: Accessibility permission not granted.\n"
        "         Go to: System Settings → Privacy & Security → Accessibility\n"
        "         Allow JoyHarness. If the entry already exists but input does not work,\n"
        "         run scripts/verify-macos-code-identity.sh before resetting permissions.\n"
        "         Then restart JoyHarness.\n"
    )


def request_required_permissions() -> bool:
    """Request missing platform permissions for the current process when possible."""
    return _request_macos_accessibility()


def _check_macos_accessibility() -> bool:
    """Check Accessibility permission for the current JoyHarness process."""
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:
        logger.debug("Accessibility check failed, assuming not granted")
        return False


def _request_macos_accessibility() -> bool:
    """Prompt macOS Accessibility authorization for the current Python service."""
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions, kAXTrustedCheckOptionPrompt

        trusted = bool(AXIsProcessTrustedWithOptions({kAXTrustedCheckOptionPrompt: True}))
        if trusted:
            return True
    except Exception:
        logger.debug("Accessibility prompt failed", exc_info=True)

    try:
        subprocess.Popen(
            ["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        logger.debug("Could not open Accessibility settings", exc_info=True)
    return _check_macos_accessibility()
