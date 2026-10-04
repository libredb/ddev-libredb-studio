[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/libredb/ddev-libredb-studio/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/libredb/ddev-libredb-studio/actions/workflows/tests.yml?query=branch%3Amain)
[![last commit](https://img.shields.io/github/last-commit/libredb/ddev-libredb-studio)](https://github.com/libredb/ddev-libredb-studio/commits)
[![release](https://img.shields.io/github/v/release/libredb/ddev-libredb-studio)](https://github.com/libredb/ddev-libredb-studio/releases/latest)

# DDEV Libredb Studio

## Overview

This add-on integrates Libredb Studio into your [DDEV](https://ddev.com/) project.

## Installation

```bash
ddev add-on get libredb/ddev-libredb-studio
ddev restart
```

After installation, make sure to commit the `.ddev` directory to version control.

## Usage

| Command | Description |
| ------- | ----------- |
| `ddev describe` | View service status and used ports for Libredb Studio |
| `ddev logs -s libredb-studio` | Check Libredb Studio logs |

## Advanced Customization

To change the Docker image:

```bash
ddev dotenv set .ddev/.env.libredb-studio --libredb-studio-docker-image="ddev/ddev-utilities:latest"
ddev add-on get libredb/ddev-libredb-studio
ddev restart
```

Make sure to commit the `.ddev/.env.libredb-studio` file to version control.

All customization options (use with caution):

| Variable | Flag | Default |
| -------- | ---- | ------- |
| `LIBREDB_STUDIO_DOCKER_IMAGE` | `--libredb-studio-docker-image` | `ddev/ddev-utilities:latest` |

## Credits

**Contributed and maintained by [@libredb](https://github.com/libredb)**
