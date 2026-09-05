from pathlib import Path
import re
import subprocess
import unicodedata
import unittest


ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").glob("*.md"))


def blocks(text):
    return re.findall(r"^```([^\n]*)\n(.*?)^```[ \t]*$", text, re.M | re.S)


def anchors(text):
    result = set(re.findall(r'<a\s+id="([^"]+)"', text))
    counts = {}
    for title in re.findall(r"^#{1,6}\s+(.+)$", text, re.M):
        slug = "".join(
            char for char in title.lower()
            if char in "-_ " or unicodedata.category(char)[0] in ("L", "N", "M")
        ).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        result.add(slug if count == 0 else f"{slug}-{count}")
    return result


class DocumentationTests(unittest.TestCase):
    def test_local_links_and_fragments(self):
        for path in DOCUMENTS:
            for target in re.findall(r"\]\(([^\s)]+)\)", path.read_text()):
                with self.subTest(path=path.name, target=target):
                    if re.match(r"^[a-z]+:", target):
                        continue
                    file_part, _, fragment = target.partition("#")
                    destination = path.parent / file_part if file_part else path
                    self.assertTrue(destination.exists())
                    if fragment:
                        self.assertIn(fragment, anchors(destination.read_text()))

    def test_bilingual_code_blocks(self):
        for path in DOCUMENTS:
            if path.name.endswith(".zh-CN.md"):
                continue
            with self.subTest(path=path.name):
                translation = path.with_name(path.stem + ".zh-CN.md")
                self.assertTrue(translation.exists())
                self.assertEqual(blocks(path.read_text()), blocks(translation.read_text()))

    def test_shell_snippets_parse(self):
        for path in DOCUMENTS:
            text = path.read_text()
            self.assertEqual(len(re.findall(r"^```", text, re.M)), len(blocks(text)) * 2)
            for language, snippet in blocks(text):
                if language != "bash":
                    continue
                with self.subTest(path=path.name):
                    result = subprocess.run(
                        ["bash", "-n"], input=snippet, capture_output=True, text=True
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_installer_pins_match_the_script(self):
        script = (ROOT / "scripts" / "bring-up.sh").read_text()
        for name in ("COMMIT", "SHA256"):
            pin = re.search(r"XRAY_INSTALLER_" + name + r'="([^"]+)"', script).group(1)
            for suffix in (".md", ".zh-CN.md"):
                guide = (ROOT / "docs" / ("03-vless-reality" + suffix)).read_text()
                self.assertIn(f"INSTALLER_{name}={pin}", guide)


if __name__ == "__main__":
    unittest.main()
