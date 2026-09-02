//===----------------------------------------------------------------------===//
// Copyright (c) 2026, Modular Inc. All rights reserved.
//
// Licensed under the Apache License v2.0 with LLVM Exceptions:
// https://llvm.org/LICENSE.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#include "Support/BinaryID.h"

#include "Support/WindowsHeader.h"
#include "llvm/ADT/StringExtras.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/Format.h"
#include "llvm/Support/Process.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Support/xxhash.h"
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <stdint.h>
#elif defined(_WIN32)
#include <cstdint>
#else
#include <elf.h>
#include <link.h>

// NOLINTNEXTLINE(bugprone-reserved-identifier), external symbol
extern const ElfW(Ehdr) __ehdr_start __attribute__((visibility("hidden")));
#endif // __APPLE__

using namespace M;

// https://github.com/llvm/llvm-project/blob/d1d5fc381f0930cf1190367dd6b2e0736c341071/compiler-rt/lib/sanitizer_common/sanitizer_common.h#L469-L472
inline size_t RoundUpTo(size_t size, size_t boundary) {
  return (size + boundary - 1) & ~(boundary - 1);
}

std::string M::getBinaryID() {
  std::string str;
  llvm::raw_string_ostream os(str);

  std::string postfix = "";
  // This env var is used to override the CUDA toolchain location.
  // Compiler-generated binaries depend on the toolchain,
  // so the binary version who impacts the whole cache is toolchain-dependent.
  if (auto path = llvm::sys::Process::GetEnv("MODULAR_NVPTX_COMPILER_PATH")) {
    llvm::XXH128_hash_t digest =
        llvm::xxh3_128bits(llvm::arrayRefFromStringRef<uint8_t>(path.value()));
    std::array<uint8_t, 16> bytes;
    memcpy(&bytes[0], &digest.low64, 8);
    memcpy(&bytes[8], &digest.high64, 8);
    postfix = "-" + llvm::toHex(bytes, /*LowerCase=*/true);
  }

#if defined(__APPLE__)
  // note: This code can run in a dylib or executable, we need to fetch the
  // address of whichever one it comes from
  Dl_info info;
  if (dladdr((void *)&getBinaryID, &info) == 0)
    llvm_unreachable("dladdr failed");

  auto *execHeader = (const struct mach_header_64 *)info.dli_fbase;

  // Get the header of the current binary or shared library, and find the UUID
  // load command
  uintptr_t command = (uintptr_t)execHeader + sizeof(struct mach_header_64);
  for (uint32_t idx = 0; idx < execHeader->ncmds; ++idx) {
    if (((const struct load_command *)command)->cmd == LC_UUID) {
      const struct uuid_command *cmd = (const struct uuid_command *)command;
      for (unsigned char i : cmd->uuid)
        os << llvm::format("%02x", i);
      return str + postfix;
    } else {
      command += ((const struct load_command *)command)->cmdsize;
    }
  }
#elif defined(_WIN32)
  // PE's answer to a GNU build id note or a Mach-O LC_UUID is the GUID in the
  // CodeView entry of the debug directory. The linker generates a fresh one on
  // every link, it is the key a symbol server files a PDB under, and like the
  // other two it is read out of the mapped image rather than off disk.
  //
  // GetModuleHandleEx with FROM_ADDRESS is the dladdr of the Apple branch above,
  // and it is here for the same reason: this code can end up in the executable
  // or in a DLL, and what we want is whichever one it actually ended up in.
  // UNCHANGED_REFCOUNT because we are only reading headers, so there is nothing
  // to keep alive and nothing to release afterwards.
  HMODULE module = nullptr;
  if (!::GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            reinterpret_cast<LPCSTR>(&getBinaryID), &module))
    llvm_unreachable("GetModuleHandleEx failed");

  // An HMODULE is the address the image is mapped at, so every RVA below is an
  // offset from it and no relocation arithmetic is needed. That is the one way
  // this is simpler than the ELF branch.
  const auto *base = reinterpret_cast<const unsigned char *>(module);
  const auto *dosHeader = reinterpret_cast<const IMAGE_DOS_HEADER *>(base);
  const auto *ntHeaders =
      reinterpret_cast<const IMAGE_NT_HEADERS *>(base + dosHeader->e_lfanew);
  const IMAGE_DATA_DIRECTORY &debugDir =
      ntHeaders->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DEBUG];

  // The RSDS record. windows.h does not declare it, but its layout is fixed by
  // the PE documentation and every debugger reads it, so declaring it here is
  // the normal thing rather than a shortcut.
  struct CodeViewRSDS {
    uint32_t signature;
    GUID guid;
    uint32_t age;
    char pdbPath[1];
  };
  // "RSDS" as a little-endian uint32. Spelled in hex rather than as a multi
  // character literal, because the byte order of those is up to the compiler
  // and this one is not.
  constexpr uint32_t kRSDS = 0x53445352;

  if (debugDir.VirtualAddress != 0) {
    const auto *entries = reinterpret_cast<const IMAGE_DEBUG_DIRECTORY *>(
        base + debugDir.VirtualAddress);
    for (uint32_t i = 0; i < debugDir.Size / sizeof(IMAGE_DEBUG_DIRECTORY);
         ++i) {
      if (entries[i].Type != IMAGE_DEBUG_TYPE_CODEVIEW)
        continue;
      const auto *rsds = reinterpret_cast<const CodeViewRSDS *>(
          base + entries[i].AddressOfRawData);
      if (rsds->signature != kRSDS)
        continue;
      const auto *guidBytes =
          reinterpret_cast<const unsigned char *>(&rsds->guid);
      for (size_t byte = 0; byte < sizeof(GUID); ++byte)
        os << llvm::format("%02x", guidBytes[byte]);
      os << llvm::format("%x", rsds->age);
      return str + postfix;
    }
  }

  // No CodeView entry means the image was linked without debug info. Fall back
  // to the timestamp and image size, which is the other identity PE has always
  // had and the one a symbol server uses to name an executable rather than a
  // PDB. Weaker than a GUID, since the timestamp only has second granularity,
  // but it is there unconditionally and it still changes across a relink.
  //
  // The other two platforms call llvm_unreachable here instead. They can afford
  // to, because a build id note and an LC_UUID are emitted by default and their
  // absence really does mean something is wrong. A PE without debug info is an
  // ordinary release build, so refusing to produce an ID would take out anything
  // that caches on it.
  os << llvm::format("%08x%08x", ntHeaders->FileHeader.TimeDateStamp,
                     ntHeaders->OptionalHeader.SizeOfImage);
  return str + postfix;
#else
  // Based off various compiler-rt sources
  // https://github.com/llvm/llvm-project/blob/d1d5fc381f0930cf1190367dd6b2e0736c341071/compiler-rt/lib/profile/InstrProfilingPlatformLinux.c#L195
  // https://github.com/llvm/llvm-project/blob/d1d5fc381f0930cf1190367dd6b2e0736c341071/compiler-rt/lib/profile/InstrProfilingPlatformLinux.c#L182
  const ElfW(Ehdr) *elfHeader = &__ehdr_start;
  const ElfW(Phdr) *programHeader =
      (const ElfW(Phdr) *)((uintptr_t)elfHeader + elfHeader->e_phoff);

  uintptr_t base = 0;
  for (uint32_t i = 0; i < elfHeader->e_phnum; ++i)
    if (programHeader[i].p_type == PT_PHDR)
      base = (uintptr_t)programHeader - programHeader[i].p_vaddr;

  for (ElfW(Half) i = 0; i < elfHeader->e_phnum; ++i) {
    if (programHeader[i].p_type != PT_NOTE)
      continue;

    // There can be multiple notes, iterate until we find the build-id
    const ElfW(Nhdr) *note =
        (const ElfW(Nhdr) *)(base + programHeader[i].p_vaddr);
    const ElfW(Nhdr) *notesEnd =
        (const ElfW(Nhdr) *)((const char *)(note) + programHeader[i].p_memsz);

    while (note < notesEnd) {
      size_t payload = sizeof(ElfW(Nhdr)) + RoundUpTo(note->n_namesz, 4);

      if (note->n_type == NT_GNU_BUILD_ID) {
        const char *s = (const char *)(note) + payload;
        for (ElfW(Word) i = 0; i < note->n_descsz; ++s, ++i)
          os << llvm::format("%02hhx", *s);
        return str + postfix;
      }

      size_t noteEndOffset = RoundUpTo(note->n_descsz, 4);
      note =
          (const ElfW(Nhdr) *)((const char *)(note) + payload + noteEndOffset);
    }
  }
#endif // __APPLE__

  llvm_unreachable("No build id note found");
}
