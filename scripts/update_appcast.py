#!/usr/bin/env python3
"""Prepend a release entry to the Sparkle appcast.

The appcast is edited as text rather than through an XML parser: ElementTree
rewrites namespace prefixes and drops the CDATA wrapper around release notes,
both of which Sparkle cares about. Inserting a formatted block keeps the rest of
the file byte-identical.

Re-running for a version that is already present replaces that entry, so a
re-run of a release workflow is idempotent.
"""

import argparse
import html
import re
import sys
from datetime import datetime, timezone
from email.utils import format_datetime

ITEM_TEMPLATE = """        <item>
            <title>{version}</title>
            <pubDate>{pubdate}</pubDate>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>{min_system}</sparkle:minimumSystemVersion>
            <description><![CDATA[{notes}]]></description>
            <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" type="application/octet-stream"/>
        </item>
"""


def notes_to_html(raw: str) -> str:
    """Turn newline-separated commit subjects into a bullet list."""
    lines = [line.strip().lstrip("-*").strip() for line in raw.splitlines()]
    lines = [line for line in lines if line]
    if not lines:
        return "<ul><li>Maintenance and reliability improvements.</li></ul>"
    items = "".join(f"<li>{html.escape(line)}</li>" for line in lines)
    return f"<ul>{items}</ul>"


def drop_existing(appcast: str, version: str) -> str:
    """Remove any <item> already describing this version."""
    pattern = re.compile(r"[ \t]*<item>.*?</item>\n", re.DOTALL)
    marker = f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>"
    return pattern.sub(lambda m: "" if marker in m.group(0) else m.group(0), appcast)


def insert_item(appcast: str, item: str) -> str:
    """Place the new entry ahead of existing ones, newest first."""
    anchor = appcast.find("        <item>")
    if anchor == -1:
        anchor = appcast.find("    </channel>")
        if anchor == -1:
            sys.exit("error: appcast has neither an <item> nor a </channel> to anchor on")
    return appcast[:anchor] + item + appcast[anchor:]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--appcast", required=True)
    parser.add_argument("--version", required=True, help="marketing version, e.g. 1.0.18")
    parser.add_argument("--build", required=True, help="build number Sparkle compares on")
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--notes", default="", help="newline-separated commit subjects")
    parser.add_argument("--min-system", default="13.0")
    args = parser.parse_args()

    with open(args.appcast, encoding="utf-8") as handle:
        appcast = handle.read()

    item = ITEM_TEMPLATE.format(
        version=args.version,
        pubdate=format_datetime(datetime.now(timezone.utc)),
        build=args.build,
        min_system=args.min_system,
        notes=notes_to_html(args.notes),
        url=args.url,
        signature=args.signature,
        length=args.length,
    )

    updated = insert_item(drop_existing(appcast, args.version), item)

    with open(args.appcast, "w", encoding="utf-8") as handle:
        handle.write(updated)

    print(f"Added {args.version} (build {args.build}) to {args.appcast}")


if __name__ == "__main__":
    main()
