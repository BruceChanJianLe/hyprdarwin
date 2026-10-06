# Template for Casks/hyprdarwin.rb in BruceChanJianLe/homebrew-hyprdarwin.
# .github/workflows/release.yml fills in @VERSION@ and @SHA256@ with
# scripts/render-cask.sh and commits the result to the tap; do not edit the
# tap's copy by hand.
cask "hyprdarwin" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/BruceChanJianLe/hyprdarwin/releases/download/v#{version}/hyprdarwin-#{version}.zip"
  name "hyprdarwin"
  desc "Hyprland-inspired tiling window manager configured in Lua"
  homepage "https://github.com/BruceChanJianLe/hyprdarwin"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "hyprdarwin.app"

  # Self-signed, not notarized: without this Gatekeeper refuses to open it.
  postflight do
    system_command "/usr/bin/xattr",
                   args:         ["-dr", "com.apple.quarantine", "#{appdir}/hyprdarwin.app"],
                   must_succeed: false
  end

  uninstall quit: "io.github.brucechanjianle.hyprdarwin"

  # The config (~/.config/hypr/hyprdarwin.lua) is the user's own file and is
  # never removed.
  zap trash: [
    "~/Library/Logs/hyprdarwin.log",
    "~/Library/Preferences/io.github.brucechanjianle.hyprdarwin.plist",
  ]

  caveats <<~EOS
    hyprdarwin needs Accessibility permission. On first launch, turn on
    hyprdarwin in System Settings > Privacy & Security > Accessibility.
    Release builds are signed with one stable certificate, so the grant
    survives upgrades.
  EOS
end
