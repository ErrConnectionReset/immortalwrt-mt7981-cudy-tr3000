import contextlib
import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_export", ROOT / "package-export/collect.py")
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class PackageExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        self.build, self.lists, self.output = root / "build", root / "lists", root / "output"
        (self.build / "tmp").mkdir(parents=True)
        self.lists.mkdir()
        (self.lists / "common.list").write_text("", encoding="utf-8")
        self.config = ('CONFIG_TARGET_ARCH_PACKAGES="aarch64_cortex-a53"\n'
                       'CONFIG_TARGET_BOARD="mediatek"\nCONFIG_TARGET_SUBTARGET="filogic"\n')
        self.metadata = ""

    def package(self, name, state="y", abi="", arch="aarch64_cortex-a53", content=b"IPK fixture",
                version="1.0-r1", metadata_version=None):
        self.config += f"CONFIG_PACKAGE_{name}={state}\n" if state != "n" else f"# CONFIG_PACKAGE_{name} is not set\n"
        self.metadata += f"Package: {name}\nVersion: {metadata_version or version}\nRepository: base\nType: ipkg\n"
        if abi:
            self.metadata += f"ABI-Version: {abi}\n"
        self.metadata += "Description: fixture\n@@\n"
        suffix = (("-" if name[-1].isdigit() else "") + abi) if abi and not name.startswith("kmod-") else ""
        directory = self.build / "bin/packages/aarch64_cortex-a53/base"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{name}{suffix}_{version}_{arch}.ipk"
        path.write_bytes(content)
        return path

    def run_export(self, device="256M", write_indexes=True):
        (self.build / ".config").write_text(self.config, encoding="utf-8")
        (self.build / "tmp/.packageinfo").write_text(self.metadata, encoding="utf-8")
        if write_indexes:
            indexes = {}
            for ipk in sorted((self.build / "bin").rglob("*.ipk")):
                name, version, arch = ipk.stem.split("_", 2)
                indexes.setdefault(ipk.parent, []).append(
                    f"Package: {name}\nVersion: {version}\nArchitecture: {arch}\n"
                    f"Filename: {ipk.name}\nSHA256sum: {hashlib.sha256(ipk.read_bytes()).hexdigest()}\n"
                    "Description: fixture\n continued description\n\n")
            for directory, records in indexes.items():
                (directory / "Packages").write_text("".join(records), encoding="utf-8")
        with contextlib.redirect_stdout(io.StringIO()):
            EXPORT.collect(self.build, self.lists, self.output, device)
        return tarfile.open(self.output / f"selected-packages-{device}.tar.gz")

    def test_four_requested_packages_and_checksums(self):
        names = ["luci-app-openclash", "luci-i18n-mwan3-zh-cn", "luci-app-mwan3", "mwan3"]
        for name in names:
            self.package(name, arch="all" if name.startswith("luci-") else "aarch64_cortex-a53")
        (self.lists / "common.list").write_text("\n".join(names), encoding="utf-8")
        with self.run_export() as bundle:
            ipks = [name for name in bundle.getnames() if name.endswith(".ipk")]
            self.assertEqual(len(ipks), 4)
            for line in bundle.extractfile("sha256sums").read().decode().splitlines():
                checksum, filename = line.split("  ")
                self.assertEqual(checksum, hashlib.sha256(bundle.extractfile(filename).read()).hexdigest())
            self.assertIn("lists/common.list", bundle.getnames())
            self.assertIn("build.config", bundle.getnames())

    def test_device_merge_comments_crlf_bom_and_disabled_packages(self):
        for name, state in [("foo", "y"), ("bar", "m"), ("baz", "n")]:
            self.package(name, state=state)
        (self.lists / "common.list").write_bytes(b"\xef\xbb\xbf# comment\r\nfoo\r\nbar\r\n\r\n")
        (self.lists / "128m.list").write_text("foo\nbaz\n", encoding="utf-8")
        with self.run_export("128M") as bundle:
            report = bundle.extractfile("export-report.tsv").read().decode()
            self.assertEqual(report.count("foo\ty\texported"), 1)
            self.assertIn("bar\tm\tskipped-m", report)
            self.assertIn("baz\tn\tskipped-disabled", report)
            self.assertEqual(len([p for p in bundle.getnames() if p.endswith(".ipk")]), 1)

    def test_unknown_package_fails(self):
        (self.lists / "common.list").write_text("typo\n", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "metadata record"):
            self.run_export()
        self.assertFalse((self.output / "selected-packages-256M.tar.gz").exists())

    def test_stale_version_or_wrong_architecture_does_not_match(self):
        path = self.package("foo", arch="wrong_arch")
        path.with_name("foo_0.9-r1_aarch64_cortex-a53.ipk").write_bytes(b"old")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "missing current IPK"):
            self.run_export()

    def test_abi_names_and_target_packages(self):
        for name, abi in [("libfoo", "2026"), ("foo3", "0"), ("kmod-foo", "ignored")]:
            path = self.package(name, abi=abi)
            target = self.build / "bin/targets/mediatek/filogic/packages"
            target.mkdir(parents=True, exist_ok=True)
            path.rename(target / path.name)
        (self.lists / "common.list").write_text("libfoo\nfoo3\nkmod-foo", encoding="utf-8")
        with self.run_export() as bundle:
            self.assertIn("libfoo2026_1.0-r1_aarch64_cortex-a53.ipk", bundle.getnames())
            self.assertIn("foo3-0_1.0-r1_aarch64_cortex-a53.ipk", bundle.getnames())
            self.assertIn("kmod-foo_1.0-r1_aarch64_cortex-a53.ipk", bundle.getnames())

    def test_duplicates_require_identical_content(self):
        path = self.package("foo")
        target = self.build / "bin/targets/mediatek/filogic/packages"
        target.mkdir(parents=True)
        duplicate = target / path.name
        duplicate.write_bytes(path.read_bytes())
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.run_export() as bundle:
            self.assertEqual(bundle.getnames().count(path.name), 1)
        duplicate.write_bytes(b"conflicting build")
        with self.assertRaisesRegex(ValueError, "conflicting IPK"):
            self.run_export()
        self.assertFalse((self.output / "selected-packages-256M.tar.gz").exists())

    def test_empty_lists_still_generate_report(self):
        with self.run_export() as bundle:
            self.assertEqual(bundle.extractfile("sha256sums").read(), b"")
            self.assertIn("export-report.tsv", bundle.getnames())

    def test_luci_dump_placeholder_uses_actual_versions(self):
        versions = {"luci-app-mwan3": "26.246.30525~80ed8a4",
                    "luci-i18n-mwan3-zh-cn": "26.247.12345~abcdef0"}
        for name, version in versions.items():
            self.package(name, arch="all", version=version, metadata_version="x")
        (self.lists / "common.list").write_text("\n".join(versions), encoding="utf-8")
        with self.run_export() as bundle:
            report = bundle.extractfile("export-report.tsv").read().decode()
            for name, version in versions.items():
                self.assertIn(f"{name}_{version}_all.ipk", bundle.getnames())
                self.assertIn(f"{name}\ty\texported\t{version}\t", report)

    def test_dynamic_version_conflicts_fail(self):
        path = self.package("luci-app-mwan3", arch="all", version="26.246~abc", metadata_version="x")
        path.with_name("luci-app-mwan3_26.247~def_all.ipk").write_bytes(b"another version")
        (self.lists / "common.list").write_text("luci-app-mwan3", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "conflicting IPK"):
            self.run_export()

    def test_index_checksum_mismatch_fails(self):
        path = self.package("foo")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.run_export():
            pass
        path.write_bytes(b"changed after indexing")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.run_export(write_indexes=False)
        self.assertFalse((self.output / "selected-packages-256M.tar.gz").exists())

    def test_missing_index_does_not_fall_back_to_filenames(self):
        self.package("foo")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "missing current IPK in Packages indexes"):
            self.run_export(write_indexes=False)

    def test_indexed_ipk_missing_fails(self):
        path = self.package("foo")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.run_export():
            pass
        path.unlink()
        with self.assertRaisesRegex(ValueError, "indexed IPK is missing"):
            self.run_export(write_indexes=False)

    def test_dot_slash_index_filename(self):
        path = self.package("foo")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.run_export():
            pass
        index = path.parent / "Packages"
        index.write_text(index.read_text().replace("Filename: ", "Filename: ./"), encoding="utf-8")
        with self.run_export(write_indexes=False) as bundle:
            self.assertIn(path.name, bundle.getnames())

    def test_feed_directory_and_exact_name(self):
        path = self.package("foo")
        self.metadata = self.metadata.replace("Repository: base", "Repository: luci")
        feed = self.build / "bin/packages/aarch64_cortex-a53/luci"
        feed.mkdir()
        path.rename(feed / path.name)
        (feed / "foo-extra_1.0-r1_aarch64_cortex-a53.ipk").write_bytes(b"unrelated")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.run_export() as bundle:
            self.assertEqual(len([p for p in bundle.getnames() if p.endswith(".ipk")]), 1)

    def test_build_only_package_fails(self):
        self.package("foo")
        self.metadata = self.metadata.replace("Description:", "Build-Only: 1\nDescription:")
        (self.lists / "common.list").write_text("foo", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "not an installable"):
            self.run_export()

    def test_invalid_list_syntax_fails(self):
        (self.lists / "common.list").write_text("CONFIG_PACKAGE_foo=y", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "invalid package name"):
            self.run_export()

    def test_apk_build_fails(self):
        self.config += "CONFIG_USE_APK=y\n"
        with self.assertRaisesRegex(ValueError, "CONFIG_USE_APK"):
            self.run_export()


if __name__ == "__main__":
    unittest.main()
