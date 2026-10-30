# Building and deploying this repo

This repo builds the images listed in `nucloud.env` on its `nucloud`
branch in `~/workspace/izuma/RECODE/CLOUD/<repo>`. The branch descends from
the archived production commit; `archive/<tag>` records its image digest.
Each checkout keeps its local `master` ref and has one worktree.
The rules are in [nucloud standards](https://github.com/IzumaNetworks/nucloud/blob/main/docs/standards.md),
the stages in [nucloud setup](https://github.com/IzumaNetworks/nucloud/blob/main/docs/setup.md).

## Build

```sh
export DOCKER_CONTEXT=echo
export NUCLOUD_PLATFORM="$HOME/workspace/izuma/izuma-dm-platform-k3s"
make images              # images and tags
make build               # build every image inside Docker
make build ONLY=<name>   # one image
```

Builds run entirely in Docker for `linux/amd64` on the current Docker
context. To build on a remote Docker host, select it with
`DOCKER_CONTEXT=<name>` in your shell. `make all` and `make image` also
build the images. Nucloud build and deploy targets run independently of
the repository's native host build prerequisites. Build
secrets named in `nucloud.env` (`SECRETS`) come from environment variables
and reach the build as BuildKit secrets, never as layers. A repo with
`SSH=1` reads private git dependencies through your ssh agent.

## Deploy to a k3s stage

```sh
make deploy MACHINE=k3s-trav
make deploy MACHINE=k3s-cypress
```

`deploy` uses the stage definitions in the `izuma-dm-platform` checkout
(`~/workspace/izuma/izuma-dm-platform` on branch `k3s`); set
`NUCLOUD_PLATFORM` if that checkout is elsewhere. Each release keeps its
current values and namespace; the upgrade sets this repo's image tags
and waits for its workloads across their namespaces. The release each
image goes to is the last field of its `nucloud.env` entry.
The commands above select the independent platform checkout containing
the merged charts and private kubeconfigs.

## Tags

A local build is tagged `<upstream>-nucloud.dev.<commit>`, plus a hash of
any uncommitted changes, so each changed tree deploys under a new tag and
its pods restart. CI tags `<upstream>-nucloud.<run number>`. `make push`
pushes only CI tags, so a rebuild can never replace an image a cluster
runs.

## CI

`.github/workflows/nucloud.yml` builds source changes on pull requests
into `nucloud` and pushes to `nucloud`. Changes confined to `docs/`,
README files, Markdown, `Makefile`, `Makefile.nucloud`,
`makehelp-nucloud.sh`, `.dockerignore` and the workflow file skip CI.
`Dockerfile`, `nucloud.env` and code changes trigger it.

Force a rebuild with `gh workflow run nucloud -R <org/repo> --ref nucloud`.
CI builds, tests, smoke-checks and writes SBOMs on the five-runner pool.
It pushes images to GHCR from `nucloud`, then removes its images and
build cache. Every runner service also runs its completion cleanup hook.

## Changes from upstream

`docs/fixes.md` lists every change the `nucloud` branch makes to build
files or source, and why.
