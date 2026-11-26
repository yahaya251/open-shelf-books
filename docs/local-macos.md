# Preserved local Mac runtime

[Project overview](../README.md) · [Environment setup](setup.md)

The existing Mac installation can stay independent of Docker Desktop. The project uses its own schema through an adapter to the original Lima `db` VM and `wia2001-oracle` container. Other schemas in that container remain separate.

## Compatible local layout

```text
project/
  scripts/
  db/
  .local-macos/                  ignored by Git
    .vm/
      _config/
      db/
        lima.yaml
        disk
    10_Oracle_Runtime/
      lima/bin/limactl
      db.yaml
      downloads/
      cache/
```

The original installation may remain at its external location until it can be safely shut down. Startup does not move or repair it. To use a healthy preserved installation in this layout, explicitly select `--backend lima` or configure `.local/runtime.json` as described in the environment guide. Set `OPEN_SHELF_RUNTIME_ROOT` when the local installation is elsewhere. The new project synchronizes its own `db/` and `tests/` directly to the container and does not depend on the former coursework `Project_Deliverables/03_Oracle` alias.

## Migration of an existing installation

This is a maintenance procedure, not a step performed by startup. Stop the VM through its original controller before renaming its files. Confirm it is stopped using the original `limactl` outside a restrictive execution sandbox. The original VM disk is 38,654,705,664 bytes; use a same-filesystem directory rename to preserve its sparse disk and avoid a second copy.

Move the original `.vm/` and `10_Oracle_Runtime/` as siblings under `.local-macos/`. Retain the full original directories, including base disks, configuration, SSH identity files, and container data. Do not create a replacement VM and do not run a reset.

The inspected `lima.yaml` uses a relative Ubuntu image location and no host mounts. Its generated `ssh.config` contains absolute paths to the old identity and control socket. Lima must be started with the new `LIMA_HOME`; a fresh start is expected to regenerate those generated connection settings. This expectation still requires a real start-and-connect check after relocation.

```sh
export LIMA_HOME="$PWD/.local-macos/.vm"
./.local-macos/10_Oracle_Runtime/lima/bin/limactl list db
./.local-macos/10_Oracle_Runtime/lima/bin/limactl start --tty=false db
```

After explicitly configuring the healthy preserved backend, run `run_macos.command` and check `OPEN_SHELF_START=PASS`. Confirm the existing schemas and baseline records before removing any temporary compatibility path. The project does not expose the Oracle listener to the host.

If startup fails, stop work and retain the disk. Review generated connection paths and the instance status. A restrictive sandbox may report `Broken` because it cannot read the host boot-session ID; this does not by itself establish a damaged VM. Restore the original directories to their previous location, or retain a temporary compatibility link to the preserved installation while resolving the new path. Never delete or reinitialize the disk as an automatic repair.

The old controller's `vm-start`, `db-start`, `status`, and `check` derive their local runtime paths from their own directory. Its older `sync-sql` still expects the coursework source tree and is not used by the new project. Use the project's Python launcher for new SQL operations.

Lima's documented home layout and macOS socket-path limit are described in [internal data structure](https://lima-vm.io/docs/dev/internals/) and [environment variables](https://lima-vm.io/docs/config/environment-variables/). Set `LIMA_HOME` consistently for every command. Keep its full instance path short enough for macOS Unix sockets.

## Stop the preserved environment

Closing the starter window leaves the database running. Because this VM may contain multiple schemas, stop it only when those users have finished:

```sh
export LIMA_HOME="$PWD/.local-macos/.vm"
./.local-macos/10_Oracle_Runtime/lima/bin/limactl stop db
```

The backend-aware `python3 scripts/start_project.py --stop` deliberately refuses the shared original environment. Its data stays on the VM disk.
