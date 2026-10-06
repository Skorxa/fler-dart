#!/bin/bash
# Patch Blutter for Dart 3.13+ compatibility (macro-guarded, non-invasive)
# Ported from gffhgjfhfjg/fler-dart v0.5.1
#
# Dart 3.13 four breaking changes (macros defined by SDK header feature
# detection in build script Step 2b):
#   1. ObjectStore stub accessors removed, stubs merged into StubCode (VM stubs):
#      - OBJECT_STORE_STUB_CODE_LIST removed from vm/object_store.h
#      - Stub enums referenced by blutter now have VM suffix (InitAsyncStub → InitAsyncVMStub etc.)
#      - ObjectStore::throw_stub() / StubCode::HasBeenInitialized() removed
#   2. Closure refactored to inline elements (context / delayed_type_arguments
#      fields and their AOT offset symbols removed)
#   3. Embedder API removed vm_snapshot_data / vm_snapshot_instructions fields
#      from Dart_InitializeParams
#   4. Snapshot ELF symbols unified: 4 symbols merged into _kDartSnapshotData / _kDartSnapshotText
#
# Usage: bash patch-dart313.sh <blutter-src-dir>
#   e.g. bash patch-dart313.sh /tmp/build/blutter/blutter/src
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <blutter-src-dir>"
  exit 1
fi
SRC_DIR="$1"

python3 - "$SRC_DIR" << 'PYEOF'
import sys, os
src = sys.argv[1]

def load(name):
    with open(os.path.join(src, name), encoding='utf-8') as f:
        return f.read().split('\n')

def save(name, lines):
    with open(os.path.join(src, name), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))

def already(name, marker):
    return marker in '\n'.join(load(name))

def indent_of(line):
    return line[:len(line) - len(line.lstrip('\t'))]

import sys, os
src = sys.argv[1]
def load(name):
    with open(os.path.join(src, name), encoding='utf-8') as f:
        return f.read().split('\n')
def save(name, lines):
    with open(os.path.join(src, name), 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines))
def already(name, marker):
    return marker in '\n'.join(load(name))
def indent_of(line):
    return line[:len(line) - len(line.lstrip('\t'))]
# 1. DartStub.h：枚举中的 OBJECT_STORE_STUB_CODE_LIST 块加守卫
name = 'DartStub.h'
if not already(name, 'NO_OBJECT_STORE_STUB'):
    s = load(name)
    i = s.index('#define DO(member, name) name ## Stub,')
    j = next(k for k in range(i, len(s)) if s[k].startswith('#undef DO'))
    s.insert(i, '#ifndef NO_OBJECT_STORE_STUB')
    s.insert(j + 2, '#endif')
    save(name, s)
    print('  DartStub.h: OBJECT_STORE enum block guarded')
# 2. pch.h：旧存根枚举名 → VM 后缀名别名（仅 3.13+ 生效）
name = 'pch.h'
if not already(name, 'NO_OBJECT_STORE_STUB'):
    s = load(name)
    i = s.index('#ifdef NO_INIT_LATE_STATIC_FIELD')
    j = next(k for k in range(i, len(s)) if s[k].startswith('#endif'))
    s[j + 1:j + 1] = [
        '',
        '// fler-dart: Dart 3.13+ — object store stubs merged into VM stubs (renamed with VM suffix)',
        '#ifdef NO_OBJECT_STORE_STUB',
        '#  define InitAsyncStub InitAsyncVMStub',
        '#  define DefaultTypeTestStub DefaultTypeTestVMStub',
        '#  define DefaultNullableTypeTestStub DefaultNullableTypeTestVMStub',
        '#  define AllocateMintSharedWithoutFPURegsStub AllocateMintSharedWithoutFPURegsVMStub',
        '#  define AllocateMintSharedWithFPURegsStub AllocateMintSharedWithFPURegsVMStub',
        '#  define InitLateStaticFieldStub InitLateStaticFieldVMStub',
        '#  define InitLateFinalStaticFieldStub InitLateFinalStaticFieldVMStub',
        '#  define LateInitializationErrorSharedWithoutFPURegsStub LateInitializationErrorSharedWithoutFPURegsVMStub',
        '#  define LateInitializationErrorSharedWithFPURegsStub LateInitializationErrorSharedWithFPURegsVMStub',
        '#  define WriteBarrierWrappersStub WriteBarrierWrappersVMStub',
        '#  define ArrayWriteBarrierStub ArrayWriteBarrierVMStub',
        '#endif',
    ]
    save(name, s)
    print('  pch.h: stub kind aliases added')
# 3. DartApp.cpp：loadStubs 的 ObjectStore 存根装载块加守卫
name = 'DartApp.cpp'
if not already(name, 'NO_OBJECT_STORE_STUB'):
    s = load(name)
    i = s.index('#define DO(member, name) \\')
    assert 'store->member()' in s[i + 1], 'DartApp.cpp: loadStubs DO block not found'
    s.insert(i, '#ifndef NO_OBJECT_STORE_STUB')
    k = next(x for x in range(i, len(s)) if 'StubCode::HasBeenInitialized' in s[x])
    s[k + 1:k + 1] = [
        '#else',
        '\t// fler-dart: Dart 3.13+ — object store stub accessors removed (merged into VM stubs)',
        '\tthrowStubAddr = dart::StubCode::Throw().EntryPoint();',
        '#endif',
    ]
    save(name, s)
    print('  DartApp.cpp: loadStubs object-store block guarded')
# 4. CodeAnalyzer_arm64.cpp：Closure context / delayed type arguments 检测加守卫
name = 'CodeAnalyzer_arm64.cpp'
if not already(name, 'NO_CLOSURE_CONTEXT_FIELD'):
    s = load(name)
    i = next(k for k in range(len(s)) if 'AOT_Closure_context_offset - dart::kHeapObjectTag' in s[k])
    orig = s[i]
    s[i:i + 1] = [
        '#ifndef NO_CLOSURE_CONTEXT_FIELD',
        orig,
        '#else',
        indent_of(orig) + 'if (false) { // fler-dart: Dart 3.13+ Closure.context removed (inline elements)',
        '#endif',
    ]
    i = next(k for k in range(len(s)) if 'AOT_Closure_delayed_type_arguments_offset - dart::kHeapObjectTag' in s[k])
    orig = s[i]
    s[i:i + 1] = [
        '#ifndef NO_CLOSURE_CONTEXT_FIELD',
        orig,
        '#else',
        indent_of(orig) + 'if (false) { // fler-dart: Dart 3.13+ Closure.delayed_type_arguments removed',
        '#endif',
    ]
    save(name, s)
    print('  CodeAnalyzer_arm64.cpp: closure field guards added')
# 5. FridaWriter.cpp：contextOffset 输出加守卫
name = 'FridaWriter.cpp'
if not already(name, 'NO_CLOSURE_CONTEXT_FIELD'):
    s = load(name)
    i = next(k for k in range(len(s)) if 'AOT_Closure_context_offset <<' in s[k])
    s[i:i + 1] = ['#ifndef NO_CLOSURE_CONTEXT_FIELD', s[i], '#endif']
    save(name, s)
    print('  FridaWriter.cpp: contextOffset output guarded')
# 6. DartLoader.cpp：Dart_InitializeParams 的 vm_snapshot 字段加守卫
#    Dart 3.13 起嵌入 API 移除 vm_snapshot_data/vm_snapshot_instructions
#    （VM 快照不再经由 Dart_Initialize 传入，isolate 快照接口不变）。
name = 'DartLoader.cpp'
if not already(name, 'NO_EMBED_VM_SNAPSHOT'):
    s = load(name)
    i = next(k for k in range(len(s)) if 'init_params.vm_snapshot_data' in s[k])
    s[i:i + 2] = ['#ifndef NO_EMBED_VM_SNAPSHOT'] + s[i:i + 2] + ['#endif']
    save(name, s)
    print('  DartLoader.cpp: vm_snapshot params guarded')
# 7. ElfHelper.cpp：快照 ELF 符号统一为 _kDartSnapshotData/_kDartSnapshotText
#    Dart 3.13 起 4 个符号（_kDartVmSnapshotData 等）合并为 2 个，
#    统一快照直接传给 Dart_CreateIsolateGroup（见 3.13 dart_api.h 文档）。
name = 'ElfHelper.cpp'
if not already(name, 'NO_SPLIT_SNAPSHOT_SYMBOLS'):
    s = load(name)
    i = next(k for k in range(len(s)) if 'const char* s_first = kVmSnapshotDataAsmSymbol;' in s[k])
    assert 'const char* s_last = s_first + strlen(kVmSnapshotDataAsmSymbol)' in s[i + 1]
    s[i:i + 2] = [
        '#ifdef NO_SPLIT_SNAPSHOT_SYMBOLS',
        '\t\t\tconst char* s_first = kSnapshotDataAsmSymbol;',
        '\t\t\tconst char* s_last = s_first + strlen(kSnapshotDataAsmSymbol) + 1;',
        '#else',
        s[i], s[i + 1],
        '#endif',
    ]
    i = next(k for k in range(len(s)) if 'strcmp(name, kVmSnapshotDataAsmSymbol)' in s[k])
    j = next(k for k in range(i, len(s)) if 'isolate_snapshot_instructions = elf + dynsym->value;' in s[k])
    block = s[i:j + 2]
    s[i:j + 2] = ['#ifndef NO_SPLIT_SNAPSHOT_SYMBOLS'] + block + [
        '#else',
        '\t\t// fler-dart: Dart 3.13+ unified snapshot (_kDartSnapshotData/_kDartSnapshotText)',
        '\t\tif (strcmp(name, kSnapshotDataAsmSymbol) == 0) {',
        '\t\t\tvm_snapshot_data = isolate_snapshot_data = elf + dynsym->value;',
        '\t\t}',
        '\t\telse if (strcmp(name, kSnapshotTextAsmSymbol) == 0) {',
        '\t\t\tvm_snapshot_instructions = isolate_snapshot_instructions = elf + dynsym->value;',
        '\t\t}',
        '#endif',
    ]
    save(name, s)
    print('  ElfHelper.cpp: unified snapshot symbols guarded')
print('  Dart 3.13+ compat patches applied')
PYEOF
echo "Dart 3.13+ compat patches applied"
