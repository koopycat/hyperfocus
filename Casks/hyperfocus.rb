cask "hyperfocus" do
  version "1.0.0"

  url "https://github.com/koopycat/hyperfocus/releases/download/v#{version}/Hyperfocus-#{version}.dmg",
      verified: "github.com/koopycat/hyperfocus/"
  sha256 "c9593df1feae26d14e988b06d965e5b117c6cb60dc0b3c9b31d0f97737224861"

  name "Hyperfocus"
  desc "Blur and desaturate background windows so only the active window stays sharp"
  homepage "https://koopycat.github.io/hyperfocus/"

  depends_on macos: :monterey

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
