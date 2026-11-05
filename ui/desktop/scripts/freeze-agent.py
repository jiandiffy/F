"""Freeze canonical modules and regular compatibility entries; no bundle symlinks."""
from pathlib import Path
import json
import os
import shutil
import sys


def freeze(resources):
    resources = Path(resources).resolve(strict=True)

    def checked(path):
        resolved = path.resolve(strict=True)
        if resources != resolved and resources not in resolved.parents:
            raise ValueError('Resource alias escapes the signed bundle: ' + str(path))
        return resolved

    def module_entries(source, destination):
        destination.mkdir()
        for entry in sorted(source.iterdir()):
            target = checked(entry)
            output = destination/entry.name
            if target.is_dir():
                module_entries(target, output)
            elif target.suffix == '.mjs':
                relative = os.path.relpath(target, output.parent)
                if not relative.startswith('.'):
                    relative = './' + relative
                output.write_text('export * from ' + json.dumps(relative) + ';\n')
            else:
                shutil.copy2(target, output)

    for entry in sorted((resources/'runtime/harness/src').iterdir()):
        if entry.is_symlink():
            target = checked(entry)
            entry.unlink()
            module_entries(target, entry)

    # Non-module aliases are generated assets, such as the Chrome extension.
    for entry in sorted(resources.rglob('*')):
        if not entry.is_symlink():
            continue
        target = checked(entry)
        entry.unlink()
        if target.is_dir():
            shutil.copytree(target, entry)
        else:
            shutil.copy2(target, entry)
    if any(entry.is_symlink() for entry in resources.rglob('*')):
        raise ValueError('Unresolved resource alias')


if __name__ == '__main__':
    freeze(sys.argv[1])
