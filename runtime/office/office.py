"""Convert and render Office files with isolated LibreOffice state."""
from pathlib import Path
import argparse
import shutil
import subprocess
import tempfile


def convert(source, output, kind):
    executable = shutil.which('soffice')
    if not executable:
        candidate = Path('/Applications/LibreOffice.app/Contents/MacOS/soffice')
        executable = str(candidate) if candidate.exists() else None
    if not executable:
        raise RuntimeError('LibreOffice is required for Office rendering and recalculation')
    output.mkdir(parents=True, exist_ok=True)
    target = output / (source.stem + '.' + kind)
    if target.resolve() == source.resolve() or target.exists():
        raise ValueError('Choose a new output directory; existing files are never overwritten')
    with tempfile.TemporaryDirectory(prefix='f-office-profile-') as profile:
        result = subprocess.run([executable, '-env:UserInstallation=' + Path(profile).as_uri(), '--headless', '--convert-to', kind, '--outdir', str(output), str(source)], capture_output=True, text=True, timeout=180)
        if result.returncode or not target.is_file() or not target.stat().st_size:
            raise RuntimeError('Office conversion failed: ' + result.stdout + result.stderr)
    return target


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['render', 'pdf', 'recalculate'])
    parser.add_argument('source', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if args.action == 'recalculate':
        if source.suffix.lower() != '.xlsx':
            raise ValueError('Recalculation requires XLSX')
        target = convert(source, args.output, 'xlsx')
        from openpyxl import load_workbook
        workbook = load_workbook(target, data_only=True)
        failures = [f'{sheet.title}!{cell.coordinate}: {cell.value}' for sheet in workbook for row in sheet for cell in row if cell.data_type == 'e']
        workbook.close()
        if failures:
            raise RuntimeError('Calculated workbook contains errors: ' + ', '.join(failures[:30]))
    else:
        target = convert(source, args.output, 'pdf')
        from pypdf import PdfReader
        if not PdfReader(target).pages:
            raise RuntimeError('Exported PDF has no pages')
        if args.action == 'render':
            renderer = shutil.which('pdftoppm')
            if not renderer:
                raise RuntimeError('pdftoppm is required for page images; PDF retained at ' + str(target))
            subprocess.run([renderer, '-png', '-r', '110', str(target), str(args.output / source.stem)], check=True, timeout=180)
    print(target)


if __name__ == '__main__':
    main()
