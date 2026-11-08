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
import re
import subprocess
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

    def test_a_heading_inside_a_code_block_is_not_a_section(self):
        text = "\n".join(build("## New\n\n```\n## Checks\nan example\n```\n\nAfter the block."))
        for kept in ("## Checks", "an example", "After the block."):
            self.assertIn(kept, text)
        self.assertEqual(text.count("```"), 2)

    def test_a_reviewer_section_holding_a_code_block_is_left_out_whole(self):
        text = "\n".join(build("## New\n\nKept.\n\n## Checks\n\n```\n## Not a heading\n```\n\nGone."))
        self.assertIn("Kept.", text)
        for dropped in ("```", "Not a heading", "Gone."):
            self.assertNotIn(dropped, text)

    def test_a_long_code_block_is_closed_and_reopened_across_messages(self):
        code = [f"line {number} " + "x" * 100 for number in range(40)]
        messages = build("## New\n\n```lua\n" + "\n".join(code) + "\n```\n\nAfter the block.")
        self.assertGreater(len(messages), 1)
        self.assert_well_formed(messages)
        for message in messages:
            self.assertEqual(sum(line.startswith("```") for line in message.split("\n")) % 2, 0, message)
        for message in messages[1:-1]:
            self.assertTrue(message.startswith("```lua\n"))
            self.assertTrue(message.endswith("\n```"))
        posted = [line for message in messages for line in message.split("\n") if line.startswith("line ")]
        self.assertEqual(posted, code)
        self.assertIn("After the block.", messages[-1])

    def assert_fences_balance(self, messages):
        self.assert_well_formed(messages)
        for message in messages:
            self.assertEqual(sum(line.startswith("```") for line in message.split("\n")) % 2, 0, message)

    def test_a_code_line_nearly_as_long_as_a_message_still_fits_with_its_fence(self):
        for length in (1990, 1995, 2000):
            notes = "## New\n\n```lua\nfirst\n" + "x" * length + "\nlast\n```"
            messages = build(notes)
            self.assert_fences_balance(messages)
            self.assertIn("first", messages[0])

    def test_a_code_line_longer_than_a_message_stays_inside_its_code_block(self):
        solid = "x" * 5000
        messages = build(f"## New\n\n```\nfirst\n{solid}\nlast\n```\n\nAfter the block.")
        self.assert_fences_balance(messages)
        posted = [line for message in messages for line in message.split("\n")]
        self.assertEqual("".join(line for line in posted if line.startswith("x")), solid)
        self.assertLess(posted.index("first"), posted.index("last"))
        self.assertIn("After the block.", messages[-1])

    def test_inline_code_with_three_backticks_does_not_hide_a_reviewer_section(self):
        text = "\n".join(build("## New\n\n```foo``` is inline.\n\n## Checks\n\nGone."))
        self.assertIn("is inline.", text)
        self.assertNotIn("Gone.", text)

    def test_a_longer_closing_fence_ends_the_code_block(self):
        text = "\n".join(build("## New\n\n```\ncode\n`````\n\n## Checks\n\nGone."))
        self.assertIn("code", text)
        self.assertNotIn("Gone.", text)

    def test_a_line_that_only_starts_like_a_fence_does_not_end_the_code_block(self):
        text = "\n".join(build("## New\n\n```\n``` not the end\n## Checks\nstays\n```\n\n## Checks\n\nGone."))
        self.assertIn("stays", text)
        self.assertNotIn("Gone.", text)

    def test_a_section_heading_is_never_left_at_the_end_of_a_message(self):
        small = "## First\n\n" + "\n".join(bullets(5))
        big = "## Big\n\n" + "\n".join(bullets(12))
        messages = build(f"{small}\n\n{big}")
        self.assertGreater(len(messages), 1)
        for message in messages:
            self.assertFalse(message.split("\n")[-1].startswith("#"), message)

    def test_a_heading_inside_a_tilde_code_block_is_not_a_section(self):
        text = "\n".join(build("## New\n\n~~~\n## Checks\nkept\n~~~\n\n## Checks\n\nGone."))
        self.assertIn("kept", text)
        self.assertNotIn("Gone.", text)

    def test_a_fence_of_the_other_kind_does_not_close_a_code_block(self):
        text = "\n".join(build("## New\n\n```\n~~~\n## Checks\nkept\n```"))
        self.assertIn("kept", text)

    def test_a_fence_line_with_words_after_it_does_not_close_a_code_block(self):
        text = "\n".join(build("## New\n\n```\n```lua\n## Checks\nkept\n```"))
        self.assertIn("kept", text)

    def test_a_shorter_fence_does_not_close_a_longer_one(self):
        text = "\n".join(build("## New\n\n````\n```\n## Checks\nkept\n```\n````\n\n## Checks\n\nGone."))
        self.assertIn("kept", text)
        self.assertNotIn("Gone.", text)

    def test_a_heading_straight_after_a_code_block_is_a_section_again(self):
        text = "\n".join(build("## New\n\n```\ncode\n```\n## Checks\n\nGone."))
        self.assertIn("code", text)
        self.assertNotIn("Gone.", text)

    def test_a_fence_indented_four_spaces_is_not_a_code_block(self):
        text = "\n".join(build("## New\n\n    ```\n\n## Checks\n\nGone."))
        self.assertNotIn("Gone.", text)

    def test_a_long_code_block_is_closed_and_reopened_with_its_own_fence(self):
        code = [f"line {number} " + "x" * 100 for number in range(40)]
        for opener, closer in (("~~~sh", "~~~"), ("````lua", "````")):
            messages = build(f"## New\n\n{opener}\n" + "\n".join(code) + f"\n{closer}")
            self.assertGreater(len(messages), 1)
            self.assert_well_formed(messages)
            for message in messages[1:-1]:
                self.assertTrue(message.startswith(f"{opener}\n"), message[:20])
                self.assertTrue(message.endswith(f"\n{closer}"), message[-20:])

    def test_the_closing_fence_of_a_split_code_block_always_fits(self):
        for length in range(90, 130):
            code = [f"{number:02d} " + "x" * (length - 3) for number in range(60)]
            messages = build("## New\n\n```\n" + "\n".join(code) + "\n```")
            self.assert_well_formed(messages)
            for message in messages:
                self.assertEqual(sum(line == "```" for line in message.split("\n")) % 2, 0, length)
            self.assertEqual([line for message in messages for line in message.split("\n") if line[:2].isdigit()], code)

    def test_a_long_code_block_that_is_never_closed_still_arrives_whole(self):
        code = [f"line {number} " + "x" * 100 for number in range(40)]
        messages = build("## New\n\n```\n" + "\n".join(code))
        self.assert_well_formed(messages)
        self.assertEqual([line for message in messages for line in message.split("\n") if line.startswith("line ")], code)

    def test_the_version_heading_stays_above_a_long_first_section(self):
        messages = build("## Big\n\n" + "\n".join(bullets(12)))
        self.assertTrue(messages[0].startswith(f"# {VERSION}\n\n## Big\n\n- bullet 0 "))

    def test_a_long_section_after_another_section_starts_its_own_message(self):
        small = "## First\n\n" + "\n".join(bullets(2))
        big = "## Big\n\n" + "\n".join(bullets(12))
        messages = build(f"{small}\n\n{big}")
        self.assertNotIn("## Big", messages[0])
        self.assertTrue(messages[1].startswith("## Big\n"))

    def test_text_of_exactly_the_limit_stays_one_message(self):
        room = LIMIT - len(f"# {VERSION}\n\n\n\n{LINK}")
        messages = build("y" * room)
        self.assertEqual(len(messages), 1)
        self.assertEqual(len(messages[0]), LIMIT)

    def test_one_character_over_the_limit_makes_two_messages(self):
        room = LIMIT - len(f"# {VERSION}\n\n\n\n{LINK}") + 1
        self.assertEqual(len(build("y" * room)), 2)

    def test_a_line_of_exactly_the_limit_is_never_split(self):
        full = "- " + "w " * 998 + "ww"
        self.assertEqual(len(full), LIMIT)
        messages = build("## Big\n\n" + "\n".join(bullets(2) + [full] + bullets(2)))
        self.assert_well_formed(messages)
        self.assertIn(full, [line for message in messages for line in message.split("\n")])

    def test_only_a_two_hash_heading_starts_or_ends_a_reviewer_section(self):
        notes = (
            "## Fixed\n\n### Checks\n\nKept three.\n\n# Checks\n\nKept one.\n\n##Checks\n\nKept none.\n\n"
            "## Checks\n\n### Detail\n\nGone three.\n\n# Title\n\nGone one.\n\n## New\n\nKept after."
        )
        text = "\n".join(build(notes))
        for kept in ("### Checks", "Kept three.", "# Checks", "Kept one.", "##Checks", "Kept none.", "Kept after."):
            self.assertIn(kept, text)
        for dropped in ("### Detail", "Gone three.", "# Title", "Gone one."):
            self.assertNotIn(dropped, text)

    def test_indented_lines_keep_their_indent_across_a_split(self):
        lines = [line if number % 2 == 0 else "  " + line for number, line in enumerate(bullets(12))]
        messages = build("## Big\n\n" + "\n".join(lines))
        self.assertGreater(len(messages), 1)
        posted = [line for message in messages for line in message.split("\n")]
        self.assertEqual([line for line in posted if "bullet" in line], lines)

    def test_the_link_is_still_last_when_the_last_section_fills_a_message(self):
        section = "## Big\n\n- " + "z" * (LIMIT - len("## Big\n\n- "))
        self.assertEqual(len(section), LIMIT)
        messages = build(section)
        self.assert_well_formed(messages)
        self.assertTrue(messages[-1].endswith(LINK))
        self.assertIn("- " + "z" * (LIMIT - len("## Big\n\n- ")), "\n".join(messages))


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

    def test_a_rate_limit_on_a_later_message_retries_only_that_message(self):
        notes = "\n".join(bullets(20))
        wanted = discord_post.build_messages(VERSION, notes, URL)
        self.assertGreater(len(wanted), 2)
        run = Run(notes=notes, answers=[Response(), http_error(429, b'{"retry_after": 1}')])
        self.assertEqual(run.code, 0)
        sent = [payload["content"] for payload in run.payloads()]
        self.assertEqual(sent, [wanted[0], wanted[1]] + wanted[1:])

    def test_a_rate_limit_asking_for_an_impossible_wait_stays_within_the_limits(self):
        for body in (b'{"retry_after": -5}', b'{"retry_after": NaN}', b'{"retry_after": Infinity}', b'{"retry_after": null}'):
            run = Run(answers=[http_error(429, body)])
            self.assertEqual(run.code, 0, body)
            self.assertEqual(len(run.requests), 2, body)
            self.assertEqual(len(run.sleeps), 1, body)
            self.assertTrue(0 <= run.sleeps[0] <= 30, body)

    def test_a_webhook_pasted_with_stray_spaces_is_posted_to_clean(self):
        run = Run(DISCORD_WEBHOOK_URL=f"  {WEBHOOK}\n")
        self.assertEqual(run.code, 0)
        self.assertEqual(run.requests[0].full_url, WEBHOOK + "?wait=true")


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

    def test_an_error_answer_whose_body_cannot_be_read_is_a_named_failure(self):
        error = http_error(500)
        error.read = mock.Mock(side_effect=http.client.IncompleteRead(b""))
        run = Run(answers=[error])
        self.assert_failed(run, "posted 0 of 1", "500")
        self.assertEqual(len(run.requests), 1)

    def test_a_rate_limit_whose_body_cannot_be_read_still_waits_and_retries(self):
        error = http_error(429)
        error.read = mock.Mock(side_effect=TimeoutError("timed out"))
        run = Run(answers=[error])
        self.assertEqual(run.code, 0)
        self.assertEqual(run.sleeps, [1])

    def test_a_failure_answer_that_cannot_be_read_is_never_retried(self):
        for problem in (ValueError("closed"), ConnectionResetError("reset"), http.client.IncompleteRead(b"")):
            error = http_error(404)
            error.read = mock.Mock(side_effect=problem)
            run = Run(answers=[error])
            self.assert_failed(run, "posted 0 of 1", "404")
            self.assertEqual(len(run.requests), 1)
            self.assertEqual(run.sleeps, [])

    def test_a_huge_wait_in_the_answer_falls_back_to_the_header(self):
        huge = b'{"retry_after": 1' + b"0" * 400 + b"}"
        run = Run(answers=[http_error(429, huge, {"Retry-After": "4"})])
        self.assertEqual(run.code, 0)
        self.assertEqual(run.sleeps, [4])

    def test_a_rate_limit_asking_for_a_huge_wait_is_not_a_crash(self):
        huge = b'{"retry_after": 1' + b"0" * 400 + b"}"
        run = Run(answers=[http_error(429, huge)])
        self.assertEqual(run.code, 0)
        self.assertEqual(run.sleeps, [1])

    def test_a_network_error_never_prints_the_webhook(self):
        run = Run(answers=[urllib.error.URLError(f"could not reach {WEBHOOK}?wait=true")])
        self.assert_failed(run, "posted 0 of 1")

    def test_a_broken_connection_is_a_failure_not_a_crash(self):
        run = Run(answers=[http.client.IncompleteRead(b"")])
        self.assert_failed(run, "posted 0 of 1")

    def test_an_error_answer_that_names_the_webhook_never_prints_it(self):
        body = json.dumps({"message": f"bad {WEBHOOK}"}).encode()
        self.assert_failed(Run(answers=[http_error(400, body)]), "400")

    def test_a_bad_version_fails_even_with_no_webhook(self):
        run = Run(VERSION="0.7.3", DISCORD_WEBHOOK_URL=None)
        self.assert_failed(run, "version")
        self.assertNotIn("skipped", run.output)

    def test_an_empty_release_link_fails_and_sends_nothing(self):
        run = Run(RELEASE_URL="")
        self.assert_failed(run, "release link")
        self.assertEqual(run.requests, [])

    def test_notes_that_are_not_text_fail_and_send_nothing(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "notes.md")
            with open(path, "wb") as handle:
                handle.write(b"## Fixed\n\n\xff\xfe\n")
            run = Run(NOTES_FILE=path)
        self.assert_failed(run, "notes")
        self.assertEqual(run.requests, [])

    def test_only_a_rate_limit_is_ever_retried(self):
        for answer in (http_error(403), http_error(500), urllib.error.URLError("down")):
            run = Run(answers=[answer])
            self.assert_failed(run, "posted 0 of 1")
            self.assertEqual(len(run.requests), 1)
            self.assertEqual(run.sleeps, [])

    def test_a_failure_after_a_rate_limit_stops_there(self):
        run = Run(answers=[http_error(429, b'{"retry_after": 1}'), http_error(500)])
        self.assert_failed(run, "posted 0 of 1", "500")
        self.assertEqual(len(run.requests), 2)

    def test_an_error_answer_that_is_not_a_json_object_still_names_the_status(self):
        for body in (b"[]", b"oops", b"\xff\xfe", b""):
            run = Run(answers=[http_error(500, body)])
            self.assert_failed(run, "posted 0 of 1", "Discord answered 500")


def workflow(name):
    with open(os.path.join(ROOT, ".github", "workflows", name), encoding="utf-8") as handle:
        return handle.read()


def run_blocks(text):
    """Returns the text of every `run:` entry in a workflow, including multi-line ones."""
    blocks = []
    lines = text.split("\n")
    for index, line in enumerate(lines):
        found = re.match(r"( *)(- )?run:(.*)", line)
        if not found:
            continue
        indent = len(found.group(1)) + len(found.group(2) or "")
        block = [found.group(3)]
        for following in lines[index + 1 :]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            block.append(following)
        blocks.append("\n".join(block))
    return blocks


def job(text, name):
    """Returns one job of a workflow, from its name up to the next job."""
    found = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", text, re.MULTILINE | re.DOTALL)
    return found.group(1) if found else None


class Workflows(unittest.TestCase):
    def test_the_discord_workflow_can_be_called_and_run_by_hand_with_a_version(self):
        text = workflow("discord.yml")
        self.assertIn("name: Post release to Discord", text)
        for trigger in ("workflow_call", "workflow_dispatch"):
            found = re.search(rf"^  {trigger}:\n(.*?)(?=^  \S|^\S)", text, re.MULTILINE | re.DOTALL)
            self.assertIsNotNone(found, trigger)
            self.assertRegex(found.group(1), r"version:\n\s+.*(\n\s+.*)*required: true")
        self.assertRegex(text, r"secrets:\n\s+DISCORD_WEBHOOK_URL:\n\s+required: false")
        self.assertRegex(text, r"(?m)^permissions:\n  contents: read$")

    def test_the_discord_workflow_reads_the_release_and_runs_the_script(self):
        text = workflow("discord.yml")
        self.assertIn('gh release view "$VERSION"', text)
        self.assertIn("python3 tools/discord_post.py", text)
        self.assertIn("DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}", text)
        self.assertLess(text.index("gh release view"), text.index("python3 tools/discord_post.py"))

    def test_the_webhook_reaches_only_the_step_that_posts(self):
        text = workflow("discord.yml")
        steps = re.split(r"(?m)^      - ", text)
        holding = [step for step in steps if "secrets.DISCORD_WEBHOOK_URL" in step]
        self.assertEqual(len(holding), 1)
        self.assertIn("python3 tools/discord_post.py", holding[0])

    def test_no_run_block_holds_an_expression(self):
        for name in ("discord.yml", "release.yml", "tests.yml"):
            blocks = run_blocks(workflow(name))
            self.assertTrue(blocks, name)
            for block in blocks:
                self.assertNotIn("${{", block, name)

    def test_the_release_workflow_calls_the_discord_workflow_after_a_published_release(self):
        discord = job(workflow("release.yml"), "discord")
        self.assertIsNotNone(discord)
        self.assertIn("needs: release", discord)
        self.assertIn("contents: read", discord)
        self.assertIn("uses: ./.github/workflows/discord.yml", discord)
        self.assertIn("version: ${{ github.event.pull_request.title }}", discord)
        self.assertIn("DISCORD_WEBHOOK_URL: ${{ secrets.DISCORD_WEBHOOK_URL }}", discord)

    def test_a_discord_problem_cannot_reach_the_release_job(self):
        text = workflow("release.yml")
        release = job(text, "release")
        self.assertNotIn("iscord", release)
        self.assertNotIn("continue-on-error", text)
        self.assertLess(text.index("  release:\n"), text.index("  discord:\n"))

    def test_a_manual_run_never_starts_the_check_or_release_jobs(self):
        self.assertNotIn("workflow_dispatch", workflow("release.yml"))

    def test_the_test_workflow_runs_these_tests(self):
        self.assertIn("python3 tests/discord_post_test.py", workflow("tests.yml"))

    def test_the_discord_job_keeps_the_default_rule_that_a_failed_release_stops_it(self):
        self.assertNotRegex(job(workflow("release.yml"), "discord"), r"(?m)^\s+if:")


class ReadStep(unittest.TestCase):
    """Runs the Discord workflow's "Read the release" step with a stand-in for `gh`."""

    def read_step(self, version, gh_exit=0):
        text = workflow("discord.yml")
        step = next(part for part in re.split(r"(?m)^      - ", text) if part.startswith("name: Read the release"))
        script = "\n".join(line.strip() for line in run_blocks(step)[0].split("\n")[1:])
        with tempfile.TemporaryDirectory() as folder:
            calls = os.path.join(folder, "gh-calls")
            stand_in = os.path.join(folder, "gh")
            with open(stand_in, "w", encoding="utf-8") as handle:
                handle.write(
                    "#!/bin/bash\n"
                    f'echo "$*" >> "{calls}"\n'
                    f"[ {gh_exit} -eq 0 ] || {{ echo 'release not found' >&2; exit {gh_exit}; }}\n"
                    f'case "$*" in *"--json body"*) printf "## Fixed\\n\\n- One.\\n";; *) echo "{URL}";; esac\n'
                )
            os.chmod(stand_in, 0o755)
            github_env = os.path.join(folder, "github-env")
            open(github_env, "w", encoding="utf-8").close()
            result = subprocess.run(
                ["bash", "-e", "-c", script],
                env={
                    "PATH": folder + os.pathsep + os.environ["PATH"],
                    "VERSION": version,
                    "GITHUB_REPOSITORY": "norto22/Mileage",
                    "GITHUB_ENV": github_env,
                    "RUNNER_TEMP": folder,
                },
                stdin=subprocess.DEVNULL,
                capture_output=True,
                text=True,
            )
            notes = os.path.join(folder, "notes.md")
            with open(github_env, encoding="utf-8") as handle:
                exported = handle.read()
            called = os.path.exists(calls)
            body = None
            if os.path.exists(notes):
                with open(notes, encoding="utf-8") as handle:
                    body = handle.read()
        return result, exported, called, body

    def test_a_published_release_hands_its_notes_and_link_to_the_next_step(self):
        result, exported, called, body = self.read_step(VERSION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(called)
        self.assertEqual(body, "## Fixed\n\n- One.\n")
        self.assertEqual(exported, f"RELEASE_URL={URL}\n")

    def test_a_version_that_is_not_a_release_number_fails_before_github_is_asked(self):
        for version in ("", "0.7.2", "v0.7", "v0.7.2-rc1", "v0.7.2; touch pwned", "v0.7.2\nv0.7.3"):
            result, exported, called, _ = self.read_step(version)
            self.assertNotEqual(result.returncode, 0, version)
            self.assertIn("discord post failed: version must be vX.X.X", result.stdout, version)
            self.assertFalse(called, version)
            self.assertEqual(exported, "", version)

    def test_an_unknown_version_fails_the_step_and_hands_nothing_on(self):
        result, exported, called, _ = self.read_step("v9.9.9", gh_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(called)
        self.assertIn("release not found", result.stderr)
        self.assertEqual(exported, "")


if __name__ == "__main__":
    unittest.main()
