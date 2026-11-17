# flox-activate-action

Load a [Flox](https://flox.dev) environment into a GitHub Actions job. It works like the `setup-*` actions: `use` it once, and every following step in the job has the environment's packages on `PATH` and its variables set. That includes steps that `use:` third-party actions.

This action is modeled on [nicknovitski/nix-develop](https://github.com/nicknovitski/nix-develop), which does the same thing for `nix develop`.

## Usage

Install Flox first, for example with [`flox/install-flox-action`](https://github.com/flox/install-flox-action):

```yaml
steps:
  - uses: actions/checkout@v7
  - uses: flox/install-flox-action@v2
  - uses: devbytes-cloud/flox-activate-action@v1
  - run: go test ./...        # go comes from .flox/
  - uses: goreleaser/goreleaser-action@v7
    with:
      version-file: .tool-versions
      args: release --clean
```

### Inputs

| Input         | Description                                                                                                                                                    | Default |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `dir`         | Directory containing the `.flox/` directory to activate. Defaults to the working directory.                                                                    |         |
| `environment` | FloxHub environment to activate (`owner/name`), instead of a local one.                                                                                        |         |
| `trust`       | Pass `--trust`, so the hooks of a FloxHub environment that isn't trusted yet can run.                    | `false` |
| `arguments`   | Extra arguments for `flox activate`, split on whitespace.                                                                                                      |         |

```yaml
  - uses: devbytes-cloud/flox-activate-action@v1
    with:
      dir: tools/ci
```

```yaml
  - uses: devbytes-cloud/flox-activate-action@v1
    with:
      environment: my-org/ci-tools
      trust: true
```

## Why?

Without this action, each step has to opt into the environment on its own:

```yaml
      - run: flox activate -- go test ./...
      - run: flox activate -- golangci-lint run
```

or uses the environment as the step's shell:

```yaml
      - run: go test ./...
        shell: flox activate -- bash -e {0}
```

Both are repetitive, and neither reaches steps that `use:` other actions. For example, `actions/setup-node` with `cache: pnpm` needs `pnpm` on `PATH`, and only an environment exported to the whole job puts it there. [`flox/activate-action`](https://github.com/flox/activate-action) has the same limit: it runs one command inside the environment.

## How it works

1. Runs `flox activate [args] -- bash -c 'printf "\0"; env -0'`. Anything the `on-activate` hook prints to stdout comes before the NUL, so it is printed to the log and never parsed as a variable. If `flox activate` fails, the step fails.
2. Each variable whose value differs from the step's current environment is appended to [`$GITHUB_ENV`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#setting-an-environment-variable). The heredoc form with a random delimiter is used, so multi-line values are safe.
3. Each `PATH` entry that exists and isn't already on the runner's `PATH` is appended to [`$GITHUB_PATH`](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-system-path), last to first. Appending prepends, so writing in reverse keeps the environment's order.

### Caveats

- Only what `flox activate` puts in the environment is exported. That covers `[install]`, `[vars]`, and variables `export`ed by `hook.on-activate`. Shell functions and aliases from `[profile]` scripts can't cross step boundaries.
- `[services]` aren't kept running. The activation exits as soon as its environment has been captured. Start services in the step that needs them, for example with `flox activate --start-services -- <command>`.

## Development

This repository has its own Flox environment with `shellcheck` and `shfmt`, and CI loads it with the action itself.

```sh
flox activate
shellcheck flox-activate-gha.sh
shfmt -d flox-activate-gha.sh
```

The script also runs locally. With `GITHUB_ENV` and `GITHUB_PATH` unset, whatever it would export goes to stderr:

```sh
INPUT_DIR=test-env ./flox-activate-gha.sh
```

`test-env/` is the fixture environment that the CI tests run against.