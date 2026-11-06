class Meetings < Formula
  desc "Menu bar app for your next meeting, driven by an ICS calendar subscription"
  homepage "https://github.com/markcipolla/meetings"
  url "https://github.com/markcipolla/meetings/archive/refs/tags/v0.2.3.tar.gz"
  sha256 "5f828c8c6ee1a243a58e7f345dbde2708cb8f96a6c39775233ed8f4119787a16"
  license "MIT"
  head "https://github.com/markcipolla/meetings.git", branch: "main"

  depends_on macos: :sonoma

  def install
    ENV["VERSION"] = version.to_s
    system "./build.sh"
    prefix.install "build/Meetings.app"
  end

  def caveats
    <<~EOS
      Link the app so Spotlight and Login Items can see it, then launch it:
        ln -sfn #{opt_prefix}/Meetings.app /Applications/Meetings.app
        open /Applications/Meetings.app

      It reads whatever is in Calendar.app, so subscribe to your work ICS feed first:
        open "webcal://your-feed.ics"
    EOS
  end

  test do
    system "#{prefix}/Meetings.app/Contents/MacOS/Meetings", "--selftest"
  end
end
