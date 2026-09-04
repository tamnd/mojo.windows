# ===----------------------------------------------------------------------=== #
# Copyright (c) 2026, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #
"""Taking a Windows path apart, which is not the job it is on Unix.

A Unix path is a run of names with slashes between them, and everything `split`,
`dirname` and `join` do follows from that one sentence. A Windows path has a
piece in front that is not a name and does not behave like one, and every
function in this file exists because of that piece.

There are four kinds of it and the differences between them are not cosmetic.

`C:\\Users\\name` names one exact place. The drive letter and the separator after
it belong together and neither half means anything without the other.

`C:Users\\name` is a different path. Windows keeps a current directory per drive,
so that one means `Users\\name` relative to wherever the process last was on C.
Nobody writes one deliberately. They come out of joining `C:` to something, and
reading one as absolute puts a program in the wrong directory rather than
failing, which is the worst of the available outcomes.

`\\Users\\name` has a root but no drive, so it means that place on whichever drive
is current. Also not absolute, for the same reason.

`\\\\server\\share\\name` is a UNC path, and the first two components together are
the drive. Neither `\\\\server` nor the parent of `\\\\server\\share` is a place you
can be. There is also `\\\\?\\C:\\name`, which turns off path parsing in the kernel
and lifts the length limit, and `\\\\?\\UNC\\server\\share`, which is that same
trick applied to a share and which puts the server name eight bytes in rather
than two.

On top of all that, a forward slash works everywhere a backslash does. Real path
text on Windows is full of them, out of shells, configuration files and a fair
part of the Windows API, so nothing here may look for one separator only.

Taking a path apart is not all of it. There are rules about what a name means
that splitting never has to know, and three of them are here because getting
them wrong is quiet rather than loud. Case is not part of a name, so two strings
that differ only in case are one file. `CON`, `NUL`, `COM1` and their relatives
are devices at every level of every directory, so a program that builds a name
out of somebody else's text can be talked into opening one. Trailing dots and
spaces are dropped on the way in, so `file.txt.` reaches `file.txt` while every
lexical function here still reads the dot as part of the name.

The rules below are CPython's, from `ntpath`, and deliberately so rather than for
lack of an opinion. Anyone who has written Python on Windows already knows what
these functions do with a strange path, and a port that is subtly cleverer than
the thing everybody knows is worse than one that is not.

Everything here is text. Nothing in this file touches the file system, so none of
it depends on whether any of these paths exists.
"""

from ..env import getenv
from ..os import sep

comptime _BACKSLASH = Byte(ord("\\"))
comptime _SLASH = Byte(ord("/"))
comptime _COLON = Byte(ord(":"))
comptime _QUESTION = Byte(ord("?"))
comptime _DOT = Byte(ord("."))
comptime _SPACE = Byte(ord(" "))

# The length of the extended length UNC prefix, counting the separator that
# closes it, because the scan for the server name has to start after that
# separator rather than on it.
comptime _UNC_PREFIX_LENGTH = 8


@always_inline
def _is_sep(byte: Byte) -> Bool:
    """Whether a byte separates two components of a Windows path."""
    return byte == _BACKSLASH or byte == _SLASH


@always_inline
def _upper(byte: Byte) -> Byte:
    """An ASCII byte in upper case, and anything else unchanged.

    ASCII only, and that is the whole promise. A drive letter is ASCII and the
    UNC prefix is ASCII, which is everything this file compares without regard
    to case. A full Unicode case fold is a much larger claim and belongs
    somewhere it can be tested as one.
    """
    if byte >= Byte(ord("a")) and byte <= Byte(ord("z")):
        return byte - 32
    return byte


def _is_ascii(path: StringSlice) -> Bool:
    """Whether every byte of `path` is ASCII."""
    var bytes = path.as_bytes()
    for i in range(path.byte_length()):
        if bytes[i] >= 0x80:
            return False
    return True


def _normcase(path: StringSlice) -> String:
    """A path in the form two paths have to be in to be compared as text.

    Windows compares path names without regard to case and stores whatever case
    was written, so `C:\\Users` and `c:\\users` are two spellings of one file.
    It also takes either separator everywhere, so `C:/Users` is a third.
    Anything that decides whether two paths are the same by comparing the
    strings has to put both through here first, and has to keep the originals
    for anything it shows a person or hands to the file system.

    This is CPython's `ntpath.normcase`: the separators go one way and the whole
    string goes to lower case. It is not a normalisation in any other sense. It
    does not touch `.` or `..`, it does not collapse repeated separators, and it
    does not make a relative path absolute, so two paths that name the same file
    can still come out of here different.

    Lower case rather than upper is worth a word, because Windows itself folds
    the other way and the two disagree on a handful of characters. Matching
    CPython matters more here than matching the kernel, since the comparison
    this feeds is between two strings a program is holding, not between a string
    and something on disk.
    """
    return path.replace("/", "\\").lower()


def _equal_ignoring_case(a: StringSlice, b: StringSlice) -> Bool:
    """Whether two drives are the same drive, ignoring case.

    This is `_normcase` without the separator rewriting and without allocating,
    which is worth having separately because a drive is almost always a letter
    and a colon and the answer is two byte comparisons. The fold falls back to
    the same one `_normcase` uses as soon as either side has a byte outside
    ASCII, which for a drive means a share on a server with a non ASCII name.
    """
    if not _is_ascii(a) or not _is_ascii(b):
        # Not a byte for byte comparison, because lowering a character can
        # change how many bytes it takes and even how many characters it is.
        return a.lower() == b.lower()
    if a.byte_length() != b.byte_length():
        return False
    var a_bytes = a.as_bytes()
    var b_bytes = b.as_bytes()
    for i in range(a.byte_length()):
        if _upper(a_bytes[i]) != _upper(b_bytes[i]):
            return False
    return True


def _find_sep(path: StringSlice, start: Int) -> Int:
    """The index of the first separator at or after `start`, or -1."""
    var bytes = path.as_bytes()
    for i in range(start, path.byte_length()):
        if _is_sep(bytes[i]):
            return i
    return -1


def _rfind_sep(path: StringSlice) -> Int:
    """The index of the last separator, or -1."""
    var bytes = path.as_bytes()
    var i = path.byte_length()
    while i > 0:
        i -= 1
        if _is_sep(bytes[i]):
            return i
    return -1


def _strip_end(path: StringSlice) -> Int:
    """The length `path` has once trailing separators are taken off."""
    var bytes = path.as_bytes()
    var end = path.byte_length()
    while end > 0 and _is_sep(bytes[end - 1]):
        end -= 1
    return end


def _has_unc_prefix(path: StringSlice) -> Bool:
    """Whether `path` opens with the extended length UNC prefix.

    Windows does not care about the case of the letters and takes either
    separator, so `//?/unc/` is the same prefix as `\\\\?\\UNC\\` and both have
    to be recognised.
    """
    if path.byte_length() < _UNC_PREFIX_LENGTH:
        return False
    var bytes = path.as_bytes()
    if not _is_sep(bytes[0]) or not _is_sep(bytes[1]):
        return False
    if bytes[2] != _QUESTION or not _is_sep(bytes[3]):
        return False
    if _upper(bytes[4]) != Byte(ord("U")):
        return False
    if _upper(bytes[5]) != Byte(ord("N")):
        return False
    if _upper(bytes[6]) != Byte(ord("C")):
        return False
    return _is_sep(bytes[7])


def _splitroot(path: StringSlice) -> Tuple[String, String, String]:
    """Splits a Windows path into drive, root and the rest.

    The three pieces put back together are the original string, byte for byte,
    which is what makes this usable as the front of every other function here.

    The drive is the part that is not a name: a drive letter, or a whole
    `\\\\server\\share`. The root is the separator that says the rest is measured
    from the top rather than from where the process happens to be. Either can be
    empty and they mean different things when they are, which is the reason they
    are two values and not one.
    """
    comptime empty = String("")
    var length = path.byte_length()
    var bytes = path.as_bytes()

    if length >= 1 and _is_sep(bytes[0]):
        if length >= 2 and _is_sep(bytes[1]):
            # Two leading separators, so a UNC share, `\\server\share`, or a
            # device path, `\\?\C:` or `\\.\PhysicalDrive0`. Both have two
            # components of drive rather than one, and the extended length UNC
            # prefix pushes those two components along by its own length.
            var start = 2
            if _has_unc_prefix(path):
                start = _UNC_PREFIX_LENGTH
            var server_end = _find_sep(path, start)
            if server_end < 0:
                # `\\server` on its own. Not a place, and there is nothing after
                # it to be relative to, so it is all drive.
                return String(path), empty, empty
            var share_end = _find_sep(path, server_end + 1)
            if share_end < 0:
                # `\\server\share`, which is the whole drive and nothing else.
                return String(path), empty, empty
            return (
                String(path[byte=:share_end]),
                String(path[byte=share_end : share_end + 1]),
                String(path[byte = share_end + 1 :]),
            )
        # A root and no drive, `\Windows`. That is the top of whichever drive is
        # current, so it is rooted without being absolute.
        return empty, String(path[byte=:1]), String(path[byte=1:])

    if length >= 2 and bytes[1] == _COLON:
        if length >= 3 and _is_sep(bytes[2]):
            # `C:\Windows`, the only spelling that names one place on its own.
            return (
                String(path[byte=:2]),
                String(path[byte=2:3]),
                String(path[byte=3:]),
            )
        # `C:Windows`, relative to the current directory on C. A drive with no
        # root, which is why the two are kept apart.
        return String(path[byte=:2]), empty, String(path[byte=2:])

    return empty, empty, String(path)


def _split(path: StringSlice) -> Tuple[String, String]:
    """Splits a Windows path into everything before the last name, and the name.

    The drive comes off first and goes back on at the end untouched. Without
    that, splitting `C:\\` would find the separator inside the drive and hand
    back a head of `C:` and a tail of nothing, which reads as a relative path
    and is not one.
    """
    var parts = _splitroot(path)
    var front = parts[0]
    front += parts[1]
    var rest = parts[2]

    var cut = _rfind_sep(rest) + 1
    var head = rest[byte=:cut]
    var tail = String(rest[byte=cut:])

    # Trailing separators come off the head, but only after the root has been
    # taken away, so that the root itself survives being the whole head.
    front += head[byte=: _strip_end(head)]
    return front^, tail^


def _is_absolute(path: StringSlice) -> Bool:
    """Whether a Windows path names one place and needs nothing else to.

    Two spellings qualify and no others. A drive letter with a root after it,
    and two leading separators, which covers both a UNC share and a device path.

    A leading separator on its own does not, and neither does a drive letter on
    its own, because both of them are measured from a current directory. This is
    what CPython settled on and it is worth saying why: calling `\\Windows`
    absolute is true in the sense that it does not start from the current
    directory of the current drive, and false in the sense that resolving it
    still needs to know which drive that is. The second sense is the one every
    caller of this function actually wants.
    """
    var length = path.byte_length()
    var bytes = path.as_bytes()

    if length >= 3 and bytes[1] == _COLON and _is_sep(bytes[2]):
        return True
    if length >= 2 and _is_sep(bytes[0]) and _is_sep(bytes[1]):
        return True
    return False


def _join(path: StringSlice, tail: StringSlice) -> String:
    """Joins one path onto another under the Windows rules.

    Joining is not concatenation with a separator in the middle, because the
    second path can say enough about where it starts to make the first one
    irrelevant. There are three ways it can do that and they give three
    different answers, which is the whole of what is below.
    """
    var left = _splitroot(path)
    var right = _splitroot(tail)

    var drive = left[0]
    var root = left[1]
    var rest = left[2]

    if right[1]:
        # The second path has a root, so it replaces what came before rather
        # than extending it. It keeps the first path's drive when it does not
        # name one of its own, which is how `C:\a` joined to `\b` comes out as
        # `C:\b` and not as a path on some other drive.
        if right[0] or not drive:
            drive = right[0]
        root = right[1]
        rest = right[2]
    else:
        if right[0] and not _equal_ignoring_case(right[0], drive):
            # A different drive. Nothing about a place on one volume says
            # anything about a name on another, so the first path is dropped.
            return String(tail)
        if right[0]:
            # The same drive spelled in a different case. Take the newer
            # spelling, since that is the one the caller just wrote.
            drive = right[0]
        if rest and not _is_sep(rest.as_bytes()[rest.byte_length() - 1]):
            rest += sep
        rest += right[2]

    # A drive with no root is a position part way through a name rather than the
    # start of one, so a share needs a separator putting back between it and
    # what follows. A drive letter does not, because `C:a` is a real path and
    # means something different from `C:\a`.
    if rest and not root and drive:
        var last = drive.as_bytes()[drive.byte_length() - 1]
        if last != _COLON and not _is_sep(last):
            return drive + sep + rest

    return drive + root + rest


def _is_reserved_character(byte: Byte) -> Bool:
    """Whether a byte cannot appear in a Windows file name.

    The control characters are out because the file system says so. The colon
    is out because it opens an alternate data stream rather than a file, so
    `name:stream` is not a name with a colon in it. The rest are the wildcards
    and the redirection characters the command interpreter and the file system
    both claim.
    """
    if byte < 32:
        return True
    return (
        byte == Byte(ord('"'))
        or byte == Byte(ord("*"))
        or byte == _COLON
        or byte == Byte(ord("<"))
        or byte == Byte(ord(">"))
        or byte == _QUESTION
        or byte == Byte(ord("|"))
        or _is_sep(byte)
    )


def _is_device_stem(stem: StringSlice) -> Bool:
    """Whether a name with its extension taken off is a DOS device.

    These are not names that happen to be taken. They are devices at every
    level of every directory, so `C:\\dir\\nul.txt` is the null device and not a
    file in `dir`, and the open succeeds, which is what makes them worth a
    function.

    The superscript digits on the end of the port numbers are not a typo.
    Windows reads `COM\\u00b9` as `COM1`, so a name that looks like ordinary
    text is a device.
    """
    var length = stem.byte_length()
    var bytes = stem.as_bytes()

    if length == 3:
        return (
            _equal_ignoring_case(stem, "CON")
            or _equal_ignoring_case(stem, "PRN")
            or _equal_ignoring_case(stem, "AUX")
            or _equal_ignoring_case(stem, "NUL")
        )
    if length == 6:
        return _equal_ignoring_case(stem, "CONIN$")
    if length == 7:
        return _equal_ignoring_case(stem, "CONOUT$")

    # A serial or parallel port, which is three letters and a port number.
    if length != 4 and length != 5:
        return False
    var head = stem[byte=:3]
    if not _equal_ignoring_case(head, "COM") and not _equal_ignoring_case(
        head, "LPT"
    ):
        return False
    if length == 4:
        return bytes[3] >= Byte(ord("1")) and bytes[3] <= Byte(ord("9"))
    # The superscripts one, two and three, which are two bytes each in UTF-8
    # and share a first byte.
    return bytes[3] == 0xC2 and (
        bytes[4] == 0xB9 or bytes[4] == 0xB2 or bytes[4] == 0xB3
    )


def _is_reserved_name(name: StringSlice) -> Bool:
    """Whether one component of a path is a name Windows will not give you."""
    var length = name.byte_length()
    if length == 0:
        return False
    var bytes = name.as_bytes()

    if bytes[length - 1] == _DOT or bytes[length - 1] == _SPACE:
        # Windows strips trailing dots and spaces from a name on the way in, so
        # `file.txt.` and `file.txt ` both reach `file.txt` and nothing in the
        # lexical splitting sees them as anything but part of the name. The two
        # answers disagree, so the name is reserved rather than quietly
        # rewritten here, because rewriting it would make `split` and `join`
        # stop putting a path back together byte for byte.
        #
        # `.` and `..` end in a dot and are not this. They are the two names
        # every directory has.
        if bytes[length - 1] == _DOT:
            if length == 1:
                return False
            if length == 2 and bytes[0] == _DOT:
                return False
        return True

    for i in range(length):
        if _is_reserved_character(bytes[i]):
            return True

    # The device check is on the name with its extension taken off, and with
    # the spaces before the dot taken off as well, so `nul.txt` and `nul .txt`
    # are both the null device.
    var stem_end = 0
    while stem_end < length and bytes[stem_end] != _DOT:
        stem_end += 1
    while stem_end > 0 and bytes[stem_end - 1] == _SPACE:
        stem_end -= 1
    return _is_device_stem(name[byte=:stem_end])


def _is_reserved(path: StringSlice) -> Bool:
    """Whether Windows reserves any name in `path`.

    A program that builds a file name out of text somebody else supplied can be
    talked into opening a device instead of a file, and there is nothing to
    notice afterwards because the open succeeds and reads and writes work. So
    this is a check to run before creating a file, not a way to explain a
    failure after one.

    The drive comes off first, because a drive is not a name and the colon in
    `C:` would otherwise look like the colon that opens a data stream. Every
    component after that is checked, not just the last one, since a reserved
    name anywhere in the path is reserved.

    Says nothing about whether the path exists, or about limits the file system
    imposes rather than the name parser. It is also only the rules as they are
    written down: a name this says nothing about can still be refused.
    """
    var rest = _splitroot(path)[2]
    var length = rest.byte_length()
    var bytes = rest.as_bytes()

    var start = 0
    for i in range(length + 1):
        if i == length or _is_sep(bytes[i]):
            if _is_reserved_name(rest[byte=start:i]):
                return True
            start = i + 1
    return False


def _expanduser(path: StringSlice) -> String:
    """Expands a leading `~` from the environment rather than a user database.

    Windows has no password database to look a user up in, so a home directory
    comes out of `USERPROFILE`, or out of `HOMEDRIVE` and `HOMEPATH` together
    when that is not set. Both are set by the system on any machine somebody is
    logged in to, and neither is guaranteed, which is why the path comes back
    untouched when neither is there.

    `~other` is guesswork on every platform and more so here. Windows profile
    directories usually sit side by side under one parent and are named after
    the user they belong to, so the guess is to take the current user's home,
    back up one level and put the other name on the end. When the current
    user's own home does not fit that shape the guess has nothing to stand on,
    and the path comes back unexpanded rather than pointing at a directory that
    was never there.
    """
    if not path.startswith("~"):
        return String(path)

    # Where the user name ends: the first separator, or the end of the string.
    var name_end = _find_sep(path, 1)
    if name_end < 0:
        name_end = path.byte_length()

    var home = getenv("USERPROFILE")
    if not home:
        var relative_home = getenv("HOMEPATH")
        if not relative_home:
            return String(path)
        home = _join(getenv("HOMEDRIVE"), relative_home)

    if name_end != 1:
        var wanted = String(path[byte=1:name_end])
        if wanted != getenv("USERNAME"):
            if getenv("USERNAME") != _split(home)[1]:
                return String(path)
            home = _join(_split(home)[0], wanted)

    home += path[byte=name_end:]
    return home^
