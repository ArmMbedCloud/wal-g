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

Builds run entirely in Docker for `linux/amd64`. To build on a remote
Docker host, set `DOCKER_CONTEXT` in your shell. Build secrets named in
`nucloud.env` (`SECRETS`) come from environment variables and reach the
build as BuildKit secrets, never as layers.

## Deploy to a k3s stage

```sh
make deploy ENV=k3s-dev  # build, import into the VM, helm upgrade each release with the new tags
```

`deploy` uses the stage definitions in `izuma-dm-platform-k3s`; set
`NUCLOUD_PLATFORM` if that checkout is elsewhere. Each release keeps its
current values; only this repo's image tags change. The release each
image goes to is the last field of its `nucloud.env` entry.

## Tags

Every image is tagged `<upstream>-nucloud.<n>`. `make push` refuses any
other tag, so a rebuild can never replace an image a cluster runs.

## Changes from upstream

`docs/fixes.md` lists every change the `nucloud` branch makes to build
files or source, and why.
