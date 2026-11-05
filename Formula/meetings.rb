class Meetings < Formula
  desc "Menu bar app for your next meeting, driven by an ICS calendar subscription"
  homepage "https://github.com/markcipolla/meetings"
  url "https://github.com/markcipolla/meetings/archive/refs/tags/v0.2.1.tar.gz"
  sha256 "e30546dbf1cef08f3f533f9bc8342edf3cc7122ff542cae92f2b66831cb2b6f7"
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
