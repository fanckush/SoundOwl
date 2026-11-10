# Homebrew Cask for SoundOwl.
#
# This file belongs in the tap repo (fanckush/homebrew-soundowl) at Casks/soundowl.rb, not in
# the main app repo. It is kept here as the source of truth. The Release workflow bumps the copy
# in the tap.
cask "soundowl" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/fanckush/SoundOwl/releases/download/v#{version}/SoundOwl-#{version}.zip"
  name "SoundOwl"
  desc "Makes voice recordings clearer with an on-device speech restoration model"
  homepage "https://fanckush.github.io/SoundOwl/"

  livecheck do
    url :url
    strategy :github_latest
  end

  # The app updates itself through Sparkle, so brew leaves upgrades to it.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "SoundOwl.app"
  binary "#{appdir}/SoundOwl.app/Contents/Resources/soundowl"

  zap trash: [
    "~/Library/Application Support/SoundOwl",
    "~/Library/Caches/app.soundowl.SoundOwl",
    "~/Library/HTTPStorages/app.soundowl.SoundOwl",
    "~/Library/Preferences/app.soundowl.SoundOwl.plist",
  ]
end
