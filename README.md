# Drupal IDE

Full featured IDE for Drupal based on VSCode and Docker Desktop. Drupal and Apache run in it's own container. MySQL runs in a separate container. Project management tools, text editor, debugger, shell, version control all in one integrated environment.

![Drupal IDE in action](https://i.imgur.com/iXh5SiU.png)

##### :warning: Do not clone this repository. Add it as a submodule.  See [Installation](#installation) below.

### Contents

1. [Requirements](#requirements)
1. [Installation](#installation)


### Requirements
:ballot_box_with_check:  Install [Docker Desktop](https://www.docker.com/products/docker-desktop). Note that Docker Desktop is not supported in all versions of Windows unfortunately.

:ballot_box_with_check: Install [VSCode](https://code.visualstudio.com/).

:ballot_box_with_check: From the VSCode extension manager, install the [Remote Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension.

:ballot_box_with_check: Additionally, you may need to configure the disk your project directory lives on as a Docker Desktop shared drive. If some shell (eg PowerShell) code appears when you enable a share, it is important to run that code in a terminal.

:warning: This software is brand new and is currently only tested in Windows 10 Pro. It should run on MacOS but this is untested. Feedback welcome via issue queue or pull request. More complete documentation still under construction.


### Installation

In your project directory, run the following command:

```bash
    $ git submodule add https://github.com/dfletcher/drupal-ide .devcontainer
```

This will add a .devcontainer subdirectory which VSCode will recognize. Before you open it, configure by copying some files from .devcontainer into your project root:

```bash
    $ cp .devcontainer/.env.drupal-ide.example .env.drupal-ide
    $ cp -r .devcontainer/.vscode .vscode
```
Open .env.drupal-ide locally and configure your site name and any modules that you want enabled at install time.

The .vscode subdirectory contains X-Debug configuration for debugging. You may have to adjust the paths.