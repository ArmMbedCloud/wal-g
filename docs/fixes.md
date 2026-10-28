# Build fixes

Source is unchanged from `v0.2.14`. The build differs from the upstream `Makefile` `deps` and `pg_build` targets as follows.

| Error | Change | File |
|---|---|---|
| The Docker build context has no `.git`, so `git submodule update` cannot fetch `submodules/brotli`. | The build stage clones `google/brotli` at the submodule commit `5805f99a`. | `Dockerfile` |
| `go build` stamps `GitRevision` and `WalgVersion` from `git`, which the build context lacks. | The build passes `d372cbd` and `v0.2.14` as build arguments. | `Dockerfile` |
| `golang:1.11-stretch` apt sources return 404. | The build stage points apt at `archive.debian.org`. | `Dockerfile` |

The rebuilt binary reports `wal-g version v0.2.14 d372cbd ... PostgreSQL`, as in `platform/stolon:0.16.0-pg12.8-5`.
