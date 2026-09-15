#!/usr/bin/env python3
"""Publish a release's artifacts to the object storage the updater reads.

GitHub stays the canonical release -- it is where the signed package and its
checksum are archived, and it is the fallback if this bucket ever goes away.
But mainland China cannot reliably reach it, and the updater only ever talked
to GitHub: raw.githubusercontent.com for the feed, releases/download for the
package. Anyone who could not reach GitHub was stuck on whatever version they
first installed, no matter where the site pointed its download button. So the
feed and the packages it announces both live here now.

No third-party packages. This runs in the workflow that holds the Developer ID
signing key, and COS's signature is forty lines of hmac -- pulling a vendor SDK
into that process to save them would widen what has to be trusted with the key.

Publish order is not cosmetic: packages first, feed last. The feed is the only
file that changes meaning at a fixed URL, so the window between "feed announces
0.1.9" and "0.1.9 is downloadable" is a window where every updater that checks
gets offered an update that 404s.
"""

from __future__ import annotations

import hashlib
import hmac
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BUCKET = "joyharness-1305183734"
REGION = "ap-shanghai"
HOST = f"{BUCKET}.cos.{REGION}.myqcloud.com"
PUBLIC_PREFIX = f"https://{HOST}/"

# There is no CDN in front of this bucket -- the default domain is the origin --
# so these headers are the only cache control there is, and nothing needs
# purging after a publish. A package filename carries its version, so a cached
# copy stays correct forever. The feed is the opposite: same URL, new meaning
# every release, and a stale cached copy is an update nobody is offered.
SERVING = {
    ".dmg": ("application/x-apple-diskimage", "public, max-age=31536000, immutable", True),
    ".sha256": ("text/plain; charset=utf-8", "public, max-age=31536000, immutable", False),
    ".xml": ("application/xml; charset=utf-8", "public, max-age=300, must-revalidate", False),
}


def quote(value: str, safe: str = "") -> str:
    return urllib.parse.quote(str(value), safe=safe)


def authorization(method: str, key: str, headers: dict[str, str],
                  secret_id: str, secret_key: str, valid_for: int = 900) -> str:
    """Build a COS request signature (q-sign-algorithm=sha1).

    Every header named in q-header-list is part of what is signed, so the
    request has to send exactly these and no fewer -- a header dropped in
    transit reads as a forged signature rather than as a missing header.
    """
    now = int(time.time())
    # Backdated a minute: the runner's clock and COS's do not have to agree to
    # the second, and a signature that is not valid yet fails as "access
    # denied", which reads as a wrong key rather than as a clock skew.
    key_time = f"{now - 60};{now + valid_for}"
    sign_key = hmac.new(secret_key.encode(), key_time.encode(), hashlib.sha1).hexdigest()

    signed = sorted((name.lower(), value) for name, value in headers.items())
    header_list = ";".join(name for name, _ in signed)
    header_string = "&".join(f"{quote(name)}={quote(value)}" for name, value in signed)

    # The leading slash is part of what COS signs. Without it every request
    # comes back SignatureDoesNotMatch -- which reads as a bad key rather than
    # as a malformed path, and the key is the first thing you go check.
    http_string = f"{method.lower()}\n/{quote(key, safe='/')}\n\n{header_string}\n"
    string_to_sign = f"sha1\n{key_time}\n{hashlib.sha1(http_string.encode()).hexdigest()}\n"
    signature = hmac.new(sign_key.encode(), string_to_sign.encode(), hashlib.sha1).hexdigest()

    return ("q-sign-algorithm=sha1"
            f"&q-ak={secret_id}"
            f"&q-sign-time={key_time}"
            f"&q-key-time={key_time}"
            f"&q-header-list={header_list}"
            "&q-url-param-list="
            f"&q-signature={signature}")


def put(path: Path, secret_id: str, secret_key: str) -> None:
    if path.suffix not in SERVING:
        raise SystemExit(f"{path.name}: no serving rules for a {path.suffix} file")
    content_type, cache_control, as_attachment = SERVING[path.suffix]
    body = path.read_bytes()
    key = path.name

    headers = {
        "host": HOST,
        "content-type": content_type,
        "content-length": str(len(body)),
        "cache-control": cache_control,
    }
    if as_attachment:
        # COS already forces this on its default domain, but that is their
        # policy and not a promise. Saying it ourselves keeps "clicking the
        # button saves a file" from depending on a vendor default holding.
        headers["content-disposition"] = f'attachment; filename="{key}"'
    headers["authorization"] = authorization("put", key, headers, secret_id, secret_key)

    request = urllib.request.Request(PUBLIC_PREFIX + quote(key, safe="/"),
                                     data=body, headers=headers, method="PUT")
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            if response.status not in (200, 204):
                raise SystemExit(f"{key}: COS answered HTTP {response.status}")
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{key}: upload failed, HTTP {error.code}\n"
                         f"{error.read().decode('utf-8', 'replace')}") from error
    print(f"  put  {key}  ({len(body)} bytes, {content_type})")


def verify(path: Path) -> None:
    """Read the object back anonymously and compare it to what we sent.

    Anonymously on purpose. This is the same request a person downloading the
    app makes, so one check covers three things that fail independently: the
    upload landed, the bucket is still public-read, and the bytes being served
    are the bytes that were signed and notarized. The website used to assert
    that its own copy matched its own copy, which is why it once served a
    package that would not launch for a full day without anything going red.
    """
    key = path.name
    url = PUBLIC_PREFIX + quote(key, safe="/")
    try:
        with urllib.request.urlopen(url, timeout=300) as response:
            served = response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{key}: published, but serving HTTP {error.code} to an "
                         f"anonymous reader -- check the bucket is public-read\n"
                         f"{error.read().decode('utf-8', 'replace')}") from error

    expected = hashlib.sha256(path.read_bytes()).hexdigest()
    actual = hashlib.sha256(served).hexdigest()
    if expected != actual:
        raise SystemExit(f"{key}: served bytes are not the bytes we uploaded "
                         f"(sent {expected[:12]}…, served {actual[:12]}…)")
    print(f"  ok   {url}")


# The exact string COS said it expected, quoted back to us in a 403 body when
# the path in the signature was missing its leading slash. It is the only
# authority we have for this format that is not our own reading of the docs, so
# it is kept as a fixture: the signature can be checked for free, offline, and
# without credentials, which matters because the failure it guards against
# arrives as "SignatureDoesNotMatch" -- indistinguishable from a wrong key, and
# the key is the first place anyone looks.
SELF_TEST_HEADERS = {
    "host": HOST,
    "content-type": "application/x-apple-diskimage",
    "content-length": "21299002",
    "cache-control": "public, max-age=31536000, immutable",
    "content-disposition": 'attachment; filename="JoyHarness-macos-v0.1.8.dmg"',
}
SELF_TEST_KEY = "JoyHarness-macos-v0.1.8.dmg"
SELF_TEST_EXPECTED = (
    "put\n"
    "/JoyHarness-macos-v0.1.8.dmg\n"
    "\n"
    "cache-control=public%2C%20max-age%3D31536000%2C%20immutable"
    "&content-disposition=attachment%3B%20filename%3D%22JoyHarness-macos-v0.1.8.dmg%22"
    "&content-length=21299002"
    "&content-type=application%2Fx-apple-diskimage"
    "&host=joyharness-1305183734.cos.ap-shanghai.myqcloud.com\n"
)


def self_test() -> int:
    signed = sorted((name.lower(), value) for name, value in SELF_TEST_HEADERS.items())
    header_string = "&".join(f"{quote(name)}={quote(value)}" for name, value in signed)
    built = f"put\n/{quote(SELF_TEST_KEY, safe='/')}\n\n{header_string}\n"
    if built != SELF_TEST_EXPECTED:
        print("the signed string is not what COS expects:", file=sys.stderr)
        print(f"  built    {built!r}", file=sys.stderr)
        print(f"  expected {SELF_TEST_EXPECTED!r}", file=sys.stderr)
        return 1
    print("publish-to-cos: signature format matches the fixture COS returned.")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2

    secret_id = os.environ.get("COS_SECRET_ID", "")
    secret_key = os.environ.get("COS_SECRET_KEY", "")
    if not secret_id or not secret_key:
        print("COS_SECRET_ID and COS_SECRET_KEY are not set; nothing was published.",
              file=sys.stderr)
        return 1

    paths = [Path(argument) for argument in argv]
    for path in paths:
        if not path.is_file():
            print(f"{path}: not a file", file=sys.stderr)
            return 1

    # Feed last, whatever order the caller listed them in. See the module note.
    paths.sort(key=lambda path: path.suffix == ".xml")

    for path in paths:
        put(path, secret_id, secret_key)
        verify(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
