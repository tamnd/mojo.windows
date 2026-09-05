# Downloading and running a release

What is in the archive, what Windows says about it the first time you run it, and how to check you got what we published.

## What you get

`mojo-windows-runtime-<version>-x86_64.zip` from the [releases page](https://github.com/tamnd/mojo.windows/releases).

```
bin\hello.exe                 a Mojo program, cross compiled
bin\*.dll                     the runtime
lib\*.lib                     the import libraries
example\hello.mojo            the source bin\hello.exe was built from
LICENSE NOTICE README.txt upstream.lock
```

There is no `mojo.exe`. The compiler runs on Linux and cross compiles, so what you can do with the archive is run a Mojo program on Windows and link against the runtime, and what you cannot do is build one there. Native hosting is M6.

x64 only, Windows 10 version 1809 or later. No Visual C++ redistributable, because the C runtime is linked statically.

Keep the DLLs beside whatever loads them. Copy `bin\hello.exe` somewhere on its own and it will fail to start with `0xC0000135` and nothing on screen, which is Windows for a missing DLL rather than a broken binary.

## Check what you downloaded

Every release has a `SHA256SUMS-windows` next to the archives.

```powershell
Get-FileHash mojo-windows-runtime-0.4.2-x86_64.zip -Algorithm SHA256
```

Compare that against the line in `SHA256SUMS-windows`, or on a machine with the GNU tools use `sha256sum -c SHA256SUMS-windows`, which checks both archives at once.

The overlay archives in the same release carry a build provenance attestation and can be checked with `gh attestation verify`. The Windows archives cannot, and [docs/releasing.md](releasing.md) says why. So for the binaries the checksum is the whole of the assurance, which is worth knowing before you rely on it.

## Windows will warn about it, and here is exactly what happens

These binaries are unsigned and published by somebody Windows has never heard of. That is expected, it is not a symptom of a broken build, and it is not something you can make go away by rebuilding.

What triggers a warning is not the file itself, it is the mark of the web: an alternate data stream named `Zone.Identifier` that says the file came from the internet. Whether your copy has one depends on how you downloaded and unpacked it, and the difference is larger than it looks.

Downloading in a browser sets it on the zip. Downloading with `Invoke-WebRequest` or `curl` does not, so a scripted download produces files with no mark at all.

Unpacking with Explorer, the built in extract in File Explorer, copies the mark onto every file it writes, so `bin\hello.exe` ends up marked. Unpacking with `Expand-Archive` in PowerShell does not, so the same zip produces unmarked files. Both of those were checked on the machine rather than looked up.

```powershell
Get-Item bin\hello.exe -Stream *
```

If that lists a `Zone.Identifier` stream then the file is marked, and if it lists only `:$DATA` then it is not.

A marked executable started from Explorer, by double clicking it, is what raises the SmartScreen dialog: "Windows protected your PC", with the Run anyway button hidden behind More info. That is the reputation check, and it clears itself over time as more people download the same file. A marked executable started from a console, `cmd.exe` or PowerShell, runs without a dialog, because that check is part of the shell rather than part of loading the program.

`Unblock-File` removes the mark if you would rather clear it deliberately.

```powershell
Get-ChildItem -Recurse | Unblock-File
```

Do that after you have checked the SHA-256 and not before, because clearing the mark is the point at which you have decided you trust the file.

## Antivirus

Defender scanned a freshly downloaded and unpacked v0.4.2 on Windows 11 26H1, engine 1.1.26080.3, and found nothing. That is one machine on one signature version and it is not a promise about yours.

A false positive is a real possibility for what this project will eventually ship. A compiler that writes executable memory and then jumps into it sits close to the behavioural profile heuristics are built to catch, so the risk goes up rather than down when `mojo.exe` arrives. If Defender does quarantine something here, that is worth reporting: submit it to Microsoft at https://www.microsoft.com/en-us/wdsi/filesubmission, which is free and usually resolved in days, and open an issue here so the next person is not surprised by it.

## Why nothing is signed

A standard code signing certificate costs a few hundred a year and removes the unknown publisher wording, but SmartScreen reputation still builds with download volume, so the warnings largely persist anyway. An extended validation certificate grants reputation immediately, costs more and needs a hardware token. Neither is worth it for a project at this stage, and buying one would trade real money for a slightly better first impression rather than for any actual security.

Checksums and provenance are the substitute, and for verifying you got the file we published they are the stronger answer of the two.
