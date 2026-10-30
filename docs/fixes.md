# Build fixes

The source version is `v0.2.14`. Docker supplies the toolchain and dependencies for the build.

| Error | Change | File |
|---|---|---|
| The Docker build context has no `.git`, so `git submodule update` cannot fetch `submodules/brotli`. | The build stage clones `google/brotli` at the submodule commit `5805f99a`. | `Dockerfile` |
| `go build` stamps `GitRevision` and `WalgVersion` from `git`, which the build context lacks. | The build passes `d372cbd` and `v0.2.14` as build arguments. | `Dockerfile` |
| `golang:1.11-stretch` apt sources return 404. | The build stage points apt at `archive.debian.org`. | `Dockerfile` |

## Nucloud commands

| Setting | Reason | File |
|---|---|---|
| Nucloud targets use an isolated Makefile branch | `make build` and `make deploy` use Docker without invoking native host prerequisites; other explicit targets retain their native rules. | `Makefile` |
