"""Generate the pinned UE4SS DWM export thunks; no game binaries are read."""
from pathlib import Path
import argparse
import re

ROOT = Path(__file__).resolve().parent


def generate(output: Path):
    exports = []
    for line in (ROOT / 'dwmapi.exports').read_text('ascii').splitlines():
        if not line.strip() or line.startswith('Path:'):
            continue
        match = re.fullmatch(r'(\d+)\s*(\w+)?\s*', line)
        if not match:
            raise ValueError(f'Invalid export: {line}')
        exports.append((int(match[1]), match[2]))
    if len(exports) != len({ordinal for ordinal, _ in exports}):
        raise ValueError('Duplicate export ordinal')
    output.mkdir(parents=True, exist_ok=True)
    definitions = ['LIBRARY dwmapi', 'EXPORTS']
    asm = ['.code', 'extern mProcs:QWORD']
    cpp = [f'extern "C" {{ uintptr_t mProcs[{len(exports)}] = {{}}; }}',
           'static void setup_forwarders(HMODULE original) {']
    for index, (ordinal, name) in enumerate(exports):
        definitions.append(f'  {name or "ordinal" + str(ordinal)}=f{index} @{ordinal}')
        asm.extend((f'f{index} proc', f'  jmp mProcs[8*{index}]', f'f{index} endp'))
        symbol = f'"{name}"' if name else f'MAKEINTRESOURCEA({ordinal})'
        cpp.append(f'  mProcs[{index}] = reinterpret_cast<uintptr_t>(GetProcAddress(original, {symbol}));')
    asm.append('end')
    cpp.append('}')
    for filename, lines in [('dwmapi.def', definitions), ('dwmapi.asm', asm), ('proxy_exports.inc', cpp)]:
        (output / filename).write_text('\n'.join(lines) + '\n', 'ascii')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    generate(parser.parse_args().output)
