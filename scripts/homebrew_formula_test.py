import unittest

from homebrew_formula import render


class FormulaTests(unittest.TestCase):
    def test_release_has_fixed_runtime_and_declarative_staging(self):
        formula = render("v1.2.3", "a" * 64)
        self.assertIn('/download/v1.2.3/', formula)
        self.assertIn('version "1.2.3"', formula)
        self.assertIn('post_install_steps do', formula)
        self.assertIn('"__service-stage", "--root", "{{var}}/dieter/service"', formula)
        self.assertIn('run [var/"dieter/service/bin/dieter"', formula)
        self.assertIn('"--runtime", var/"dieter/service"', formula)
        self.assertNotIn('opt_bin/', formula)
        self.assertNotIn('def post_install', formula)
        self.assertNotIn('ffmpeg', formula)

    def test_rejects_formula_interpolation_and_invalid_digests(self):
        for version, digest in [('1.2.3"; abort', 'a' * 64), ('1.2.3', '$(oops)'), ('', 'a' * 64)]:
            with self.assertRaises(ValueError):
                render(version, digest)


if __name__ == '__main__':
    unittest.main()
