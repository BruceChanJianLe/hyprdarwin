# homebrew-hyprdarwin

Homebrew tap for [hyprdarwin](https://github.com/BruceChanJianLe/hyprdarwin), a Hyprland-inspired tiling window manager for macOS 26 on Apple Silicon.

This repository is written by hyprdarwin's release workflow: every `vX.Y.Z` release commits `Casks/hyprdarwin.rb` here. Change the cask in hyprdarwin's `packaging/homebrew/`, not here.

## Install

```sh
brew tap brucechanjianle/hyprdarwin
brew install --cask brucechanjianle/hyprdarwin/hyprdarwin
```

Upgrade with `brew upgrade --cask hyprdarwin`. On first launch, grant Accessibility in System Settings > Privacy & Security > Accessibility.

## nix-darwin (nix-homebrew)

```nix
homebrew = {
  taps = [ "brucechanjianle/hyprdarwin" ];
  casks = [ "brucechanjianle/hyprdarwin/hyprdarwin" ];
};

# Homebrew refuses to load casks from non-official taps until trusted.
nix-homebrew.trust.casks = [ "brucechanjianle/hyprdarwin/hyprdarwin" ];
```
