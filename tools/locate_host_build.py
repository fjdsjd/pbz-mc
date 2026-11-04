"""Locate PBZ hook candidates in an updated executable. This tool only reads files."""
import argparse
import bisect
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import sys

import capstone
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP
import pefile

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('take_damage', 'apply_health', 'modify_attribute', 'activate_state', 'retry_a', 'retry_b')


class Image:
    def __init__(self, path):
        with path.open('rb') as stream:
            self.digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        self.pe = pefile.PE(str(path), fast_load=True)
        if self.pe.FILE_HEADER.Machine != 0x8664 or self.pe.OPTIONAL_HEADER.Magic != 0x20b:
            raise ValueError(f'{path.name}: expected a Windows x64 PE')
        directory = self.pe.OPTIONAL_HEADER.DATA_DIRECTORY[3]
        self.functions = sorted((a, b) for a, b, _ in struct.iter_unpack(
            '<III', self.pe.get_data(directory.VirtualAddress, directory.Size)) if a < b)
        self.starts = [a for a, _ in self.functions]
        self.code = [(s.VirtualAddress, s.get_data()) for s in self.pe.sections
                     if s.Characteristics & 0x20000000 and s.SizeOfRawData]
        self.dis = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.dis.detail = True

    def function_at(self, rva):
        i = bisect.bisect_right(self.starts, rva) - 1
        if i < 0 or rva >= self.functions[i][1]:
            raise ValueError(f'{rva:#x} is outside x64 unwind ranges')
        return self.functions[i]

    def instructions(self, start, end):
        # RVA-relative disassembly makes immediate branch targets RVAs too.
        ins = list(self.dis.disasm(self.pe.get_data(start, end - start), start))
        if not ins or ins[-1].address + ins[-1].size != end:
            raise ValueError(f'incomplete disassembly at {start:#x}')
        return ins


def normalized(ins, start, end):
    """Only mask RIP displacements and external branch/call relocations."""
    plain, mask = bytearray(), bytearray()
    for i in ins:
        keep = bytearray([1]) * i.size
        if i.disp_size and any(op.type == X86_OP_MEM and op.mem.base == X86_REG_RIP for op in i.operands):
            keep[i.disp_offset:i.disp_offset+i.disp_size] = bytes(i.disp_size)
        if i.imm_size and (i.group(capstone.CS_GRP_JUMP) or i.group(capstone.CS_GRP_CALL)):
            if i.operands[0].type == X86_OP_IMM and not start <= i.operands[0].imm < end:
                keep[i.imm_offset:i.imm_offset+i.imm_size] = bytes(i.imm_size)
        plain.extend(b if k else 0 for b, k in zip(i.bytes, keep))
        mask.extend(keep)
    return bytes(plain), bytes(mask)


def find_function(old, new, rva):
    start, end = old.function_at(rva)
    ins = old.instructions(start, end)
    expect = normalized(ins, start, end)
    anchor = max(re.finditer(b'\x01+', expect[1]), key=lambda m: m.end() - m.start())
    needle = expect[0][anchor.start():anchor.end()]
    hits = []
    for section_rva, code in new.code:
        offset = 0
        while (pos := code.find(needle, offset)) >= 0:
            offset = pos + 1
            candidate = section_rva + pos - anchor.start()
            index = bisect.bisect_left(new.starts, candidate)
            if index >= len(new.starts) or new.starts[index] != candidate:
                continue
            a, b = new.functions[index]
            if b-a == end-start and normalized(new.instructions(a, b), a, b) == expect:
                hits.append(a + (rva-start))
    if len(hits) != 1:
        raise ValueError(f'{rva:#x}: {len(hits)} matching function ranges; manual review required')
    return hits[0], len(ins)


def direct_callee(image, ret):
    call, = image.instructions(ret-5, ret)
    if call.mnemonic != 'call' or call.operands[0].type != X86_OP_IMM:
        raise ValueError(f'{ret:#x} is not a direct call return address')
    return call.operands[0].imm


def locate(old, new):
    rows = [next(csv.reader([line[1:-2]])) for line in
            (ROOT/'native/json_bridge/host_builds.inc').read_text('ascii').splitlines() if line.startswith('{')]
    profiles = {row[0]: dict(zip(NAMES, (int(v, 16) for v in row[3:]), strict=True)) for row in rows}
    if old.digest not in profiles:
        raise ValueError('reference executable is not a verified build')
    result, lengths = {}, {}
    for name, rva in profiles[old.digest].items():
        result[name], lengths[name] = find_function(old, new, rva)
    for site in ('retry_a', 'retry_b'):
        if (direct_callee(old, profiles[old.digest][site]) != profiles[old.digest]['activate_state']
                or direct_callee(new, result[site]) != result['activate_state']):
            raise ValueError(f'{site}: pending-state call target changed')
    if new.digest in profiles and result != profiles[new.digest]:
        raise ValueError('candidates differ from the verified target table')
    return dict(reference_sha256=old.digest, candidate_sha256=new.digest,
                candidate_rvas={k: hex(v) for k, v in result.items()}, matched_instructions=lengths,
                runtime_verified=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reference', type=Path, help='a verified PBZ.exe')
    parser.add_argument('candidate', type=Path, help='the updated PBZ.exe')
    args = parser.parse_args()
    try:
        print(json.dumps(locate(Image(args.reference), Image(args.candidate)), indent=2))
    except (OSError, ValueError, pefile.PEFormatError, capstone.CsError) as err:
        sys.exit(str(err))
