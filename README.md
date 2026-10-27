# Command Comparer

A searchable side-by-side table of the commands [Flisk](https://flisk.sh), Terraform, Docker Compose, Tilt and Skaffold give you for the same everyday tasks. Flisk is always the first column. Every cell has a link to the docs behind it.

Live site: <https://flisk-sh.github.io/command-comparer/>

Flisk runs a multi-service app on your computer. It does not deploy and it does not write Kubernetes manifests. Terraform provisions real infrastructure, so the Terraform cells show the nearest command and say when the job is different. A cell that says "No equivalent" means the tool has no command for the task. We do not invent one.

The layout follows [CloudComparer](https://github.com/ilyas-it83/CloudComparer): a Jekyll site that renders one YAML data file into a table, published on GitHub Pages.

## What is in the repo

| Path | What it is |
| --- | --- |
| `_data/commands.yml` | All the data: tools, task types and one cell per task and tool |
| `index.html` | The page. Loops over the data and writes the table |
| `_includes/cell.html`, `_includes/cmd.html` | How one cell and one command render |
| `_layouts/default.html` | Page shell, fonts, theme script |
| `assets/css/style.css` | Light and dark themes, table, phone card layout |
| `assets/js/compare.js` | Search, filters, theme toggle, copy buttons |
| `scripts/check-data.rb` | Checks the data (see below) |
| `.github/workflows/site.yml` | Checks, builds and deploys to GitHub Pages |
| `.github/workflows/links.yml` | Weekly check that every source URL still loads |

## Data format

`_data/commands.yml` has four top-level keys:

- `checked`: the date and Flisk version the Flisk commands were last checked against.
- `tools`: the columns, in display order. Flisk first. Each has `id`, `name`, `site`, `docs`, `what`, `scope` and `why`.
- `categories`: task types used by the filter chips.
- `tasks`: the rows. Each has `id`, `category`, `task`, `keywords` and `cells`.

A cell is keyed by tool id:

```yaml
- id: restart
  category: run
  task: Restart one service
  keywords: reload rebuild trigger
  cells:
    flisk:
      cmd: flisk restart api
      note: Triggers the service's update in the running stack.
      source: https://github.com/flisk-sh/flisk/blob/main/cli/src/commands/restart.ts
    skaffold:
      status: none
      note: No per-service restart. skaffold dev redeploys when files change.
      source: https://skaffold.dev/docs/references/cli/
```

| Field | Meaning |
| --- | --- |
| `cmd` | The command, as a string or a list of strings. Leave it out for `none` and `na`. |
| `status` | `match` (default) does the same job. `partial` is the closest command but a different job. `none` has no equivalent. `na` is not needed for this tool. |
| `note` | One or two plain sentences. Required for `partial`, `none` and `na`. |
| `source` | An `https` URL to the official docs or source. Required on every cell, including `none`. |

Rules for the data:

- A Flisk command must be a real one. Check it with `flisk <command> --help`.
- Another tool's command must come from that tool's official docs, linked in `source`.
- If a tool has no command for the task, write `status: none` and say what you do instead. Do not fill the cell with a guess.
- Public numbers about Flisk must use the wording in Flisk's [claims registry](https://github.com/flisk-sh/flisk/blob/main/docs/claims.md). This table does not use any.

## Check the data

Needs Ruby 2.6 or newer and nothing else.

```bash
ruby scripts/check-data.rb            # structure: a cell per task and tool, every cell has an https source
ruby scripts/check-data.rb --flisk    # also run each Flisk command's subcommand and flags against the installed flisk
ruby scripts/check-data.rb --links    # also fetch every source URL and expect a 2xx
```

The first form runs on every pull request. `--links` runs weekly. `--flisk` needs `flisk` on your `PATH`, so run it yourself after editing a Flisk cell.

## Build and preview

With Ruby 3.x and Bundler:

```bash
bundle install
bundle exec jekyll serve
```

Open <http://localhost:4000/command-comparer/>.

With Docker only:

```bash
docker run --rm -p 4000:4000 -v "$PWD":/site -w /site ruby:3.3-slim \
  bash -c "bundle install && bundle exec jekyll serve --host 0.0.0.0"
```

## Deploy

Pushing to `main` runs `.github/workflows/site.yml`. It checks the data, builds with Jekyll and deploys with the official GitHub Pages actions. Pages is set to deploy from GitHub Actions (Settings, Pages, Source). Unlike CloudComparer, no personal access token or `gh-pages` branch is needed.

If you move the site to a custom domain or a root URL, set `url` and `baseurl` in `_config.yml`.

## Licence

MIT. See [LICENSE](LICENSE).
