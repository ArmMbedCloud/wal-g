# Building and deploying this repo

This repo builds the images listed in `nucloud.env` on its `nucloud`
branch. The branch starts at the commit of the tag production runs;
`archive/<tag>` marks that commit and records the production image digest.
The rules are in [nucloud standards](https://github.com/IzumaNetworks/nucloud/blob/main/docs/standards.md),
the stages in [nucloud setup](https://github.com/IzumaNetworks/nucloud/blob/main/docs/setup.md).

## Build

```sh
make images              # what this repo builds and the tags
make image               # build every image inside Docker; nothing installed locally
make image ONLY=<name>   # one image
```

Builds run entirely in Docker for `linux/amd64` on the current Docker
context. To build on a remote Docker host, select it with
`docker context use <name>` or set `DOCKER_CONTEXT` in your shell. Build
secrets named in `nucloud.env` (`SECRETS`) come from environment variables
and reach the build as BuildKit secrets, never as layers. A repo with
`SSH=1` reads private git dependencies through your ssh agent.

## Deploy to a k3s stage

```sh
make deploy MACHINE=k3s-cypress  # build, import into the stage's VM, helm upgrade each release with the new tags
```

`deploy` uses the stage definitions in the `izuma-dm-platform` checkout
(`~/workspace/izuma/izuma-dm-platform` on branch `k3s`); set
`NUCLOUD_PLATFORM` if that checkout is elsewhere. Each release keeps its
current values; only this repo's image tags change. The release each
image goes to is the last field of its `nucloud.env` entry.

## Tags

A local build is tagged `<upstream>-nucloud.dev.<commit>`, plus a hash of
any uncommitted changes, so each changed tree deploys under a new tag and
its pods restart. CI tags `<upstream>-nucloud.<run number>`. `make push`
pushes only CI tags, so a rebuild can never replace an image a cluster
runs.

## CI

`.github/workflows/nucloud.yml` runs only when started by hand:
`gh workflow run nucloud -R <org/repo> --ref nucloud`. It builds, tests,
smoke-checks and writes SBOMs, pushes the images to GHCR from `nucloud`,
then removes its images and build cache from the runner.

## Changes from upstream

`docs/fixes.md` lists every change the `nucloud` branch makes to build
files or source, and why.
