"""Self-contained release-note HTML for Sparkle's existing scrolling viewport.

Deliberately supports the publishing format we use: headings, paragraphs,
unordered/ordered lists, fenced code, inline code, bold, and HTTPS links.
Other Markdown and raw HTML remain readable, escaped text. This is not a
general-purpose Markdown parser and never fetches images or other resources.
"""
from __future__ import annotations

import html
import re
from urllib.parse import urlsplit


STYLE = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
html {
  overflow-y: scroll;
  scrollbar-gutter: stable;
}
body {
  margin: 0;
  padding: 16px 18px;
  font: 13px/1.65 -apple-system, BlinkMacSystemFont, sans-serif;
  color: #242424;
  background: #fff;
  overflow-wrap: anywhere;
  word-wrap: break-word;
}
main { min-width: 0; max-width: 100%; }
h1, h2, h3, h4, h5, h6 { margin: 1.1em 0 .5em; line-height: 1.4; }
h1 { font-size: 19px; }
h2 { font-size: 16px; }
h3, h4, h5, h6 { font-size: 14px; }
main > :first-child { margin-top: 0; }
main > :last-child { margin-bottom: 0; }
p, ul, ol, pre { margin: 0 0 12px; }
ul, ol { padding-left: 1.65em; }
li { margin: 0 0 .6em; }
li:last-child { margin-bottom: 0; }
a { color: #065cbd; text-decoration: underline; }
code { font: .92em/1.6 ui-monospace, Menlo, monospace; }
pre {
  white-space: pre-wrap;
  overflow-wrap: anywhere;
  word-wrap: break-word;
  padding: 10px;
  border: 1px solid #ddd;
  border-radius: 5px;
  background: #f5f5f5;
}
hr { border: 0; border-top: 1px solid #ddd; margin: 16px 0; }
/* Explicit WebKit scrollbars remain discoverable with overlay scrollers.
   The viewport owns scrolling; do not add a second scrolling body or main. */
::-webkit-scrollbar { width: 12px; height: 12px; }
::-webkit-scrollbar-track { background: #f1f1f1; }
::-webkit-scrollbar-thumb {
  background: #888;
  border: 3px solid #f1f1f1;
  border-radius: 8px;
  min-height: 28px;
}
::-webkit-scrollbar-thumb:hover { background: #606060; }
@media (prefers-color-scheme: dark) {
  body { color: #eee; background: #202020; }
  a { color: #82b9ff; }
  pre { background: #292929; border-color: #555; }
  hr { border-color: #555; }
  ::-webkit-scrollbar-track { background: #292929; }
  ::-webkit-scrollbar-thumb { background: #999; border-color: #292929; }
  ::-webkit-scrollbar-thumb:hover { background: #bbb; }
}
""".strip()

_INLINE = re.compile(r"(`+)(.+?)\1|\*\*(.+?)\*\*|(?<!!)\[([^\]\n]+)\]\(([^\s)]+)\)")
_HEADING = re.compile(r"^(#{1,6})\s+(.+)$")
_LIST = re.compile(r"^([-+*]|\d+[.)])\s+(.+)$")
_FENCE = re.compile(r"^(`{3,}|~{3,})[^`~]*$")


def _inline(text: str, depth: int = 0) -> str:
    if depth >= 8:
        return html.escape(text)
    output = []
    start = 0
    for match in _INLINE.finditer(text):
        output.append(html.escape(text[start:match.start()]))
        if match[1]:
            output.append("<code>" + html.escape(match[2]) + "</code>")
        elif match[3]:
            output.append("<strong>" + _inline(match[3], depth + 1) + "</strong>")
        else:
            try:
                url = urlsplit(match[5])
                safe = (url.scheme == "https" and bool(url.hostname)
                        and url.username is None and url.password is None
                        and not any(ord(c) < 32 for c in match[5]))
            except ValueError:
                safe = False
            if safe:
                output.append('<a href="' + html.escape(match[5], quote=True)
                              + '">' + _inline(match[4], depth + 1) + '</a>')
            else:
                output.append(html.escape(match[0]))
        start = match.end()
    output.append(html.escape(text[start:]))
    return "".join(output)


def render_release_notes(notes: str) -> str:
    """Render UTF-8 Markdown without executable HTML or external resources."""
    lines = notes.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    blocks: list[str] = []
    paragraph: list[str] = []
    list_tag: str | None = None
    i = 0

    def close_paragraph() -> None:
        if paragraph:
            blocks.append("<p>" + _inline(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    def close_list() -> None:
        nonlocal list_tag
        if list_tag:
            blocks.append("</" + list_tag + ">")
            list_tag = None

    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line:
            close_paragraph()
            close_list()
            continue
        fence = _FENCE.fullmatch(line)
        if fence:
            close_paragraph()
            close_list()
            marker = fence[1]
            code: list[str] = []
            while i < len(lines):
                candidate = lines[i].strip()
                if (len(candidate) >= len(marker)
                        and candidate == marker[0] * len(candidate)):
                    i += 1
                    break
                code.append(lines[i])
                i += 1
            blocks.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
            continue
        heading = _HEADING.fullmatch(line)
        if heading:
            close_paragraph()
            close_list()
            level = str(len(heading[1]))
            blocks.append("<h" + level + ">" + _inline(heading[2]) + "</h" + level + ">")
            continue
        if line in ("---", "***", "___"):
            close_paragraph()
            close_list()
            blocks.append("<hr>")
            continue
        item = _LIST.fullmatch(line)
        if item:
            close_paragraph()
            tag = "ol" if item[1][0].isdigit() else "ul"
            if list_tag != tag:
                close_list()
                start = int(item[1][:-1]) if tag == "ol" else 1
                attribute = ' start="' + str(start) + '"' if start != 1 else ""
                blocks.append("<" + tag + attribute + ">")
                list_tag = tag
            # Publishing notes use one paragraph per item; accept indented
            # continuation lines without losing their text.
            content = [item[2]]
            while (i < len(lines) and lines[i].startswith(("  ", "\t"))
                   and lines[i].strip() and not _LIST.fullmatch(lines[i].strip())
                   and not _FENCE.fullmatch(lines[i].strip())):
                content.append(lines[i].strip())
                i += 1
            blocks.append("<li>" + _inline(" ".join(content)) + "</li>")
            continue
        close_list()
        paragraph.append(line)
    close_paragraph()
    close_list()
    body = "\n".join(blocks) or "<p>此版本未提供更新说明。</p>"
    return ('<!doctype html>\n<html lang="zh-Hans"><head><meta charset="utf-8">\n'
            '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
            '<title>OKVideoMac 更新说明</title>\n<style>\n' + STYLE
            + '\n</style></head><body><main aria-label="更新说明">\n'
            + body + '\n</main></body></html>\n')
