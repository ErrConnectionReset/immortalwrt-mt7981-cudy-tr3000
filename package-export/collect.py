#!/usr/bin/env python3
"""Export selected built-in IPKs from the current OpenWrt build."""

import argparse
import hashlib
import re
import shutil
import tarfile
import tempfile
from pathlib import Path


DEVICES = {"256M": "256m", "128M": "128m", "128M-Ubootmod": "128muboot"}


def read_list(path):
    packages = set()
    for number, line in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        name = line.strip()
        if not name or name.startswith("#"):
            continue
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", name):
            raise ValueError(f"{path}:{number}: invalid package name: {name}")
        packages.add(name)
    return packages


def read_metadata(path):
    packages = {}
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("Package: "):
            current = {}
            packages.setdefault(line[9:], []).append(current)
        elif line == "@@" or line.startswith("Description:"):
            current = None
        elif current is not None and ": " in line:
            key, value = line.split(": ", 1)
            current[key] = value
    return packages


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def indexed_ipks(roots, name, version, arch):
    matches = []
    for root in roots:
        index = root / "Packages"
        if not index.is_file():
            continue
        for block in index.read_text(encoding="utf-8").split("\n\n"):
            fields = dict(line.split(": ", 1) for line in block.splitlines()
                          if not line.startswith((" ", "\t")) and ": " in line)
            if fields.get("Package") != name or fields.get("Architecture") not in (arch, "all"):
                continue
            actual_version = fields["Version"]
            # LuCI deliberately emits Version: x during the metadata/DUMP phase.
            if actual_version == "x" or (version != "x" and actual_version != version):
                continue
            filename = f"{name}_{actual_version}_{fields['Architecture']}.ipk"
            if fields["Filename"] not in (filename, f"./{filename}"):
                raise ValueError(f"unexpected indexed filename: {fields['Filename']}")
            ipk = root / filename
            if not ipk.is_file():
                raise ValueError(f"indexed IPK is missing: {ipk}")
            checksum = digest(ipk)
            if checksum != fields["SHA256sum"]:
                raise ValueError(f"indexed IPK checksum mismatch: {ipk}")
            matches.append((ipk, actual_version, checksum))
    if not matches:
        raise ValueError(f"missing current IPK in Packages indexes: {name}_{version}_({arch}|all).ipk")
    if len({(path.name, actual_version, checksum) for path, actual_version, checksum in matches}) != 1:
        raise ValueError("conflicting IPK candidates in Packages indexes")
    return matches[0]


def collect(build, lists, output, device):
    config_path = build / ".config"
    config = {}
    for line in config_path.read_text(encoding="utf-8").splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            config[key] = value.strip('"')
    if config.get("CONFIG_USE_APK") == "y":
        raise ValueError("IPK export requires an opkg/IPK build, not CONFIG_USE_APK=y")

    sources = [lists / "common.list"]
    specific = lists / f"{DEVICES[device]}.list"
    if specific.is_file():
        sources.append(specific)
    requested = set()
    for source in sources:
        requested.update(read_list(source))
    metadata = read_metadata(build / "tmp/.packageinfo")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"selected-packages-{device}.tar.gz"
    summary = output / f"package-export-summary-{device}.md"
    rows = []
    errors = []

    with tempfile.TemporaryDirectory(prefix="package-export-") as temporary:
        stage = Path(temporary)
        (stage / "lists").mkdir()
        for source in sources:
            shutil.copyfile(source, stage / "lists" / source.name)
        shutil.copyfile(config_path, stage / "build.config")
        for name in sorted(requested):
            state = config.get(f"CONFIG_PACKAGE_{name}", "n")
            records = metadata.get(name, [])
            row = [name, state, "", "", "", ""]
            try:
                if len(records) != 1:
                    raise ValueError(f"expected one package metadata record, found {len(records)}")
                info = records[0]
                if info.get("Build-Only") == "1" or "ipkg" not in info.get("Type", "ipkg").split():
                    raise ValueError("not an installable IPK package")
                if state != "y":
                    row[2] = "skipped-m" if state == "m" else "skipped-disabled"
                    rows.append(row)
                    continue
                version = info["Version"]
                abi = info.get("ABI-Version", "") if not name.startswith("kmod-") else ""
                real_name = name + (("-" if name[-1].isdigit() else "") + abi if abi else "")
                arch = config["CONFIG_TARGET_ARCH_PACKAGES"]
                roots = [build / "bin/packages" / arch / info.get("Repository", "base"),
                         build / "bin/targets" / config["CONFIG_TARGET_BOARD"] /
                         config["CONFIG_TARGET_SUBTARGET"] / "packages"]
                ipk, actual_version, checksum = indexed_ipks(roots, real_name, version, arch)
                shutil.copyfile(ipk, stage / ipk.name)
                row[2:] = ["exported", actual_version, ipk.name, checksum]
            except (ValueError, KeyError) as error:
                row[2] = "error"
                errors.append(f"{name}: {error}")
            rows.append(row)

        report = "package\tconfig\tresult\tversion\tfilename\tsha256\n"
        report += "".join("\t".join(row) + "\n" for row in rows)
        (stage / "export-report.tsv").write_text(report, encoding="utf-8")
        summary_text = f"### Selected IPK export: {device}\n\n"
        summary_text += "| Package | Config | Result | IPK |\n| --- | --- | --- | --- |\n"
        summary_text += "".join(f"| `{r[0]}` | `{r[1]}` | {r[2]} | {r[4] or '—'} |\n" for r in rows)
        if not rows:
            summary_text += "\nNo packages requested.\n"
        summary_text += f"\nArchive: `{archive.name}`. Dependencies are not exported automatically.\n"
        if errors:
            summary_text += "\nExport failed:\n\n" + "".join(f"- {error}\n" for error in errors)
        summary.write_text(summary_text, encoding="utf-8")
        print(summary_text)
        if errors:
            # Never leave a successful-looking archive after a failed export.
            archive.unlink(missing_ok=True)
            raise ValueError("\n".join(errors))
        checksums = "".join(f"{r[5]}  {r[4]}\n" for r in rows if r[2] == "exported")
        (stage / "sha256sums").write_text(checksums, encoding="utf-8")
        with tarfile.open(archive, "w:gz") as bundle:
            for path in sorted(stage.iterdir()):
                bundle.add(path, arcname=path.name)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--lists", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--device", choices=DEVICES, required=True)
    args = parser.parse_args()
    try:
        collect(args.build, args.lists, args.output, args.device)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f"Package export failed: {error}\n")
