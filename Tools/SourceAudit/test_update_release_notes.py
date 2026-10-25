import unittest
from html.parser import HTMLParser

from update_release_notes import render_release_notes


class Document(HTMLParser):
    def __init__(self, source):
        super().__init__()
        self.elements = []
        self.text = []
        self.in_main = False
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))
        if tag == 'main':
            self.in_main = True

    def handle_endtag(self, tag):
        if tag == 'main':
            self.in_main = False

    def handle_data(self, data):
        if self.in_main:
            self.text.append(data)


class UpdateReleaseNotesTests(unittest.TestCase):
    def test_actual_publishing_format_becomes_readable_blocks_and_links(self):
        source = ('# 更新说明\n\n- **播放修复**：保留 `M3U`。\n'
                  '- 第二项\n  包含续行。\n\n## 更多\n\n'
                  '详情见[发布记录](https://example.org/notes?a=1&b=2)。')
        rendered = render_release_notes(source)
        document = Document(rendered)
        tags = [tag for tag, _ in document.elements]
        self.assertIn('h1', tags)
        self.assertIn('h2', tags)
        self.assertEqual(tags.count('ul'), 1)
        self.assertEqual(tags.count('li'), 2)
        self.assertIn('strong', tags)
        self.assertIn('code', tags)
        self.assertNotIn('pre', tags)
        self.assertEqual([a['href'] for t, a in document.elements if t == 'a'],
                         ['https://example.org/notes?a=1&b=2'])
        self.assertIn('第二项 包含续行。', ''.join(document.text))

    def test_html_scripts_images_and_unsafe_links_are_readable_inert_text(self):
        source = ('<script>alert(1)</script>\n\n'
                  '<img src="https://example.org/tracker" onerror="alert(1)">\n\n'
                  '[运行](javascript:alert) [本机](file:///private/tmp/a) '
                  '[网络](http://example.org) [凭证](https://u:p@example.org) '
                  '![图片](https://example.org/pixel.png)')
        doc = Document(render_release_notes(source))
        tags = {t for t, _ in doc.elements}
        self.assertFalse(tags & {'script', 'img', 'iframe', 'a', 'link'})
        for text in ['<script>alert(1)</script>', 'javascript:alert', 'https://u:p@example.org', '![图片]']:
            self.assertIn(text, ''.join(doc.text))

    def test_fenced_code_preserves_lines_and_does_not_execute_markup(self):
        source = '```text\n<a href="https://example.org">**raw**</a>\n  indent\n```\n\n结尾'
        doc = Document(render_release_notes(source))
        tags = [t for t, _ in doc.elements]
        self.assertEqual(tags.count('pre'), 1)
        self.assertNotIn('a', tags)
        self.assertNotIn('strong', tags)
        self.assertIn('<a href="https://example.org">**raw**</a>\n  indent', ''.join(doc.text))
        self.assertTrue(''.join(doc.text).strip().endswith('结尾'))

    def test_unclosed_fence_and_unsupported_syntax_do_not_lose_text(self):
        doc = Document(render_release_notes('> 引用\n\n~~~\n未闭合\n**保留**'))
        self.assertIn('> 引用', ''.join(doc.text))
        self.assertIn('未闭合\n**保留**', ''.join(doc.text))

    def test_ordered_lists_keep_start_number_and_new_list_type(self):
        doc = Document(render_release_notes('3. 第三步\n4. 第四步\n- 其他\n\n正文'))
        self.assertIn(('ol', {'start': '3'}), doc.elements)
        self.assertIn(('ul', {}), doc.elements)
        self.assertEqual(sum(t == 'li' for t, _ in doc.elements), 3)

    def test_long_content_is_not_truncated_or_replaced_by_an_external_page(self):
        token = '中文LongURL_' * 1000
        doc = Document(render_release_notes('# 标题\n\n' + token + '\n\n最后一行'))
        self.assertIn(token, ''.join(doc.text))
        self.assertTrue(''.join(doc.text).strip().endswith('最后一行'))
        self.assertFalse(any(t in ('iframe', 'script', 'link') for t, _ in doc.elements))

    def test_empty_notes_have_a_readable_fallback(self):
        doc = Document(render_release_notes(' \r\n\t'))
        self.assertIn('此版本未提供更新说明。', ''.join(doc.text))

    def test_quoted_link_does_not_inject_an_attribute(self):
        doc = Document(render_release_notes('[链接](https://example.org/"onclick="x)'))
        links = [a for t, a in doc.elements if t == 'a']
        self.assertEqual(len(links), 1)
        self.assertEqual(set(links[0]), {'href'})


if __name__ == '__main__':
    unittest.main()
