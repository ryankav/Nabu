# Nabu
Multimedia repository

## Development Setup

This project uses [Nix flakes](https://nixos.wiki/wiki/Flakes) to manage the development environment.

### Prerequisites

1. Install Nix with flakes enabled: https://nixos.org/download
2. Install direnv (optional but recommended): https://direnv.net/

### Getting Started

**With direnv (recommended):**
```bash
direnv allow
```
The Zig toolchain will automatically activate when you enter the directory.

**Without direnv:**
```bash
nix develop
```

### Updating Zig

To update to the latest nightly Zig build:
```bash
nix flake update
```
