#!/usr/bin/env python3
"""Posts a published release's title and notes to a Discord channel.

    VERSION=v0.7.2 NOTES_FILE=notes.md RELEASE_URL=<link> python3 tools/discord_post.py --dry-run

Without --dry-run it also needs DISCORD_WEBHOOK_URL=<webhook>. Everything is read from environment variables, never from the command line, so the
notes are only ever data and the webhook address stays out of process listings. Rules:
  - the notes keep their own markdown, without the sections written for the reviewer
    ("Before merging" and "Checks");
  - the version goes first and a link to the release last;
  - the text is split into messages of at most 2,000 characters, Discord's limit: between
    sections where it can, between lines otherwise, and only a single line longer than a
    whole message is ever split, at a word break;
  - no message can ping anyone, whatever the notes say;
  - the webhook address is never printed.
--dry-run prints the messages and sends nothing. With no webhook set the post is skipped
with a warning, so a release never depends on Discord. Exits 0 when posted, skipped or
dry-run, and 1 naming the reason otherwise.
"""
import argparse
import http.client
import json
import math
import os
import re
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from release_check import TITLE_PATTERN  # noqa: E402

MESSAGE_LIMIT = 2000
REVIEWER_SECTIONS = {"before merging", "checks"}
SECTION_HEADING = re.compile(r"## +(.*)")
USERNAME = "Mileage"
SUPPRESS_LINK_PREVIEWS = 4
# Discord turns away requests carrying Python's default User-Agent.
USER_AGENT = "DiscordBot (https://github.com/norto22/Mileage, 1.0)"
TIMEOUT_SECONDS = 15
MAX_RETRIES = 3
MAX_WAIT_SECONDS = 30


def without_reviewer_sections(notes):
    """Returns the notes' lines, leaving out each reviewer section up to the next heading."""
    kept = []
    skipping = False
    for line in notes.replace("\r\n", "\n").split("\n"):
        heading = SECTION_HEADING.fullmatch(line)
        if heading:
            skipping = heading.group(1).strip().casefold() in REVIEWER_SECTIONS
        if not skipping:
            kept.append(line)
    return "\n".join(kept).strip()


def sections_of(text):
    """Splits text into blocks, a new one starting at each section heading."""
    blocks = [[]]
    for line in text.split("\n"):
        if SECTION_HEADING.fullmatch(line):
            blocks.append([])
        blocks[-1].append(line)
    return ["\n".join(block).strip() for block in blocks if "".join(block).strip()]


def split_long_line(line):
    """Splits a line longer than a message at word breaks; cuts it where it has none."""
    pieces = []
    while len(line) > MESSAGE_LIMIT:
        cut = line.rfind(" ", 1, MESSAGE_LIMIT + 1)
        if cut <= 0:
            cut = MESSAGE_LIMIT
        pieces.append(line[:cut].rstrip())
        line = line[cut:].lstrip()
    pieces.append(line)
    return [piece for piece in pieces if piece]


def split_messages(text):
    """Packs text into messages, each at most MESSAGE_LIMIT characters."""
    messages = []
    current = ""

    def flush():
        nonlocal current
        if current.strip():
            messages.append(current.rstrip())
        current = ""

    for block in sections_of(text):
        joined = f"{current}\n\n{block}" if current else block
        if len(joined) <= MESSAGE_LIMIT:
            current = joined
            continue
        if len(block) <= MESSAGE_LIMIT:
            flush()
            current = block
            continue
        for line in ([""] if current else []) + block.split("\n"):
            line = line if line.strip() else ""
            if len(line) > MESSAGE_LIMIT:
                flush()
                *whole, current = split_long_line(line)
                messages.extend(whole)
            elif current or line.strip():
                candidate = f"{current}\n{line}" if current else line
                if len(candidate) > MESSAGE_LIMIT:
                    flush()
                    candidate = line
                current = candidate
    flush()
    return messages


def build_messages(version, notes, url):
    """Returns the Discord messages for a release, in posting order."""
    parts = [f"# {version}", without_reviewer_sections(notes), f"[Download {version}]({url})"]
    return split_messages("\n\n".join(part for part in parts if part))


def retry_delay(body, headers):
    """Returns the seconds Discord asked to wait, from its answer or else its header."""
    for read in (lambda: json.loads(body)["retry_after"], lambda: headers["Retry-After"]):
        try:
            delay = float(read())
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(delay) and delay >= 0:
            return min(delay, MAX_WAIT_SECONDS)
    return 1


def http_problem(status, body):
    """Describes a failed answer from Discord by its status and its own message."""
    try:
        detail = json.loads(body).get("message")
    except (AttributeError, ValueError):
        detail = None
    return f"Discord answered {status}" + (f" ({detail})" if detail else "")


def send(webhook, message):
    """Posts one message, waiting out rate limits. Returns what went wrong, or None."""
    payload = {
        "content": message,
        "username": USERNAME,
        "allowed_mentions": {"parse": []},
        "flags": SUPPRESS_LINK_PREVIEWS,
    }
    request = urllib.request.Request(
        f"{webhook}?wait=true",
        data=json.dumps(payload).encode("utf-8"),
        method="POST",
        headers={"Content-Type": "application/json", "User-Agent": USER_AGENT},
    )
    for attempt in range(MAX_RETRIES + 1):
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS):
                return None
        except urllib.error.HTTPError as error:
            body = error.read()
            if error.code != 429 or attempt == MAX_RETRIES:
                return http_problem(error.code, body)
            time.sleep(retry_delay(body, error.headers))
        except (OSError, http.client.HTTPException, ValueError) as error:
            return f"could not reach Discord: {error}"


def post(webhook, messages):
    """Posts the messages in order, stopping at the first that fails. Returns an exit code."""
    for sent, message in enumerate(messages):
        problem = send(webhook, message)
        if problem:
            for secret in (webhook, webhook.rsplit("/", 1)[-1]):
                problem = problem.replace(secret, "[webhook]") if secret else problem
            return fail(f"posted {sent} of {len(messages)}; {problem}")
    print(f"posted {len(messages)} message(s) to Discord")
    return 0


def fail(reason):
    print(f"discord post failed: {reason}", file=sys.stderr)
    return 1


def main(argv=None):
    parser = argparse.ArgumentParser(description="Posts a release's notes to Discord.")
    parser.add_argument("--dry-run", action="store_true", help="print the messages and send nothing")
    dry_run = parser.parse_args(argv).dry_run

    version = os.environ.get("VERSION", "")
    if not TITLE_PATTERN.fullmatch(version):
        return fail("version must be vX.X.X, for example v0.2.0")

    webhook = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    if not webhook and not dry_run:
        print("::warning::discord post skipped: no DISCORD_WEBHOOK_URL secret")
        return 0
    if not dry_run and not webhook.startswith("https://"):
        return fail("DISCORD_WEBHOOK_URL is not an https address")

    url = os.environ.get("RELEASE_URL", "")
    if not url:
        return fail("no release link in RELEASE_URL")
    try:
        with open(os.environ.get("NOTES_FILE", ""), encoding="utf-8") as handle:
            notes = handle.read()
    except (OSError, ValueError):
        return fail("could not read the notes file named by NOTES_FILE")

    messages = build_messages(version, notes, url)
    if dry_run:
        for number, message in enumerate(messages, 1):
            print(f"--- message {number} of {len(messages)} ({len(message)} characters) ---\n{message}")
        return 0
    return post(webhook, messages)


if __name__ == "__main__":
    sys.exit(main())
