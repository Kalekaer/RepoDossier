import importlib.util
from pathlib import Path
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('site_assets', REPO / 'tools/check-site-assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class SiteAssetsTests(unittest.TestCase):
    def setUp(self):
        directory = REPO / 'data/_tmp'
        directory.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix='site-assets-test-', dir=directory)
        self.root = Path(self.temp.name)
        (self.root / 'data/site').mkdir(parents=True)
        (self.root / 'assets/bg').mkdir(parents=True)
        (self.root / 'assets/ui').mkdir(parents=True)

    def tearDown(self):
        self.temp.cleanup()

    def test_base_href_and_css_dependencies_are_resolved(self):
        (self.root / 'index.html').write_text('<base href="data/site/"><link rel="stylesheet" href="../../assets/ui/site.css">', encoding='utf-8')
        css = self.root / 'assets/ui/site.css'
        css.write_text('body{background:url(../bg/photo.jpg)}', encoding='utf-8')
        photo = self.root / 'assets/bg/photo.jpg'
        photo.write_bytes(b'fixture')
        self.assertEqual(assets.check(self.root)['missing'], [])
        photo.unlink()
        missing = assets.check(self.root)['missing']
        self.assertEqual(len(missing), 1)
        self.assertEqual(missing[0]['file'], 'assets/ui/site.css')

    def test_missing_generated_page_resource_is_reported(self):
        (self.root / 'data/site/daily.html').write_text('<style>.hero{background:url("../../assets/bg/missing.jpg")}</style>', encoding='utf-8')
        missing = assets.check(self.root)['missing']
        self.assertEqual(len(missing), 1)
        self.assertIn('missing.jpg', missing[0]['reference'])

    def test_external_and_dynamic_resources_are_not_claimed_as_local(self):
        (self.root / 'index.html').write_text('<img src="https://example.invalid/assets/bg/remote.jpg"><style>body{background:url(data:image/png;base64,AAAA)}</style><script>const x="assets/bg/${name}.jpg";</script>', encoding='utf-8')
        self.assertEqual(assets.check(self.root)['missing'], [])


if __name__ == '__main__':
    unittest.main()
