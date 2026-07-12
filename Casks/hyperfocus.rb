cask "hyperfocus" do
  version "1.0.0"

  url "https://github.com/user/hyperfocus/releases/download/v#{version}/Hyperfocus-#{version}.dmg",
      verified: "github.com/user/hyperfocus/"
  sha256 :no_check

  # The app self-updates via Sparkle; the SUAppcast feed is published on the
  # landing page. `auto_updates` tells Homebrew not to manage updates itself.
  # Drop the `appcast` line if/when submitting to homebrew-core (deprecated stanza).
  appcast "https://hyperfocus.app/appcast.xml"
  auto_updates true

  name "Hyperfocus"
  desc "Blur and desaturate background windows so only the active window stays sharp"
  homepage "https://hyperfocus.app/"

  depends_on macos: ">= :monterey"

  app "Hyperfocus.app"

  zap trash: [
    "~/Library/Preferences/com.hyperfocus.app.plist",
    "~/Library/Application Support/Hyperfocus",
    "~/Library/Application Support/com.hyperfocus.app",
    "~/Library/Caches/com.hyperfocus.app",
    "~/Library/HTTPStorages/com.hyperfocus.app",
    "~/Library/Saved Application State/com.hyperfocus.app.savedState",
  ]
end
