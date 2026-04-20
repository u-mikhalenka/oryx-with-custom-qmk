# Oryx with custom QMK

This repository allows combining the convenience of [Oryx’s](https://www.zsa.io/oryx) graphical layout editing with the power of [QMK](https://qmk.fm), allowing you to customize your Oryx layout with advanced QMK features like Achordion and Repeat Key, while automating firmware builds through GitHub Actions.

For a detailed guide, check out the full [blog post here](https://blog.zsa.io/oryx-custom-qmk-features).

## How it works

Each time you run the GitHub Action, the workflow will:
1. Fetch the latest changes made in Oryx.
2. Merge them with any QMK features you've added in the source code.
3. Build the firmware, incorporating modifications from both Oryx and your custom source code.

## How to use

1. Fork this repository (be sure to **uncheck the "Copy the main branch only" option**).
2. To initialize the repository with your layout:
   - Go to the **Actions** tab.
   - Select **Fetch and build layout**.
   - Click **Run workflow**.
   - Input your layout ID and keyboard type (your layout must be public in Oryx), then run the workflow.
   - (To avoid having to input values each time, you can modify the default values at the top of the `.github/workflows/fetch-and-build-layout.yml` file).
3. A folder containing your layout will be generated at the root of the repository.
4. You can now add your custom QMK features to this folder:
   - Edit `config.h`, `keymap.c` and `rules.mk` according to the [QMK documentation](https://github.com/qmk/qmk_firmware/tree/master/docs/features).
   - Commit and push to the **main** branch.
5. You can continue editing your layout through Oryx:
   - Make your changes in Oryx. 
   - Optionally, add a description of your changes in the **Some notes about what you changed** field; if provided, this will be used as commit message.
   - Confirm changes by clicking the **Compile this layout** button.
6. To build the firmware (including both Oryx and code modifications), rerun the GitHub Action. The firmware will be available for download in the action’s artifacts.
7. Flash your downloaded firmware using [Keymapp](https://www.zsa.io/flash#flash-keymap).
8. Enjoy!

## Build locally

You can reproduce the GitHub Action locally with [build-local.sh](build-local.sh).

Requirements:
- `git`
- `curl`
- `jq`
- `unzip`

Host build requirements on macOS:
- `make`
- `qmk` installed, for example via `brew install qmk/qmk/qmk`

Docker build requirements:
- `docker`

Example:

```bash
./build-local.sh --layout-id X3nL6 --geometry voyager
```

Use Docker explicitly if you want the previous containerized build path:

```bash
./build-local.sh --layout-id X3nL6 --geometry voyager --use-docker
```

The script will:
1. Fetch the latest Oryx export for the requested layout.
2. Reuse cached local `main` and `oryx` clones under `.local-build/cache` and merge them the same way as the workflow.
3. Check out the matching QMK firmware branch in the submodule.
4. Build the firmware on the local host by default on macOS, or in Docker when `--use-docker` is passed.
5. Copy the merged layout and compiled firmware into `.local-build/`.

Use `--keep-temp` if you want to inspect the per-run downloaded layout files after a failed merge or build.

## Oryx Chrome extension

To make building even easier, [@nivekmai](https://github.com/nivekmai) created an [Oryx Chrome extension](https://chromewebstore.google.com/detail/oryx-extension/bocjciklgnhkejkdfilcikhjfbmbcjal) to be able to trigger the GitHub Actions from inside Oryx itself.
