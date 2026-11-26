# Sharing the source

[Project overview](../README.md)

This directory contains English source, synthetic fixtures and project documentation. The original Git repository remains private until the owner chooses another visibility. A source export can omit the local runtime and initialize a fresh database on another computer.

Keep these machine-specific items out of Git and shared archives:

- `.local-macos/`: VM disks, SSH identity, cached downloads and original local credentials.
- `.local/`: ignored machine configuration.
- Environment files, passwords, private keys and unreviewed console captures.
- Generated run logs and Python caches.

The supplied `.gitignore` excludes these locations. Review an export's file list before publishing; a plain recursive copy of the whole working directory would still include ignored files. The intended shared files are `db`, `scripts`, `tests`, `queries`, `docs`, `demo`, the two starter files, README and repository configuration files.

The seed people and identifiers are synthetic. The optional scenario uses `example.invalid` addresses and rolls back its rows. Do not replace those fixtures with private records in an export.
