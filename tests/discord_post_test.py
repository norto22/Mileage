#!/usr/bin/env python3
"""Tests for tools/discord_post.py and the workflows that run it.

    python3 tests/discord_post_test.py               every test
    python3 tests/discord_post_test.py Messages      one class

Nothing here reaches GitHub or Discord: the web request is replaced by a stand-in.
"""
import contextlib
import http.client
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))

import discord_post  # noqa: E402

VERSION = "v0.7.3"
URL = "https://github.com/norto22/Mileage/releases/tag/v0.7.3"
LINK = "[Download v0.7.3](https://github.com/norto22/Mileage/releases/tag/v0.7.3)"
LIMIT = 2000
TOKEN = "made-up-webhook-token"
WEBHOOK = f"https://discord.example/api/webhooks/1/{TOKEN}"


def build(notes):
    return discord_post.build_messages(VERSION, notes, URL)


def bullets(count, length=300):
    """Returns numbered bullet lines, each exactly `length` characters long."""
    lines = []
    for number in range(count):
        start = f"- bullet {number} "
        lines.append(start + "x" * (length - len(start)))
    return lines


class Messages(unittest.TestCase):
    def assert_well_formed(self, messages):
        self.assertTrue(messages)
        for message in messages:
            self.assertLessEqual(len(message), LIMIT)
            self.assertTrue(message.strip())
            self.assertFalse(message.startswith("\n"))
            self.assertFalse(message.endswith("\n"))
            self.assertNotEqual(message.split("\n")[0].strip(), "")
            self.assertNotEqual(message.split("\n")[-1].strip(), "")

    def test_short_notes_are_one_message_with_the_heading_first_and_the_link_last(self):
        messages = build("## Fixed\n\n- **A fix.** It works now.")
        self.assertEqual(
            messages, [f"# {VERSION}\n\n## Fixed\n\n- **A fix.** It works now.\n\n{LINK}"]
        )

    def test_reviewer_sections_are_left_out_and_every_other_section_stays(self):
        notes = (
            "## Fixed\n\n- One.\n\n## Before merging\n\n- Test it.\n\n"
            "## For server owners\n\n- Two.\n\n## Checks\n\nAll pass.\n\n## Not yet played live\n\nThree."
        )
        text = "\n".join(build(notes))
        for kept in ("## Fixed", "- One.", "## For server owners", "- Two.", "## Not yet played live", "Three."):
            self.assertIn(kept, text)
        for dropped in ("Before merging", "Test it.", "## Checks", "All pass."):
            self.assertNotIn(dropped, text)

    def test_reviewer_headings_match_in_any_letter_case_and_with_stray_spaces(self):
        text = "\n".join(build("## New\n\nKept.\n\n##   BEFORE merging  \n\nGone one.\n\n## checks\n\nGone two."))
        self.assertIn("Kept.", text)
        self.assertNotIn("Gone one.", text)
        self.assertNotIn("Gone two.", text)

    def test_other_headings_and_text_that_mention_checks_stay(self):
        notes = "## Checks done\n\nKept heading.\n\n## New\n\nThe Checks section and Before merging are named here."
        text = "\n".join(build(notes))
        self.assertIn("## Checks done", text)
        self.assertIn("Kept heading.", text)
        self.assertIn("The Checks section and Before merging are named here.", text)

    def test_notes_saved_with_windows_line_endings_lose_reviewer_sections_too(self):
        messages = build("## Fixed\r\n\r\n- One.\r\n\r\n## Checks\r\n\r\nAll pass.\r\n")
        self.assertEqual(messages, [f"# {VERSION}\n\n## Fixed\n\n- One.\n\n{LINK}"])

    def test_empty_notes_are_one_message_with_the_heading_and_link(self):
        self.assertEqual(build(""), [f"# {VERSION}\n\n{LINK}"])
        self.assertEqual(build("  \n\n"), [f"# {VERSION}\n\n{LINK}"])

    def test_notes_with_only_reviewer_sections_are_one_message_with_the_heading_and_link(self):
        self.assertEqual(build("## Before merging\n\nA.\n\n## Checks\n\nB."), [f"# {VERSION}\n\n{LINK}"])

    def test_long_notes_keep_every_line_in_order_within_the_limit(self):
        sections = []
        for name in ("Fixed", "New", "Changed"):
            sections.append(f"## {name}\n\n" + "\n".join(bullets(5)))
        notes = "\n\n".join(sections)
        messages = build(notes)
        self.assertGreater(len(messages), 1)
        self.assert_well_formed(messages)
        kept = [line for line in "\n".join(messages).split("\n") if line.strip()]
        wanted = [f"# {VERSION}"] + [line for line in notes.split("\n") if line.strip()] + [LINK]
        self.assertEqual(kept, wanted)
        self.assertTrue(messages[0].startswith(f"# {VERSION}\n"))
        self.assertTrue(messages[-1].endswith(LINK))

    def test_sections_that_fit_are_kept_whole(self):
        first = "## First\n\n" + "\n".join(bullets(5))
        second = "## Second\n\n" + "\n".join(bullets(5))
        messages = build(f"{first}\n\n{second}")
        self.assertEqual(len(messages), 2)
        self.assertIn("## First", messages[0])
        self.assertNotIn("## Second", messages[0])
        self.assertTrue(messages[1].startswith("## Second"))

    def test_a_section_over_the_limit_breaks_only_between_lines(self):
        lines = bullets(12)
        messages = build("## Big\n\n" + "\n".join(lines))
        self.assertGreater(len(messages), 1)
        self.assert_well_formed(messages)
        posted = [line for message in messages for line in message.split("\n")]
        for line in lines:
            self.assertIn(line, posted)

    def test_a_bullet_longer_than_a_message_continues_at_a_word_break_and_is_the_only_line_split(self):
        long_bullet = "- " + " ".join(["word"] * 500)
        self.assertEqual(len(long_bullet), 2501)
        before = bullets(2)
        after = bullets(2)
        messages = build("## New\n\n" + "\n".join(before + [long_bullet] + after))
        self.assert_well_formed(messages)
        posted = [line for message in messages for line in message.split("\n")]
        for line in before + after:
            self.assertIn(line, posted)
        self.assertNotIn(long_bullet, posted)
        pieces = [line for line in posted if line.startswith("- word") or line.startswith("word")]
        self.assertEqual(len(pieces), 2)
        self.assertEqual(" ".join(pieces), long_bullet)
        started = [message for message in messages if message.startswith("- word")]
        self.assertEqual(len(started), 1)

    def test_a_line_with_no_spaces_is_cut_at_the_limit(self):
        solid = "x" * 2500
        messages = build(solid)
        self.assert_well_formed(messages)
        self.assertEqual("".join(line for message in messages for line in message.split("\n") if line.startswith("x")), solid)

    def test_a_very_long_line_of_spaces_is_treated_as_a_blank_line(self):
        messages = build("## New\n\n" + "\n".join(bullets(7)) + "\n" + " " * 2500 + "\n- after")
        self.assert_well_formed(messages)
        self.assertIn("- after", "\n".join(messages))

    def test_text_of_exactly_the_limit_stays_one_message(self):
        room = LIMIT - len(f"# {VERSION}\n\n\n\n{LINK}")
        messages = build("y" * room)
        self.assertEqual(len(messages), 1)
        self.assertEqual(len(messages[0]), LIMIT)

    def test_one_character_over_the_limit_makes_two_messages(self):
        room = LIMIT - len(f"# {VERSION}\n\n\n\n{LINK}") + 1
        self.assertEqual(len(build("y" * room)), 2)


class Response:
    """Stands in for a successful answer from Discord."""

    status = 200

    def __enter__(self):
        return self

    def __exit__(self, *details):
        return False


def http_error(status, body=b"{}", headers=None):
    return urllib.error.HTTPError(WEBHOOK + "?wait=true", status, "failed", headers or {}, io.BytesIO(body))


class Run:
    """Runs the script's main() with a stand-in for the web request and the clock."""

    def __init__(self, notes="## Fixed\n\n- One.", args=(), answers=(), **env):
        self.answers = list(answers)
        self.requests = []
        self.sleeps = []
        self.stdout = io.StringIO()
        self.stderr = io.StringIO()
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "notes.md")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(notes)
            values = {
                "VERSION": VERSION,
                "NOTES_FILE": path,
                "RELEASE_URL": URL,
                "DISCORD_WEBHOOK_URL": WEBHOOK,
            }
            values.update(env)
            values = {key: value for key, value in values.items() if value is not None}
            with mock.patch.dict(os.environ, values, clear=True), mock.patch(
                "urllib.request.urlopen", self.urlopen
            ), mock.patch("time.sleep", self.sleeps.append), contextlib.redirect_stdout(
                self.stdout
            ), contextlib.redirect_stderr(self.stderr):
                self.code = discord_post.main(list(args))
        self.output = self.stdout.getvalue() + self.stderr.getvalue()

    def urlopen(self, request, timeout=None):
        self.requests.append(request)
        if self.answers:
            answer = self.answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
        return Response()

    def payloads(self):
        return [json.loads(request.data) for request in self.requests]


class Mentions(unittest.TestCase):
    def test_every_message_switches_off_every_mention(self):
        notes = "\n".join(f"- @everyone @here <@&123> <@456> line {n} " + "x" * 300 for n in range(20))
        run = Run(notes=notes)
        self.assertEqual(run.code, 0)
        self.assertGreater(len(run.requests), 1)
        for payload in run.payloads():
            self.assertEqual(payload["allowed_mentions"], {"parse": []})

    def test_mentions_stay_as_plain_text_and_the_post_adds_none(self):
        run = Run(notes="- Hello @everyone and @here.")
        content = run.payloads()[0]["content"]
        self.assertIn("@everyone", content)
        self.assertEqual(Run(notes="- Hello.").payloads()[0]["content"].count("@"), 0)


class Posting(unittest.TestCase):
    def test_each_message_is_posted_in_order_with_its_settings(self):
        notes = "\n".join(bullets(20))
        run = Run(notes=notes)
        wanted = discord_post.build_messages(VERSION, notes, URL)
        self.assertEqual(run.code, 0)
        self.assertGreater(len(wanted), 1)
        self.assertEqual([payload["content"] for payload in run.payloads()], wanted)
        for request, payload in zip(run.requests, run.payloads()):
            self.assertEqual(request.full_url, WEBHOOK + "?wait=true")
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(request.get_header("Content-type"), "application/json")
            self.assertIn("DiscordBot", request.get_header("User-agent"))
            self.assertEqual(payload["username"], "Mileage")
            self.assertEqual(payload["flags"], 4)

    def test_a_dry_run_prints_each_message_and_sends_nothing(self):
        notes = "\n".join(bullets(20))
        run = Run(notes=notes, args=["--dry-run"])
        wanted = discord_post.build_messages(VERSION, notes, URL)
        self.assertEqual(run.code, 0)
        self.assertEqual(run.requests, [])
        for number, message in enumerate(wanted, 1):
            self.assertIn(f"--- message {number} of {len(wanted)} ({len(message)} characters) ---\n{message}\n", run.output)

    def test_a_dry_run_needs_no_webhook(self):
        run = Run(args=["--dry-run"], DISCORD_WEBHOOK_URL=None)
        self.assertEqual(run.code, 0)
        self.assertIn("--- message 1 of 1", run.output)

    def test_a_rate_limit_waits_as_told_and_retries(self):
        run = Run(answers=[http_error(429, b'{"retry_after": 2.5}')])
        self.assertEqual(run.code, 0)
        self.assertEqual(len(run.requests), 2)
        self.assertEqual(run.sleeps, [2.5])

    def test_a_rate_limit_waits_at_most_30_seconds(self):
        run = Run(answers=[http_error(429, b'{"retry_after": 900}')])
        self.assertEqual(run.sleeps, [30])

    def test_a_rate_limit_with_an_unreadable_answer_uses_the_header_or_one_second(self):
        run = Run(answers=[http_error(429, b"oops", {"Retry-After": "4"})])
        self.assertEqual(run.sleeps, [4])
        run = Run(answers=[http_error(429, b"oops")])
        self.assertEqual(run.sleeps, [1])


class SkipAndFailure(unittest.TestCase):
    def assert_failed(self, run, *words):
        self.assertEqual(run.code, 1)
        self.assertIn("discord post failed: ", run.stderr.getvalue())
        for word in words:
            self.assertIn(word, run.stderr.getvalue())
        self.assertNotIn(WEBHOOK, run.output)
        self.assertNotIn(TOKEN, run.output)

    def test_no_webhook_skips_with_a_warning_and_sends_nothing(self):
        for value in (None, "", "   "):
            run = Run(DISCORD_WEBHOOK_URL=value)
            self.assertEqual(run.code, 0)
            self.assertEqual(run.requests, [])
            self.assertIn("::warning::discord post skipped: no DISCORD_WEBHOOK_URL secret", run.stdout.getvalue())

    def test_a_bad_version_fails_and_sends_nothing(self):
        for version in (None, "", "0.7.3", "v0.7", "v0.7.3-rc1", "v0.7.3\n"):
            run = Run(VERSION=version)
            self.assert_failed(run, "version")
            self.assertEqual(run.requests, [])

    def test_a_missing_notes_file_fails_and_sends_nothing(self):
        for path in (None, "/nonexistent/notes.md"):
            run = Run(NOTES_FILE=path)
            self.assert_failed(run, "notes")
            self.assertEqual(run.requests, [])

    def test_a_missing_release_link_fails_and_sends_nothing(self):
        run = Run(RELEASE_URL=None)
        self.assert_failed(run, "release link")
        self.assertEqual(run.requests, [])

    def test_a_webhook_that_is_not_https_fails_without_printing_it(self):
        run = Run(DISCORD_WEBHOOK_URL=f"http://example.invalid/{TOKEN}")
        self.assert_failed(run, "https")
        self.assertEqual(run.requests, [])

    def test_a_rate_limit_that_never_clears_stops_after_3_retries(self):
        run = Run(answers=[http_error(429, b'{"retry_after": 1}') for _ in range(9)])
        self.assert_failed(run, "posted 0 of 1", "429")
        self.assertEqual(len(run.requests), 4)
        self.assertEqual(len(run.sleeps), 3)

    def test_a_webhook_discord_reports_as_gone_is_not_retried(self):
        run = Run(answers=[http_error(404, b'{"message": "Unknown Webhook"}')])
        self.assert_failed(run, "posted 0 of 1", "404", "Unknown Webhook")
        self.assertEqual(len(run.requests), 1)
        self.assertEqual(run.sleeps, [])

    def test_a_failure_part_way_says_how_many_went_out_and_stops(self):
        notes = "\n".join(bullets(20))
        total = len(discord_post.build_messages(VERSION, notes, URL))
        run = Run(notes=notes, answers=[Response(), http_error(500)])
        self.assert_failed(run, f"posted 1 of {total}", "500")
        self.assertEqual(len(run.requests), 2)

    def test_a_network_error_never_prints_the_webhook(self):
        run = Run(answers=[urllib.error.URLError(f"could not reach {WEBHOOK}?wait=true")])
        self.assert_failed(run, "posted 0 of 1")

    def test_a_broken_connection_is_a_failure_not_a_crash(self):
        run = Run(answers=[http.client.IncompleteRead(b"")])
        self.assert_failed(run, "posted 0 of 1")

    def test_an_error_answer_that_names_the_webhook_never_prints_it(self):
        body = json.dumps({"message": f"bad {WEBHOOK}"}).encode()
        self.assert_failed(Run(answers=[http_error(400, body)]), "400")


if __name__ == "__main__":
    unittest.main()
