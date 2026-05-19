class Termite < Formula
  desc "WhatsApp your terminal with a small wacli companion"
  homepage "https://github.com/adamzafir/termite"
  url "https://github.com/adamzafir/termite/releases/download/v0.1.0/termite-0.1.0.tar.gz"
  sha256 "b36b95ca3b3d692efb1cbd81a2dec35b51a260c3ff60984b9188f4c91dca386e"
  license "MIT"

  depends_on "jq"
  depends_on "node"
  depends_on "steipete/tap/wacli"
  uses_from_macos "sqlite"

  def install
    bin.install "termite"
    bin.install "termite.sh"
  end

  test do
    system "#{bin}/termite", "--help"
  end
end
