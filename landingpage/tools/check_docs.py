#!/usr/bin/env python3
"""Validate the built site and local links in maintained repository documentation."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.ids = set()
        self.links = []
        self.images = []
        self.search = []
        self.canonical = ""
        self.feed(path.read_text())

    def handle_starttag(self, tag, values):
        attrs = dict(values)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical = attrs.get("href", "")
        for key in ("href", "src"):
            if attrs.get(key):
                self.links.append(attrs[key])
        if tag == "img":
            self.images.append(attrs)
        if attrs.get("data-search-url"):
            self.search.append(attrs["data-search-url"])


def check_site(public):
    pages = {p.resolve(): Page(p) for p in public.rglob("*.html")}
    errors = []
    home = pages.get((public / "index.html").resolve())
    if not home:
        return ["Build the site first: no index.html"], 0
    origin = urlsplit(home.canonical)
    prefix = origin.path.rstrip("/") + "/"

    def resolve(page, url):
        parts = urlsplit(url)
        if parts.scheme and (parts.scheme not in ("http", "https") or parts.netloc != origin.netloc):
            return None, ""
        if parts.netloc and parts.netloc != origin.netloc:
            return None, ""
        path = unquote(parts.path)
        if path.startswith("/"):
            if not path.startswith(prefix):
                errors.append(f"{page.path.relative_to(public)}: link escapes site base {prefix}: {url}")
                return None, ""
            target = public / path[len(prefix):]
        elif path:
            target = page.path.parent / path
        else:
            target = page.path
        if target.is_dir() or path.endswith("/"):
            target /= "index.html"
        return target.resolve(), unquote(parts.fragment)

    checked_indexes = set()
    for page in pages.values():
        for link in page.links + page.search:
            target, fragment = resolve(page, link)
            if target is None:
                continue
            if not target.is_file():
                errors.append(f"{page.path.relative_to(public)}: missing {link}")
            elif fragment and target in pages and fragment not in pages[target].ids:
                errors.append(f"{page.path.relative_to(public)}: missing fragment {link}")
        for attrs in page.images:
            if "alt" not in attrs or (not (attrs["alt"] or "").strip() and attrs.get("aria-hidden") != "true"):
                errors.append(f"{page.path.relative_to(public)}: image needs alt text: {attrs.get('src')}")
        for url in page.search:
            target, _ = resolve(page, url)
            if target is None or target in checked_indexes or not target.is_file():
                continue
            checked_indexes.add(target)
            for entry in json.loads(target.read_text()):
                result, _ = resolve(page, entry["url"])
                if result not in pages or not entry["title"] or not entry["description"]:
                    errors.append(f"Invalid search entry: {entry.get('url')}")
    if not checked_indexes:
        errors.append("No documentation search index was generated")
    return errors, len(pages)


def markdown_links():
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT).decode().split("\0")
    paths = sorted({
        p for p in tracked
        if p.endswith(".md")
        and not re.search(r"(?:^|/)[^/]*\d{4}-\d{2}-\d{2}[^/]*\.md$", p)
        and (
            p in {"README.md", "CONTRIBUTING.md", "SECURITY.md"}
            or p.startswith(("docs/", "landingpage/", "api/", "deploy/"))
            or (p.startswith("apps/") and p.endswith("README.md") and "/Vendor/" not in p)
        )
    })
    errors = []
    for name in paths:
        path = ROOT / name
        if not path.exists():
            continue
        text = re.sub(r"^```[^\n]*\n.*?^```\s*$", "", path.read_text(), flags=re.M | re.S)
        # Inline Markdown links and images; prose code examples are not destinations.
        for match in re.finditer(r"\[[^\]\n]*\]\((<[^>]+>|[^\s)]+)(?:\s+\"[^\"]*\")?\)", text):
            url = match[1].strip("<>")
            parts = urlsplit(url)
            if parts.scheme or parts.netloc or not parts.path or "{{" in url:
                continue
            if parts.path.startswith("/") and name.startswith("landingpage/"):
                continue  # Validated against generated HTML above.
            target = (path.parent / unquote(parts.path)).resolve()
            if not target.exists():
                errors.append(f"{name}: missing local link {url}")
        for match in re.finditer(r'<(?:img|a)\b[^>]*(?:src|href)="([^"{]+)"', text):
            parts = urlsplit(match[1])
            if not parts.scheme and not parts.netloc and parts.path and not parts.path.startswith("/"):
                if not (path.parent / unquote(parts.path)).exists():
                    errors.append(f"{name}: missing HTML link {match[1]}")
    return errors, len(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--public", type=Path, default=ROOT / "landingpage/public")
    args = parser.parse_args()
    site_errors, pages = check_site(args.public.resolve())
    repo_errors, documents = markdown_links()
    errors = sorted(set(site_errors + repo_errors))
    if errors:
        print("\n".join(errors))
        raise SystemExit(1)
    print(f"Documentation checks passed: {pages} rendered pages, {documents} Markdown files, local links, fragments, images, and search index.")


if __name__ == "__main__":
    main()
