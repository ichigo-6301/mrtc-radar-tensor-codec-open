#!/usr/bin/env python3
"""Focused tests for private-repository leakage patterns."""

import unittest

import scan_public_release


class PublicReleaseScannerTests(unittest.TestCase):
    def test_private_repository_slug_and_urls_are_rejected(self):
        pattern = scan_public_release.CONTENT_PATTERNS["private_repository"]
        private_slug = "ichigo-6301/" + "mrtc-radar-tensor-codec"
        for value in (
                private_slug,
                "https://github.com/" + private_slug,
                "git@github.com:" + private_slug + ".git"):
            self.assertIsNotNone(pattern.search(value), value)

    def test_public_repository_is_allowed(self):
        pattern = scan_public_release.CONTENT_PATTERNS["private_repository"]
        self.assertIsNone(pattern.search("ichigo-6301/mrtc-radar-tensor-codec-open"))
        self.assertIsNone(pattern.search(
            "https://github.com/ichigo-6301/mrtc-radar-tensor-codec-open.git"
        ))


if __name__ == "__main__":
    unittest.main()
