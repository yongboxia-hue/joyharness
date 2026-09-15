#!/usr/bin/env python3
"""Publish a release's artifacts to the object storage the updater reads.

GitHub stays the canonical release -- it is where the signed package and its
checksum are archived, and it is the fallback if this bucket ever goes away.
But mainland China cannot reliably reach it, and the updater only ever talked
to GitHub: raw.githubusercontent.com for the feed, releases/download for the
package. Anyone who could not reach GitHub was stuck on whatever version they
first installed, no matter where the site pointed its download button. So the
feed and the packages it announces both live here now.

Two names for one build, because two readers want opposite things:

  JoyHarness-macos-v0.1.9.dmg   Sparkle. Each enclosure in the feed carries a
                                signature and a byte length for one exact
                                build, so its URL has to name an object that
                                never changes.
  JoyHarness.dmg                The website. A fixed address means the site
                                stops needing an edit and a deploy every
                                release just to move a version number, and the
                                file the visitor saves is named after the app
                                rather than after a number they cannot act on.
                                The app tells them what version they have.

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
import subprocess
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
# purging after a publish.
#
# A versioned package and the alias want opposite rules for the same bytes. The
# versioned name is good forever. The alias is the same URL with new bytes every
# release, and the feed is the same again: cached too long, a release is invisible
# to everyone who already visited.
IMMUTABLE = "public, max-age=31536000, immutable"
REVALIDATE = "public, max-age=300, must-revalidate"

CONTENT_TYPES = {
    ".dmg": "application/x-apple-diskimage",
    ".sha256": "text/plain; charset=utf-8",
    ".xml": "application/xml; charset=utf-8",
    ".txt": "text/plain; charset=utf-8",
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


def put(key: str, body: bytes, cache_control: str,
        secret_id: str, secret_key: str) -> None:
    suffix = Path(key).suffix
    if suffix not in CONTENT_TYPES:
        raise SystemExit(f"{key}: no serving rules for a {suffix} file")

    headers = {
        "host": HOST,
        "content-type": CONTENT_TYPES[suffix],
        "content-length": str(len(body)),
        "cache-control": cache_control,
    }
    if suffix == ".dmg":
        # COS already forces this on its default domain, but that is their
        # policy and not a promise. Saying it ourselves keeps "clicking the
        # button saves a file" from depending on a vendor default holding --
        # and names the saved file after the key, so the alias arrives as
        # JoyHarness.dmg rather than under the versioned name it was built as.
        headers["content-disposition"] = f'attachment; filename="{key}"'
    headers["authorization"] = authorization("put", key, headers, secret_id, secret_key)

    # The runner is not in China and the bucket is, so this is the same slow
    # link the whole migration exists because of, crossed in the other
    # direction. A flat 300s killed the first real release mid-package: the
    # write timed out, and the transfer that had already happened was thrown
    # away. Budget by size against a floor of 100KB/s, and retry -- a timeout
    # here is congestion, not a wrong request, and congestion passes.
    timeout = 60 + len(body) // 100_000
    attempts = 4
    for attempt in range(1, attempts + 1):
        # Re-signed each time: a signature is only valid for a window, and a
        # retry after a long stall could otherwise be rejected as expired --
        # which would read as a bad key rather than as a slow network.
        headers["authorization"] = authorization("put", key, {
            name: value for name, value in headers.items() if name != "authorization"
        }, secret_id, secret_key)
        request = urllib.request.Request(PUBLIC_PREFIX + quote(key, safe="/"),
                                         data=body, headers=headers, method="PUT")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                if response.status not in (200, 204):
                    raise SystemExit(f"{key}: COS answered HTTP {response.status}")
            break
        except urllib.error.HTTPError as error:
            # An answer, not a failure to reach: retrying will not change it.
            raise SystemExit(f"{key}: upload failed, HTTP {error.code}\n"
                             f"{error.read().decode('utf-8', 'replace')}") from error
        except (urllib.error.URLError, OSError) as error:
            if attempt == attempts:
                raise SystemExit(f"{key}: upload failed after {attempts} attempts "
                                 f"({timeout}s each): {error}") from error
            pause = 5 * attempt
            print(f"  ..   {key}: {error}; retrying in {pause}s "
                  f"({attempt}/{attempts - 1})", flush=True)
            time.sleep(pause)
    print(f"  put  {key}  ({len(body)} bytes, {CONTENT_TYPES[suffix]})")


def verify(key: str, body: bytes) -> None:
    """Read the object back anonymously and compare it to what we sent.

    Anonymously on purpose. This is the same request a person downloading the
    app makes, so one check covers three things that fail independently: the
    upload landed, the bucket is still public-read, and the bytes being served
    are the bytes that were signed and notarized. The website used to assert
    that its own copy matched its own copy, which is why it once served a
    package that would not launch for a full day without anything going red.
    """
    url = PUBLIC_PREFIX + quote(key, safe="/")
    try:
        with urllib.request.urlopen(url, timeout=60 + len(body) // 100_000) as response:
            served = response.read()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"{key}: published, but serving HTTP {error.code} to an "
                         f"anonymous reader -- check the bucket is public-read\n"
                         f"{error.read().decode('utf-8', 'replace')}") from error

    expected = hashlib.sha256(body).hexdigest()
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
    "cache-control": IMMUTABLE,
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


def alias_uploads(paths: list[Path], alias: str) -> list[tuple[str, bytes, str]]:
    """The same build, published again under the name the website links to."""
    packages = [path for path in paths if path.suffix == ".dmg"]
    if len(packages) != 1:
        raise SystemExit(f"--alias needs exactly one .dmg to alias, got {len(packages)}")
    package = packages[0]

    uploads = [(alias, package.read_bytes(), REVALIDATE)]

    digest_file = package.with_name(package.name + ".sha256")
    if digest_file.is_file():
        # Rewritten to name the alias, not the build it came from. `shasum -c`
        # compares the filename in the file against what is on disk, so a
        # checksum reading JoyHarness-macos-v0.1.9.dmg fails for someone who
        # downloaded JoyHarness.dmg -- and it fails as "no such file", which
        # reads as a corrupted or tampered download rather than as a cosmetic
        # naming mismatch.
        digest = digest_file.read_text().strip().split()[0]
        uploads.append((f"{alias}.sha256", f"{digest}  {alias}\n".encode(), REVALIDATE))
    return uploads


def credential(name: str) -> str:
    """The environment first, then the login keychain.

    CI has no keychain and sets the environment from repository secrets. A
    local publish has the opposite problem: passing a secret on a command line
    puts it in shell history, and prompting for it puts it wherever the session
    is being recorded. Reading it from the keychain means a local run needs
    neither -- the value is stored once, by hand, and never appears again.
    """
    value = os.environ.get(name, "")
    if value:
        return value
    try:
        found = subprocess.run(
            ["security", "find-generic-password", "-s", f"joyharness-{name}", "-w"],
            capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return ""
    return found.stdout.strip()


def check_credentials(secret_id: str, secret_key: str) -> int:
    """Prove the configured credentials can actually write to the bucket.

    --self-test checks the signature format and needs no credentials; this
    checks the credentials and needs the network. Both exist because the
    alternative is finding out during a release, after the build has been
    signed, notarized and published to GitHub -- at which point the tag is
    public and the fix is a re-run rather than an edit.

    It writes a small object rather than reading one: read access is public
    here, so a successful GET would prove nothing about the key.
    """
    # A real extension: Path(".credential-check").suffix is empty, and an
    # object with no known type is refused before it is ever uploaded.
    key = "credential-check.txt"
    body = f"ok {time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n".encode()
    put(key, body, REVALIDATE, secret_id, secret_key)
    verify(key, body)
    print("publish-to-cos: these credentials can write to the bucket.")
    return 0


def probe(megabytes: int, secret_id: str, secret_key: str) -> int:
    """Measure what this machine can actually push into the bucket.

    Written because the first real release died on a write timeout and the
    honest answer to "is a retry enough" was that nobody had measured the link.
    """
    body = b"\0" * (megabytes * 1024 * 1024)
    key = "credential-check.txt"
    started = time.monotonic()
    put(key, body, REVALIDATE, secret_id, secret_key)
    elapsed = time.monotonic() - started
    rate = len(body) / elapsed / 1024
    print(f"publish-to-cos: {megabytes}MB in {elapsed:.1f}s ({rate:.0f} KB/s)")
    return 0


def main(argv: list[str]) -> int:
    if argv == ["--self-test"]:
        return self_test()

    alias = ""
    if "--alias" in argv:
        index = argv.index("--alias")
        if index + 1 >= len(argv):
            print("--alias needs a filename", file=sys.stderr)
            return 2
        alias = argv[index + 1]
        argv = argv[:index] + argv[index + 2:]

    if not argv:
        print(__doc__, file=sys.stderr)
        return 2

    secret_id = credential("COS_SECRET_ID")
    secret_key = credential("COS_SECRET_KEY")
    if not secret_id or not secret_key:
        print("No COS credentials. CI sets COS_SECRET_ID and COS_SECRET_KEY from\n"
              "repository secrets; for a local publish, store them once with:\n"
              "  security add-generic-password -s joyharness-COS_SECRET_ID  -a \"$USER\" -w\n"
              "  security add-generic-password -s joyharness-COS_SECRET_KEY -a \"$USER\" -w\n"
              "Nothing was published.", file=sys.stderr)
        return 1

    if argv == ["--check-credentials"]:
        return check_credentials(secret_id, secret_key)

    if len(argv) == 2 and argv[0] == "--probe":
        return probe(int(argv[1]), secret_id, secret_key)

    paths = [Path(argument) for argument in argv]
    for path in paths:
        if not path.is_file():
            print(f"{path}: not a file", file=sys.stderr)
            return 1

    uploads = [(path.name, path.read_bytes(),
                REVALIDATE if path.suffix == ".xml" else IMMUTABLE)
               for path in paths]
    if alias:
        uploads += alias_uploads(paths, alias)

    # Feed last, whatever order the caller listed them in. See the module note.
    uploads.sort(key=lambda upload: upload[0].endswith(".xml"))

    for key, body, cache_control in uploads:
        put(key, body, cache_control, secret_id, secret_key)
        verify(key, body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
