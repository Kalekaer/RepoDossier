"""Check local static asset references in generated HTML/CSS/JS (stdlib only)."""
import argparse
from html.parser import HTMLParser
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

CSS_URL = re.compile(r'''url\(\s*["']?([^\s)"']+)["']?\s*\)''', re.I)
LITERAL_ASSET = re.compile(r'''["']((?:\.{1,2}/|/)*assets/[^"']+)["']''')


class References(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.base = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'base' and self.base is None:
            self.base = attrs.get('href')
        for key in ('src', 'href', 'poster'):
            if tag != 'base' and attrs.get(key):
                self.links.append(attrs[key])
        self.links.extend(CSS_URL.findall(attrs.get('style', '')))


def check(root):
    root = root.resolve()
    assets = root / 'assets'
    queue = [p for p in (root / 'index.html', root / 'overview.html') if p.exists()]
    queue += list((root / 'data/site').glob('*.html'))
    seen, missing = set(), set()
    while queue:
        file = queue.pop()
        if file in seen:
            continue
        seen.add(file)
        text = file.read_text('utf-8-sig')
        parser = References()
        if file.suffix == '.html':
            parser.feed(text)
        directory = file.parent
        if parser.base and not urlsplit(parser.base).scheme:
            directory = (directory / unquote(urlsplit(parser.base).path)).resolve()
        refs = parser.links + CSS_URL.findall(text) + LITERAL_ASSET.findall(text)
        for ref in refs:
            if any(part in ref for part in ('${', '{{', '<%', '+', '\\')):
                continue  # Dynamic references are checked in the real browser.
            url = urlsplit(ref)
            if url.scheme or url.netloc or not url.path:
                continue
            path = unquote(url.path)
            target = (root / path.lstrip('/') if path.startswith('/') else directory / path).resolve()
            if not target.is_relative_to(assets):
                continue
            if not target.is_file():
                missing.add((file.relative_to(root).as_posix(), ref))
            elif target.suffix in ('.css', '.js'):
                queue.append(target)
    return {'checked_files': len(seen), 'missing': [{'file': f, 'reference': r} for f, r in sorted(missing)]}


if __name__ == '__main__':
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    result = check(cli.parse_args().root)
    print(json.dumps(result, ensure_ascii=True))
    raise SystemExit(bool(result['missing']))
