+++
title = 'Home Server Gitops Lite on Nothing but Github and Docker'
date = '2026-04-22T01:46:47.155Z'
draft = false
tags = ["github","docker","productivity","tooling"]
+++

*Originally published on [DEV Community](https://dev.to/nckslvrmn/home-server-gitops-lite-on-nothing-but-github-and-docker-19lo).*

I run a decent little stack of services out of my house. Whisper (an end-to-end encrypted secret sharing app), bar_keep, archivist, a few other side projects, plus the base infra that ties them together: Traefik, shared networks, a handful of private stacks. For a while every deploy meant SSHing into the server, and I was pretty tired of it.

What I actually wanted was something like the popular GitOps tools a lot of folks run on top of Kubernetes. Push code, get a deploy, done. No shell, no secrets on disk, no kubectl. But I'm not running Kubernetes at home and I wasn't about to install it just for this, so I took a different route.

I ended up gluing together three things that basically give me the same experience those tools give you, just lighter and totally free on top of GitHub. It's all stuff I already run, the control plane is GitHub itself, and honestly I think it's a pretty fun pattern that other folks with home servers might like.

## The three pieces

There are three parts to this, and two of them are tools I built:

1. **[github-multi-runner](https://github.com/nckslvrmn/github-multi-runner)** — a single container that runs a bunch of GitHub Actions self-hosted runners, configured via a JSON file.
2. **[docker-compose-deploy](https://github.com/nckslvrmn/docker-compose-deploy)** — a composite GitHub Action that runs `docker compose up` on a self-hosted runner.
3. **The pattern:** a private "base infra" repo that owns networks, volumes, and shared stacks, plus each service repo owning its own real `compose.yml` that is both the deployment config and a working example for anyone reading the repo.

The runner container is the thing that turns "my home server" into "a GitHub Actions target." The action is the thing that actually deploys. The pattern is what ties it all together so I never have to touch a terminal to ship.

## github-multi-runner: one container, many runners

The official `ghcr.io/actions/actions-runner` image is designed around one runner per container. Which is fine, but I've got a bunch of repos (public and private) plus an org, and spinning up 10 containers just to attach to 10 scopes feels silly. I also wanted to be able to add and remove runners without bouncing anything else.

So github-multi-runner is just a bash entrypoint and a JSON file mounted into the official image. No custom image to build and maintain. The JSON looks like this:

```json
{
  "runners": [
    { "name": "my-org", "scope": "org", "target": "my-github-org" },
    { "name": "my-repo", "scope": "repo", "target": "myuser/my-repo" },
    { "name": "whisper", "scope": "repo", "target": "nckslvrmn/whisper" }
  ]
}
```

The entrypoint watches that file. If you add a runner, it registers and starts it. If you change one, it gracefully deregisters and re-registers just that one. If you remove a runner, it drains it. Unrelated runners are never touched. It also handles docker socket access automatically (detects the GID and adds the runner user to a matching group), so workflows that run `docker compose` just work.

A few things I cared about while building it: graceful drains so nothing gets yanked mid-job, persistent registrations across container restarts so there's no deregister/re-register thrash, and per-runner log files so debugging is just a `tail -F` away.

The whole thing is a single bash script because bash is what ships in the runner image and I didn't want another dependency.

The deploy on the host side is just a compose file with the official runner image, the entrypoint mounted in, the JSON config mounted in, the docker socket mounted in, and a `GITHUB_TOKEN` in the environment. That's it.

## docker-compose-deploy: the dumbest possible deploy action

This one is even simpler. It's a composite GitHub Action whose entire job is:

```yaml
- uses: docker/setup-compose-action@v2
- shell: bash
  run: docker compose -f "${{ inputs.file }}" up -d --pull always --remove-orphans
```

That's really it. It takes a file path and optional args and runs `docker compose up`. It's not magic. The magic is *where* it runs, which is on a self-hosted runner on my server, which means `docker compose up` happens on the actual deploy target.

Because it's a normal GitHub Action, I get all the things that come with that for free:

- Secrets from GitHub's encrypted secret store get injected as env vars on the step, and `docker compose` substitutes them into the compose file at runtime. Secrets never land in the compose file or on disk.
- The workflow log is the deploy log.
- If the compose file is bad, the workflow fails and I get an email.
- `workflow_dispatch` gives me a big green "deploy" button in the GitHub UI for manual deploys.

## The pattern: real compose files in service repos

Here's the part I think is actually the coolest bit. It's not a tool, it's just a convention.

Every service repo has a real `compose.yml` in the root. Not an example, not a template. The literal file that gets used in production. For Whisper, it looks roughly like this:

```yaml
services:
  whisper:
    image: ghcr.io/nckslvrmn/whisper:${WHISPER_VERSION:-latest}
    environment:
      - S3_BUCKET=${S3_BUCKET}
      - DYNAMO_TABLE=${DYNAMO_TABLE}
    volumes:
      - /home/nsilverman/.aws:/root/.aws/:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.whisper.rule=Host(`whisper.slvr.io`)"
      - "traefik.http.routers.whisper.entrypoints=websecure"
    networks:
      - traefik

networks:
  traefik:
    external: true
```

Anyone cloning the repo to self-host Whisper gets a totally usable compose file to start from. Someone reading the repo to understand how the thing is deployed gets the literal answer. And I get to use the same file to deploy my own instance. One file, three audiences, no drift.

The base infra that this compose file depends on (the `traefik` network, the Traefik container itself, shared volumes, private stacks that don't belong in public repos) lives in a separate private repo. That repo has its own compose file and its own deploy workflow. Everything connects via external networks, which means each service repo and the base infra repo all deploy fully independently.

## Putting it all together: Whisper as an example

Whisper's deploy workflow has two jobs. The first runs in GitHub Actions' default runner environment and builds the Docker image and pushes it to GHCR. The second runs on `[self-hosted]` and does the actual deploy:

```yaml
deploy:
  needs: push-whisper-image
  runs-on: [self-hosted]
  steps:
    - uses: actions/checkout@v5
    - uses: nckslvrmn/docker-compose-deploy@main
      with:
        file: compose.yml
      env:
        S3_BUCKET: ${{ secrets.S3_BUCKET }}
        DYNAMO_TABLE: ${{ secrets.DYNAMO_TABLE }}
        WHISPER_VERSION: ${{ github.ref_name }}
```

That `runs-on: [self-hosted]` is the whole trick. It tells GitHub to route the job to one of my runners, which are running inside my multi-runner container on my home server. The action checks out the repo, runs `docker compose up` with `compose.yml` and the version tag from the release, and because compose does an image pull with `--pull always`, the new version lands. Traefik picks up the label changes automatically. Old container goes down, new one comes up, no downtime.

When I cut a new tagged release on GitHub, the whole chain runs:

1. Release published.
2. Image builds in GitHub Actions' default runner environment and gets pushed to GHCR.
3. Deploy job runs on my home server, pulls the new image, runs compose.
4. Profit.

There's also a `workflow_dispatch` variant for manual deploys where I can pass a version string in the UI. Super handy for rolling back.

## Why I like this

A few reasons:

- **No SSH, no kubectl, no shell.** The entire deployment surface is a GitHub Action workflow file. If I want to deploy something new, I write a compose file and a workflow. If I want to roll back, I just rerun the deploy action with the previous version tag.
- **No control plane to run.** The popular GitOps tools need a Kubernetes cluster, a bunch of CRDs, and a UI server to actually host them. This setup needs a container and a JSON file, and GitHub is the control plane.
- **Secrets are already solved.** GitHub already has an encrypted secret store with fine-grained access controls. I don't need Vault for a home setup. I just put secrets in the repo's secret settings and reference them in the workflow.
- **The compose file is the source of truth *and* a working example.** Anyone reading the repo can see exactly how the thing is deployed. There's no "well the real config is in some private ops repo" split.
- **Each repo deploys on its own.** No monorepo, no shared deploy pipeline, no coordination. The only shared thing is the external Traefik network and the base infra repo that owns it.
- **It's fully GitOps-ish.** The state of my server is described by the compose files in my repos. If I nuked the server and restored the base infra repo, then re-ran every service workflow, everything would come back up in a known state.

## Tradeoffs, because there are always tradeoffs

I'm not trying to pretend this is a full-blown GitOps platform. A few things it doesn't do:

- **Self-hosted runners on public repos are a real security concern, but it can be done safely.** Out of the box, anyone can open a PR and execute code on your host. You can absolutely run this setup on public repos if you're careful about what triggers the self-hosted job. I only gate the deploy workflow on releases being cut, which can only be done by repo owners, so random PRs can't touch the host. For an extra layer you can also use GitHub environment protection rules to require approval before a self-hosted job runs. This makes it pretty safe, but it's still worth being careful about.
- **No drift detection.** If I SSH in and manually change something (which, with this setup, I basically never do anymore), nothing notices. A real continuously-reconciling controller would flag it. Here, the next deploy would just overwrite the drift.
- **No multi-node.** This is one home server. If I wanted HA across multiple machines I'd need something heavier. For a homelab this is fine.
- **Still technically pull based via `docker compose up`.** Images are pulled from GHCR, but the trigger for the deploy is a workflow, not a continuously-reconciling controller. If GHCR has a new image and no workflow ran, nothing happens. You can bolt `on: registry_package` onto the workflow to trigger on image publish, which I do in a couple spots.

None of these have bitten me in practice for a home setup, but they're worth knowing if you want to copy this.

## Try it

If any of this sounds useful:

- **[github-multi-runner](https://github.com/nckslvrmn/github-multi-runner)** — drop in the compose file, point at a JSON config, set a PAT, done.
- **[docker-compose-deploy](https://github.com/nckslvrmn/docker-compose-deploy)** — add it as a step in any workflow that targets a self-hosted runner.
- **[whisper](https://github.com/nckslvrmn/whisper)** — has the full worked example of the release → build → deploy chain in `.github/workflows/docker.yml`.

The whole thing clicks together in an afternoon. If you've got a home server and you've been wishing for a lighter-weight GitOps story, I think this is a pretty good one.
