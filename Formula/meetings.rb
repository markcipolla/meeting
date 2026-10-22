class Meetings < Formula
  desc "Menu bar app for your next meeting, driven by an ICS calendar subscription"
  homepage "https://github.com/markcipolla/meeting"
  url "https://github.com/markcipolla/meeting/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "MIT"
  head "https://github.com/markcipolla/meeting.git", branch: "main"

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
